-- @lib: audit_chain
-- @category: security
-- @desc: 链式哈希审计（tamper-evident audit log）——append-only 记录 + prev_hash 链 + verify() 逐行复算；
--        篡改任一历史行（改字段/改链/删行）即刻暴露。哈希用 DuckDB 内建 sha256()（零新依赖、零编译）。
-- @source: original（duckdb-luajit 系列）
-- @requires: _duckdb_query（普通模式，非 trusted 沙箱）+ DuckDB 内建 sha256() / lag() OVER()
-- @license: MIT (duckdb-luajit-libs project)
--
-- 定位：etl_run_log 记「跑过什么」，本库解决「记录本身可被改而不留痕」——即审计的证据力。
--       对应监管语境里的 tamper-evident audit log（例：IETF draft-klrc-aiagent-auth-03 的
--       "deployments MUST produce durable audit logs ... Audit records MUST be tamper-evident"）。
--
-- 表模型（op:'setup' 建表，幂等）：
--   <t>(seq BIGINT, ts VARCHAR, prev_hash VARCHAR, hash VARCHAR,
--       actor VARCHAR, action VARCHAR, scope VARCHAR, scope_hash VARCHAR,
--       payload VARCHAR, outcome VARCHAR)
--
-- ⭐ 规范化串（canonical form，任何语言都能独立复算——这是「可验证」的定义）：
--   canon = concat_ws('|', prev_hash, CAST(seq AS VARCHAR), ts, actor, action,
--                     scope, scope_hash, payload, outcome)     -- 缺省字段按空串参与
--   hash  = sha256(canon)                                      -- 小写 hex
--   prev_hash = 上一行 hash；首行（创世）prev_hash = ''（空串）
--   字段顺序唯一来源 = 本文件 FIELDS 表；append 与 verify 共用，杜绝两处口径漂移。
--
-- 调用（luajit_s('audit_chain', {op:...})）：
--   setup   → 'ok'                          建表（幂等）
--   append  → JSON {seq, ts, prev_hash, hash}  {actor, action, scope, scope_hash, payload, outcome}
--   verify  → JSON {ok, n, first_bad, reason, head}   reason = hash_mismatch | chain_break
--   head    → JSON {seq, hash}
--   logs    → JSON 数组（最近 n 条，默认 10）
--   scope_hash → sha256(hex)   {v}  调用方对「授权范围/参数」求稳定指纹（与 dataapp paramsHash 同构）
--   status  → 配置快照（调试）
--
-- ⚠️ 诚实边界：
--   1) 本库保证「记录可被事后独立验证」，**不保证写入当时不可伪造**——持有写权限者可以
--      重算整条链后重写全部 hash（append-only 的强制点在数据库权限层，不在这里；
--      配合 rbac 的 allow_write=false 才闭环）。
--   2) 删除尾部行不可被链本身发现（末行无后继）→ verify 额外报 n，请把 n 与外部台账对账；
--   3) 时间戳由 Lua 侧生成（UTC，秒级）并参与哈希 → 可独立复算，但精度到秒。

local T = 'audit_chain'

-- ⭐ 规范串字段顺序（唯一来源）
local FIELDS = { 'prev_hash', 'seq', 'ts', 'actor', 'action', 'scope', 'scope_hash', 'payload', 'outcome' }

-- 完整记录列（含结果列 hash 本身）；load_jsonl 用它建表，verify 用它按名取列。
local REC_FIELDS = { 'seq', 'ts', 'prev_hash', 'hash', 'actor', 'action', 'scope', 'scope_hash', 'payload', 'outcome' }

local function esc(v)
  if v == nil then return '' end
  if type(v) == 'boolean' then return v and 'true' or 'false' end
  return (tostring(v):gsub("'", "''"))
end

local function lit(v)
  return "'" .. esc(v) .. "'"
end

local function jesc(s)
  return (tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('[\n\r\t]', ' '))
end

-- SQL 侧「列 → 规范串元素」表达式（verify 用）
local function col_vals()
  local out = {}
  for _, f in ipairs(FIELDS) do
    if f == 'seq' then
      out[#out + 1] = 'CAST(' .. f .. ' AS VARCHAR)'
    else
      out[#out + 1] = "coalesce(" .. f .. ",'')"
    end
  end
  return table.concat(out, ', ')
end

-- SQL 侧「字面量 → 规范串元素」表达式（append 用），顺序同样由 FIELDS 决定
local function lit_vals(ts, seq_expr, prev_expr, rec)
  local map = {
    prev_hash  = prev_expr,
    seq        = 'CAST(' .. seq_expr .. ' AS VARCHAR)',
    ts         = lit(ts),
    actor      = lit(rec.actor),
    action     = lit(rec.action),
    scope      = lit(rec.scope),
    scope_hash = lit(rec.scope_hash),
    payload    = lit(rec.payload),
    outcome    = lit(rec.outcome),
  }
  local out = {}
  for _, f in ipairs(FIELDS) do out[#out + 1] = map[f] end
  return table.concat(out, ', ')
end

local function canon_cols()
  return "concat_ws('|', " .. col_vals() .. ')'
end

local function one(sql)
  local rows = _duckdb_query(sql)
  return rows and rows[1] or nil
end

local function setup()
  local ok, err = pcall(function()
    _duckdb_query('CREATE TABLE IF NOT EXISTS ' .. T .. ' ('
      .. 'seq BIGINT, ts VARCHAR, prev_hash VARCHAR, hash VARCHAR, '
      .. 'actor VARCHAR, action VARCHAR, scope VARCHAR, scope_hash VARCHAR, '
      .. 'payload VARCHAR, outcome VARCHAR)')
  end)
  if not ok then return 'error: ' .. tostring(err) end
  return 'ok'
end

local function append(rec)
  if rec.actor == nil or rec.actor == '' then return 'error: need actor' end
  if rec.action == nil or rec.action == '' then return 'error: need action' end
  setup()
  local ts = os.date('!%Y-%m-%dT%H:%M:%SZ')
  -- ⚠️ coalesce 必须在子查询**外面**：写在里面时空表返回零行 → 标量子查询整体为 NULL，
  --    而 concat_ws 会静默跳过 NULL → append 与 verify 的规范串错位一个分隔符（实测踩过）。
  local prev_expr = "coalesce((SELECT hash FROM " .. T .. " ORDER BY seq DESC LIMIT 1), '')"
  local seq_expr = '(SELECT coalesce(max(seq),0)+1 FROM ' .. T .. ')'
  local canon = "concat_ws('|', " .. lit_vals(ts, seq_expr, prev_expr, rec) .. ')'
  local sql = 'INSERT INTO ' .. T .. ' SELECT '
    .. seq_expr .. ', ' .. lit(ts) .. ', ' .. prev_expr .. ', '
    .. 'sha256(' .. canon .. '), '
    .. lit(rec.actor) .. ', ' .. lit(rec.action) .. ', ' .. lit(rec.scope) .. ', '
    .. lit(rec.scope_hash) .. ', ' .. lit(rec.payload) .. ', ' .. lit(rec.outcome)
  local ok, err = pcall(function() _duckdb_query(sql) end)
  if not ok then return 'error: ' .. tostring(err) end
  local r = one('SELECT seq, ts, prev_hash, hash FROM ' .. T .. ' ORDER BY seq DESC LIMIT 1')
  if not r then return 'error: append readback failed' end
  return '{"seq":' .. tostring(r.seq) .. ',"ts":"' .. jesc(r.ts) .. '","prev_hash":"' .. jesc(r.prev_hash)
    .. '","hash":"' .. jesc(r.hash) .. '"}'
end

-- ⭐ 核心：逐行复算 + 链式校验
local function verify(tbl)
  tbl = tbl or T
  local rows = _duckdb_query('SELECT seq, hash AS stored, sha256(' .. canon_cols() .. ') AS recomputed, '
    .. "coalesce(lag(hash) OVER (ORDER BY seq), '') AS expect_prev, prev_hash "
    .. 'FROM ' .. tbl .. ' ORDER BY seq')
  if not rows then return 'error: cannot read ' .. tbl end
  local n = #rows
  local first_bad, reason = nil, nil
  local head = ''
  for i = 1, n do
    local r = rows[i]
    head = r.stored
    if r.stored ~= r.recomputed then
      first_bad, reason = r.seq, 'hash_mismatch'
      break
    end
    if r.prev_hash ~= r.expect_prev then
      first_bad, reason = r.seq, 'chain_break'
      break
    end
  end
  local ok = (first_bad == nil)
  return '{"ok":' .. (ok and 'true' or 'false') .. ',"n":' .. tostring(n)
    .. ',"first_bad":' .. (first_bad and tostring(first_bad) or 'null')
    .. ',"reason":"' .. (reason or '') .. '","head":"' .. jesc(head or '') .. '"}'
end

local function head(tbl)
  tbl = tbl or T
  local r = one('SELECT seq, hash FROM ' .. tbl .. ' ORDER BY seq DESC LIMIT 1')
  if not r then return '{"seq":0,"hash":""}' end
  return '{"seq":' .. tostring(r.seq) .. ',"hash":"' .. jesc(r.hash) .. '"}'
end

local function logs(n, tbl)
  tbl = tbl or T
  n = tonumber(n) or 10
  local rows = _duckdb_query('SELECT seq, ts, hash, actor, action, scope, scope_hash, payload, outcome FROM '
    .. tbl .. ' ORDER BY seq DESC LIMIT ' .. tostring(n))
  if not rows then return 'error: cannot read ' .. tbl end
  local out = {}
  for i = 1, #rows do
    local r = rows[i]
    out[#out + 1] = '{"seq":' .. tostring(r.seq) .. ',"ts":"' .. jesc(r.ts) .. '","hash":"' .. jesc(r.hash)
      .. '","actor":"' .. jesc(r.actor) .. '","action":"' .. jesc(r.action) .. '","scope":"' .. jesc(r.scope)
      .. '","scope_hash":"' .. jesc(r.scope_hash) .. '","payload":"' .. jesc(r.payload)
      .. '","outcome":"' .. jesc(r.outcome) .. '"}'
  end
  return '[' .. table.concat(out, ',') .. ']'
end

local function scope_hash(v)
  local r = one("SELECT sha256(coalesce(" .. lit(v) .. ",'')) AS h")
  if not r then return 'error: sha256 unavailable' end
  return r.h
end

-- ⭐ 跨语言入口：把外部写入方（如 NPP 的 C# GovernanceAuditChain）产出的 JSONL 装进表再 verify。
-- ⚠️ 必须**显式声明列类型**：read_json_auto 会把 ts 推成 TIMESTAMPTZ，转字符串即变成
--    '2026-09-15 11:48:38+08'，而写入方写的是 '2026-09-15T03:48:38Z' → 规范串不同 →
--    误报 hash_mismatch（实测踩过，非算法不一致）。
local COLS_JSON = "{'seq':'BIGINT','ts':'VARCHAR','prev_hash':'VARCHAR','hash':'VARCHAR','actor':'VARCHAR',"
  .. "'action':'VARCHAR','scope':'VARCHAR','scope_hash':'VARCHAR','payload':'VARCHAR','outcome':'VARCHAR'}"

local function load_jsonl(f, tbl)
  if f == nil or f == '' then return 'error: need f (jsonl path)' end
  tbl = tbl or T
  -- ⚠️ 必须用 REC_FIELDS（含 hash 本身）而非 FIELDS：FIELDS 只是参与规范串的 9 个字段，
  --    hash 是算出来的结果列，漏掉它则 verify 在回灌表上直接 binder 报错（实测踩过）。
  local sql = 'CREATE OR REPLACE TABLE ' .. tbl .. ' AS SELECT ' .. table.concat(REC_FIELDS, ', ')
    .. ' FROM read_json(' .. lit(f) .. ', columns := ' .. COLS_JSON .. ", format := 'newline_delimited')"
  local ok, err = pcall(function() _duckdb_query(sql) end)
  if not ok then return 'error: ' .. tostring(err) end
  local r = one('SELECT count(*) AS c FROM ' .. tbl)
  return '{"loaded":"' .. tbl .. '","rows":' .. tostring(r and r.c or 0) .. '}'
end

return function(p)
  if not p or not p.op then return 'error: need op' end
  -- ⚠️ 参数名用 tbl 而非 table：`table` 是 SQL 保留字，struct 字面量 {op:'x', table:'y'} 会
  --    Parser Error: syntax error at or near "table"（实测踩过）。p.table 仅作兼容保留。
  local tbl = (p.tbl ~= nil and p.tbl ~= '') and p.tbl
    or ((p.table ~= nil and p.table ~= '') and p.table or T)
  if p.op == 'setup' then return setup() end
  if p.op == 'append' then return append(p) end
  if p.op == 'verify' then return verify(tbl) end
  if p.op == 'head' then return head(tbl) end
  if p.op == 'logs' then return logs(p.n, tbl) end
  if p.op == 'load_jsonl' then return load_jsonl(p.f, tbl) end
  if p.op == 'scope_hash' then return scope_hash(p.v) end
  if p.op == 'status' then
    return 'table=' .. T .. ';fields=' .. table.concat(FIELDS, ',') .. ';hash=sha256(canonical concat_ws)'
  end
  return 'error: unknown op ' .. tostring(p.op)
end
