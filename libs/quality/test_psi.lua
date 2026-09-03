-- psi.lua 锚定测试 v2：精确可算占比锚点 + 相对性质断言
local f = dofile('psi.lua')
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

-- 锚 1: 相同分布 → PSI=0（占比数组直接传）
check('identical shares', f({e = {0.2,0.3,0.3,0.2}, a = {0.2,0.3,0.3,0.2}, op = 'psi'}), '0.0000')

-- 锚 2: 手工可算占比锚点 → PSI = Σ(a-e)ln(a/e) = 0.2484906...
--    (0.1-0.2)ln0.5 + (0.2-0.3)ln(2/3) + 0 + (0.4-0.2)ln2 = 0.0693147+0.0405465+0.1386294 = 0.2484906
check('manual shares psi', f({e = {0.2,0.3,0.3,0.2}, a = {0.1,0.2,0.3,0.4}, op = 'psi'}), '0.2485')

-- 锚 3: report 同锚点 → verdict=moderate-drift（0.10<0.2485<=0.25）
local rep = f({e = {0.2,0.3,0.3,0.2}, a = {0.1,0.2,0.3,0.4}, op = 'report'})
print("  report = " .. rep)
if rep:match('"verdict":"moderate%-drift"') and rep:match('"psi":0%.2485') then
  passed = passed + 1
else
  failed = failed + 1
end

-- 锚 4: 原始数组自动分箱，性质断言：相同=0 < 平移分布 < 完全分离
local id = tonumber(f({raw_e = {1,2,3,4,5}, raw_a = {1,2,3,4,5}, op = 'psi'}))
local shifted = tonumber(f({raw_e = {1,2,3,4,5,6,7,8,9,10}, raw_a = {2,3,4,5,6,7,8,9,10,11}, op = 'psi'}))
local sep = tonumber(f({raw_e = {1,1,1,1,1}, raw_a = {100,100,100,100,100}, op = 'psi'}))
print(string.format("  order-check: id=%g shifted=%g sep=%g", id, shifted, sep))
if id == 0 and shifted > 0 and sep > shifted then passed = passed + 1 else failed = failed + 1 end

-- 锚 5: 显式边界分箱（同箱占用 → 0）
check('breaks same-occupancy', f({raw_e = {1,5,9}, raw_a = {2,6,10}, breaks = {3,7}, op = 'psi'}), '0.0000')

-- 锚 6: 常量列兜底
check('constant col', f({raw_e = {5,5,5,5}, raw_a = {5,5,5,5}, op = 'psi'}), '0.0000')

-- 锚 7: 占比数组不等长 → error
local e = f({e = {0.5,0.5}, a = {1.0}, op = 'psi'})
if e:match('error') then passed = passed + 1 else failed = failed + 1 end

-- 锚 8: KL 正性
local k = tonumber(f({raw_e = {1,1,1,1,1}, raw_a = {100,100,100,100,100}, op = 'kl'}))
if k and k > 0 then passed = passed + 1 else failed = failed + 1 end

-- 锚 9: chi2 可用
local c = f({raw_e = {1,2,3,4,5,6,7,8,9,10}, raw_a = {1,1,1,1,1,10,10,10,10,10}, op = 'chi2'})
print("  chi2 = " .. tostring(c))
if c and tonumber(c) and tonumber(c) > 0 then passed = passed + 1 else failed = failed + 1 end

print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
