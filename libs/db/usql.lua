-- @lib: usql
-- @category: db
-- @desc: in-process 数据库 transport：Lua 进程内加载 usql-bridge（Go c-shared，内嵌 xo/usql 的 database/sql 驱动），连接常驻、多次查询无进程冷启。与 dbcli+usql 二进制互补：那条路要用户机器装 usql 二进制、每查询拉进程（30-100ms 冷启）；本库零外部二进制，实测持续查询 ~0.2ms/次（PoC 口径，SQLite）。
-- @source: alitrack/usql-bridge（Go 桥，MIT）+ 本 FFI 桥（original）
-- @requires: luajit FFI 可用（默认非 trusted 模式）；usql-bridge 工件（按平台自动解析，见下）
-- @license: MIT (alitrack/usql-bridge + original)
-- 自包含：spec 用内联极简 JSON 解析（扁平 string+number 对象），不依赖 labs 的 json 库。
--
-- 工件按平台选名（usql-bridge release v0.1.1 起覆盖全平台）：
--   Linux x64   -> usqlbridge-linux-amd64.so
--   Linux arm64 -> usqlbridge-linux-arm64.so
--   macOS arm64 -> usqlbridge-darwin-arm64.dylib
--   macOS x64   -> usqlbridge-darwin-amd64.dylib
--   Windows x64 -> usqlbridge-windows-amd64.dll
--
-- 工件解析顺序（bootstrap）：
--   1. spec 里的 lib 字段（完整路径，显式指定，最高优先）
--   2. 环境变量 USQL_BRIDGE_LIB
--   3. ~/.duckdb/luajit-libs/<平台工件名>（缓存位置，与 install 的 Lua 缓存同目录）
--   4. curl 从 GitHub release 拉取到缓存位置（best-effort，仅 POSIX shell；部分网络到
--      GitHub release CDN 很慢/不通，失败走 ERR 行提示手动下载）
--   手动放置：gh release download v0.1.1 --repo alitrack/usql-bridge 后放到第 3 处。
--
-- 形态：表函数（luajit_table）。list 参数 = JSON 规格字符串（扁平对象，内联解析）：
--   {"op":"connect","url":"moderncsqlite:////tmp/x.db"}   -- 连接，返回一行（id=N 或 ERR: ...）
--   {"op":"query","id":1,"sql":"SELECT 1 AS a"}            -- 查询，每行 = 一个 JSON 对象
--   {"op":"export","id":1,"sql":"SELECT ...","format":"parquet",
--    "path":"<可选>","compression":"snappy|none"}           -- 列式导出，返回 Parquet 文件路径
--   {"op":"exec","id":1,"sql":"INSERT INTO t VALUES (1)"}  -- 写，返回 OK rows=N
--   {"op":"close","id":1}                                  -- 关闭
--   {"op":"benchmark","id":1,"n":100,"sql":"SELECT 1"}     -- 持续查询基准
-- 连接 id 在同一 DuckDB 进程内跨调用持久（Go 侧 map[int]*sql.DB，Ping 冷启前置到 connect）。
-- 错误行：'ERR: <reason>'。
--
-- export（v0.2.0 起）：走列式，不走 JSON。JSON 只有 number/string/bool/null，类型得靠
-- DuckDB 侧 from_json 推断（DATE/DATETIME→VARCHAR、BOOLEAN→整数、DECIMAL→DOUBLE），
-- 且文本化会把 BLOB 的非 UTF-8 字节变成 U+FFFD（不可逆）。export 按 driver 声明的类型
-- 建 Parquet schema，字节和类型原样过，DuckDB 侧 read_parquet 零解析：
--   SELECT * FROM read_parquet(luajit_vs('usql', '{"op":"export","id":1,"sql":"SELECT ..."}'));
-- 10 万行 x 10 列实测：导出 11ms / 6.9MB（JSON 路径同数据 267ms / 18.6MB）。
-- 不写 path 时落系统临时目录，连接 close 时自动清理；写了 path 就不动它。
-- 注意：export 的返回值是文件路径，不做 escrow（路径必须原样）。
--
-- scheme（usql 驱动注册名）：moderncsqlite（纯 Go SQLite，当前 release 默认）；
-- 需要 postgres/mysql 等：在 usql-bridge 的 main.go import 对应 drivers/<scheme> 后重新发布 .so。
-- DSN 形如 <scheme>://<连接参数>（同 usql CLI 的 URL 语法，github.com/xo/dburl）。
--
-- 注意：
--   * 写外部库不受 DuckDB 侧 read_only/production 保护（SQL 直接交给目标库执行），写权限自己负责。
--   * 与 dbcli 的边界：dbcli=通用本机 CLI 总线（任意客户端、每查询子进程）；本库=进程内常驻连接（快，驱动编译期决定）。

local ffi = require('ffi')

ffi.cdef[[
  extern char* usql_connect(const char* url);
  extern char* usql_query(int id, const char* query);
  extern char* usql_exec(int id, const char* query);
  extern char* usql_export(const char* spec);
  extern int   usql_close(int id);
  extern void free(void* ptr);
]]

local REL_TAG = 'v0.2.0'
local IS_WIN = (jit and jit.os == 'Windows')

-- 平台 -> 工件名。LuaJIT 的 jit.os: Linux / OSX / Windows；jit.arch: x64 / arm64。
local function artifact_name()
  local osname = (jit and jit.os) or 'Linux'
  local arch = (jit and jit.arch) or 'x64'
  local a = (arch == 'arm64') and 'arm64' or 'amd64'
  if osname == 'Windows' then return 'usqlbridge-windows-' .. a .. '.dll' end
  if osname == 'OSX' or osname == 'macOS' then return 'usqlbridge-darwin-' .. a .. '.dylib' end
  return 'usqlbridge-linux-' .. a .. '.so'
end

local ARTIFACT = artifact_name()
-- 下载基址可覆盖（镜像/自建源，也用于离线验证下载链路）：USQL_BRIDGE_BASE_URL 需带结尾 /
local REL_BASE = os.getenv('USQL_BRIDGE_BASE_URL')
  or ('https://github.com/alitrack/usql-bridge/releases/download/' .. REL_TAG .. '/')
local REL = REL_BASE .. ARTIFACT

-- 极简 JSON 解析：只认扁平对象 {"k":"str","n":123}（string 值 + 数字值），
-- 够 usql 的 spec 用，避免引入 labs json 库依赖（保持单文件自包含）。
local function parse_spec(s)
  s = s:match('^%s*(.-)%s*$')
  if s:sub(1, 1) ~= '{' or s:sub(-1) ~= '}' then
    return nil, 'spec must be a flat JSON object {..}'
  end
  local t = {}
  local pos = 2 -- 跳过开头的 '{'
  while true do
    -- 跳过空白和逗号，定位下一个键的起始
    local j = s:find('[^%s,]', pos)
    if not j then break end
    -- 读键 "key"
    local kstart = s:find('"', j)
    local kend = kstart and s:find('"', kstart + 1)
    if not kstart or not kend then break end
    local key = s:sub(kstart + 1, kend - 1)
    -- 期望 ':'
    local colon = s:find(':', kend + 1)
    if not colon then return nil, 'expected : after key "' .. key .. '"' end
    -- 读值
    pos = colon + 1
    local vstart = s:find('[%S]', pos)
    if not vstart then return nil, 'missing value for key "' .. key .. '"' end
    if s:sub(vstart, vstart) == '"' then
      -- 字符串值：取到下一个未转义的 "（spec 里值不含引号转义，直接找下一个 "）
      local vend = s:find('"', vstart + 1)
      if not vend then return nil, 'unterminated string for key "' .. key .. '"' end
      t[key] = s:sub(vstart + 1, vend - 1)
      pos = vend + 1
    else
      -- 数字 / true / false / null
      local lit = s:match('[%w%-]+', vstart)
      if not lit then return nil, 'bad value for key "' .. key .. '": ' .. s:sub(vstart, vstart + 20) end
      t[key] = (tonumber(lit) or lit)
      pos = vstart + #lit
    end
  end
  return t
end

local function home()
  return os.getenv('HOME') or os.getenv('USERPROFILE') or '/tmp'
end

local function cache_dir()
  return home() .. '/.duckdb/luajit-libs'
end

local function cache_path()
  return cache_dir() .. '/' .. ARTIFACT
end

local function ensure_dir(p)
  local cmd = IS_WIN and ('if not exist "' .. p .. '" mkdir "' .. p .. '"') or ('mkdir -p ' .. p)
  local r = io.popen(cmd, 'r')
  if r then r:read('a') r:close() end
end

-- 工件头魔数校验：CDN 会静默截断（实测 GitHub release CDN 慢时只落地一半，
-- dlopen 半截文件直接失败）。按平台认前 4 字节，截断文件一律当没下成。
local function magic_ok(path)
  local f = io.open(path, 'rb')
  if not f then return false end
  local head = f:read(4)
  f:close()
  if not head or #head < 4 then return false end
  local b1, b2, b3, b4 = head:byte(1, 4)
  if IS_WIN then                                               -- PE: MZ
    return b1 == 0x4D and b2 == 0x5A
  end
  if jit and jit.os == 'OSX' then                              -- Mach-O 64 LE / fat
    return (b1 == 0xCF and b2 == 0xFA and b3 == 0xED and b4 == 0xFE)
        or (b1 == 0xCA and b2 == 0xFE and b3 == 0xBA and b4 == 0xBE)
  end
  return b1 == 0x7F and b2 == 0x45 and b3 == 0x4C and b4 == 0x46 -- ELF
end

-- 自动下载只在 POSIX shell 下做（依赖 rm/curl）；Windows 上跳过，走手动放置，
-- 失败时的 ERR 行会给出 gh 下载命令和目标目录。
local function download(url, dest)
  if IS_WIN then return false end
  io.popen('rm -f ' .. dest, 'w')
  local r = io.popen('curl -sL --max-time 600 -o ' .. dest .. ' ' .. url .. ' 2>/dev/null', 'r')
  if r then r:read('a') r:close() end
  local f = io.open(dest, 'rb')
  if not f then return false end
  local n = #f:read('a')
  f:close()
  if n < 4000000 or not magic_ok(dest) then -- 真实工件 10MB 量级；小了或头不对 = 没拉全
    os.remove(dest)
    return false
  end
  return true
end

local lib = nil
local libpath = nil

local function loadlib(spec_lib)
  if lib then return lib end
  local candidates = {}
  if spec_lib and spec_lib ~= '' then candidates[#candidates + 1] = spec_lib end
  local env = os.getenv('USQL_BRIDGE_LIB')
  if env and env ~= '' then candidates[#candidates + 1] = env end
  candidates[#candidates + 1] = cache_path()

  local p
  for i = 1, #candidates do
    local f = io.open(candidates[i], 'rb')
    if f then
      f:close()
      -- 显式指定的路径（spec.lib / 环境变量）信任调用方，交给 ffi.load 报错；
      -- 缓存目录里的截断文件当不存在处理并清掉，让下面重新下载。
      if candidates[i] == cache_path() and not magic_ok(candidates[i]) then
        os.remove(candidates[i])
      else
        p = candidates[i]
        break
      end
    end
  end

  if not p then
    ensure_dir(cache_dir())
    if download(REL, cache_path()) then
      p = cache_path()
    else
      return nil, 'cannot load ' .. ARTIFACT .. ': not in ' .. table.concat(candidates, ', ')
        .. ' and auto-download failed (GitHub release CDN slow/unreachable?).'
        .. ' Manual: gh release download ' .. REL_TAG .. ' --repo alitrack/usql-bridge'
        .. ', place at ' .. cache_path()
    end
  end

  local ok, llib = pcall(ffi.load, p)
  if not ok then
    return nil, 'ffi.load failed for ' .. p .. ': ' .. tostring(llib)
  end
  lib, libpath = llib, p
  return llib
end

local function free_ret(cstr)
  local s = ffi.string(cstr)
  ffi.C.free(cstr)
  return s
end

local function escrow(s)
  return (s:gsub('|', '¦'):gsub('\n', ' '))
end

local function run(t, raw)
  local okl, lerr = loadlib(t.lib)
  if not okl then return { 'ERR: ' .. lerr } end
  lib = okl

  local op = t.op or 'query'
  if op == 'connect' then
    if not t.url then return { 'ERR: connect needs url' } end
    return { escrow(free_ret(lib.usql_connect(t.url))) }
  elseif op == 'close' then
    if not t.id then return { 'ERR: close needs id' } end
    return { 'closed=' .. tostring(lib.usql_close(t.id)) }
  elseif op == 'export' then
    if not t.id then return { 'ERR: export needs id (call connect first)' } end
    if not t.sql then return { 'ERR: export needs sql' } end
    -- 整个 spec 原样交给 Go 侧解析（路径里的转义交给 encoding/json，Lua 侧不碰）；
    -- 返回值是文件路径，必须原样——不能 escrow。
    return { free_ret(lib.usql_export(raw)) }
  elseif op == 'exec' or op == 'query' or op == 'benchmark' then
    if not t.id then return { 'ERR: ' .. op .. ' needs id (call connect first)' } end
    if not t.sql then return { 'ERR: ' .. op .. ' needs sql' } end
    if op == 'exec' then
      return { escrow(free_ret(lib.usql_exec(t.id, t.sql))) }
    elseif op == 'benchmark' then
      local n = tonumber(t.n) or 100
      local r0 = free_ret(lib.usql_query(t.id, t.sql))
      local t0 = os.clock()
      for i = 1, n do free_ret(lib.usql_query(t.id, t.sql)) end
      local t1 = os.clock()
      return { string.format('first=%s then %d queries in %.1fms (%.3f ms/each)',
        escrow(r0), n, (t1 - t0) * 1000, (t1 - t0) * 1000 / n) }
    else
      return { escrow(free_ret(lib.usql_query(t.id, t.sql))) }
    end
  end
  return { 'ERR: unknown op ' .. tostring(op) }
end

-- 单个 spec -> 单个结果字符串（批形态用）。错误也以 'ERR: ...' 文本回。
local function call_one(spec)
  if not spec or spec == '' then
    return 'ERR: usql needs a JSON spec in list (op/url/id/sql, see @desc)'
  end
  local ok, t = pcall(parse_spec, spec)
  if not ok or type(t) ~= 'table' or not next(t) then
    return 'ERR: bad JSON spec: ' .. escrow(tostring(t))
  end
  local out = run(t, spec)
  return out[1] or ''
end

-- 调用形态（同一个库文件两种入口）：
--   luajit_table('usql', list := '<spec>')  -> 传进来是**字符串**：返回行表（每行一列）
--   luajit_vs('usql', '<spec>') / usql('<spec>') 宏 -> 传进来是**表** {s1..sn}（按 chunk 批）：
--                                              要返回同长度的字符串表
-- 我们每行只有一列，两种形态的结果形状一致（一个字符串数组）。
return function(list)
  if type(list) == 'table' then
    local out = {}
    for i = 1, #list do out[i] = call_one(list[i]) end
    return out
  end
  if not list or list == '' then
    return { 'ERR: usql needs a JSON spec in list (op/url/id/sql, see @desc)' }
  end
  local ok, t = pcall(parse_spec, list)
  if not ok or type(t) ~= 'table' or not next(t) then
    return { 'ERR: bad JSON spec: ' .. escrow(tostring(t)) }
  end
  return run(t, list)
end
