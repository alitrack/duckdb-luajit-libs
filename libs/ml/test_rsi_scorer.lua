-- test_rsi_scorer.lua — 锚定测试（luajit test_rsi_scorer.lua；无 luajit 时跑 test_rsi_scorer.sql 同锚点）
-- 锚点值 = 2026-10-13 实测（与 test_rsi_scorer.sql 一致）
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: poc
local f = dofile('rsi_scorer.lua')
local passed, failed = 0, 0
local function check(desc, got, expect)
  if tostring(got) == tostring(expect) then
    passed = passed + 1
    print("  ✓ " .. desc .. " = " .. tostring(got))
  else
    failed = failed + 1
    print("  ✗ " .. desc .. " got=" .. tostring(got) .. " expect=" .. tostring(expect))
  end
end

local function jfield(s, k)
  return s:match('"' .. k .. '":([^,}]+)')
end

-- ===== op=default_weights：出厂权重 =====
local dw = f({op = 'default_weights'})
check('default exec_ok', jfield(dw, 'exec_ok'), '2')
check('default row_count', jfield(dw, 'row_count'), '1')
check('default latency_ms', jfield(dw, 'latency_ms'), '0.5')
check('default null_rate', jfield(dw, 'null_rate'), '1')
check('default error_class', jfield(dw, 'error_class'), '0.2')

-- ===== op=score：实测锚点（latency 预算内 base=0；error_class 'ok' base=0）=====
-- 全优：exec 2×1 + row 1×1 + lat 0.5×0 + null 1×(-0.02) + err 0.2×0 = 2.98
local good = f({op='score', f={exec_ok=1, row_count=1000, expect_rows=1000, latency_ms=120, null_rate=0.01, error_class='ok'}})
check('score good', jfield(good, 'score'), '2.98')
-- 报错：exec -2 + syntax(-0.9×0.2=-0.18) = -2.18
local bad = f({op='score', f={exec_ok=0, row_count=0, latency_ms=90, null_rate=0, error_class='syntax'}})
check('score bad', jfield(bad, 'score'), '-2.18')

-- ===== op=select：4 候选 → argmax=c1，ranking 首位 c1 =====
local sel = f({op='select', candidates={
  {candidate_id='c2', features={exec_ok=0, row_count=0, latency_ms=70, null_rate=0, error_class='runtime'}},
  {candidate_id='c1', features={exec_ok=1, row_count=1000, expect_rows=1000, latency_ms=120, null_rate=0.01, error_class='ok'}},
  {candidate_id='c3', features={exec_ok=1, row_count=3000, expect_rows=1000, latency_ms=200, null_rate=0.05, error_class='ok'}},
  {candidate_id='c4', features={exec_ok=1, row_count=1000, expect_rows=1000, latency_ms=9000, null_rate=0.02, error_class='ok'}},
}})
check('select argmax', jfield(sel, 'selected_id'), '"c1"')
check('ranking first', sel:match('"candidate_id":"(c%d)","rank":1'), 'c1')

-- 权重覆盖：exec_ok 归零 → 行数合理者胜（a: 1000/1000；b: 0 行被 row_count 罚）
local sel2 = f({op='select', weights={exec_ok=0, row_count=1}, candidates={
  {candidate_id='a', features={exec_ok=0, row_count=1000, expect_rows=1000}},
  {candidate_id='b', features={exec_ok=1, row_count=0, expect_rows=1000}},
}})
check('weights override works', jfield(sel2, 'selected_id'), '"a"')

-- ===== op=update_weights =====
-- 正负例均不违反感知机间隔 → updates=0（权重不动）
local uw = f({op='update_weights', history={
  {features={exec_ok=1, row_count=1000, expect_rows=1000, latency_ms=120, null_rate=0.01, error_class='ok'}, pass=1},
  {features={exec_ok=0, row_count=0, latency_ms=90, null_rate=0, error_class='syntax'}, pass=0},
}})
check('no-margin-violation → no update', jfield(uw, 'updates'), '0')
check('samples counted', jfield(uw, 'samples'), '2')

-- 正例但 exec_ok=0（违反间隔；epochs 默认 3 → 每 epoch 1 次更新）
-- base(exec_ok=0)=-1 → z=-2<0 且 y=1 → w.exec_ok -= 0.1/epoch → 2→1.7；bias += 0.1/epoch → 0.3
local uw2 = f({op='update_weights', history={{features={exec_ok=0}, pass=1}}})
check('perceptron pulls exec_ok', jfield(uw2, 'exec_ok'), '1.7')
check('perceptron adjusts bias', jfield(uw2, 'bias'), '0.3')
check('updates = epochs × 1', jfield(uw2, 'updates'), '3')

-- ===== JSON 入参通道 =====
local gj = f({op='score', f='{ "exec_ok": 1, "row_count": 500, "expect_rows": 500 }', weights='{ "exec_ok": 2, "row_count": 1 }'})
check('json input path', jfield(gj, 'score'), '3')

-- ===== 容错：未知 op 显式报错 =====
check('unknown op flagged', f({op='nope'}):match('unknown op') ~= nil, 'true')

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
