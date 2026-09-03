-- entity.lua 锚定测试
local f = dofile('entity.lua')
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

-- 锚 1: Soundex 经典锚点（标准表）
check('soundex Robert', f({v = 'Robert', mode = 'soundex', op = 'block'}), 'R163')
check('soundex Rupert', f({v = 'Rupert', mode = 'soundex', op = 'block'}), 'R163')
check('soundex Ashcraft', f({v = 'Ashcraft', mode = 'soundex', op = 'block'}), 'A261')
check('soundex Tymczak', f({v = 'Tymczak', mode = 'soundex', op = 'block'}), 'T522')

-- 锚 2: first3（标准化后取前 3 代码点；中文 OK）
check('first3 latin', f({v = '  John,Smith! ', mode = 'first3', op = 'block'}), 'joh')
check('first3 chinese', f({v = '王小明的客户', mode = 'first3', op = 'block'}), '王小明')

-- 锚 3: Jaro-Winkler（前缀权重 0.25 = fuzzy lib 约定；经典 0.9611 是 p=0.1 口径）
check('jw martha/marhta', f({a = 'martha', b = 'marhta', op = 'match'}), '0.9861')
check('jw jones/johns', f({a = 'jones', b = 'johns', op = 'match'}), '0.9333')
check('jw identical', f({a = 'Alice Chen', b = 'Alice Chen', op = 'match'}), '1.0000')
check('jw chinese similar', f({a = '王小明', b = '王小民', op = 'match'}), '0.8889')

-- 锚 4: resolve 完整管道——同人不同写法合并
local r = f({records = {
  {id = 1, name = 'Alice Chen', city = 'Hangzhou'},
  {id = 2, name = 'Alice Chen', city = 'HZ'},
  {id = 3, name = 'Bob Li', city = 'Shanghai'},
  {id = 4, name = 'Bob Lee', city = 'SH'},
  {id = 5, name = 'Charlie', city = 'Beijing'},
}, key_fields = {'name', 'city'}, threshold = 0.88, op = 'resolve'})
print("  resolve = " .. r)
-- 断言：两个 2 人簇 + 1 个单例；canonical 正确
local ok1 = r:match('"cluster":1,"ids":%[1,2%]') or r:match('"ids":%[1,2%]')
local ok2 = r:match('"ids":%[3,4%]')
local ok3 = r:match('"size":2') and r:match('"size":2') ~= nil
local cnt2 = 0
for m in r:gmatch('"size":2') do cnt2 = cnt2 + 1 end
if ok1 and ok2 and cnt2 == 2 then passed = passed + 1 else failed = failed + 1 end

-- 锚 5: 无重复 → 全单例（pairs=0）
local r2 = f({records = {{id = 1, name = 'Alpha'}, {id = 2, name = 'Beta'}, {id = 3, name = 'Gamma'}},
  threshold = 0.88, op = 'resolve'})
print("  resolve-distinct = " .. r2)
if r2:match('"pairs":0') and r2:match('"clusters":%[%{.*%},%{.*%},%{.*%}%]') then
  passed = passed + 1
else
  failed = failed + 1
end

print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
