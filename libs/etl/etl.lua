-- etl.lua: ETL 流程层——审计 / 幂等 / 自愈 / 组件化 / Pipeline 引擎（2026-08-19）
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
--                                           if_node(条件路由) / switch_node(多路路由)
--                                 路由: 下游节点 route="true"/"false" 匹配 if_node 条件 → 不匹配的支路跳过
--                                        switch_node 的 selector 返回 string → 下游 route 匹配才执行
--                                 重试: 节点配置 retry={max=3, backoff=1.0} → 指数退避 backoff×2^(n-1)
--                                 超时: 节点配置 timeout=60 → 超时后中止（含重试总时间）
--                                 错误恢复: 节点配置 on_error="handler_id" → 失败时不中止，运行 handler 后继续
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

-- 繁忙等待（秒，LuaJIT 内无可移植 sleep，用 busy-loop 替代）
local function busy_sleep(sec)
  local t0 = os.clock()
  while os.clock() - t0 < sec do end
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
--     { id = "has_data", type = "if_node",   deps = {"audit"},
--       condition = function(ctx) return ctx.audit > 0 end },
--     { id = "process", type = "transform",  deps = {"has_data"}, route = "true",
--       query = "SELECT * FROM clean WHERE amount > 100" },
--     { id = "log_empty", type = "sink",     deps = {"has_data"}, route = "false",
--       table = "empty_log" },
--     { id = "out",   type = "sink",         table = "orders_clean", deps = { "process" },
--       retry = { max = 2, backoff = 1.0 }, timeout = 120 },
--     { id = "risky", type = "transform",    deps = {"src"},
--       query = "SELECT 1/0", on_error = "fallback" },
--     { id = "fallback", type = "transform", deps = {"src"},
--       query = "SELECT 0 AS result" },
--   },
-- }
-- 执行语义：source → CREATE OR REPLACE TEMP TABLE <id> AS <query>
--           transform → CREATE OR REPLACE TEMP TABLE <id> AS <query>（引用上游临时表）
--           transform_lua → 读上游表行 → Lua 闭包逐行处理 → 写回临时表
--           quality → 对上游表跑 checks，任一失败抛错
--           sink → CREATE OR REPLACE TABLE <table> AS SELECT * FROM <上游>
--           if_node → 评估 condition(ctx)，路由到 "true" 或 "false" 分支
--           switch_node → 评估 selector(ctx)，路由到对应 case 分支
--           路由：下游节点 route="X" 匹配 if_node/switch_node 结果才执行，不匹配跳过（不报错）
--           重试：retry.max 次重试，退避 retry.backoff × 2^(n-1) 秒
--           超时：timeout 秒内必须完成（含重试总时间），超时走失败逻辑
--           错误恢复：on_error 设 handler_id，失败时不中止，handler 在拓扑中正常执行
-- 每节点执行记一条审计（etl_run_log），失败即中止（除非设 on_error）。

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
  -- 校验：route 节点必须有 deps
  for _, n in ipairs(p.nodes) do
    if n.route and (not n.deps or #n.deps == 0) then
      error("pipeline: node '" .. n.id .. "' has route but no deps", 0)
    end
    if n.on_error and not by_id[n.on_error] then
      error("pipeline: node '" .. n.id .. "' on_error target '" .. n.on_error .. "' not found", 0)
    end
  end
  local compiled = { name = p.name or "unnamed", order = order, nodes = by_id }
  return compiled
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
  elseif typ == "if_node" then
    -- 评估条件：condition(results) → boolean
    local cond = n.condition
    if type(cond) ~= "function" then error("if_node: expected condition function", 0) end
    local ok, val = pcall(cond, results)
    if not ok then error("if_node: condition failed: " .. tostring(val), 0) end
    local route = val and "true" or "false"
    results["_route_" .. n.id] = route
    return nil  -- if_node 不产生数据行
  elseif typ == "switch_node" then
    -- 评估选择器：selector(results) → string
    local sel = n.selector
    if type(sel) ~= "function" then error("switch_node: expected selector function", 0) end
    local ok, val = pcall(sel, results)
    if not ok then error("switch_node: selector failed: " .. tostring(val), 0) end
    local route = tostring(val)
    results["_route_" .. n.id] = route
    return nil  -- switch_node 不产生数据行
  else
    error("pipeline: unknown node type " .. tostring(typ), 0)
  end
end

-- 执行 Pipeline（先 compile 再逐节点执行）
-- 返回 { node_results = { id = rows, ... } }，失败节点标记 "failed:<err>"
function etl.pipeline(p)
  local c = etl.compile(p)
  local results = {}
  for _, id in ipairs(c.order) do
    local n = c.nodes[id]

    -- 路由检查：下游节点有 route 字段，检查依赖的 if_node/switch_node 结果是否匹配
    if n.route then
      local dep = n.deps and n.deps[1]
      local route_key = "_route_" .. (dep or "")
      if results[route_key] ~= n.route then
        -- 路由不匹配，跳过此节点
        results[n.id] = "skipped"
        goto continue
      end
    end

    -- 重试循环
    local max_retries = (n.retry and type(n.retry) == "table" and n.retry.max) or 0
    local backoff = (n.retry and type(n.retry) == "table" and n.retry.backoff) or 1.0
    local timeout = n.timeout or 0
    local t_start = os.clock()
    local ok, res = false, nil
    local last_dt = 0

    for attempt = 0, max_retries do
      -- 超时检查（包括重试总时间）
      if timeout > 0 then
        local elapsed = os.clock() - t_start
        if elapsed >= timeout then
          res = "timeout after " .. tostring(math.floor(elapsed)) .. "s (max " .. tostring(timeout) .. "s)"
          break
        end
      end

      local t0 = os.clock()
      ok, res = pcall(function() return etl.run_node(n, results) end)
      last_dt = math.floor((os.clock() - t0) * 1000)

      if ok then
        break
      end

      -- 失败且有重试次数：退避等待后重试
      if attempt < max_retries then
        local sleep_s = backoff * (2 ^ attempt)
        busy_sleep(sleep_s)
      end
    end

    if ok then
      etl.log(0, "node:" .. n.id, '{"type":"' .. tostring(n.type) .. '"}', last_dt, res or 0, true, nil)
      results[n.id] = res
    else
      local total_dt = math.floor((os.clock() - t_start) * 1000)
      etl.log(0, "node:" .. n.id, '{"type":"' .. tostring(n.type) .. '"}', total_dt, 0, false, tostring(res))

      if n.on_error then
        -- 有错误恢复：标记失败，继续管道
        results[n.id] = "failed:" .. tostring(res)
        results["_err_" .. n.id] = tostring(res)
      else
        error("pipeline[" .. tostring(c.name) .. "] node '" .. n.id .. "' failed: " .. tostring(res), 0)
      end
    end
    ::continue::
  end
  return results
end

return etl