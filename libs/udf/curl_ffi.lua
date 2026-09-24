-- @lib: curl_ffi
-- @category: udf
-- @desc: FFI 版 HTTP 客户端（dlopen libcurl，零 fork、零临时文件）。与 curl CLI 版
--        jev_ask 传输层对拍的产物：同一 URL/body 两种 transport 响应逐字节一致（PoC 留档）。
--        用途：jev_ask 的大批量 per-row 调用（CLI 版每行 fork 一次 curl 进程，FFI 版无此开销）。
-- @source: original（duckdb-luajit 系列）
-- @requires: 系统 libcurl 动态库（WSL Ubuntu 自带 libcurl.so.4；Windows 需 libcurl-x64.dll 或
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--            装 curl 发行版；macOS 自带 libcurl.4.dylib）。**不需要** curl.h 头文件——
--            只 cdef 用到的最小符号集（2026-09-22 实测：无 dev 头、非特权 WSL 也能跑）。
-- ⚠️ 需普通模式（非 trusted）：ffi.load 被 trusted 沙箱禁用（与 linalg/usql 同档）。
--
-- ── 用法 ───────────────────────────────────────────────────────────────
--   install:  SELECT * FROM luajit_module(mode := 'install', sql_name := 'curl_ffi');
--   quick_compile:
--     SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'curl_ffi',
--       source := (SELECT content FROM read_text('/path/to/curl_ffi.lua')));
--   调用（spec = {url, body?, headers? = {k:v,...}, timeout? = 秒, max_size? = 字节}）:
--     SELECT luajit_s('curl_ffi', {url: 'http://127.0.0.1:18090/healthz'});
--     SELECT luajit_s('curl_ffi', {url: '<post_url>', body: '{"state":"..."}',
--                                  headers: {'Content-Type': 'application/json'}});
--   返回值约定（与 jev_ask 一致）：
--     * 成功 → HTTP 200-299：返回响应 body 字符串
--     * 非 2xx → 'error: HTTP <code> from <url>: <body 前 400 字符>'
--     * 失败   → 'error: <curl 错误码> <curl_strerror 消息>'（可见、可 grep、可计数）
--
-- ── 设计纪律 ──────────────────────────────────────────────────────────
--   1. 失败一律返回 error: 字符串，不用 error()（扩展会把 Lua error() 吞成 NULL，见 jev_ask 纪律 2）。
--   2. body 超 max_size（默认 16MB）→ write 回调返回 0 → CURL_WRITE_ERROR(23) → 显形，
--      绝不静默截断（数据完整性优先）。
--   3. **curl_easy_setopt 必须 cast 成非变参类型化指针**（2026-09-22 实测根因）：纯 C 对拍探针
--      逐 setopt 全返回 0 + perform OK，但直接走 cdef 的 `int f(CURL*,int,...)` 变参时 LuaJIT 把
--      裸数字当 double 压栈、Lua 字符串不保证转 const char* → URL 设成垃圾 → perform 报
--      CURL 3 (BAD_FUNCTION_ARGUMENT)。解法：按参数形态分别 cast（str/long/cb 三套签名），
--      ABI 显式、无 varargs 类型猜测。
--   4. 无连接池：curl_easy 每次 init/cleanup。Jev 场景（70-500ms 单次决策）下 fork 开销才是瓶颈，
--      连接复用收益有限；真需要时再升级为 curl_multi 长连接（届时本文件接口不变）。
--   5. **⚠️ 串行 per-row 专用（非并发安全）**：write 回调是模块级单函数 + 模块级状态（_collected 等），
--      同一时刻只能有一个 in-flight 请求。批量跑务必走 **Python loop 逐行参数查询**（skill 实测比
--      SQL table-scan 快 ~190x，且 per-row FFI 本就该串行）。若在 DuckDB 并行扫描（多线程）里调本
--      lib 会竞态 → 回调状态互相踩。curl_ffi 本身**没有**线程锁，别在多线程 UDF 里裸调。

local ffi = require('ffi')  -- 扩展的 Lua state 无全局 ffi（iconv.lua 同款写法，实测）

local function load_lib()
  local names = {
    'libcurl.so.4', 'libcurl.so',             -- Linux (Ubuntu/Debian 实测)
    'libcurl.4.dylib', 'libcurl.dylib',       -- macOS
    'libcurl-x64.dll', 'libcurl.dll',         -- Windows: curl 官方 DLL / 裸名
    'libcurl-4.dll', 'libcurl-openssl-4.dll', -- Windows: Git-for-Windows/MSYS2 命名（2026-09-22 实测主机名）
  }
  for _, n in ipairs(names) do
    local ok, llib = pcall(ffi.load, n)
    if ok then return llib end
  end
  return nil
end

local lib = load_lib()
local curl
local setopt_str  -- int (CURL*, int, const char*)
local setopt_long -- int (CURL*, int, long)
local setopt_cb   -- int (CURL*, int, curl_write_callback)
local setopt_slist-- int (CURL*, int, curl_slist*)
local cdef_done = false
local OPT = {
  -- ⚠️ 这些数值是 **curl.h 的稳定 ABI 常量**（2026-09-22 从 8.5.0 头文件逐一核对，勿再手写猜测）。
  -- 关键点：宏是 `CURLOPT(na,t,nu) na = t + nu`，值 = **类型前缀 + 序号**：
  --   OBJECTPOINT=STRINGPOINT=SLISTPOINT=CBPOINT=10000,  FUNCTIONPOINT=20000,  LONG=0。
  -- 写错会返回 48 (BAD_FUNCTION_ARGUMENT) 而非崩溃；perform 再报 CURL 3（URL 没设上）。
  URL = 10002,          -- STRINGPOINT(10000) + 2
  WRITEDATA = 10001,    -- CBPOINT(10000) + 1（write 回调的 userdata 槽）
  WRITEFUNCTION = 20011,-- FUNCTIONPOINT(20000) + 11
  POSTFIELDS = 10015,   -- OBJECTPOINT(10000) + 15
  HTTPHEADER = 10023,   -- SLISTPOINT(10000) + 23
  POST = 47,            -- LONG(0) + 47
  CONNECTTIMEOUT = 78,  -- LONG(0) + 78
  TIMEOUT = 13,         -- LONG(0) + 13
  NOSIGNAL = 99,        -- LONG(0) + 99：防多线程下 signal 干扰（curl 官方建议）
  Noproxy = 10177,      -- STRINGPOINT(10000) + 177
}
local INFO_RESPONSE_CODE = 0x200002  -- CURLINFO_RESPONSE_CODE = CURLINFO_LONG(0x200000) + 2

local function ensure()
  if curl then return true end
  if not lib then return false end
  if not cdef_done then
    -- pcall 包裹：同一 LuaJIT state 里本模块被 dofile 多次（如测试探针复用）时，
    -- 重复 cdef 同符号会报 attempt to redefine → 忽略，沿用已注册声明（幂等）。
    pcall(ffi.cdef, [[
      typedef struct curl_easy *CURL;
      typedef size_t (*curl_write_callback)(char *ptr, size_t size, size_t nmemb, void *userdata);
      typedef struct curl_slist {
        struct curl_slist *next;
        char *data;
      } curl_slist;
      typedef struct {
        int age;
        const char *version;
      } curl_version_info_data;
      CURL *curl_easy_init(void);
      int  curl_easy_setopt(CURL *curl, int op, ...);
      int  curl_easy_getinfo(CURL *curl, int info, ...);
      long curl_easy_perform(CURL *curl);
      void curl_easy_cleanup(CURL *curl);
      const char *curl_easy_strerror(int curl_err);
      const curl_version_info_data *curl_version_info(int age);
      curl_slist *curl_slist_append(curl_slist *list, const char *data);
      void curl_slist_free_all(curl_slist *list);
    ]])
    -- 变参 → 按参数形态 cast 成显式类型化签名（设计纪律 3 的根因修法）
    setopt_str   = ffi.cast('int (*)(CURL *, int, const char *)', lib.curl_easy_setopt)
    setopt_long  = ffi.cast('int (*)(CURL *, int, long)', lib.curl_easy_setopt)
    setopt_cb    = ffi.cast('int (*)(CURL *, int, curl_write_callback)', lib.curl_easy_setopt)
    setopt_slist = ffi.cast('int (*)(CURL *, int, curl_slist *)', lib.curl_easy_setopt)
    cdef_done = true
  end
  curl = lib
  return true
end

local function err(msg) return 'error: ' .. tostring(msg) end

local function build_headers(t)
  if not t or next(t) == nil then return nil end
  local lines = {}
  for k, v in pairs(t) do
    lines[#lines + 1] = tostring(k) .. ': ' .. tostring(v)
  end
  table.sort(lines) -- 确定性顺序
  local h = nil
  for _, l in ipairs(lines) do
    h = curl.curl_slist_append(h, l)
  end
  return h
end

-- ── 写回调：模块级单函数 + 预 cast 成 C 指针（关键，2026-09-22 实测根因）──────────────
-- 两个坑叠加，缺一不可：
-- (a) 每次调用 `local function on_write` 新建闭包 → 每个不同闭包作为 C 回调都生成新 trampoline；
-- (b) 即便同一模块级函数，**直接传 Lua 函数**给 setopt_cb 仍按调用生成 trampoline（LuaJIT 池有上限）
--     → 批量几百次后 "too many callbacks"（N≤200 不报、N=1000 报 104 次，随调用数增长）。
-- 解法：回调是模块级单函数（读模块级状态），且 **cast 成 C 指针一次**、之后每次传 cdata →
-- 零 trampoline 增长（纯 Lua 1500 次循环实测全过）。状态非并发安全 → 串行 per-row（Python loop）。
local _collected = {}
local _n_bytes = 0
local _oob = false
local _max_size = 16 * 1024 * 1024

local function on_write(ptr, size, nmemb, _ud)
  local total = tonumber(size) * tonumber(nmemb)
  if _oob or _n_bytes + total > _max_size then
    _oob = true
    return 0 -- 触发 CURL_WRITE_ERROR(23)，绝不静默截断
  end
  _collected[#_collected + 1] = ffi.string(ptr, total)
  _n_bytes = _n_bytes + total
  return total
end

-- 关键（2026-09-22 实测）：把回调 **cast 成 C 指针一次**，之后每次 setopt_cb 都传这个 cdata。
-- 直接传 Lua 函数 on_write 会每次生成一个新 trampoline（LuaJIT trampoline 池有上限）→
-- 批量几百次后 "too many callbacks"（N≤200 不报、N=1000 报 104 次）。cast 成 cdata 后
-- 复用同一个 C 入口 = 零 trampoline 增长（纯 Lua 1500 次循环实测全过）。
-- 必须懒计算：cast 依赖 cdef 已声明 curl_write_callback 类型（ensure() 里），不能在模块加载期算。
local on_write_c
local function get_on_write_c()
  if not on_write_c then on_write_c = ffi.cast('curl_write_callback', on_write) end
  return on_write_c
end

local function http_post(spec)
  if not ensure() then
    return nil, 'libcurl not found (need libcurl.so.4 / libcurl.4.dylib / libcurl-x64.dll in loader path)'
  end
  local url = spec.url
  if url == nil or url == '' then return nil, 'empty url' end

  local body = spec.body or ''
  local timeout = spec.timeout or 120
  _max_size = spec.max_size or 16 * 1024 * 1024

  -- 复位模块级回调状态（串行前提下安全）
  _collected = {}
  _n_bytes = 0
  _oob = false

  local handle = curl.curl_easy_init()
  if handle == nil then return nil, 'curl_easy_init failed' end

  local header_list = build_headers(spec.headers)
  local setup_err
  local function setup()
    setopt_str(handle, OPT.URL, url)
    setopt_cb(handle, OPT.WRITEFUNCTION, get_on_write_c())   -- 复用预 cast 的 C 指针 = 零 trampoline 增长
    if body ~= '' then
      setopt_long(handle, OPT.POST, 1)
      setopt_str(handle, OPT.POSTFIELDS, body)
    end
    if header_list then
      setopt_slist(handle, OPT.HTTPHEADER, header_list)
    end
    -- 内网/loopback 免代理（CLI 版 --noproxy '*' 的对应物，WSL 代理环境变量实测会带偏 loopback）
    setopt_str(handle, OPT.Noproxy, '*')
    setopt_long(handle, OPT.NOSIGNAL, 1)
    setopt_long(handle, OPT.CONNECTTIMEOUT, 10)
    setopt_long(handle, OPT.TIMEOUT, timeout)
  end
  local ok_setup, err_setup = pcall(setup)
  if not ok_setup then setup_err = tostring(err_setup) end

  local rc = -1
  if ok_setup then rc = tonumber(curl.curl_easy_perform(handle)) or -1 end

  local code_n = 0
  if ok_setup then
    local getinfo_lptr = ffi.cast('int (*)(CURL *, int, long *)', lib.curl_easy_getinfo)
    local codep = ffi.new('long[1]')
    pcall(getinfo_lptr, handle, INFO_RESPONSE_CODE, codep)
    code_n = tonumber(codep[0]) or 0
  end
  if header_list then pcall(curl.curl_slist_free_all, header_list) end
  pcall(curl.curl_easy_cleanup, handle)

  if not ok_setup then
    return nil, 'lua error during curl setup: ' .. setup_err
  end
  if rc ~= 0 then
    if _oob then
      return nil, string.format('CURL_WRITE_ERROR(23): response exceeded max_size %d bytes', _max_size)
    end
    local msg = ffi.string(curl.curl_easy_strerror(rc))
    return nil, string.format('CURL %d: %s', rc, msg)
  end
  local payload = table.concat(_collected, '')
  if code_n < 200 or code_n >= 300 then
    return nil, string.format('HTTP %d from %s: %s', code_n, url, payload:sub(1, 400))
  end
  return payload
end

local function version()
  if not ensure() then return err('libcurl not found') end
  local d = curl.curl_version_info(0)
  return ffi.string(d.version)
end

-- 暴露 http_post 给同会话的 jev_ask 复用（_G 副作用，init.lua 同款 batch-register 模式）：
-- jev_ask 的 ask() 优先走这里（零 fork），不存在时回退 curl CLI。
_G._curl_ffi_post = http_post

return function(p)
  p = p or {}
  local op = p.op or 'post'
  if op == 'version' then return version() end
  if op == 'post' or op == 'get' then
    local res, e = http_post(p)
    if not res then return err(e) end
    return res
  end
  return err('unknown op `' .. tostring(op) .. '` (post | get | version)')
end
