-- @lib: rbac
-- @category: security
-- @desc: Quack RBAC 策略引擎 v4（演示策略）——protected = secret_data / public_data / other_data；
--        全目录 default-deny + 视图→基表展开 + RBAC 元数据恒拒 + 函数/文件函数黑名单。挂 quack authn/authz 钩子。
-- @source: original（duckdb-luajit 系列）
-- @requires: _duckdb_query（普通模式；trusted 沙箱下不可用）
--
-- 与 rbac_mimic.lua【同一引擎、逐字节同体】（`local CONFIG` 块之后的引擎主体必须保持一致，
-- 差异仅限 protected 清单与头部注释）——tests/verify_rbac.py 有引擎同体性断言，漂移即红。
-- 安全模型说明、v3/v4 修复项、已知残留（字面量误拒）—— 全部见 rbac_mimic.lua 头部注释。
--
-- 重要：v2 的"sample 未把元数据表列入 protected → 可 dump quack_tokens"漏洞
-- 在 v3 中由 META_TABLES 恒拒结构性修复，与 protected 清单无关。
--
-- 表模型 / 挂钩 / 调用：同 rbac_mimic.lua。

local CONFIG = {
  tokens_table   = 'quack_tokens',
  sessions_table = 'quack_sessions',
  roles_table    = 'user_roles',
  perms_table    = 'role_perms',
  -- 演示受控表：secret_data(机密) / public_data(公开) / other_data(未授权演示表，验证 default-deny)
  protected      = { 'secret_data', 'public_data', 'other_data' },
  allow_write    = false,  -- true = 放行写语句并按 can_write 细粒度授权；false = 一切写语句拒绝（推荐）
  strict_write   = true,   -- true = WITH 开头且含写关键字一律拒绝（合法 CTE 读放行）
  audit_table    = nil,    -- 设 'rbac_audit' 则 authz 每次决策记审计（每查询多一次写，性能敏感慎用）
}

-- RBAC 元数据：恒拒（任何角色不可读写，grant 也不可为其授权）
local META_TABLES = {
  [CONFIG.tokens_table]   = true,
  [CONFIG.sessions_table] = true,
  [CONFIG.roles_table]    = true,
  [CONFIG.perms_table]    = true,
}
-- 系统目录：恒拒（防目录/元数据列举）
local CATALOG_BLOCK = { 'INFORMATION_SCHEMA', 'PG_CATALOG', 'DUCKDB_CATALOG',
                        'SQLITE_MASTER', 'SQLITE_SCHEMA', 'SQLITE_TEMP_MASTER' }
-- 远程查询文本中任意位置出现即拒绝（大小写不敏感）。
-- 以 '_'/' ' 结尾的按前缀匹配（DUCKDB_ 后跟函数名；LOAD 后跟空格）
local BLOCKED_TOKENS = {
  { t = 'LUAJIT_S',     prefix = false },
  { t = 'LUAJIT_QUERY', prefix = false },
  { t = 'LUAJIT_MODULE', prefix = false },
  { t = 'LUAJIT(',      prefix = false },
  { t = 'INSTALL',      prefix = false },
  { t = 'LOAD',         prefix = true  },
  { t = 'ATTACH',       prefix = false },
  { t = 'DETACH',       prefix = false },
  { t = 'PRAGMA',       prefix = false },
  { t = 'SET GLOBAL',   prefix = false },
  { t = 'DUCKDB_',      prefix = true  },
}
-- v4: 文件/外部读取器函数黑名单（词边界、大小写不敏感、文本任意位置）。
-- 这类函数读取表世界之外的文件——P2P 场景即服务器文件系统（原始数据文件、
-- 甚至本策略源码）。此前远程用户可据此读取服务器上任意文件。
local BLOCKED_FILE_FNS = {
  'READ_PARQUET', 'PARQUET_SCAN', 'PARQUET_METADATA', 'PARQUET_FILE',
  'READ_CSV', 'READ_CSV_AUTO', 'CSV_SCAN', 'READ_FITS', 'READ_SAT',
  'READ_NDJSON', 'NDJSON_SCAN', 'READ_JSON', 'READ_JSON_AUTO', 'JSON_SCAN',
  'READ_TEXT', 'READ_BLOB', 'READ_BLOB_LIST',
  'ST_READ', 'ST_WRITE', 'ST_GET', 'ST_COPY', 'ST_ATTACH', 'ST_COLUMNS', 'ST_EXECUTE',
  'SQLITE_SCAN', 'SQLITE_ATTACH', 'SQLITE_TABLE',
  'ICEBERG_SCAN', 'ICEBERG_REST', 'ICEBERG_ATTACH',
  'HTTPFS',
}
-- 强写关键字：出现在"读取"语句文本任意位置即拒绝（堵堆叠语句/副作用）
local MID_WRITE_KWS = { 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'CREATE', 'DROP',
                        'ALTER', 'COPY', 'EXECUTE', 'CALL', 'TRUNCATE' }

local READ_KWS  = { 'SELECT', 'FROM', 'WITH', 'EXPLAIN', 'DESCRIBE', 'SHOW', 'VALUES', 'TABLE', 'SUMMARIZE' }
local WRITE_KWS = { 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'COPY', 'CREATE', 'DROP', 'ALTER', 'SET', 'CALL',
                    'ATTACH', 'DETACH', 'EXPORT', 'IMPORT', 'CHECKPOINT', 'VACUUM', 'COMMENT', 'INSTALL',
                    'LOAD', 'PREPARE', 'EXECUTE', 'USE', 'GRANT', 'REVOKE', 'TRUNCATE' }

local function esc(s)
  return (s:gsub("'", "''"))
end

local function q(rows, i, col)
  return rows and rows[i] and rows[i][col]
end

-- 词边界子串匹配：needle（大写）出现在 hay（大写）中，且 needle 前一位是
-- 行首或非标识符字符；prefix=true 时不检查后界（用于 'DUCKDB_'、'LOAD ' 类前缀）
local function text_has(needle, hay, prefix)
  local i = 1
  while true do
    local s = hay:find(needle, i, true)
    if not s then return false end
    local prev_ok = (s == 1) or (hay:sub(s - 1, s - 1):match('[%w_]') == nil)
    if prev_ok then
      if prefix then return true end
      local e = s + #needle - 1
      local next_ok = (e == #hay) or (hay:sub(e + 1, e + 1):match('[%w_]') == nil)
      if next_ok then return true end
    end
    i = s + 1
  end
end

local function classify(up)
  for _, kw in ipairs(READ_KWS) do
    if up:find('^' .. kw) then return 'read' end
  end
  for _, kw in ipairs(WRITE_KWS) do
    if up:find('^' .. kw) then return 'write' end
  end
  return 'unknown'  -- 未识别前缀：拒绝
end

local function resolve_user(sid)
  local u = _duckdb_query("SELECT user_name FROM " .. CONFIG.sessions_table .. " WHERE sid = '" .. esc(sid or '') .. "'")
  return q(u, 1, 'user_name')
end

local function user_has_perm(user, tbl, need_write)
  local col = need_write and 'can_write' or 'can_select'
  local r = _duckdb_query(
    "SELECT COUNT(*) AS n FROM " .. CONFIG.roles_table .. " ur JOIN " .. CONFIG.perms_table .. " rp ON rp.role = ur.role " ..
    "WHERE ur.user_name = '" .. esc(user) .. "' AND rp.table_name = '" .. esc(tbl) .. "' AND rp." .. col .. " = true")
  return (q(r, 1, 'n') or 0) > 0
end

-- 现存用户对象名（表 + 视图，bare 名，小写）。
-- v4 修复：v3 用 `table_schema`（1.5.x/2.0 实际列名是 `schema_name`）+ `duckdb_views().table_name`
-- （实际是 `view_name`）——坏列名让 _duckdb_query 返回 nil（不抛错），全集为空，
-- default-deny 循环空转，只剩 protected 清单 3 道闸。这里改为正确列名，并只排除
-- 系统/临时库（文件库的 database_name = 文件名，内存库 = 'memory'，均保留）。
local function catalog_names()
  local r = _duckdb_query(
    "SELECT table_name FROM duckdb_tables() WHERE database_name NOT IN ('system','temp') AND schema_name NOT IN ('information_schema','pg_catalog') " ..
    "UNION SELECT view_name AS table_name FROM duckdb_views() WHERE database_name NOT IN ('system','temp') AND schema_name NOT IN ('information_schema','pg_catalog')")
  local set = {}
  for i = 1, (r and #r or 0) do
    local n = r[i]['table_name']
    if n then set[n:lower()] = true end
  end
  return set
end

-- 用户视图名(小写) -> 定义 SQL（供"视图包表"展开；排除系统/临时库）。
local function view_sqls()
  local r = _duckdb_query(
    "SELECT view_name, sql FROM duckdb_views() WHERE database_name NOT IN ('system','temp') AND schema_name NOT IN ('information_schema','pg_catalog')")
  local m = {}
  for i = 1, (r and #r or 0) do
    local n = r[i]['view_name']
    if n then m[n:lower()] = r[i]['sql'] or '' end
  end
  return m
end

-- sql 文本（任意大小写）中引用的 catalog 对象名（词边界、大小写不敏感）→ set。
local function objects_referenced(sqltext, cat)
  local up = string.upper(sqltext or '')
  local found = {}
  for bare in pairs(cat) do
    if text_has(bare:upper(), up) then found[bare] = true end
  end
  return found
end

-- 对象 name（小写，可为表或视图）传递包裹的【基表】集合（小写）。
--   表      -> {name}
--   视图    -> 其 SQL 引用的对象各自的基表之并（传递；环安全）。
-- 只返回 catalog 内已知对象；纯常量视图/纯视图环 -> 空集（不泄漏数据）。
local function base_tables(name, cat, vsql, memo, inprog)
  name = name:lower()
  if memo[name] then return memo[name] end
  if inprog[name] then return {} end
  inprog[name] = true
  local set
  if vsql[name] then
    set = {}
    for ref in pairs(objects_referenced(vsql[name], cat)) do
      if ref ~= name then
        for b in pairs(base_tables(ref, cat, vsql, memo, inprog)) do set[b] = true end
      end
    end
  else
    set = { [name] = true }
  end
  inprog[name] = nil
  memo[name] = set
  return set
end

local function authn(p)
  local sid = p.sid or ''
  -- sid 形态校验：非空、限长、仅安全字符（防垃圾会话写入/注入）
  if sid == '' or #sid > 128 or not sid:match('^[%w%._%-/]+$') then return false end
  local rows = _duckdb_query(
    "SELECT user_name FROM " .. CONFIG.tokens_table .. " WHERE auth_token = '" .. esc(p.client_token or '') .. "'")
  local user = q(rows, 1, 'user_name')
  if not user then return false end
  -- 已有会话映射不被覆盖（防以新 token 顶掉受害者 sid）
  _duckdb_query(
    "INSERT INTO " .. CONFIG.sessions_table .. " " ..
    "SELECT '" .. esc(sid) .. "' AS sid, '" .. esc(user) .. "' AS user_name " ..
    "WHERE NOT EXISTS (SELECT 1 FROM " .. CONFIG.sessions_table .. " WHERE sid = '" .. esc(sid) .. "')")
  return true
end

local function authz(p)
  local query = p.q or ''
  local up = string.upper(query)
  up = up:gsub('^%s+', ''):gsub('%s+$', '')
  if up == '' then return false end
  -- 0) quack client ATTACH handshake catalog discovery (exact shapes) → allow.
  -- Without this the v3 default-deny kills the client own schema listing
  -- (information_schema.schemata 2-col + duckdb_tables UNION duckdb_views)
  -- and every ATTACH fails with Authorization failed.
  local hs1 = up:find("^SELECT CATALOG_NAME, SCHEMA_NAME") and up:find("INFORMATION_SCHEMA%.SCHEMATA")
  local hs2 = up:find("^SELECT SCHEMA_NAME, SQL") and up:find("DUCKDB_TABLES") and up:find("DUCKDB_VIEWS") and up:find("UNION ALL")
  if hs1 or hs2 then return true end

  -- 1) 函数/关键字黑名单：任意位置出现即拒（大小写不敏感）
  for _, bt in ipairs(BLOCKED_TOKENS) do
    if text_has(bt.t, up, bt.prefix) then
      return false
    end
  end
  for _, cb in ipairs(CATALOG_BLOCK) do
    if text_has(cb, up) then return false end
  end
  -- 1b) v4: 文件/外部读取器函数 → 拒（读取表世界之外的文件 = 读服务器文件系统）
  for _, fn in ipairs(BLOCKED_FILE_FNS) do
    if text_has(fn, up) then return false end
  end

  local kind = classify(up)
  if kind == 'unknown' then return false end

  -- 2) 读取语句文本中再出现强写关键字 → 拒（堵堆叠语句 / "SELECT ..; INSERT .."）
  if kind == 'read' then
    for _, kw in ipairs(MID_WRITE_KWS) do
      if text_has(kw, up) then return false end
    end
    -- EXPLAIN 含写关键字或 ANALYZE → 拒（堵 EXPLAIN ANALYZE <write> 执行副作用）
    if up:find('^EXPLAIN') and (text_has('ANALYZE', up) or text_has('INSERT', up) or text_has('UPDATE', up)
        or text_has('DELETE', up) or text_has('MERGE', up) or text_has('CREATE', up) or text_has('DROP', up)) then
      return false
    end
    -- 3) strict_write：WITH 开头且文本含写关键字 → 拒（合法 CTE 读放行）
    if CONFIG.strict_write and up:find('^WITH') then
      for _, kw in ipairs(MID_WRITE_KWS) do
        if text_has(kw, up) then return false end
      end
    end
  end

  local user = resolve_user(p.sid)
  if not user then return false end

  local need_write = (kind == 'write')
  if need_write and not CONFIG.allow_write then return false end

  -- 4) RBAC 元数据恒拒（防 token dump / 权限表读取）
  for name in pairs(META_TABLES) do
    if text_has(name:upper(), up) then return false end
  end

  -- 5) 全目录 default-deny（v4）：查询引用的每个 catalog 对象，展开其【传递包裹的
  --    基表】，每个基表都必须有授权。表→自身；视图→其 SQL 引用的对象之基表并集。
  --    视图不再是"免费通道"：读包了 secret_data 的视图，等价于要求 secret_data 授权
  --    （fail-closed）。v3 的坏列名让此循环空转（全集为空），此处以正确列名复活它。
  local cat = catalog_names()
  local vsql = view_sqls()
  local memo = {}
  local inprog = {}
  for bare in pairs(cat) do
    if text_has(bare:upper(), up) then
      for b in pairs(base_tables(bare, cat, vsql, memo, inprog)) do
        if not user_has_perm(user, b, need_write) then return false end
      end
    end
  end
  -- 防御：protected 清单中（可能尚未建表的）名称同样检查（未建表 → 基表=自身）
  for _, tbl in ipairs(CONFIG.protected) do
    if not cat[tbl:lower()] and text_has(tbl:upper(), up) then
      if not user_has_perm(user, tbl:lower(), need_write) then return false end
    end
  end

  if CONFIG.audit_table then
    _duckdb_query("INSERT INTO " .. CONFIG.audit_table ..
      " VALUES ('" .. esc(p.sid or '') .. "', '" .. esc(user) .. "', '" .. esc(query) .. "', CURRENT_TIMESTAMP)")
  end
  return true
end

-- 管理员操作：仅服务器本地会话执行。远程 SQL 调用 luajit_s 会被 authz 黑名单拒绝。
local function grant(p)
  local role, tbl = (p.role or ''):lower(), (p.tbl or ''):lower()
  if role == '' or tbl == '' then return 'error: role/tbl required' end
  if META_TABLES[tbl] then return 'error: cannot grant RBAC metadata table ' .. tbl end
  local cat = catalog_names()
  if not cat[tbl] then return 'error: table ' .. tbl .. ' not found' end
  local ok, err = pcall(function()
    _duckdb_query("INSERT OR REPLACE INTO " .. CONFIG.perms_table ..
      " VALUES ('" .. esc(role) .. "', '" .. esc(tbl) .. "', " ..
      (p.can_select and 'true' or 'false') .. ", " .. (p.can_write and 'true' or 'false') .. ")")
  end)
  return ok and 'ok' or ('error: ' .. tostring(err))
end

local function setup()
  local ddl = {
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.tokens_table .. " (auth_token VARCHAR PRIMARY KEY, user_name VARCHAR)",
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.sessions_table .. " (sid VARCHAR PRIMARY KEY, user_name VARCHAR)",
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.roles_table .. " (user_name VARCHAR, role VARCHAR)",
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.perms_table .. " (role VARCHAR, table_name VARCHAR, can_select BOOLEAN, can_write BOOLEAN, PRIMARY KEY(role, table_name))",
  }
  for _, s in ipairs(ddl) do
    local ok, err = pcall(function() _duckdb_query(s) end)
    if not ok then return 'error: ' .. tostring(err) end
  end
  return 'ok'
end

return function(p)
  if not p or not p.op then return 'error: need op' end
  if p.op == 'authn' then return authn(p) end
  if p.op == 'authz' then return authz(p) end
  if p.op == 'grant' then return grant(p) end
  if p.op == 'setup' then return setup() end
  if p.op == 'tables' then
    return table.concat(CONFIG.protected, ',')
  end
  if p.op == 'status' then
    return 'protected=' .. table.concat(CONFIG.protected, ',') .. ';allow_write=' .. tostring(CONFIG.allow_write) ..
           ';strict_write=' .. tostring(CONFIG.strict_write) .. ';audit=' .. tostring(CONFIG.audit_table or 'off')
  end
  return 'error: unknown op ' .. tostring(p.op)
end
