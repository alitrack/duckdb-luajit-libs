-- privacy.lua 锚定测试 v2（RNG 重写为 Park-Miller/Schrage 后）
local f = dofile('privacy.lua')
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
local function ok(desc, cond)
  if cond then passed = passed + 1; print("  ✓ " .. desc)
  else failed = failed + 1; print("  ✗ " .. desc) end
end

-- 锚 1: mask star（11 位手机号 → 首1尾1，中间 9 星）
check('mask star phone', f({v = '13800138000', mode = 'star', op = 'mask'}), '1*********0')
check('mask star short', f({v = 'ab', mode = 'star', op = 'mask'}), '**')
-- 锚 2: mask hash 确定性 + 盐敏感 + 无 NaN
local h1 = f({v = 'Alice@example.com', salt = 's1', mode = 'hash', op = 'mask'})
local h2 = f({v = 'Alice@example.com', salt = 's1', mode = 'hash', op = 'mask'})
local h3 = f({v = 'Alice@example.com', salt = 's2', mode = 'hash', op = 'mask'})
check('hash deterministic', h1, h2)
ok('hash salt changes output', h1 ~= h3 and not h1:match('nan'))
print("  hash(s1)=" .. h1 .. " hash(s2)=" .. h3)
-- 锚 3: mask bin
check('mask bin', f({v = '37', lo = 0, hi = 100, bins = 10, mode = 'bin', op = 'mask'}), '[30,40)')
-- 锚 4: mask rand 确定性
check('rand deterministic', f({v = '张三', salt = 'x', mode = 'rand', op = 'mask'}),
  f({v = '张三', salt = 'x', mode = 'rand', op = 'mask'}))
-- 锚 5: dp_count 确定性 + ε 灵敏度（低 ε → 更大噪声，200 样本极差对比）
local c1 = f({true_count = 1000, epsilon = 1.0, seed = 42, op = 'dp_count'})
local c2 = f({true_count = 1000, epsilon = 1.0, seed = 42, op = 'dp_count'})
check('dp_count deterministic', c1, c2)
ok('dp_count sane', tonumber(c1) ~= nil and math.abs(tonumber(c1) - 1000) < 50)
local spread_hi, spread_lo = 0, 0
for i = 1, 200 do
  local v = tonumber(f({true_count = 1000, epsilon = 0.1, seed = i, op = 'dp_count'}))
  spread_hi = math.max(spread_hi, math.abs(v - 1000))
  local w = tonumber(f({true_count = 1000, epsilon = 10, seed = i, op = 'dp_count'}))
  spread_lo = math.max(spread_lo, math.abs(w - 1000))
end
print(string.format("  dp_count spread: eps=0.1 → %d, eps=10 → %d", spread_hi, spread_lo))
ok('epsilon sensitivity', spread_hi > spread_lo * 3)
-- 锚 6: dp_mean —— 单次抽取受 Laplace 重尾影响（|m-50|<30 即可），200 次平均应收敛到 50±5
local m = tonumber(f({true_sum = 5000, true_count = 100, range = 100, epsilon = 1.0, seed = 7, op = 'dp_mean'}))
print("  dp_mean(seed=7) = " .. tostring(m))
ok('dp_mean single sane', m ~= nil and math.abs(m - 50) < 30)
local acc = 0
for i = 1, 200 do
  local v = tonumber(f({true_sum = 5000, true_count = 100, range = 100, epsilon = 1.0, seed = i, op = 'dp_mean'}))
  acc = acc + v
end
local avg = acc / 200
print(string.format("  dp_mean avg(200 seeds) = %.2f (true 50)", avg))
ok('dp_mean converges', math.abs(avg - 50) < 5)
-- 锚 7: kanon —— 4 条 2 组 k=2（age 泛化区间；city 共享前缀）
local k = f({records = {
  {id = 1, qi = {age = 25, city = 'hz'}},
  {id = 2, qi = {age = 26, city = 'hz'}},
  {id = 3, qi = {age = 60, city = 'sh'}},
  {id = 4, qi = {age = 61, city = 'sh'}},
}, k = 2, op = 'kanon'})
print("  kanon = " .. k)
local cnt2 = 0
for _ in k:gmatch('"size":2') do cnt2 = cnt2 + 1 end
ok('kanon exactly 2 groups of 2', cnt2 == 2)
ok('kanon age intervals', k:match('%[25,26%]') ~= nil and k:match('%[60,61%]') ~= nil)
ok('kanon city prefix kept', k:match('"city":"hz"') ~= nil and k:match('"city":"sh"') ~= nil)
-- 锚 8: kanon 2 行 k=2 → 单组不抑制
local k2 = f({records = {{id = 1, qi = {age = 25}}, {id = 2, qi = {age = 30}}}, k = 2, op = 'kanon'})
ok('kanon small group', k2:match('"suppressed":0') ~= nil)

print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
