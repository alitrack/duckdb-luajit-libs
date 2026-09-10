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

-- 锚 9: mask_cn —— CN 合规规则库（格式保持 + fail-closed + hash 确定性）
check('cn idcard18 star', f({v = '110101199003071234', kind = 'idcard', op = 'mask_cn'}), '110101********1234')
check('cn idcard15 star', f({v = '110101900307123', kind = 'idcard', op = 'mask_cn'}), '110101*****7123')
check('cn idcard birth generalize', f({v = '110101199003071234', kind = 'idcard', mode = 'birth', op = 'mask_cn'}),
  '110101199001011234')
check('cn idcard15 birth generalize', f({v = '110101900307123', kind = 'idcard', mode = 'birth', op = 'mask_cn'}),
  '110101900101123')
check('cn mobile star', f({v = '13800138000', op = 'mask_cn'}), '138****8000')  -- auto 识别
check('cn bankcard16 star', f({v = '6222021234567890', kind = 'bankcard', op = 'mask_cn'}), '622202******7890')
check('cn bankcard19 star', f({v = '6222021234567890123', kind = 'bankcard', op = 'mask_cn'}), '622202*********0123')
check('cn name 2char', f({v = '张三', kind = 'name', op = 'mask_cn'}), '张*')
check('cn name 3char', f({v = '王小明', kind = 'name', op = 'mask_cn'}), '王**')
check('cn name compound surname', f({v = '欧阳锋', kind = 'name', op = 'mask_cn'}), '欧阳*')
check('cn email', f({v = 'zhangsan@example.com', op = 'mask_cn'}), 'z***@example.com')
check('cn auto idcard', f({v = '110101199003071234', op = 'mask_cn'}), '110101********1234')
-- 格式保持：长度不变（下游长度校验不炸）
for _, t in ipairs({ { '110101199003071234', 'idcard', 18 }, { '13800138000', 'mobile', 11 },
  { '6222021234567890', 'bankcard', 16 } }) do
  ok('cn length preserved (' .. t[2] .. ')', #f({ v = t[1], kind = t[2], op = 'mask_cn' }) == t[3])
end
-- fail-closed：长度不符 / 非数字 → 通用 star 全掩，绝不原样透出
local fc = f({ v = '12345', kind = 'idcard', op = 'mask_cn' })
ok('cn fail-closed idcard len mismatch', fc == '1***5' and not fc:match('234'))
local fc2 = f({ v = 'abcdef', kind = 'mobile', op = 'mask_cn' })
ok('cn fail-closed mobile non-numeric', fc2 == 'a****f' and fc2 ~= 'abcdef')
-- UTF-8 安全：非 ASCII 兜底按字切分（不产出半个汉字）
check('cn generic utf8 head/tail', f({ v = '张三丰', kind = 'generic', op = 'mask_cn' }), '张*丰')
check('cn auto undetected cjk', f({ v = '这是一个很长的中文串', op = 'mask_cn' }), '这********串')
-- hash 模式：确定性（同输入同输出 = 可作外键）+ 盐敏感 + 前缀保留
local mh1 = f({ v = '110101199003071234', kind = 'idcard', mode = 'hash', salt = 'k1', op = 'mask_cn' })
local mh2 = f({ v = '110101199003071234', kind = 'idcard', mode = 'hash', salt = 'k1', op = 'mask_cn' })
local mh3 = f({ v = '110101199003071234', kind = 'idcard', mode = 'hash', salt = 'k2', op = 'mask_cn' })
check('cn hash deterministic', mh1, mh2)
ok('cn hash salt-sensitive', mh1 ~= mh3)
ok('cn hash keeps idcard region prefix', mh1:sub(1, 6) == '110101' and mh1:match('^110101#%x%x%x%x%x%x%x%x$') ~= nil)
print("  mask_cn hash(salt k1) = " .. mh1)

-- 锚 10: dateshift —— 临床日期平移（可证伪三断言 + 独立日期引擎交叉验证）
local function dnum(s)  -- 独立实现（os.time/mktime，与本 lib 的 Hinnant 算法不同源）
  local y, m, d = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 86400
end
local D = f({ v = '2150-03-04', key = '10001', days = 180, op = 'dateshift', with_delta = true })
local sd, sdl = D:match('^(.-)|(-?%d+)$')
print("  dateshift(2150-03-04, key=10001, ±180) = " .. sd .. " (delta " .. sdl .. ")")
ok('dateshift format valid', sd:match('^%d%d%d%d%-%d%d%-%d%d$') ~= nil)
ok('dateshift delta matches independent engine', dnum(sd) - dnum('2150-03-04') == tonumber(sdl))
-- 断言① 同 subject 恒同偏移（两次调用 + 跨不同日期）
local D2 = f({ v = '2150-03-04', key = '10001', days = 180, op = 'dateshift', with_delta = true })
ok('dateshift deterministic (same key)', D == D2)
local Da = f({ v = '2150-01-01', key = '10001', days = 180, op = 'dateshift' })
local Db = f({ v = '2150-12-31', key = '10001', days = 180, op = 'dateshift' })
ok('dateshift same key ⇒ same offset across dates',
  (dnum(Da) - dnum('2150-01-01')) == (dnum(Db) - dnum('2150-12-31')))
ok('dateshift dateoffset agrees', tonumber(f({ key = '10001', days = 180, op = 'dateoffset' })) == tonumber(sdl))
-- 断言② max|delta| ≤ days（300 个 key 扫描）
local worst = 0
for i = 1, 300 do
  local r = f({ v = '2150-06-15', key = 'subj' .. i, days = 30, op = 'dateshift', with_delta = true })
  worst = math.max(worst, math.abs(tonumber(r:match('|(-?%d+)$'))))
end
print("  max |delta| over 300 keys (days=30) = " .. worst)
ok('dateshift |delta| <= days', worst <= 30)
-- 断言③ 相对时间（住院第几天 / 两事件间隔）逐位不变
local lo, hi = '2150-03-01', '2150-03-09'
local ls, hs = f({ v = lo, key = 'p7', days = 365, op = 'dateshift' }), f({ v = hi, key = 'p7', days = 365, op = 'dateshift' })
ok('dateshift preserves interval', (dnum(hi) - dnum(lo)) == (dnum(hs) - dnum(ls)) and (dnum(hs) - dnum(ls)) == 8)
-- 闰年/跨年：2020-02-29 与 2020-12-31 平移后仍是合法日期且位移精确
local leap = f({ v = '2020-02-29', key = 'leap', days = 366, op = 'dateshift', with_delta = true })
local ld, ldl = leap:match('^(.-)|(-?%d+)$')
ok('dateshift leap-day valid', ld:match('^%d%d%d%d%-%d%d%-%d%d$') ~= nil and dnum(ld) - dnum('2020-02-29') == tonumber(ldl))
local ye = f({ v = '2023-12-31', key = 'ye', days = 10, op = 'dateshift', with_delta = true })
local yd, ydl = ye:match('^(.-)|(-?%d+)$')
ok('dateshift year rollover', dnum(yd) - dnum('2023-12-31') == tonumber(ydl))
-- 时间部分原样保留 / days=0 恒等 / 非法日期 → 'null'
ok('dateshift keeps time part', f({ v = '2150-03-04 08:30:00', key = 'k', days = 7, op = 'dateshift' }):match(' 08:30:00$') ~= nil)
check('dateshift days=0 identity', f({ v = '2150-03-04', key = 'k', days = 0, op = 'dateshift' }), '2150-03-04')
check('dateshift invalid calendar day', f({ v = '2023-02-30', key = 'k', op = 'dateshift' }), 'null')
check('dateshift invalid month', f({ v = '2023-13-01', key = 'k', op = 'dateshift' }), 'null')
check('dateshift garbage', f({ v = 'not-a-date', key = 'k', op = 'dateshift' }), 'null')

print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
