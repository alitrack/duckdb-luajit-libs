-- @lib: usql
-- @category: db
-- @desc: in-process 数据库 transport：Lua 进程内加载 usql-bridge（Go c-shared，内嵌 xo/usql 的 database/sql 驱动），连接常驻、多次查询无进程冷启。与 dbcli+usql 二进制互补：那条路要用户机器装 usql 二进制、每查询拉进程（30-100ms 冷启）；本库零外部二进制，实测持续查询 ~0.2ms/次（PoC 口径，SQLite）。
-- @source: alitrack/usql-bridge（Go 桥，MIT）+ 本 FFI 桥（original）
-- @requires: luajit FFI 可用（默认非 trusted 模式）；usqlbridge-linux-amd64.so（自动解析，见下）
-- 自包含：spec 用内联极简 JSON 解析（扁平 string+number 对象），不依赖 labs 的 json 库。
--
-- .so 解析顺序（bootstrap）：
--   1. spec 里的 lib 字段（完整路径，显式指定，最高优先）
--   2. 环境变量 USQL_BRIDGE_LIB
--   3. ~/.duckdb/luajit-libs/usqlbridge-linux-amd64.so（缓存位置，与 install 的 Lua 缓存同目录）
--   4. curl 从 GitHub release 拉取到缓存位置（best-effort；部分网络到 GitHub release CDN 很慢/不通，失败走 ERR 行提示手动下载）
--   手动放置：gh release download v0.1.0 --repo alitrack/usql-bridge 后放到第 3 处。
--
-- 形态：表函数（luajit_table）。list 参数 = JSON 规格字符串（扁平对象，内联解析）：
--   {"op":"connect","url":"moderncsqlite:////tmp/x.db"}   -- 连接，返回一行（id=N 或 ERR: ...）
--   {"op":"query","id":1,"sql":"SELECT 1 AS a"}            -- 查询，每行 = 一个 JSON 对象
--   {"op":"exec","id":1,"sql":"INSERT INTO t VALUES (1)"}  -- 写，返回 OK rows=N
--   {"op":"close","id":1}                                  -- 关闭
--   {"op":"benchmark","id":1,"n":100,"sql":"SELECT 1"}     -- 持续查询基准
-- 连接 id 在同一 DuckDB 进程内跨调用持久（Go 侧 map[int]*sql.DB，Ping 冷启前置到 connect）。
-- 错误行：'ERR: <reason>'。
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
  extern int   usql_close(int id);
  extern void free(void* ptr);
]]

local ARTIFACT = 'usqlbridge-linux-amd64.so'
local REL = 'https://github.com/alitrack/usql-bridge/releases/download/v0.1.0/' .. ARTIFACT

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
  local r = io.popen('mkdir -p ' .. p, 'r')
  if r then r:read('a') r:close() end
end

local function download(url, dest)
  io.popen('rm -f ' .. dest, 'w')
  local r = io.popen('curl -sL --max-time 600 -o ' .. dest .. ' ' .. url .. ' 2>/dev/null', 'r')
  if r then r:read('a') r:close() end
  local f = io.open(dest, 'rb')
  if not f then return false end
  local n = #f:read('a')
  f:close()
  if n < 1000000 then -- 工件 15MB 量级；小于 1MB = 没拉全（CDN 截断）
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
    if f then f:close() p = candidates[i] break end
  end

  if not p then
    ensure_dir(cache_dir())
    if download(REL, cache_path()) then
      p = cache_path()
    else
      return nil, 'cannot load ' .. ARTIFACT .. ': not in ' .. table.concat(candidates, ', ')
        .. ' and auto-download failed (GitHub release CDN slow/unreachable?).'
        .. ' Manual: gh release download v0.1.0 --repo alitrack/usql-bridge'
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

local function run(t)
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

return function(list)
  if not list or list == '' then
    return { 'ERR: usql needs a JSON spec in list (op/url/id/sql, see @desc)' }
  end
  local ok, t = pcall(parse_spec, list)
  if not ok or type(t) ~= 'table' or not next(t) then
    return { 'ERR: bad JSON spec: ' .. escrow(tostring(t)) }
  end
  return run(t)
end
