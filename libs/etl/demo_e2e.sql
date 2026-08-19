-- etl.pipeline E2E 演示（2026-08-20）
-- 用法：duckdb -unsigned < demo_e2e.sql
-- 演示：Pipeline 引擎 v2 全部能力
--   source / transform / quality / if_node / switch_node / sink
--   条件路由 / 重试 / 超时 / 错误恢复 / 审计

-- ============ 1. 准备数据 ============
CREATE OR REPLACE TABLE orders AS SELECT * FROM (VALUES
  (1, 'Alice',   250.0, 'completed'),
  (2, 'Bob',     150.0, 'completed'),
  (3, 'Charlie',  80.0, 'pending'),
  (4, 'Diana',   500.0, 'completed'),
  (5, 'Eve',      30.0, 'cancelled')
) AS t(id, name, amount, status);

CREATE OR REPLACE TABLE customers AS SELECT * FROM (VALUES
  (1, 'Alice',    'VIP'),
  (2, 'Bob',      'Regular'),
  (4, 'Diana',    'VIP'),
  (6, 'Frank',    'New')
) AS t(id, name, tier);

.print '✅ 数据准备完成'

-- ============ 2. 安装 etl 模块 ============
SELECT * FROM luajit_module(mode := 'install', sql_name := 'etl');

-- 编译 pipeline 执行函数
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'etl_run_pipeline',
  source := 'return function(p) return etl.pipeline(p) end');

.print '✅ etl 模块已加载'

-- ============ 3. 运行 Pipeline ============
-- 完整 ETL 流程：
--   src_orders ─→ clean_orders ─→ quality_check ─→ has_data?(if_node)
--                                                   ├─ true → agg_high_value → sink_high_value
--                                                   └─ false → sink_empty_log
--   src_customers ─→ risky_join ─→ fallback_join (on_error 恢复)

SELECT luajit_s('etl_run_pipeline', '{
  "name": "orders_etl_demo",
  "nodes": [
    -- ① 源数据加载
    {"id": "src_orders",   "type": "source",
     "query": "SELECT * FROM orders WHERE status = ''completed''"},
    {"id": "src_customers","type": "source",
     "query": "SELECT * FROM customers"},

    -- ② 数据清洗
    {"id": "clean_orders", "type": "transform",
     "query": "SELECT id, upper(name) AS name, amount, status FROM src_orders WHERE amount > 0",
     "deps": ["src_orders"]},

    -- ③ 数据质量检查
    {"id": "quality_check", "type": "quality",
     "deps": ["clean_orders"],
     "checks": [
       {"type": "not_null", "col": "id"},
       {"type": "unique", "col": "id"},
       {"type": "rowcount_min", "min": 1}
     ]},

    -- ④ 条件路由：有数据才处理
    {"id": "has_data", "type": "if_node",
     "deps": ["quality_check"],
     "condition": null},

    -- ⑤ 高价值订单（route=true 分支）
    {"id": "agg_high_value", "type": "transform",
     "deps": ["has_data"], "route": "true",
     "query": "SELECT name, sum(amount) AS total FROM clean_orders WHERE amount >= 100 GROUP BY name ORDER BY total DESC"},

    -- ⑥ 落表（route=true 分支）
    {"id": "sink_high_value", "type": "sink",
     "deps": ["agg_high_value"], "table": "high_value_orders"},

    -- ⑦ 空数据日志（route=false 分支——本例不会执行）
    {"id": "sink_empty_log", "type": "sink",
     "deps": ["has_data"], "route": "false", "table": "empty_log"},

    -- ⑧ 易错节点 + 错误恢复
    {"id": "risky_join", "type": "transform",
     "deps": ["src_customers"],
     "query": "SELECT c.id, c.name, c.tier FROM src_customers c JOIN nonexistent_table n ON c.id = n.id",
     "on_error": "fallback_join",
     "retry": {"max": 1, "backoff": 0.1}},

    {"id": "fallback_join", "type": "transform",
     "deps": ["src_customers"],
     "query": "SELECT id, name, tier, ''fallback'' AS note FROM src_customers"},

    -- ⑨ 落 customers 结果
    {"id": "sink_customers", "type": "sink",
     "deps": ["fallback_join"], "table": "vip_customers"}
  ]
}');

.print ''
.print '✅ Pipeline 执行完毕'
.print ''

-- ============ 4. 验证结果 ============
.print '═══════════════════════════════════════'
.print '📊 结果验证'
.print '═══════════════════════════════════════'

.print ''
.print '--- high_value_orders（高价值订单）---'
SELECT * FROM high_value_orders;

.print ''
.print '--- vip_customers（含错误恢复的客户数据）---'
SELECT * FROM vip_customers;

.print ''
.print '--- 审计日志（最近 10 条）---'
SELECT CAST(run_id AS BIGINT) AS run_id, ts, fn,
       CAST(duration_ms AS BIGINT) AS duration_ms,
       CAST(rows AS BIGINT) AS rows, success, err
FROM etl_run_log ORDER BY ts DESC LIMIT 10;

.print ''
.print '--- empty_log（应为空，route=false 分支未执行）---'
SELECT COUNT(*) AS empty_log_rows FROM empty_log;

.print ''
.print '═══════════════════════════════════════'
.print '🎉 E2E 演示完成'
.print '═══════════════════════════════════════'