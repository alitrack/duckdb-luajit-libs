-- @lib: dbcli
-- @category: db
-- @desc: 通用"本机客户端"数据库 transport——Lua 调本机 DB CLI（sqlite3/psql/mysql/redis-cli/任意），把输出转成表函数行。duckdb_universal 的长尾 transport 总线：新增数据库支持 = 本机装好 CLI + 一条 SQL，无需重编 Rust 扩展。
-- @source: original（duckdb-luajit 系列）
-- @requires: 本机已安装对应 CLI；io.popen 可用（默认非 trusted 模式）
-- @license: MIT (duckdb-luajit-libs project)
--
-- 形态：表函数（luajit_table）。list 参数 = JSON 规格字符串：
--   {"client":"sqlite3","args":["-json","/tmp/x.db"],"sql":"SELECT 1 AS a","kind":"json"}
--   {"client":"psql","args":["-X","-A","-F","\t","-t","-v","ON_ERROR_STOP=1","-h","host","-p","5432","-U","user","db"],"sql":"SELECT 1","kind":"tsv"}
--   {"client":"redis-cli","args":["-h","host","-p","6379"],"sql":"GET foo","kind":"raw"}
--   {"client":"sqlite3","args":["/tmp/x.db"],"sql":"PRAGMA table_info(t)","op":"exec"}
--
-- 字段：
--   client  可执行文件名（sqlite3/psql/mysql/redis-cli/usql/任意）
--   args    参数数组（或空格分隔字符串）。usql: 放 -q -J 等开关 + DSN，如
--           ["-q","-J","sqlite3:///path/to/x.db"]（DSN 是最后一个位置参数）
--   sql     要执行的语句（走 stdin 临时文件；usql 会自动补尾分号）
--   kind    json（默认：解析为数组，每个对象一行，原样输出）| tsv（每个 tab 行一行）| raw（每个输出行一行）
--   op      query（默认）| exec（只取最后一行/计数）| ping（只验证客户端可执行）
--
-- usql（https://github.com/xo/usql，`-tags most` 构建）一条 client 覆盖 40+ 种数据库（drivers/ 45 目录，含同库多绑定；SQL 库，不含 redis/mongo）：
--   sqlite3/postgres/mysql/clickhouse/snowflake/bigquery/databricks/
--   cassandra/couchbase/cosmos/dynamodb/firebird/ignite/maxcompute/mssql/oracle/
--   presto/trino/vertica/h2/voltdb/ydb/... 详见 usql drivers/ 目录。
--   用法：client="usql", args=["-q","-J","<scheme>://<dsn>"]。
--   注意：usql sqlite3 DSN 会自动创建空库（查"不存在"的库不会报错，会建 0 字节文件）。
--
-- 输出行：单列行（表函数 row_idx|val 中的 val）。json kind 下行 = 客户端输出的 JSON 对象字符串
--（SQL 侧可用 json 库或 regexp 提取）；tsv/raw kind 下行 = 原始文本（'|' 已转义为 '¦'）。
-- 错误行：'ERR: <reason>'。

local function J()
  local m = dofile('/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/json.lua')
  return m
end

local function shq(s)
  -- POSIX shell single-quote escaping (io.popen runs through sh -c):
  -- wrap in ' and turn each embedded ' into '\'
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function escrow(s)
  return (s:gsub('|', '¦'):gsub('\n', ' '))
end

local function run_read(cmd)
  local f = assert(io.popen(cmd, 'r'))
  local out = f:read('a') or ''
  f:close()
  return out
end

local function run_write(cmd, stdin)
  local f = assert(io.popen(cmd, 'w'))
  f:write(stdin)
  f:close()
end

local function parse_spec(s)
  local ok, t = pcall(J().decode, s)
  if not ok then
    return nil, 'bad JSON spec: ' .. tostring(t)
  end
  if type(t) ~= 'table' then
    return nil, 'spec must be a JSON object'
  end
  return t
end

local function build_cmd(t)
  local client = t.client
  if not client then
    return nil, 'missing client'
  end
  if not client:match('^[%w%.%-_%/]+$') then
    return nil, 'client name contains unsafe characters'
  end
  local parts = { shq(client) }
  local args = t.args
  if type(args) == 'table' then
    for i = 1, #args do
      local a = tostring(args[i])
      if a:find('%z') then return nil, 'arg contains NUL' end
      parts[#parts + 1] = shq(a)
    end
  elseif type(args) == 'string' and args ~= '' then
    for w in args:gmatch('%S+') do
      parts[#parts + 1] = shq(w)
    end
  end
  local cmd = table.concat(parts, ' ')
  return cmd
end

local function query(t)
  local cmd, berr = build_cmd(t)
  if not cmd then return nil, berr end

  local kind = t.kind or 'json'
  local op = t.op or 'query'
  if op == 'ping' then
    local out = run_read(cmd .. ' --version 2>&1')
    local first = out:match('^[^\n]*')
    return { escrow(first) }
  end

  local out
  -- ALL clients feed SQL via a temp stdin file: keeps SQL bytes out of the
  -- command line entirely (no shell/SQL double-escaping, safe for quotes,
  -- newlines, CJK, and very long statements).
  if not t.sql then
    return nil, 'need sql for client ' .. t.client
  end
  local tmp = '/tmp/dbcli_stdin_' .. tostring(os.time()) .. '_' .. math.random(100000, 999999) .. '.sql'
  local w = io.open(tmp, 'w')
  if not w then
    return nil, 'cannot write stdin tmp file ' .. tmp
  end
  -- usql quirk: statements fed via stdin MUST be terminated with ';'
  -- otherwise it silently returns empty output (-c form does not need this).
  -- Match by basename (client may be a full path like /opt/bin/usql_most).
  local client_base = t.client:match('[^/\\]+$') or ''
  local is_usql = client_base:match('^usql') ~= nil
  local sql_text = t.sql
  if is_usql and not sql_text:match('%;%s*$') then
    sql_text = sql_text .. ';'
  end
  w:write(sql_text)
  w:close()
  out = run_read(cmd .. ' < ' .. tmp .. ' 2>&1')
  os.remove(tmp)

  local rows = {}
  if op == 'exec' then
    local last = out:match('([^\n]*)\n?$')
    return { escrow(last or '') }
  end

  if kind == 'json' then
    local s = out:match('^%s*(.-)%s*$')
    if s == '' then
      return { '[]' }
    end
    local ok, parsed = pcall(J().decode, s)
    if not ok then
      return { 'ERR: client output not JSON: ' .. escrow(s:sub(1, 300)) }
    end
    if type(parsed) ~= 'table' then
      return { escrow(s) }
    end
    for i = 1, #parsed do
      local item = parsed[i]
      if type(item) == 'table' then
        rows[#rows + 1] = escrow(J().encode(item))
      else
        rows[#rows + 1] = escrow(tostring(item))
      end
    end
    if #rows == 0 and next(parsed) then
      rows[1] = escrow(s)
    end
    return rows
  elseif kind == 'tsv' or kind == 'raw' then
    for line in (out .. '\n'):gmatch('(.-)\n') do
      if line ~= '' then
        rows[#rows + 1] = escrow(line)
      end
    end
    return rows
  end
  return { 'ERR: unknown kind ' .. tostring(kind) }
end

return function(list)
  if not list or list == '' then
    return { 'ERR: dbcli needs a JSON spec in list (see @desc)' }
  end
  local t, perr = parse_spec(list)
  if not t then
    return { 'ERR: ' .. perr }
  end
  local rows, err = query(t)
  if not rows then
    return { 'ERR: ' .. tostring(err) }
  end
  return rows
end
