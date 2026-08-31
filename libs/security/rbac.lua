-- @lib: rbac
-- @category: security
-- @desc: Quack RBAC 策略引擎——token 认证 + 连接会话记录 + 角色表级授权 + 只读白名单加固，
--        挂 quack_authentication_function / quack_authorization_function 钩子（普通模式，需 _duckdb_query）
-- @source: original（duckdb-luajit 系列）
-- @requires: _duckdb_query（普通模式；trusted 沙箱下不可用）
-- Role-Based Access Control policy engine for DuckDB Quack (LuaJIT 5.1).
--
-- 定位：Quack 是强制点（每条查询 PREPARE 前跑 authorization 钩子），本库是策略引擎。
-- 安全前提（务必读）：
--   1) 授权钩子默认拒绝一切写语句（allow_write=false）——否则客户端可
--      SET GLOBAL quack_authorization_function / CREATE OR REPLACE MACRO / 篡改权限表 绕过；
--   2) 权限元数据表与数据同平面，本库通过“禁写”保护它们（管理员在服务器本地执行 grant/setup）；
--   3) 语句类型判断基于 SQL 文本前缀，非解析器——官方文档亦警告
--      “WITH x AS (SELECT 1) INSERT INTO t ...” 型绕过；strict_write=true 时 WITH 前缀一律拒绝（宁可错杀）。
--
-- 表模型（管理员在服务器会话执行 luajit_s('rbac', {op:'setup'}) 一次）：
--   quack_tokens (auth_token PK, user_name)   -- token→用户
--   quack_sessions (sid PK, user_name)        -- 连接→用户（authn 钩子写入）
--   user_roles (user_name, role)              -- 用户→角色
--   role_perms (role, table_name, can_select, can_write)  -- 角色→表权限
--
-- 挂钩（服务器会话，LOAD luajit + compile 本库之后）：
--   CREATE MACRO rbac_authn(sid, ct, st) AS (luajit_s('rbac', {op:'authn', sid:sid, client_token:ct, server_token:st})::BOOLEAN);
--   CREATE MACRO rbac_authz(sid, q)    AS (luajit_s('rbac', {op:'authz', sid:sid, q:q})::BOOLEAN);
--   SET GLOBAL quack_authentication_function = 'rbac_authn';
--   SET GLOBAL quack_authorization_function  = 'rbac_authz';
--
-- 调用（luajit_s('rbac', {op:...})）：
--   authn  → BOOLEAN（查 token 表 + 写会话表）
--   authz  → BOOLEAN（白名单 + 角色表级权限）
--   grant  → 管理员专用 {op:'grant', role, tbl, can_select, can_write} 改 role_perms（仅服务器本地执行！）
--   setup  → 管理员专用：建 4 张 RBAC 表（仅服务器本地执行！）
--   status → 配置快照（调试用）

local CONFIG = {
  tokens_table   = 'quack_tokens',
  sessions_table = 'quack_sessions',
  roles_table    = 'user_roles',
  perms_table    = 'role_perms',
  protected      = { 'secret_data', 'public_data' },  -- 受控表清单（authz 逐表查权限）
  allow_write    = false,  -- true = 放行写语句并按 can_write 细粒度授权；false = 一切写语句拒绝（推荐）
  strict_write   = true,   -- true = WITH 开头一律拒绝（防 “WITH x AS (SELECT 1) INSERT INTO t” 型绕过）
  audit_table    = nil,    -- 设 'rbac_audit' 则 authz 每次决策记审计（每查询多一次写，性能敏感慎用）
}

local READ_KWS  = { 'SELECT', 'FROM', 'WITH', 'EXPLAIN', 'DESCRIBE', 'SHOW', 'VALUES', 'TABLE', 'PRAGMA', 'SUMMARIZE' }
local WRITE_KWS = { 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'COPY', 'CREATE', 'DROP', 'ALTER', 'SET', 'CALL',
                    'ATTACH', 'DETACH', 'EXPORT', 'IMPORT', 'CHECKPOINT', 'VACUUM', 'COMMENT', 'INSTALL',
                    'LOAD', 'PREPARE', 'EXECUTE', 'USE', 'GRANT', 'REVOKE', 'TRUNCATE' }

local function esc(s)
  return (s:gsub("'", "''"))
end

local function q(rows, i, col)
  return rows and rows[i] and rows[i][col]
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

local function check_tables(query, user, need_write)
  for _, tbl in ipairs(CONFIG.protected) do
    if string.find(query, tbl, 1, true) then
      if not user_has_perm(user, tbl, need_write) then return false end
    end
  end
  return true
end

local function authn(p)
  local rows = _duckdb_query(
    "SELECT user_name FROM " .. CONFIG.tokens_table .. " WHERE auth_token = '" .. esc(p.client_token or '') .. "'")
  local user = q(rows, 1, 'user_name')
  if not user then return false end
  _duckdb_query("INSERT INTO " .. CONFIG.sessions_table .. " VALUES ('" .. esc(p.sid or '') .. "', '" .. esc(user) .. "')")
  return true
end

local function authz(p)
  local query = p.q or ''
  local up = string.upper(query:gsub('^%s+', ''):gsub('%s+$', ''))
  if up == '' then return false end
  local kind = classify(up)
  if kind == 'unknown' then return false end
  if kind == 'read' and up:find('^WITH') and CONFIG.strict_write then return false end  -- 防 WITH 注入式写绕过
  local user = resolve_user(p.sid)
  if not user then return false end
  local need_write = (kind == 'write')
  if need_write and not CONFIG.allow_write then return false end
  if not check_tables(query, user, need_write) then return false end
  if CONFIG.audit_table then
    _duckdb_query("INSERT INTO " .. CONFIG.audit_table ..
      " VALUES ('" .. esc(p.sid or '') .. "', '" .. esc(user) .. "', '" .. esc(query) .. "', CURRENT_TIMESTAMP)")
  end
  return true
end

-- 管理员操作：仅服务器本地会话执行。若经 quack 客户端执行，会被 authz 白名单拒绝——这正是设计意图。
local function grant(p)
  local ok, err = pcall(function()
    _duckdb_query("INSERT OR REPLACE INTO " .. CONFIG.perms_table ..
      " VALUES ('" .. esc(p.role or '') .. "', '" .. esc(p.tbl or '') .. "', " ..
      (p.can_select and 'true' or 'false') .. ", " .. (p.can_write and 'true' or 'false') .. ")")
  end)
  return ok and 'ok' or ('error: ' .. tostring(err))
end

local function setup()
  local ddl = {
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.tokens_table .. " (auth_token VARCHAR PRIMARY KEY, user_name VARCHAR)",
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.sessions_table .. " (sid VARCHAR PRIMARY KEY, user_name VARCHAR)",
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.roles_table .. " (user_name VARCHAR, role VARCHAR)",
    "CREATE TABLE IF NOT EXISTS " .. CONFIG.perms_table .. " (role VARCHAR, table_name VARCHAR, can_select BOOLEAN, can_write BOOLEAN)",
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
  if p.op == 'status' then
    return 'protected=' .. table.concat(CONFIG.protected, ',') .. ';allow_write=' .. tostring(CONFIG.allow_write) ..
           ';strict_write=' .. tostring(CONFIG.strict_write) .. ';audit=' .. tostring(CONFIG.audit_table or 'off')
  end
  return 'error: unknown op ' .. tostring(p.op)
end
