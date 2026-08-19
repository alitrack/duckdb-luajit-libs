-- etl.pipeline E2E 演示（2026-08-20）
-- 用法：编译后通过 luajit_s 调用
-- 演示 Pipeline 引擎 v2 全部能力：
--   source / transform / quality / if_node / switch_node / sink
--   条件路由 / 重试 / 超时 / 错误恢复 / 审计

return function(noop)
  -- ============ 1. 准备数据 ============
  _duckdb_call("CREATE OR REPLACE TABLE demo_orders AS SELECT * FROM (VALUES" ..
    "(1, 'Alice',   250.0, 'completed')," ..
    "(2, 'Bob',     150.0, 'completed')," ..
    "(3, 'Charlie',  80.0, 'pending')," ..
    "(4, 'Diana',   500.0, 'completed')," ..
    "(5, 'Eve',      30.0, 'cancelled')) AS t(id, name, amount, status)")

  _duckdb_call("CREATE OR REPLACE TABLE demo_customers AS SELECT * FROM (VALUES" ..
    "(1, 'Alice',    'VIP')," ..
    "(2, 'Bob',      'Regular')," ..
    "(4, 'Diana',    'VIP')," ..
    "(6, 'Frank',    'New')) AS t(id, name, tier)")

  -- ============ 2. 定义 Pipeline ============
  local pipeline = {
    name = "orders_etl_demo",
    nodes = {
      -- ① 源数据加载
      { id = "src_orders",    type = "source",
        query = "SELECT * FROM demo_orders WHERE status = 'completed'" },
      { id = "src_customers", type = "source",
        query = "SELECT * FROM demo_customers" },

      -- ② 数据清洗
      { id = "clean_orders", type = "transform",
        query = "SELECT id, upper(name) AS name, amount, status FROM src_orders WHERE amount > 0",
        deps = { "src_orders" } },

      -- ③ 数据质量检查
      { id = "quality_check", type = "quality",
        deps = { "clean_orders" },
        checks = {
          { type = "not_null", col = "id" },
          { type = "unique",   col = "id" },
          { type = "rowcount_min", min = 1 },
        } },

      -- ④ 条件路由：有数据才处理
      { id = "has_data", type = "if_node",
        deps = { "quality_check" },
        condition = function(results)
          -- clean_orders 有数据（3 行 completed 订单）
          return (results.quality_check or 0) > 0
        end },

      -- ⑤ 高价值订单（route=true 分支）
      { id = "agg_high_value", type = "transform",
        deps = { "has_data" }, route = "true",
        query = "SELECT name, sum(amount) AS total FROM clean_orders WHERE amount >= 100 GROUP BY name ORDER BY total DESC" },

      -- ⑥ 落表（route=true 分支）
      { id = "sink_high_value", type = "sink",
        deps = { "agg_high_value" }, table = "demo_high_value" },

      -- ⑦ 空数据日志（route=false 分支——因有数据，不会执行）
      { id = "sink_empty_log", type = "sink",
        deps = { "has_data" }, route = "false", table = "demo_empty_log" },

      -- ⑧ 易错节点 + 错误恢复（on_error + retry）
      { id = "risky_join", type = "transform",
        deps = { "src_customers" },
        query = "SELECT c.id, c.name, c.tier FROM src_customers c JOIN nonexistent_table n ON c.id = n.id",
        on_error = "fallback_join",
        retry = { max = 1, backoff = 0.1 } },

      { id = "fallback_join", type = "transform",
        deps = { "src_customers" },
        query = "SELECT id, name, tier, 'fallback' AS note FROM src_customers" },

      -- ⑨ 落 customers 结果
      { id = "sink_customers", type = "sink",
        deps = { "fallback_join" }, table = "demo_vip_customers" },

      -- ⑩ 多路路由演示：switch_node 按金额分桶
      { id = "switch_bucket", type = "switch_node",
        deps = { "clean_orders" },
        selector = function(results)
          -- 如果有高价值订单走 "high" 分支，否则走 "low"
          local rows = _duckdb_query("SELECT count(*) AS n FROM clean_orders WHERE amount >= 100")
          if rows and rows[1] and tonumber(rows[1].n) > 0 then
            return "high"
          end
          return "low"
        end },

      { id = "bucket_report", type = "transform",
        deps = { "switch_bucket" }, route = "high",
        query = "SELECT 'Budget: ' || CAST(sum(amount) AS VARCHAR) AS report FROM clean_orders" },

      { id = "bucket_low_notice", type = "sink",
        deps = { "switch_bucket" }, route = "low", table = "demo_low_notice" },
    },
  }

  -- ============ 3. 执行 Pipeline ============
  local ok, result = pcall(etl.pipeline, pipeline)
  if not ok then
    _duckdb_call("INSERT INTO demo_results VALUES ('ERROR: " .. tostring(result):gsub("'", "''") .. "')")
    return "FAILED: " .. tostring(result)
  end

  -- ============ 4. 验证结果 ============
  local report = {}

  report[#report + 1] = "=" .. string.rep("=", 55) .. "="
  report[#report + 1] = "  etl.pipeline E2E — 验证报告"
  report[#report + 1] = "=" .. string.rep("=", 55) .. "="

  -- 4a. high_value 表
  local hv = _duckdb_query("SELECT * FROM demo_high_value ORDER BY total DESC")
  report[#report + 1] = ""
  report[#report + 1] = "📊 demo_high_value（高价值订单 ≥100）"
  if hv and #hv > 0 then
    for _, r in ipairs(hv) do
      report[#report + 1] = "  " .. tostring(r.name) .. " → " .. tostring(r.total)
    end
  else
    report[#report + 1] = "  (empty)"
  end

  -- 4b. customers 表（含错误恢复）
  local vc = _duckdb_query("SELECT * FROM demo_vip_customers ORDER BY id")
  report[#report + 1] = ""
  report[#report + 1] = "📊 demo_vip_customers（含错误恢复 → fallback 列）"
  if vc and #vc > 0 then
    for _, r in ipairs(vc) do
      report[#report + 1] = "  " .. tostring(r.id) .. "  " .. tostring(r.name) .. "  " .. tostring(r.tier) ..
        (r.note and ("  [" .. tostring(r.note) .. "]") or "")
    end
  end

  -- 4c. empty_log 应为空（route=false 未执行）
  local el = _duckdb_query("SELECT count(*) AS n FROM demo_empty_log")
  local empty_rows = el and el[1] and tonumber(el[1].n) or 0
  report[#report + 1] = ""
  report[#report + 1] = "📊 demo_empty_log（route=false 分支，应 0 行）: " .. tostring(empty_rows) .. " rows"

  -- 4d. 审计日志
  local logs = _duckdb_query("SELECT fn, CAST(duration_ms AS BIGINT) AS ms, CAST(rows AS BIGINT) AS rows, success, err FROM etl_run_log ORDER BY ts DESC LIMIT 15")
  report[#report + 1] = ""
  report[#report + 1] = "📊 审计日志（最近 15 条）"
  report[#report + 1] = "  " .. string.format("%-30s %6s %5s  %-5s %s", "fn", "dur_ms", "rows", "ok?", "err")
  report[#report + 1] = "  " .. string.rep("-", 70)
  if logs then
    for _, r in ipairs(logs) do
      local err = r.err or ""
      report[#report + 1] = "  " .. string.format("%-30s %6s %5s  %-5s %s",
        tostring(r.fn), tostring(r.ms), tostring(r.rows),
        tostring(r.success), tostring(err))
    end
  end

  report[#report + 1] = ""
  report[#report + 1] = "=" .. string.rep("=", 55) .. "="
  report[#report + 1] = "  ✅ E2E 演示完成"
  report[#report + 1] = "=" .. string.rep("=", 55) .. "="

  return table.concat(report, "\n")
end