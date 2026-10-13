-- test_rsi_scorer.sql — rsi_scorer E2E（duckdb156 -unsigned < test_rsi_scorer.sql）
-- 覆盖：compile 注册 / default_weights / score（好/坏锚点）/ select（argmax+权重覆盖）/ update_weights（感知机）
-- 前置：扩展路径按本机调整（v1.5.6 线）；锚点值 = 2026-10-13 实测（见 libs/ml/rsi_scorer.lua 头部文档）

LOAD '/tmp/rsi-luajit/home/extensions/v1.5.6/linux_amd64/luajit.duckdb_extension';

SET VARIABLE src = (SELECT content FROM read_text('/mnt/d/wsl2/duckdb-luajit-libs/libs/ml/rsi_scorer.lua'));
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'rsi_scorer', source := getvariable('src'));

-- 1) 出厂权重
SELECT luajit_s('rsi_scorer', {op:'default_weights'}) AS w0;  -- 期望 exec_ok=2, row_count=1, latency_ms=0.5, null_rate=1, error_class=0.2

-- 2) score 锚点：全优候选 2.98（exec 2×1 + row 1×1 + latency 0.5×0 + null 1×(-0.02) + err 0.2×0）
SELECT luajit_s('rsi_scorer', {op:'score', f:{exec_ok:1, row_count:1000, expect_rows:1000, latency_ms:120, null_rate:0.01, error_class:'ok'}}) ->> '$.score' AS good;   -- '2.98'
SELECT luajit_s('rsi_scorer', {op:'score', f:{exec_ok:0, row_count:0, latency_ms:90, null_rate:0, error_class:'syntax'}}) ->> '$.score' AS bad;                          -- '-2.18'

-- 3) select：4 候选（c1 全优/c3 行数 3x/c4 慢/c2 报错）→ argmax=c1
SELECT luajit_s('rsi_scorer', {op:'select', candidates:[
  {candidate_id:'c2', features:{exec_ok:0, row_count:0, latency_ms:70, null_rate:0, error_class:'runtime'}},
  {candidate_id:'c1', features:{exec_ok:1, row_count:1000, expect_rows:1000, latency_ms:120, null_rate:0.01, error_class:'ok'}},
  {candidate_id:'c3', features:{exec_ok:1, row_count:3000, expect_rows:1000, latency_ms:200, null_rate:0.05, error_class:'ok'}},
  {candidate_id:'c4', features:{exec_ok:1, row_count:1000, expect_rows:1000, latency_ms:9000, null_rate:0.02, error_class:'ok'}}
]}) ->> '$.selected_id' AS sel_argmax;  -- 'c1'

-- 4) select 权重覆盖：exec_ok 归零 → 行数合理者胜（a: 1000/1000 行 b: 0 行）
SELECT luajit_s('rsi_scorer', {op:'select', weights:{exec_ok:0, row_count:1}, candidates:[
  {candidate_id:'a', features:{exec_ok:0, row_count:1000, expect_rows:1000}},
  {candidate_id:'b', features:{exec_ok:1, row_count:0, expect_rows:1000}}
]}) ->> '$.selected_id' AS sel_override;  -- 'a'

-- 5) update_weights：正负例均未违反感知机间隔 → updates=0（权重不动）
SELECT luajit_s('rsi_scorer', {op:'update_weights', history:[
  {features:{exec_ok:1, row_count:1000, expect_rows:1000, latency_ms:120, null_rate:0.01, error_class:'ok'}, pass:1},
  {features:{exec_ok:0, row_count:0, latency_ms:90, null_rate:0, error_class:'syntax'}, pass:0}
]}) ->> '$.updates' AS upd_zero;  -- '0'

-- 6) update_weights：正例但 exec_ok=0（违反间隔，epochs=3 默认）→ exec_ok 2→1.7、bias→0.3
SELECT luajit_s('rsi_scorer', {op:'update_weights', history:[{features:{exec_ok:0}, pass:1}]}) AS uw_forced;
  -- 期望 weights.exec_ok=1.7, bias=0.3, updates=3（每 epoch 1 次更新）

-- 7) JSON 入参通道：features/weights 传 JSON 字符串等价 struct
SELECT luajit_s('rsi_scorer', {op:'score', f:'{ "exec_ok": 1, "row_count": 500, "expect_rows": 500 }', weights:'{ "exec_ok": 2, "row_count": 1 }'}) ->> '$.score' AS json_path;  -- '3'
