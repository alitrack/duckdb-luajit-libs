-- etl.lua: ETL 流程层——审计 / 幂等 / 自愈 / 组件化 / Pipeline 引擎（2026-08-07）
-- 需要普通模式（非 trusted）：存储过程回查依赖 _duckdb_call / _duckdb_query
--
-- 使用（install 后）：
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'etl');
--   SELECT * FROM luajit_module(mode := 'compile', sql_name := 'etl_run_demo',
--     source := 'return function(x) return etl.run("demo", x) end');
--
-- 五大能力：
--   P0 etl.log / etl.run        —— 审计：自动建 etl_run_log 表，每次运行记 (ts, fn, args, duration_ms, rows, success, err)
--   P1 etl.validate             —— 幂等双检：throw_if_empty（源空则失败）/ throw_if_not_empty（目标已有则失败防重）
--   P1 etl.safe / insert_auto   —— 错误正则自愈：pcall + err:match(pattern) → 回退函数 → 重试
--   P2 etl.q / query / exec     —— query-doc 组件化：CTE/select/from/join/where/group/order/having 动态拼 SQL
--   P3 etl.pipeline / compile   —— Pipeline 引擎：Pipeline JSON → 拓扑排序 → 编译 → 执行 + 逐节点审计
--                                 节点类型: source(建临时表) / transform(SQL) / transform_lua(Lua闭包行处理)
--                                           quality(数据质量检查) / sink(落表)
--                                 数据质量检查: not_null / unique / rowcount_min / rowcount_max / schema

local etl = {}

-- ============ 内部工具 ============

local function esc(v)
  -- SQL 字符串转义（Lua 单引号 → SQL 双单引号）
  if type(v) == "string" then
    return "'" .. v:gsub("'", "''") .. "'"
  end
  if v == nil then return "NULL" end
  return tostring(v)
end

-- ============ P0: 审计 ============

etl.log_table = "etl_run_log"

-- 初始化审计表（幂等）
function etl.init()
  _duckdb_call("CREATE TABLE IF NOT EXISTS " .. etl.log_table .. " ("
    .. "run_id BIGINT, ts TIMESTAMP, fn VARCHAR, args VARCHAR, "
    .. "duration_ms BIGINT, rows BIGINT, success BOOLEAN, err VARCHAR)")
end

-- 写一条审计记录
function etl.log(run_id, fn, args, duration_ms, rows, success, err)
  etl.init()
  local sql = "INSERT INTO " .. etl.log_table .. " VALUES ("
    .. esc(run_id) .. ", now(), " .. esc(fn) .. ", " .. esc(args) .. ", "
    .. esc(duration_ms) .. ", " .. esc(rows) .. ", " .. (success and "true" or "false") .. ", " .. esc(err) .. ")"
  return _duckdb_call(sql)
end

-- 包装执行：计时 + 审计 + 错误捕获
-- 用法：etl.run(fn_name, args_json, fn, ...)  fn 是可 pcall 的 Lua 函数
function etl.run(fn_name, args_json, fn, ...)
  local t0 = os.clock()
  local ok, res = pcall(fn, ...)
  local dt = math.floor((os.clock() - t0) * 1000)
  if ok then
    local rows = 0
    if type(res) == "table" then rows = #res end
    etl.log(0, fn_name, args_json, dt, rows, true, nil)
    return res
  else
    etl.log(0, fn_name, args_json, dt, 0, false, tostring(res))
    error(res, 0)
  end
end

-- 读最近审计记录
function etl.logs(n)
  n = n or 10
  return _duckdb_query("SELECT CAST(run_id AS BIGINT) AS run_id, ts, fn, args, "
    .. "CAST(duration_ms AS BIGINT) AS duration_ms, CAST(rows AS BIGINT) AS rows, success, err "
    .. "FROM " .. etl.log_table .. " ORDER BY ts DESC LIMIT " .. tostring(n))
end

-- ============ P1: 幂等双检 ============

-- 校验表行数约束（ETLX load_validation）
-- 模式：throw_if_empty（表空则失败）/ throw_if_not_empty（表非空则失败，防重）
function etl.validate(tbl, mode, min_rows)
  local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. tbl)
  if not rows then error("validate: " .. tostring(err), 0) end
  local n = tonumber(rows[1].n) or 0
  if mode == "throw_if_empty" then
    if n == 0 then error("validate: table " .. tbl .. " is empty (expected rows > 0)", 0) end
  elseif mode == "throw_if_not_empty" then
    if n > 0 then error("validate: table " .. tbl .. " already has " .. n .. " rows (load twice?)", 0) end
  elseif mode == "throw_if_lt" then
    if n < (min_rows or 1) then
      error("validate: table " .. tbl .. " has " .. n .. " rows (expected >= " .. tostring(min_rows) .. ")", 0)
    end
  else
    error("validate: unknown mode " .. tostring(mode), 0)
  end
  return n
end

-- ============ P1: 错误正则自愈 ============

-- 执行 fn，若失败（抛错 或 _duckdb_call 返回 "error: ..."）且错误匹配 pattern，
-- 则执行 fallback 后重试一次（ETLX load_on_err_match）
-- 用法：etl.safe(fn, "does not exist", function() create_table() end)
function etl.safe(fn, pattern, fallback)
  local ok, res = pcall(fn)
  -- _duckdb_call 不抛 Lua error，失败时返回 "error: <msg>" 字符串——两种情况都算失败
  if ok and type(res) == "string" and res:match("^error:") then
    ok = false
    res = res:sub(7)  -- 去掉 "error: " 前缀
  end
  if ok then return res end
  local errmsg = tostring(res)
  if pattern and errmsg:match(pattern) then
    if fallback then
      local fok, ferr = pcall(fallback)
      if not fok then error("safe: fallback failed: " .. tostring(ferr), 0) end
    end
    -- 重试一次
    local ok2, res2 = pcall(fn)
    if ok2 and type(res2) == "string" and res2:match("^error:") then
      ok2 = false
      res2 = res2:sub(7)
    end
    if not ok2 then error("safe: retry failed: " .. tostring(res2), 0) end
    return res2
  end
  error(errmsg, 0)
end

-- 建表自愈包装：目标表不存在 → 自动建表 → 重试 INSERT
-- 用法：etl.insert_auto(tbl, ddl, sql)
function etl.insert_auto(tbl, ddl, sql)
  return etl.safe(
    function() return _duckdb_call(sql) end,
    "does not exist",
    function() return _duckdb_call(ddl) end)
end

-- ============ P2: query-doc 组件化 ============

-- SQL 组件动态拼接（ETLX query-doc / dbt 式组件）
-- 用法：
--   etl.q({
--     select = "a.id, a.name, b.total",
--     from = "src.orders a",
--     join = "JOIN src.customers b ON a.cust_id = b.id",
--     where = "a.amount > 100",
--     group_by = "a.id, a.name",
--     order_by = "b.total DESC",
--     limit = 10,
--   })
function etl.q(parts)
  local clauses = {
    { "WITH", parts.cte },
    { "SELECT", parts.select or "*" },
    { "FROM", parts.from },
    { "", parts.join },
    { "WHERE", parts.where },
    { "GROUP BY", parts.group_by },
    { "HAVING", parts.having },
    { "ORDER BY", parts.order_by },
    { "LIMIT", parts.limit },
  }
  local out = {}
  for _, cl in ipairs(clauses) do
    if cl[2] ~= nil and cl[2] ~= "" then
      out[#out + 1] = (cl[1] ~= "" and (cl[1] .. " " .. cl[2]) or cl[2])
    end
  end
  return table.concat(out, "\n")
end

-- 执行组件化查询，返回行表
function etl.query(parts)
  local sql = etl.q(parts)
  return _duckdb_query(sql)
end

-- 组件化 DML（INSERT INTO ... SELECT ... 由组件生成）
-- 失败时抛 Lua error（_duckdb_call 返回 "error: ..." 不抛错，这里统一）
function etl.exec(parts)
  local sql = etl.q(parts)
  local r = _duckdb_call(sql)
  if type(r) == "string" and r:match("^error:") then
    error(r:sub(7), 0)
  end
  return r
end

-- ============ P3: Pipeline 引擎 ============

-- Pipeline 结构（前端画布导出 / 手写）：
-- {
--   name = "orders_etl",
--   nodes = {
--     { id = "src",   type = "source",       query = "SELECT * FROM read_csv('orders.csv')" },
--     { id = "clean", type = "transform",    query = "SELECT id, upper(name) AS name, amount FROM src WHERE amount > 0",
--       deps = { "src" } },
--     { id = "audit", type = "quality",      checks = {
--         { type = "not_null", col = "id" },
--         { type = "unique",   col = "id" },
--         { type = "rowcount_min", min = 1 },
--       }, deps = { "clean" } },
--     { id = "out",   type = "sink",         table = "orders_clean", deps = { "clean" } },
--   },
-- }
-- 执行语义：source → CREATE OR REPLACE TEMP TABLE <id> AS <query>
--           transform → CREATE OR REPLACE TEMP TABLE <id> AS <query>（引用上游临时表）
--           transform_lua → 读上游表行 → Lua 闭包逐行处理 → 写回临时表
--           quality → 对上游表跑 checks，任一失败抛错
--           sink → CREATE OR REPLACE TABLE <table> AS SELECT * FROM <上游>
-- 每节点执行记一条审计（etl_run_log），失败即中止。

-- 内部：执行一个 quality 检查，失败抛错
local function run_check(tbl, check)
  local t = check.type
  if t == "not_null" then
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. tbl .. " WHERE " .. check.col .. " IS NULL")
    if not rows then error("quality: " .. tostring(err), 0) end
    local n = tonumber(rows[1].n) or 0
    if n > 0 then error("quality[" .. tbl .. "]: not_null(" .. check.col .. ") failed: " .. n .. " NULL values", 0) end
  elseif t == "unique" then
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS total, CAST(count(DISTINCT " .. check.col .. ") AS BIGINT) AS distinct_n FROM " .. tbl)
    if not rows then error("quality: " .. tostring(err), 0) end
    if tonumber(rows[1].total) ~= tonumber(rows[1].distinct_n) then
      error("quality[" .. tbl .. "]: unique(" .. check.col .. ") failed: total=" .. tostring(rows[1].total) .. " distinct=" .. tostring(rows[1].distinct_n), 0)
    end
  elseif t == "rowcount_min" then
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. tbl)
    if not rows then error("quality: " .. tostring(err), 0) end
    local n = tonumber(rows[1].n) or 0
    if n < (check.min or 1) then error("quality[" .. tbl .. "]: rowcount_min failed: " .. n .. " < " .. tostring(check.min), 0) end
  elseif t == "rowcount_max" then
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. tbl)
    if not rows then error("quality: " .. tostring(err), 0) end
    local n = tonumber(rows[1].n) or 0
    if n > (check.max or 0) then error("quality[" .. tbl .. "]: rowcount_max failed: " .. n .. " > " .. tostring(check.max), 0) end
  elseif t == "schema" then
    -- check.cols = { "id", "name" } —— 表必须包含这些列
    local rows, err = _duckdb_query("SELECT column_name FROM information_schema.columns WHERE table_name = '" .. tbl .. "'")
    if not rows then error("quality: " .. tostring(err), 0) end
    local have = {}
    for _, r in ipairs(rows) do have[r.column_name] = true end
    for _, col in ipairs(check.cols or {}) do
      if not have[col] then error("quality[" .. tbl .. "]: schema failed: missing column " .. tostring(col), 0) end
    end
  else
    error("quality: unknown check type " .. tostring(t), 0)
  end
end

-- 拓扑排序（Kahn）：返回节点执行顺序，有环抛错
local function topo_sort(nodes)
  local by_id = {}
  for _, n in ipairs(nodes) do by_id[n.id] = n end
  local indeg = {}
  local adj = {}
  for _, n in ipairs(nodes) do
    indeg[n.id] = 0
    adj[n.id] = {}
  end
  for _, n in ipairs(nodes) do
    for _, d in ipairs(n.deps or {}) do
      if not by_id[d] then error("pipeline: dep '" .. d .. "' not found (node " .. n.id .. ")", 0) end
      indeg[n.id] = indeg[n.id] + 1
      adj[d][#adj[d] + 1] = n.id
    end
  end
  local queue, order = {}, {}
  for _, n in ipairs(nodes) do
    if indeg[n.id] == 0 then queue[#queue + 1] = n.id end
  end
  while #queue > 0 do
    local id = table.remove(queue, 1)
    order[#order + 1] = id
    for _, m in ipairs(adj[id]) do
      indeg[m] = indeg[m] - 1
      if indeg[m] == 0 then queue[#queue + 1] = m end
    end
  end
  if #order ~= #nodes then error("pipeline: cyclic dependency detected", 0) end
  return order
end

-- 编译 Pipeline：校验结构 + 拓扑排序，返回可执行闭包
function etl.compile(p)
  if type(p) ~= "table" or not p.nodes or #p.nodes == 0 then
    error("pipeline: expected { name=..., nodes={...} }", 0)
  end
  local order = topo_sort(p.nodes)
  local by_id = {}
  for _, n in ipairs(p.nodes) do by_id[n.id] = n end
  local compiled = { name = p.name or "unnamed", order = order, nodes = by_id }
  return compiled
end

-- 执行 Pipeline（先 compile 再逐节点执行）
-- 返回 { node_results = { id = rows, ... } }
function etl.pipeline(p)
  local c = etl.compile(p)
  local results = {}
  for _, id in ipairs(c.order) do
    local n = c.nodes[id]
    local t0 = os.clock()
    local ok, res = pcall(function() return etl.run_node(n, results) end)
    local dt = math.floor((os.clock() - t0) * 1000)
    if ok then
      etl.log(0, "node:" .. n.id, "{\"type\":\"" .. tostring(n.type) .. "\"}", dt, res or 0, true, nil)
      results[n.id] = res
    else
      etl.log(0, "node:" .. n.id, "{\"type\":\"" .. tostring(n.type) .. "\"}", dt, 0, false, tostring(res))
      error("pipeline[" .. tostring(c.name) .. "] node '" .. n.id .. "' failed: " .. tostring(res), 0)
    end
  end
  return results
end

-- 执行单个节点（pipeline 内部使用）
-- 返回影响行数（或 nil）
function etl.run_node(n, results)
  local typ = n.type
  if typ == "source" or typ == "transform" then
    -- CREATE OR REPLACE TEMP TABLE <id> AS <query>
    local sql = "CREATE OR REPLACE TEMP TABLE " .. n.id .. " AS " .. n.query
    local r = _duckdb_call(sql)
    if type(r) == "string" and r:match("^error:") then error(r:sub(7), 0) end
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. n.id)
    if not rows then error(tostring(err), 0) end
    return tonumber(rows[1].n) or 0
  elseif typ == "transform_lua" then
    -- 读上游表（n.source 或第一个 dep）→ Lua 闭包逐行处理 → 写回
    local src = n.source or (n.deps and n.deps[1]) or error("transform_lua: no source", 0)
    local data, err = _duckdb_query("SELECT * FROM " .. src)
    if not data then error(tostring(err), 0) end
    local out = {}
    for _, row in ipairs(data) do
      local r = n.fn(row)
      if r ~= nil then out[#out + 1] = r end
    end
    -- 建临时表并写入
    local cols = {}
    for k, v in pairs(out[1] or {}) do
      local vt = (type(v) == "number") and "BIGINT" or "VARCHAR"
      cols[#cols + 1] = k .. " " .. vt
    end
    if #cols == 0 then error("transform_lua: empty output", 0) end
    _duckdb_call("CREATE OR REPLACE TEMP TABLE " .. n.id .. " (" .. table.concat(cols, ", ") .. ")")
    for _, row in ipairs(out) do
      local vals = {}
      for k in pairs(out[1]) do
        local v = row[k]
        if type(v) == "string" then vals[#vals + 1] = esc(v)
        elseif v == nil then vals[#vals + 1] = "NULL"
        else vals[#vals + 1] = tostring(v) end
      end
      _duckdb_call("INSERT INTO " .. n.id .. " VALUES (" .. table.concat(vals, ", ") .. ")")
    end
    return #out
  elseif typ == "quality" then
    local src = n.source or (n.deps and n.deps[1]) or error("quality: no source", 0)
    for _, chk in ipairs(n.checks or {}) do
      run_check(src, chk)
    end
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. src)
    if not rows then error(tostring(err), 0) end
    return tonumber(rows[1].n) or 0
  elseif typ == "sink" then
    local src = n.source or (n.deps and n.deps[1]) or error("sink: no source", 0)
    local tbl = n.table or n.id
    local r = _duckdb_call("CREATE OR REPLACE TABLE " .. tbl .. " AS SELECT * FROM " .. src)
    if type(r) == "string" and r:match("^error:") then error(r:sub(7), 0) end
    local rows, err = _duckdb_query("SELECT CAST(count(*) AS BIGINT) AS n FROM " .. tbl)
    if not rows then error(tostring(err), 0) end
    return tonumber(rows[1].n) or 0
  else
    error("pipeline: unknown node type " .. tostring(typ), 0)
  end
end

return etl
