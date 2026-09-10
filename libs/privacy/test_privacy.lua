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

-- ============ P1：ε 预算台账（dp_compose / dp_alloc / dp_budget）============
-- JSON 字段提取：⚠️ Lua pattern 无 `|` 交替（写 (a|b) 会静默匹配失败 → nil），
-- 故用「取到逗号/右花括号为止」再剥引号（本 lib 的字符串字段值里都不含逗号）
local function jget(s, key)
  local v = s:match('"' .. key .. '":([^,}]+)')
  if not v then return nil end
  if v:sub(1, 1) == '"' then return v:sub(2, -2) end
  return v
end
local function jnum(s, key) return tonumber(jget(s, key)) end
local function jbool(s, key) return jget(s, key) == 'true' end
local function jnear(a, b, tol) return a ~= nil and math.abs(a - b) <= (tol or 1e-3) end

-- 锚 10: dp_compose —— basic 精确；advanced = Dwork-Roth 强组合
local cp10 = f({epsilon = 0.1, count = 10, delta = 1e-5, op = 'dp_compose'})
check('compose n', jnum(cp10, 'n'), 10)
ok('compose basic = Σε', jnear(jnum(cp10, 'basic_total'), 1.0, 1e-6))
ok('compose advanced (n=10,ε=0.1) ≈ 1.6226', jnear(jnum(cp10, 'advanced_total'), 1.622598, 1e-4))
ok('compose small n: advanced > basic（诚实：此时应取 basic）',
  jnum(cp10, 'advanced_total') > jnum(cp10, 'basic_total'))
-- n=100, ε=0.01 → 强组合 0.4899 < basic 1.0（大 n 时高级组合更紧 = 记账的价值）
local cp100 = f({epsilon = 0.01, count = 100, delta = 1e-5, op = 'dp_compose'})
ok('compose advanced (n=100,ε=0.01) ≈ 0.4899', jnear(jnum(cp100, 'advanced_total'), 0.489903, 1e-4))
ok('compose large n: advanced < basic', jnum(cp100, 'advanced_total') < jnum(cp100, 'basic_total'))
-- 数组形式与均匀形式一致
local arr = {}
for i = 1, 10 do arr[i] = 0.1 end
local cp_arr = f({epsilons = arr, delta = 1e-5, op = 'dp_compose'})
ok('compose array == uniform', jnear(jnum(cp_arr, 'advanced_total'), jnum(cp10, 'advanced_total'), 1e-9))

-- 锚 11: dp_alloc —— 同预算下切给 n 条查询；两种界取更紧者
local al100 = f({budget = 1.0, n = 100, delta = 1e-5, op = 'dp_alloc'})
check('alloc best@n=100', jget(al100, 'best'), 'advanced')
ok('alloc per_query@n=100（默认 basic）= 0.01', jnear(jnum(al100, 'per_query'), 0.01, 1e-9))
ok('alloc 推荐值 ≈ 0.02（比 basic 翻倍 = 记账的价值）',
  jnear(jnum(al100, 'recommended_per_query'), 0.019998, 5e-4))
ok('alloc 界不超预算', jnum(al100, 'advanced_total') <= 1.0 + 1e-9)
local al10 = f({budget = 1.0, n = 10, delta = 1e-5, op = 'dp_alloc'})
check('alloc best@n=10 (basic 更紧)', jget(al10, 'best'), 'basic')
ok('alloc n=10: basic_per > advanced_per', jnum(al10, 'basic_per') > jnum(al10, 'advanced_per'))
local al10a = f({budget = 1.0, n = 10, delta = 1e-5, composition = 'advanced', op = 'dp_alloc'})
ok('alloc 强制 advanced 口径时 per_query = advanced_per',
  jnear(jnum(al10a, 'per_query'), jnum(al10a, 'advanced_per'), 1e-9))

-- 锚 12: dp_budget —— 单步台账门禁（账本求和 / 标量 spent / 超预算拒批 / 高级组合口径）
local b1 = f({budget = 1.0, request = 0.4, ledger = {{epsilon = 0.3}, {epsilon = 0.2}}, op = 'dp_budget'})
ok('budget allow', jbool(b1, 'allow'))
check('budget entries', jnum(b1, 'entries'), 2)
ok('budget spent_after=0.9', jnear(jnum(b1, 'spent_after'), 0.9, 1e-6))
ok('budget remaining_after=0.1', jnear(jnum(b1, 'remaining_after'), 0.1, 1e-6))
local b2 = f({budget = 1.0, request = 0.6, ledger = {{epsilon = 0.3}, {epsilon = 0.2}}, op = 'dp_budget'})
ok('budget deny over budget', not jbool(b2, 'allow'))
check('budget deny reason', jget(b2, 'reason'), 'budget_exceeded')
local b3 = f({budget = 1.0, request = 0.3, spent = 0.8, op = 'dp_budget'})
ok('budget 标量 spent 也计入', not jbool(b3, 'allow') and jnear(jnum(b3, 'spent_before'), 0.8, 1e-6))
-- 100×0.01 用 basic 已正好耗尽 1.0（1.00）；advanced 认为只花 0.4899 → 再申请 0.01 仍放行（两种口径对照）
-- 注：advanced = Σε(e^ε−1) + √(2 ln(1/δ') · Σε_i²) —— 根号项不乘 ε（Σε_i² 已含 ε²），
--     20×0.05 时 advanced=1.124 > basic=1.0（小 n 高级组合更差），故必须用 n 大、ε 小的账本
local led100 = {}
for i = 1, 100 do led100[i] = {epsilon = 0.01} end
local b4 = f({budget = 1.0, request = 0.01, ledger = led100, composition = 'advanced', op = 'dp_budget'})
local b5 = f({budget = 1.0, request = 0.01, ledger = led100, op = 'dp_budget'})
ok('budget advanced 口径放行（basic 已耗尽 1.0）', jbool(b4, 'allow'))
ok('budget basic 口径同例拒批', not jbool(b5, 'allow'))
ok('budget advanced total_before(100×0.01) ≈ 0.4899',
  jnear(jnum(b4, 'total_before'), 0.489903, 1e-4))
ok('budget advanced total_after(101×0.01) ≈ 0.4924', jnear(jnum(b4, 'total_after'), 0.492396, 1e-4))
-- 反向对照：20×0.05（小 n）高级组合反而更差 → 同预算下仍应拒批
local led20 = {}
for i = 1, 20 do led20[i] = {epsilon = 0.05} end
local b6 = f({budget = 1.0, request = 0.05, ledger = led20, composition = 'advanced', op = 'dp_budget'})
ok('budget 小 n：advanced 界(1.124) > budget → 仍拒批', not jbool(b6, 'allow'))
ok('budget 小 n advanced total_after(21×0.05) ≈ 1.153316', jnear(jnum(b6, 'total_after'), 1.153316, 1e-4))

-- ============ P1：kanon_report（l-diversity / t-closeness / 抑制率 / 泛化损失）============
local kr_recs = {
  {id = 1, qi = {age = 25, city = 'hz'}, sens = 'A'},
  {id = 2, qi = {age = 26, city = 'hz'}, sens = 'B'},
  {id = 3, qi = {age = 60, city = 'sh'}, sens = 'A'},
  {id = 4, qi = {age = 61, city = 'sh'}, sens = 'A'},
}
-- 锚 13: 全局分布 A:3 B:1；两组各 2 条 → 组1 {A,B}(distinct-l=2,H=1bit,TV=0.25)、组2 {A,A}(distinct-l=1,H=0,TV=0.25)
local kr = f({records = kr_recs, k = 2, l = 2, t = 0.2, op = 'kanon_report'})
check('report groups', jnum(kr, 'groups'), 2)
check('report k_ok', jbool(kr, 'k_ok'), true)
check('report min_class_size', jnum(kr, 'min_class_size'), 2)
check('report min_distinct_l = 1（组2 单值）', jnum(kr, 'min_distinct_l'), 1)
ok('report min_entropy_l = 0', jnear(jnum(kr, 'min_entropy_l'), 0, 1e-9))
ok('report max_t = 0.25', jnear(jnum(kr, 'max_t'), 0.25, 1e-6))
check('report t_metric=tv', jget(kr, 't_metric'), 'tv')
check('report verdict=fail（l 与 t 双违）', jget(kr, 'verdict'), 'fail')
ok('report violations = [l,t]', kr:match('"violations":%["l","t"%]') ~= nil)
ok('report 抑制率 0', jnear(jnum(kr, 'suppression_rate'), 0, 1e-9))
ok('report 泛化损失 ≈ 0.0139（age 1/36 跨度，city 组内同值）',
  jnear(jnum(kr, 'generalization_loss'), 0.013889, 1e-4))
-- l=1、t=0.3 → 通过（对照：只放宽阈值，数据未变）
local kr2 = f({records = kr_recs, k = 2, l = 1, t = 0.3, op = 'kanon_report'})
check('report 放宽后 pass', jget(kr2, 'verdict'), 'pass')
ok('report 放宽后 l_ok/t_ok 均真', jbool(kr2, 'l_ok') and jbool(kr2, 't_ok'))
ok('report 放宽后无 violation', kr2:match('"violations":%[%]') ~= nil)

-- 锚 14: t-closeness 两种度量必须给出不同值（证明 TV 与 EMD 都真实实现）
local ord_recs = {
  {id = 1, qi = {age = 25, city = 'hz'}, sens = 1},
  {id = 2, qi = {age = 26, city = 'hz'}, sens = 1},
  {id = 3, qi = {age = 60, city = 'sh'}, sens = 2},
  {id = 4, qi = {age = 61, city = 'sh'}, sens = 3},
}
local t_tv = f({records = ord_recs, k = 2, t = 0.9, op = 'kanon_report'})
local t_emd = f({records = ord_recs, k = 2, t = 0.9, ordered = true, op = 'kanon_report'})
check('TV 度量', jget(t_tv, 't_metric'), 'tv')
check('EMD 度量（ordered=true）', jget(t_emd, 't_metric'), 'emd')
ok('TV max_t = 0.5', jnear(jnum(t_tv, 'max_t'), 0.5, 1e-6))
ok('EMD max_t = 0.375（同一数据，两种度量确实不同）', jnear(jnum(t_emd, 'max_t'), 0.375, 1e-6))
ok('EMD ≠ TV', math.abs(jnum(t_emd, 'max_t') - jnum(t_tv, 'max_t')) > 0.1)
-- EMD 用同一阈值 t=0.4：TV 判死、EMD 通过（度量选择影响结论 → 必须显式声明）
local t_tv2 = f({records = ord_recs, k = 2, t = 0.4, op = 'kanon_report'})
local t_emd2 = f({records = ord_recs, k = 2, t = 0.4, ordered = true, op = 'kanon_report'})
ok('t=0.4 下 TV 不通过而 EMD 通过', not jbool(t_tv2, 't_ok') and jbool(t_emd2, 't_ok'))

-- 锚 15: k 不足 → 抑制 + verdict fail（1 条 k=2）
local kr4 = f({records = {{id = 1, qi = {age = 25}, sens = 'A'}}, k = 2, op = 'kanon_report'})
check('report k 不足 verdict=fail', jget(kr4, 'verdict'), 'fail')
ok('report suppressed=1', jnum(kr4, 'suppressed') == 1)
ok('report 抑制率 = 1', jnear(jnum(kr4, 'suppression_rate'), 1.0, 1e-9))
ok('report violations 含 k', kr4:match('"k"') ~= nil and not jbool(kr4, 'k_ok'))
-- 锚 16: 并行数组模式 + sensitive_field（SQL 侧常用形态）
local kr5 = f({age = {25, 26, 60, 61}, city = {'hz', 'hz', 'sh', 'sh'},
  disease = {'A', 'B', 'A', 'A'}, k = 2, sensitive_field = 'disease', op = 'kanon_report'})
check('report 数组模式 groups', jnum(kr5, 'groups'), 2)
check('report 数组模式 min_distinct_l', jnum(kr5, 'min_distinct_l'), 1)
ok('report 数组模式 verdict=fail', jget(kr5, 'verdict') == 'fail')
-- 锚 17: 无敏感属性 → k 单判据，l/t 字段不出现（诚实：不假装算过）
local kr6 = f({records = {
  {id = 1, qi = {age = 25, city = 'hz'}}, {id = 2, qi = {age = 26, city = 'hz'}},
  {id = 3, qi = {age = 60, city = 'sh'}}, {id = 4, qi = {age = 61, city = 'sh'}},
}, k = 2, op = 'kanon_report'})
check('report 无 sens → verdict 只看 k', jget(kr6, 'verdict'), 'pass')
ok('report 无 sens 时不输出 l_ok/t_ok', jget(kr6, 'l_ok') == nil and jget(kr6, 't_ok') == nil)
-- 锚 18: 原 kanon 返回格式未被 P1 改动（回归）
local kreg = f({records = kr_recs, k = 2, op = 'kanon'})
ok('原 kanon 格式不变（无 report 字段）', kreg:match('^%{"groups":') ~= nil and kreg:match('"suppressed":0') ~= nil
  and kreg:match('"k":2') ~= nil and kreg:match('"report"') == nil)
local kmissing = f({records = {}, k = 2, op = 'kanon'})
check('kanon 缺输入沿用旧错误 JSON', kmissing, '{"error":"records required"}')
check('kanon_report 缺输入同错误', f({records = {}, k = 2, op = 'kanon_report'}), '{"error":"records required"}')

print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
