-- etl.lua: ETL 流程层——审计 / 幂等 / 自愈 / 组件化（2026-08-07，借鉴 ETLX 工程模式）
-- 需要普通模式（非 trusted）：存储过程回查依赖 _duckdb_call / _duckdb_query
--
-- 使用（install 后）：
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'etl');
--   SELECT * FROM luajit_module(mode := 'compile', sql_name := 'etl_run_demo',
--     source := 'return function(x) return etl.run("demo", x) end');
--
-- 四大能力：
--   P0 etl.log / etl.run  —— 审计：自动建 etl_run_log 表，每次运行记 (ts, fn, args, duration_ms, rows, success, err)
--   P1 etl.validate       —— 幂等双检：throw_if_empty（源空则失败）/ throw_if_not_empty（目标已有则失败防重）
--   P1 etl.safe           —— 错误正则自愈：pcall + err:match(pattern) → 回退函数 → 重试
--   P2 etl.q              —— query-doc 组件化：CTE/select/from/join/where/group/order/having 动态拼 SQL

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

return etl
