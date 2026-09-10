-- @lib: privacy
-- @category: privacy
-- @desc: 隐私工程原语（纯 Lua，自包含）——差分隐私机制 + PII 脱敏 + k-匿名（Mondrian 简化版）。
--   【差分隐私】（ε-差分隐私，敏感度 Δf）
--   op='dp_count'：加噪计数。p.true_count 真实计数、p.epsilon（默认 1.0）、p.sensitivity（默认 1，计数恒为 1）
--     → 返回 round(true_count + Laplace(0, Δf/ε))，整数。
--   op='dp_sum'：加噪求和。p.sensitivity = 单行值域跨度（如金额 0~100000 → 100000），
--     → 返回 true_sum + Laplace(0, Δf/ε)，保留 2 位小数。
--   op='dp_mean'：加噪均值。噪声在分子（sum）与分母（count）分别注入（Δf_sum=range, Δf_count=1），
--     → 返回 (sum + Lap(range/ε)) / (count + Lap(1/ε))；count 加噪后 <1 则返回 NULL（数据太少）。
--   op='laplace'：机制暴露。返回一维 Laplace(0, scale) 噪声值（教学/审计/组合机制用）。
--   【ε 预算台账】（顺序组合记账；本 lib 无状态 → 台账由调用方以 ledger 数组传入）
--   op='dp_compose'：组合界。p.epsilon 单次 ε（或 p.epsilons 数组）、p.count（均匀 ε 的查询个数）、
--     p.delta（高级组合的 δ'，默认 1e-5）→ 返回 {basic_total, advanced_total, n, delta}
--     basic = Σε_i（顺序组合定理，精确）；advanced = Σε_i(e^{ε_i}−1) + √(2·ln(1/δ')·Σε_i²)（Dwork-Roth 强组合）
--   op='dp_alloc'：把总预算切给 n 个计划查询。p.budget、p.n、p.delta、p.composition：
--     'basic' → 每查询 ε = budget/n（和为 budget）；'advanced' → 二分求最大均匀 ε 使强组合界 ≤ budget
--     （同样总预算下 advanced 能给出更大的单查询 ε —— 这就是记账的价值）
--   op='dp_budget'：单步记账门禁。p.budget、p.request（本次申请 ε）、p.spent 或
--     p.ledger=[{epsilon=..,op='dp_count'}]（历史消耗，自动求和）、p.composition、p.delta
--     → 返回 {allow, spent_before/after, remaining_before/after, total_before/after, reason}
--     allow=false（超预算）时 reason='budget_exceeded'
--   【PII 脱敏】
--   op='mask'：p.v 待脱敏值、p.mode：
--     'hash'：FNV-1a 32 位 + 盐（p.salt 默认 ''）→ 保留前 p.keep（默认 2）字符 + '#' + 哈希 hex（8 位）
--     'star'：保留首 p.head（默认 1）与尾 p.tail（默认 1），中间 '***'（短串全掩）
--     'bin'：数值泛化分箱 p.lo/p.hi/p.bins（默认 5）→ 返回 "[lo,hi)" 区间标签
--     'suppress'：返回 NULL 标记字符串 '␀SUPPRESSED'（SQL 侧 CASE WHEN 转 NULL）
--     'rand'：确定性伪随机替换（FNV 哈希 → 0~9999 整数，同输入同输出，可复现）
--   【k-匿名】（Mondrian 简化：准标识符递归分区 + 区间泛化）
--   op='kanon'：p.records = { {id=.., qi={age=.., city='..'}, sens=..}, ... }、p.k（默认 2）
--     → 返回 JSON：{ groups:[{size, qi:[泛化区间/集合], ids:[...]}], suppressed: N }
--     泛化规则：数值 → [min,max] 区间；字符串 → 共享最长前缀（无共享 → '*')
--   op='kanon_report'：同上输入 + p.sens（敏感属性数组）或 p.sensitive_field（取 qi 里的字段）+
--     p.l（默认 2）、p.t（默认 0.2）、p.ordered（敏感属性有序/数值 → t 用 EMD，否则用 TV）
--     → 返回 k/l/t 三项检验 + 抑制率 + 泛化损失 + verdict（GB/T 42460 去标识化效果评估要素），
--       并在每组附 distinct_l / entropy_l / t 值。l 取 distinct-l 与 entropy-l 双判据。
--     诚实边界：简化版只做等权分裂（范围最宽维度优先），非严格 Mondrian 信息损失最小化；
--     l-diversity 只做 distinct-l + entropy-l（recursive-(c,l) 未实现）；t-closeness 用
--     TV(分类)/归一化 1-D EMD(有序) 而非完整 EMD；泛化损失为简化 ILA（无分类层级树时用组内离散度近似）。
--     DP 机制假设 SQL 侧已完成真实聚合（本 lib 不查表）。
--   【CN 合规脱敏规则库】（GB/T 37964 去标识化常用形态；格式保持 = 长度/位数不变，下游长度校验不炸）
--   op='mask_cn'：p.v 待脱敏值、p.kind ∈ {'idcard','mobile','bankcard','name','email','generic','auto'}
--     （默认 'auto'：按值自识别）、p.mode ∈ {'star','hash','birth'}：
--       'star'：按 CN 规则保留可识别前后缀、其余 '*'——
--               身份证前 6（行政区划）后 4 / 手机号前 3 后 4 / 银行卡前 6（BIN）后 4 /
--               姓名保留姓（复姓保留 2 字）/ 邮箱保留首字符 + 域名；
--               **识别失败或长度不符 → fail-closed 退回通用 star（保留首 1 尾 1）**，绝不原样透出
--       'hash'：保留同一前缀 + '#' + FNV-1a 32 位指纹（p.salt 盐化）→ 同输入同输出，可作外键连接键
--       'birth'：仅 idcard —— 出生日期泛化到年（前 6 + YYYY + '0101' + 后 4，长度不变）
--     例：idcard → '110101********1234'；mobile → '138****8000'；bankcard → '622202********1234'；name → '张**'
--   【日期平移】（临床 MIMIC 式去标识：同 subject 恒同偏移 → subject 内相对时间完整保留）
--   op='dateshift'：p.v 日期（'YYYY-MM-DD'，可带 ' HH:MM:SS' 后缀，时间部分原样保留）、
--     p.key subject 键、p.days 最大绝对偏移天数（默认 180）、p.salt（默认 'dateshift'）、
--     p.with_delta=true 时返回 'date|delta'（delta 供数据字典登记）。
--     偏移 = FNV-1a(key, salt) mod (2·days+1) − days ∈ [−days, days]，**只依赖 key 不依赖日期**
--     → 同 subject 各行偏移恒定 ⇒ 住院第几天/两事件间隔等相对时间逐位不变；
--     p.key 缺省 = ''（全局单一偏移，仍不可反推绝对日期）。非法日期返回 'null'。
--   op='dateoffset'：只返回该 key 的偏移天数（整数），供数据字典 / 审计登记。
--   【自由文本 PHI 脱敏】（占位符式，MIMIC `[**Name1**]` 风格；纯规则、可审计）
--   op='redact_text'：p.v 自由文本、p.dict 字典词数组（姓名等，无法凭模式识别）、
--     p.num_min 未分类长数字串阈值（默认 9 位，≥ 则按 [**NUM**] 掩掉）、
--     p.key（可选）+ p.salt（默认 'dateshift'）+ p.days（默认 180）：
--       给了 key → 日期不置占位符而是**按 dateshift 同款偏移平移**（同 key 与结构化列一致）
--       未给 key → 日期置 [**DATE**] 占位符
--     → 返回 JSON：{ text 脱敏后文本, total 命中数, counts 分类计数, map 字典词→占位符,
--       date_mode, num_min, chars_in, note }。同一原文 → 同一占位符；字典编号按
--       **字典顺序**（不是行内首现序）⇒ 同一字典跑多行文本时，同一人恒得同一编号，
--       跨行可直接对齐（稳定假名）；`map` 返回的是字典全量映射。
--     内置模式：邮箱 / URL / IPv4 / 日期（-、/、.、年月日 四形态，校验月日合法）/
--       身份证（15、18、17+X）/ 手机（1[3-9] + 9 位）/ 银行卡（16–19 位）/ 未分类长数字串。
--     诚实边界：只覆盖规则表列出的模式 + 所给字典，**未匹配的自由文本不保证无 PHI**
--     （note 字段里显式声明，不假装全覆盖）。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='privacy');
--   dp_count: SELECT luajit_s('privacy', {true_count:1000, epsilon:1.0, op:'dp_count'});
--   dp_mean:  SELECT luajit_s('privacy', {true_sum:50000, true_count:100, range:1000, epsilon:0.5, op:'dp_mean'});
--   mask:     SELECT luajit_s('privacy', {v:'13800138000', mode:'star', op:'mask'});  → '1***0'
--   kanon:    SELECT luajit_s('privacy', {records:[{id:1,qi:{age:25,city:'hz'}},{id:2,qi:{age:26,city:'hz'}},
--             {id:3,qi:{age:60,city:'sh'}},{id:4,qi:{age:61,city:'sh'}}], k:2, op:'kanon'});
--             → 两组各 2 条：age 泛化为 [25,26]/[60,61]，city 保留共享前缀
--   mask_cn:  SELECT luajit_s('privacy', {v:'110101199003071234', kind:'idcard', op:'mask_cn'});   → '110101********1234'
--             SELECT luajit_s('privacy', {v:'13800138000', op:'mask_cn'});                          → '138****8000'（auto 识别）
--             SELECT luajit_s('privacy', {v:'张三', kind:'name', mode:'hash', salt:'k1', op:'mask_cn'}); → '张#<8位指纹>'
--   dateshift:SELECT luajit_s('privacy', {v:'2150-03-04', key:'10001', days:180, op:'dateshift'});
--             → 如 '2150-01-12'（同 key 恒定偏移）；with_delta=true → '2150-01-12|-51'

local privacy = {}
local json_encode  -- 前向声明（定义在文件后部，调用发生在 chunk 加载完成后）

-- ======================================================================
-- 确定性伪随机（可复现；不依赖 math.random 全局状态）
-- ======================================================================
local bit = require('bit')

-- (a×b) mod 2^32，16 位分半精确乘法（double 内无 2^53 精度丢失）
local function mul32(a, b)
  local a_hi, a_lo = math.floor(a / 65536), a % 65536
  local b_hi, b_lo = math.floor(b / 65536), b % 65536
  local lo = a_lo * b_lo
  local mid = a_hi * b_lo + a_lo * b_hi
  return ((mid % 65536) * 65536 + lo) % 4294967296
end

-- Park-Miller LCG（Schrage 方法：全部中间值 < 2^31，double 精确）
-- 返回闭包，每次调用产出 [0,1) 均匀值
local function make_rng(seed)
  local x = (tonumber(seed) and (seed % 2147483646) or 1)
  if x <= 0 then x = 1 end
  return function()
    local q = math.floor(x / 127773)
    local r = x - q * 127773
    x = 16807 * r - 2836 * q
    if x < 0 then x = x + 2147483647 end
    return x / 2147483647
  end
end

-- FNV-1a 32 位（盐化；mul32 保证精确回绕）
local function fnv1a(s, salt)
  local h = 2166136261
  local str = tostring(salt or '') .. tostring(s)
  for i = 1, #str do
    local b = str:byte(i)
    local lo = h % 256
    h = h - lo + bit.bxor(lo, b)
    h = mul32(h, 16777619)
  end
  return h
end

-- 标准正态（Box-Muller；确定性）
local function gauss(rng)
  local u1, u2 = rng(), rng()
  if u1 < 1e-12 then u1 = 1e-12 end
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Laplace(0, scale)：u ∈ (-0.5, 0.5] → 1-2|u| ∈ [0,1)，log 恒定义
local function laplace(scale, rng)
  local u = rng() - 0.5
  return -scale * (u >= 0 and 1 or -1) * math.log(1 - 2 * math.abs(u))
end

-- ======================================================================
-- 差分隐私
-- ======================================================================
local function dp_count(p)
  local scale = (p.sensitivity or 1) / (p.epsilon or 1.0)
  local rng = make_rng(p.seed or os.time())
  return string.format('%d', math.floor((p.true_count or 0) + laplace(scale, rng) + 0.5))
end

local function dp_sum(p)
  local scale = (p.sensitivity or 100) / (p.epsilon or 1.0)
  local rng = make_rng(p.seed or os.time())
  return string.format('%.2f', (p.true_sum or 0) + laplace(scale, rng))
end

local function dp_mean(p)
  local eps = p.epsilon or 1.0
  local rng = make_rng(p.seed or os.time())
  local s_sum = (p.range or 100) / eps
  local s_cnt = 1 / eps
  local cnt = (p.true_count or 0) + laplace(s_cnt, rng)
  if cnt < 1 then return 'null' end
  local mean = ((p.true_sum or 0) + laplace(s_sum, rng)) / cnt
  return string.format('%.4f', mean)
end

-- ======================================================================
-- PII 脱敏
-- ======================================================================
local function mask(p)
  local v = tostring(p.v or '')
  local mode = p.mode or 'star'
  if mode == 'hash' then
    local keep = p.keep or 2
    local head = v:sub(1, keep)
    return head .. '#' .. string.format('%08x', fnv1a(v, p.salt or ''))
  elseif mode == 'star' then
    local head, tail = p.head or 1, p.tail or 1
    if #v <= head + tail then return string.rep('*', #v) end
    return v:sub(1, head) .. string.rep('*', #v - head - tail) .. v:sub(-tail)
  elseif mode == 'bin' then
    local x = tonumber(v)
    if not x then return 'null' end
    local lo, hi, bins = p.lo or 0, p.hi or 100, p.bins or 5
    if hi <= lo then hi = lo + 1 end
    local w = (hi - lo) / bins
    local b = math.floor((x - lo) / w)
    if b < 0 then b = 0 elseif b >= bins then b = bins - 1 end
    return string.format('[%g,%g)', lo + b * w, lo + (b + 1) * w)
  elseif mode == 'suppress' then
    return '\240\159\128\128SUPPRESSED'  -- ␀ 标记，SQL 侧转 NULL
  elseif mode == 'rand' then
    local rng = make_rng(fnv1a(v, p.salt or 'anon'))
    return string.format('%d', math.floor(rng() * 10000))
  end
  return ''
end

-- ======================================================================
-- k-匿名（Mondrian 简化：等权范围分裂 + 区间/前缀泛化）
-- ======================================================================
local function qi_min(rows, field)
  local m = math.huge
  for _, r in ipairs(rows) do
    local x = r.qi[field]
    if type(x) == 'number' and x < m then m = x end
  end
  return m
end
local function qi_max(rows, field)
  local m = -math.huge
  for _, r in ipairs(rows) do
    local x = r.qi[field]
    if type(x) == 'number' and x > m then m = x end
  end
  return m
end
local function qi_unique(rows, field)
  local seen = {}
  for _, r in ipairs(rows) do seen[tostring(r.qi[field])] = true end
  return seen
end
-- 字符串共享最长前缀
local function common_prefix(strs)
  if #strs == 0 then return '' end
  if #strs == 1 then return strs[1] end
  local p = strs[1]
  for i = 2, #strs do
    local s = strs[i]
    local k = 0
    while k < #p and k < #s and p:sub(k + 1, k + 1) == s:sub(k + 1, k + 1) do k = k + 1 end
    p = p:sub(1, k)
    if p == '' then break end
  end
  return p
end

-- 分组核心（kanon 与 kanon_report 共用）：返回 records, groups, k；
-- 输入缺失时返回错误 JSON 字符串（第一返回值类型为 string，调用方透传）
local function kanon_core(p)
  local records = p.records
  if type(records) ~= 'table' or #records == 0 then
    -- 并行数组模式（SQL 侧兼容）：{'op':'kanon', 'age':[25,26,60,61], 'city':['hz','hz','sh','sh'], 'k':2}
    local arrs, n = {}, 0
    local CONTROL = { op = true, records = true, k = true }
    for k, v in pairs(p) do
      if type(v) == 'table' and type(v[1]) ~= 'nil' and not CONTROL[k] then
        arrs[k] = v
        n = math.max(n, #v)
      end
    end
    if n == 0 then return '{"error":"records required"}' end
    records = {}
    for i = 1, n do
      records[i] = { qi = {} }
      for k, v in pairs(arrs) do
        if v[i] ~= nil then
          if k == 'sens' then records[i].sens = v[i]
          elseif k == 'id' then records[i].id = v[i]
          else records[i].qi[k] = v[i] end
        end
      end
    end
  end
  local k = p.k or 2
  -- 分裂：找范围最宽的数值维度，中位分裂；无数值维度按字符串首字符分
  local function split(rows)
    if #rows <= 2 * k - 1 then return { rows } end
    local best_field, best_span = nil, -1
    local first = rows[1].qi
    for f, v in pairs(first) do
      if type(v) == 'number' then
        local span = qi_max(rows, f) - qi_min(rows, f)
        if span > best_span then best_span, best_field = span, f end
      end
    end
    if best_field then
      local sorted = {}
      for _, r in ipairs(rows) do sorted[#sorted + 1] = r end
      table.sort(sorted, function(a, b) return a.qi[best_field] < b.qi[best_field] end)
      local mid = math.floor(#sorted / 2)
      local left, right = {}, {}
      for i = 1, mid do left[#left + 1] = sorted[i] end
      for i = mid + 1, #sorted do right[#right + 1] = sorted[i] end
      return { left, right }
    else
      return { rows }  -- 无可分裂数值维度：整组输出（字符串维度不做深度分裂，简化版）
    end
  end

  local groups = { records }
  local stable = false
  while not stable do
    stable = true
    local next_groups = {}
    for _, g in ipairs(groups) do
      if #g >= 2 * k then
        local parts = split(g)
        if #parts == 2 and #parts[1] >= k and #parts[2] >= k then
          stable = false
          for _, part in ipairs(parts) do next_groups[#next_groups + 1] = part end
        else
          next_groups[#next_groups + 1] = g
        end
      else
        next_groups[#next_groups + 1] = g
      end
    end
    groups = next_groups
  end

  return records, groups, k
end

-- k-匿名输出（保持既有返回格式不变：groups/suppressed/k）
local function kanon(p)
  local records, groups, k = kanon_core(p)
  if type(records) == 'string' then return records end  -- 错误 JSON 透传
  local out_groups, suppressed = {}, 0
  for gi, g in ipairs(groups) do
    if #g < k then
      suppressed = suppressed + #g
    end
    local qi_out, ids = {}, {}
    local sample = g[1].qi
    for f, v0 in pairs(sample) do
      if type(v0) == 'number' then
        qi_out[f] = string.format('[%g,%g]', qi_min(g, f), qi_max(g, f))
      else
        local strs = {}
        for _, r in ipairs(g) do strs[#strs + 1] = tostring(r.qi[f]) end
        local pref = common_prefix(strs)
        qi_out[f] = (pref ~= '' and pref or '*')
      end
    end
    for _, r in ipairs(g) do ids[#ids + 1] = r.id or 0 end
    out_groups[gi] = { size = #g, qi = qi_out, ids = ids }
  end
  return '{"groups":' .. json_encode(out_groups) .. ',"suppressed":' .. suppressed .. ',"k":' .. k .. '}'
end

-- ======================================================================
-- kanon_report：l-diversity + t-closeness + 抑制率/泛化损失（GB/T 42460 效果评估要素）
--   l：distinct-l（等价类内敏感值去重个数）与 entropy-l（香农熵，bits，判据 H ≥ log2(l)）
--   t：分类 → 总变差 TV；有序/数值（p.ordered=true）→ 归一化 1-D EMD（=W1/值域跨度）
--   泛化损失：数值 (max−min)/全局跨度；分类 1−1/(组内取值个数) —— 简化 ILA，按组大小加权
-- ======================================================================

-- 敏感值提取：records 模式的 r.sens，或 p.sensitive_field 指定的 qi 字段
local function sens_value(r, p)
  local v
  if p.sensitive_field then v = r.qi[p.sensitive_field] else v = r.sens end
  if v == nil then return nil end
  return tostring(v)
end

local function build_dist(rows, p)
  local d, n, miss = {}, 0, 0
  for _, r in ipairs(rows) do
    local v = sens_value(r, p)
    if v == nil then miss = miss + 1 else d[v] = (d[v] or 0) + 1; n = n + 1 end
  end
  return d, n, miss
end

-- 香农熵（bits）
local function entropy_bits(d, n)
  if n <= 0 then return 0 end
  local h = 0
  local ln2 = math.log(2)
  for _, c in pairs(d) do
    local pr = c / n
    h = h - pr * (math.log(pr) / ln2)
  end
  return h
end

-- 总变差距离 TV = ½Σ|p_i − q_i|（分类属性；两分布都归一化到 1）
local function tv_distance(dg, ng, dq, nq)
  if ng <= 0 or nq <= 0 then return 0 end
  local keys = {}
  for k in pairs(dg) do keys[k] = true end
  for k in pairs(dq) do keys[k] = true end
  local s = 0
  for k in pairs(keys) do
    s = s + math.abs((dg[k] or 0) / ng - (dq[k] or 0) / nq)
  end
  return s / 2
end

-- 归一化 1-D EMD（Wasserstein-1）：对两分布取值并集逐步长累加 CDF 差 × 间距，再除以值域跨度
local function emd_1d(dg, ng, dq, nq)
  if ng <= 0 or nq <= 0 then return 0 end
  local u = {}
  local numeric = true
  for k in pairs(dg) do
    local x = tonumber(k); if not x then numeric = false break end
    u[#u + 1] = x
  end
  if numeric then
    for k in pairs(dq) do
      local x = tonumber(k); if not x then numeric = false break end
      u[#u + 1] = x
    end
  end
  if not numeric or #u < 2 then return nil end  -- 非数值 → 由调用方回退 TV
  table.sort(u)
  -- 去重
  local vals = { u[1] }
  for i = 2, #u do if u[i] ~= vals[#vals] then vals[#vals + 1] = u[i] end end
  local span = vals[#vals] - vals[1]
  if span <= 0 then return 0 end
  local cum_g, cum_q, s = 0, 0, 0
  for i = 1, #vals - 1 do
    cum_g = cum_g + (dg[tostring(vals[i])] or 0) / ng
    cum_q = cum_q + (dq[tostring(vals[i])] or 0) / nq
    s = s + math.abs(cum_g - cum_q) * (vals[i + 1] - vals[i])
  end
  return s / span
end

-- 全局各 QI 维度跨度（用于数值泛化损失归一化）
local function field_spans(rows)
  local sp = {}
  for _, r in ipairs(rows) do
    for f, v in pairs(r.qi) do
      if type(v) == 'number' then
        local e = sp[f]
        if not e then sp[f] = { min = v, max = v } else
          if v < e.min then e.min = v end
          if v > e.max then e.max = v end
        end
      end
    end
  end
  return sp
end

-- 单组泛化损失（0 = 未泛化；1 = 完全泛化/无信息）
local function group_ila(g, spans)
  local sum, nf = 0, 0
  for f, v0 in pairs(g[1].qi) do
    nf = nf + 1
    if type(v0) == 'number' then
      local span = qi_max(g, f) - qi_min(g, f)
      local gs = spans[f] and (spans[f].max - spans[f].min) or 0
      sum = sum + (gs > 0 and (span / gs) or 0)
    else
      local seen, cnt = {}, 0
      for _, r in ipairs(g) do
        local s = tostring(r.qi[f])
        if not seen[s] then seen[s] = true; cnt = cnt + 1 end
      end
      sum = sum + (cnt > 0 and (1 - 1 / cnt) or 0)
    end
  end
  if nf == 0 then return 0 end
  return sum / nf
end

local function kanon_report(p)
  local records, groups, k = kanon_core(p)
  if type(records) == 'string' then return records end
  local n = #records
  local l_req = tonumber(p.l) or 2
  local t_req = tonumber(p.t) or 0.2
  local gl_d, gl_n, gl_miss = build_dist(records, p)
  local have_sens = gl_n > 0
  local spans = field_spans(records)

  local out_groups, suppressed, min_size = {}, 0, math.huge
  local min_distinct_l, min_entropy_l, max_t = math.huge, math.huge, 0
  local t_metric = 'tv'
  local weighted_ila, pub_n = 0, 0

  for gi, g in ipairs(groups) do
    local qi_out = {}
    for f, v0 in pairs(g[1].qi) do
      if type(v0) == 'number' then
        qi_out[f] = string.format('[%g,%g]', qi_min(g, f), qi_max(g, f))
      else
        local strs = {}
        for _, r in ipairs(g) do strs[#strs + 1] = tostring(r.qi[f]) end
        local pref = common_prefix(strs)
        qi_out[f] = (pref ~= '' and pref or '*')
      end
    end
    local ent = { size = #g, qi = qi_out }
    local ids = {}
    for _, r in ipairs(g) do ids[#ids + 1] = r.id or 0 end
    ent.ids = ids
    local dg, ng = build_dist(g, p)
    local ila = group_ila(g, spans)
    ent.ila = ila
    if #g < k then
      suppressed = suppressed + #g
    else
      if #g < min_size then min_size = #g end
      pub_n = pub_n + #g
      weighted_ila = weighted_ila + ila * #g
      if have_sens and ng > 0 then
        local dl = 0
        for _ in pairs(dg) do dl = dl + 1 end
        ent.distinct_l = dl
        ent.entropy_l = entropy_bits(dg, ng)
        if dl < min_distinct_l then min_distinct_l = dl end
        if ent.entropy_l < min_entropy_l then min_entropy_l = ent.entropy_l end
        local tv = tv_distance(dg, ng, gl_d, gl_n)
        ent.t = tv
        if p.ordered then
          local e = emd_1d(dg, ng, gl_d, gl_n)
          if e then ent.t = e; ent.t_metric = 'emd'; t_metric = 'emd' end
        end
        if ent.t > max_t then max_t = ent.t end
      end
    end
    out_groups[gi] = ent
  end

  if min_size == math.huge then min_size = 0 end
  local n_pub_groups = #groups - (function()
    local c = 0
    for _, g in ipairs(groups) do if #g < k then c = c + 1 end end
    return c
  end)()

  local k_ok = suppressed == 0
  local l_ok, t_ok = nil, nil
  local violations = {}
  if have_sens then
    l_ok = (min_distinct_l ~= math.huge) and (min_distinct_l >= l_req)
    -- entropy 判据：H ≥ log2(l)（等价类内熵下界）
    local h_need = math.log(l_req) / math.log(2)
    l_ok = l_ok and (min_entropy_l ~= math.huge) and (min_entropy_l + 1e-9 >= h_need)
    t_ok = (max_t <= t_req + 1e-12)
    if not l_ok then violations[#violations + 1] = 'l' end
    if not t_ok then violations[#violations + 1] = 't' end
  end
  if not k_ok then violations[#violations + 1] = 'k' end
  local pass = k_ok and (not have_sens or (l_ok and t_ok))

  local rep = {
    k = k, k_ok = k_ok,
    n = n, groups = n_pub_groups,
    suppressed = suppressed,
    suppression_rate = n > 0 and (suppressed / n) or 0,
    min_class_size = min_size,
    generalization_loss = pub_n > 0 and (weighted_ila / pub_n) or 0,
    total_generalization_loss = n > 0 and (weighted_ila / n) or 0,
    verdict = pass and 'pass' or 'fail',
    violations = violations,
  }
  if have_sens then
    rep.l = l_req; rep.l_ok = l_ok
    rep.min_distinct_l = (min_distinct_l == math.huge) and 0 or min_distinct_l
    rep.min_entropy_l = (min_entropy_l == math.huge) and 0 or min_entropy_l
    rep.t = t_req; rep.t_ok = t_ok
    rep.max_t = max_t; rep.t_metric = t_metric
    rep.sensitive_missing = gl_miss
  end
  return '{"report":' .. json_encode(rep) .. ',"groups":' .. json_encode(out_groups) .. '}'
end

-- ======================================================================
-- ε 预算台账（dp_compose / dp_alloc / dp_budget）
--   basic   顺序组合：ε_total = Σ ε_i（精确，无 δ）
--   advanced 强组合（Dwork-Roth）：ε_total = Σ ε_i(e^{ε_i}−1) + √(2 ln(1/δ') Σ ε_i²)
-- ======================================================================
local function advanced_epsilon(list, delta)
  local s1, s2 = 0, 0
  for _, e in ipairs(list) do
    s1 = s1 + e * (math.exp(e) - 1)
    s2 = s2 + e * e
  end
  return s1 + math.sqrt(2 * math.log(1 / delta) * s2)
end

-- 从 p.epsilon / p.epsilons / p.count 组装 ε 列表
local function eps_list(p)
  local list = {}
  if type(p.epsilons) == 'table' then
    for _, e in ipairs(p.epsilons) do
      if tonumber(e) then list[#list + 1] = tonumber(e) end
    end
  end
  local one = tonumber(p.epsilon)
  local cnt = math.floor(tonumber(p.count) or 0)
  if one then
    if #list == 0 and cnt > 0 then
      for _ = 1, cnt do list[#list + 1] = one end
    elseif cnt <= 0 then
      list[#list + 1] = one
    end
  end
  return list
end

local function list_sum(list)
  local s = 0
  for _, e in ipairs(list) do s = s + e end
  return s
end

local function dp_compose(p)
  local delta = tonumber(p.delta) or 1e-5
  local list = eps_list(p)
  if #list == 0 then return '{"error":"epsilon or epsilons required"}' end
  local basic = list_sum(list)
  local adv = advanced_epsilon(list, delta)
  return string.format(
    '{"n":%d,"delta":%g,"basic_total":%.9f,"advanced_total":%.9f,"saving_ratio":%.4f}',
    #list, delta, basic, adv, basic > 0 and (adv / basic) or 0)
end

local function dp_alloc(p)
  local budget = tonumber(p.budget) or 1.0
  local n = math.floor(tonumber(p.n) or 0)
  if n <= 0 then return '{"error":"n (query count) must be >= 1"}' end
  local comp = p.composition or 'basic'
  local delta = tonumber(p.delta) or 1e-5
  local basic_per = budget / n
  -- 高级组合：二分求最大均匀 ε 使强组合界 ≤ budget
  local lo, hi = 0, budget
  for _ = 1, 80 do
    local mid = (lo + hi) / 2
    local lst = {}
    for _ = 1, n do lst[#lst + 1] = mid end
    if advanced_epsilon(lst, delta) <= budget then lo = mid else hi = mid end
  end
  local adv_per = lo
  -- per_query 按请求口径给出（默认 basic = 保守、无需 δ；advanced/auto 用强组合界）；best 报出更紧者
  local per, best = basic_per, 'basic'
  if comp == 'advanced' or comp == 'auto' then per = adv_per end
  if adv_per > basic_per then best = 'advanced' end
  local function bound_of(x)
    if math.abs(x - basic_per) < 1e-15 then return x * n end  -- basic 口径即 Σε
    local lst = {}
    for _ = 1, n do lst[#lst + 1] = x end
    return advanced_epsilon(lst, delta)
  end
  local rec = (best == 'advanced') and adv_per or basic_per
  return string.format(
    '{"budget":%g,"n":%d,"delta":%g,"requested_composition":"%s",'
    .. '"per_query":%.9f,"total_bound":%.9f,"basic_per":%.9f,"advanced_per":%.9f,'
    .. '"basic_total":%.9f,"advanced_total":%.9f,"best":"%s","recommended_per_query":%.9f}',
    budget, n, delta, comp, per, bound_of(per), basic_per, adv_per, basic_per * n,
    bound_of(adv_per), best, rec)
end

local function dp_budget(p)
  local budget = tonumber(p.budget) or 1.0
  local request = tonumber(p.request) or 0
  local delta = tonumber(p.delta) or 1e-5
  local comp = p.composition or 'basic'
  local list, entries = {}, 0
  if type(p.ledger) == 'table' then
    for _, e in ipairs(p.ledger) do
      local x
      if type(e) == 'number' then x = e
      elseif type(e) == 'table' then x = tonumber(e.epsilon) end
      if x then list[#list + 1] = x; entries = entries + 1 end
    end
  end
  local spent = tonumber(p.spent) or 0
  local extra = spent - list_sum(list)   -- spent 里未被 ledger 覆盖的整块消耗
  if extra > 1e-12 then list[#list + 1] = extra end
  local before = list_sum(list)
  local after_basic = before + request
  local tot_before, tot_after = before, after_basic
  if comp == 'advanced' then
    tot_before = advanced_epsilon(list, delta)
    local l2 = {}
    for _, e in ipairs(list) do l2[#l2 + 1] = e end
    l2[#l2 + 1] = request
    tot_after = advanced_epsilon(l2, delta)
  end
  local allow = tot_after <= budget + 1e-12
  return string.format(
    '{"allow":%s,"composition":"%s","budget":%g,"request":%g,"delta":%g,"entries":%d,'
    .. '"spent_before":%.9f,"spent_after":%.9f,"total_before":%.9f,"total_after":%.9f,'
    .. '"remaining_before":%.9f,"remaining_after":%.9f,"reason":"%s"}',
    allow and 'true' or 'false', comp, budget, request, delta, entries,
    before, after_basic, tot_before, tot_after, budget - tot_before, budget - tot_after,
    allow and 'ok' or 'budget_exceeded')
end

-- ======================================================================
-- CN 合规脱敏规则库（mask_cn）
--   设计三原则：① 格式保持（位数不变 → 下游长度校验/落库不炸）
--              ② fail-closed（识别不出 / 长度不符 → 退通用 star 全掩，绝不原样透出）
--              ③ hash 模式确定性（同输入同输出 → 可当外键连接键）
-- ======================================================================

-- UTF-8 按字符切分（中文姓名/复姓必须按「字」处理，按字节切会输出半个汉字）
local function utf8_chars(s)
  local t, i = {}, 1
  while i <= #s do
    local b = s:byte(i)
    local n
    if b < 128 then n = 1
    elseif b < 224 then n = 2
    elseif b < 240 then n = 3
    else n = 4 end
    t[#t + 1] = s:sub(i, i + n - 1)
    i = i + n
  end
  return t
end

-- 复姓表：命中则姓名保留 2 字姓，否则保留 1 字
local COMPOUND_SURNAMES = {
  ['欧阳'] = true, ['司马'] = true, ['上官'] = true, ['诸葛'] = true, ['东方'] = true,
  ['皇甫'] = true, ['尉迟'] = true, ['公孙'] = true, ['慕容'] = true, ['司徒'] = true,
  ['令狐'] = true, ['宇文'] = true, ['长孙'] = true, ['独孤'] = true, ['南宫'] = true,
  ['西门'] = true, ['夏侯'] = true, ['端木'] = true, ['呼延'] = true, ['澹台'] = true,
}

-- 通用 star（fail-closed 兜底；非 ASCII 走按字切分，避免产出非法 UTF-8）
local function generic_star(v, head, tail)
  head, tail = head or 1, tail or 1
  if v:match('[\128-\255]') then
    local chars = utf8_chars(v)
    if #chars <= head + tail then return string.rep('*', #chars) end
    return table.concat(chars, '', 1, head) .. string.rep('*', #chars - head - tail)
      .. table.concat(chars, '', #chars - tail + 1)
  end
  if #v <= head + tail then return string.rep('*', #v) end
  return v:sub(1, head) .. string.rep('*', #v - head - tail) .. v:sub(-tail)
end

-- 值类型自识别（kind='auto'）
local function cn_detect(v)
  if v:match('^%d+$') then
    if #v == 18 or #v == 15 then return 'idcard' end
    if #v == 11 and v:sub(1, 1) == '1' and v:sub(2, 2):match('[3-9]') then return 'mobile' end
    if #v >= 16 and #v <= 19 then return 'bankcard' end
    return nil
  end
  if v:match('^[^@%s]+@[^@%s]+%.[^@%s]+$') then return 'email' end
  local chars = utf8_chars(v)
  if #chars >= 2 and #chars <= 6 then
    local all_cjk = true
    for _, c in ipairs(chars) do
      if #c ~= 3 then all_cjk = false break end  -- 3 字节 = CJK 统一表意文字
    end
    if all_cjk then return 'name' end
  end
  return nil
end

local function mask_cn(p)
  local v = tostring(p.v or '')
  if v == '' then return '' end
  local kind = p.kind or 'auto'
  if kind == 'auto' then kind = cn_detect(v) or 'generic' end
  local mode = p.mode or 'star'
  local fp = string.format('%08x', fnv1a(v, p.salt or ''))

  -- hash 模式：保留规则前缀 + 指纹（确定性 → 外键/连接键可用）
  if mode == 'hash' then
    if kind == 'idcard' and (#v == 18 or #v == 15) then return v:sub(1, 6) .. '#' .. fp end
    if kind == 'bankcard' and #v >= 16 and #v <= 19 then return v:sub(1, 6) .. '#' .. fp end
    if kind == 'mobile' and #v == 11 then return v:sub(1, 3) .. '#' .. fp end
    if kind == 'name' then
      local chars = utf8_chars(v)
      local keep = (chars[2] and COMPOUND_SURNAMES[chars[1] .. chars[2]]) and 2 or 1
      if #chars <= keep then return string.rep('*', #chars) end
      return table.concat(chars, '', 1, keep) .. '#' .. fp
    end
    if kind == 'email' then
      local at = v:find('@')
      if at and at > 1 then return v:sub(1, 1) .. '#' .. fp .. v:sub(at) end
    end
    return generic_star(v) .. '#' .. fp
  end

  -- star / birth：按 CN 规则掩码
  if kind == 'idcard' then
    -- birth 模式：出生日期泛化到年（GB/T 37964 常用；长度不变）
    -- 18 位 = 6 区划 + 8 出生(YYYYMMDD) + 4；15 位 = 6 区划 + 6 出生(YYMMDD) + 3
    if mode == 'birth' and #v == 18 then
      local y, m0, d0 = v:match('^%d%d%d%d%d%d(%d%d%d%d)(%d%d)(%d%d)%d%d%d%d$')
      if y and tonumber(m0) >= 1 and tonumber(m0) <= 12 and tonumber(d0) >= 1 and tonumber(d0) <= 31 then
        return v:sub(1, 6) .. y .. '0101' .. v:sub(-4)
      end
    end
    if mode == 'birth' and #v == 15 then
      local y, m0, d0 = v:match('^%d%d%d%d%d%d(%d%d)(%d%d)(%d%d)%d%d%d$')
      if y and tonumber(m0) >= 1 and tonumber(m0) <= 12 and tonumber(d0) >= 1 and tonumber(d0) <= 31 then
        return v:sub(1, 6) .. y .. '0101' .. v:sub(-3)
      end
    end
    if #v == 18 then return v:sub(1, 6) .. string.rep('*', 8) .. v:sub(-4) end
    if #v == 15 then return v:sub(1, 6) .. string.rep('*', 5) .. v:sub(-4) end
    return generic_star(v)
  elseif kind == 'mobile' then
    if #v == 11 then return v:sub(1, 3) .. string.rep('*', 4) .. v:sub(-4) end
    return generic_star(v)
  elseif kind == 'bankcard' then
    if #v >= 16 and #v <= 19 then return v:sub(1, 6) .. string.rep('*', #v - 10) .. v:sub(-4) end
    return generic_star(v)
  elseif kind == 'name' then
    local chars = utf8_chars(v)
    local keep = (chars[2] and COMPOUND_SURNAMES[chars[1] .. chars[2]]) and 2 or 1
    if #chars <= keep then return string.rep('*', #chars) end
    return table.concat(chars, '', 1, keep) .. string.rep('*', #chars - keep)
  elseif kind == 'email' then
    local at = v:find('@')
    if at and at > 1 then return v:sub(1, 1) .. '***' .. v:sub(at) end
    return generic_star(v)
  end
  return generic_star(v, p.head, p.tail)
end

-- ======================================================================
-- 日期平移（dateshift / dateoffset）—— MIMIC 式临床去标识
--   偏移只由 key 决定（与日期无关）⇒ ① 同 subject 恒定 ② |偏移| ≤ days
--   ③ subject 内任意两日期之差逐位不变（相对时间完整保留）
--   civil-days 用 Howard Hinnant 算法（proleptic Gregorian，纯整数，闰年精确）
-- ======================================================================
local function days_from_civil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + ((m > 2) and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + ((mp < 10) and 3 or -9)
  return y + ((m <= 2) and 1 or 0), m, d
end

-- 解析 'YYYY-MM-DD[...]' 并做日历合法性校验（拒绝 2023-02-30）
local function parse_ymd(v)
  local y, m, d, rest = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$')
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  local rz = days_from_civil(y, m, d)
  local y2, m2, d2 = civil_from_days(rz)
  if y2 ~= y or m2 ~= m or d2 ~= d then return nil end  -- 回环校验：剔除非法日历日
  return y, m, d, rest
end

-- key → 偏移天数 ∈ [-days, days]
local function key_offset(key, salt, days)
  local h = fnv1a(tostring(key or ''), salt or 'dateshift')
  return (h % (2 * days + 1)) - days
end

local function dateshift(p)
  local v = tostring(p.v or '')
  if v == '' then return 'null' end
  local y, m, d, rest = parse_ymd(v)
  if not y then return 'null' end
  local days = math.floor(math.abs(tonumber(p.days) or 180))
  local off = days == 0 and 0 or key_offset(p.key, p.salt, days)
  local ny, nm, nd = civil_from_days(days_from_civil(y, m, d) + off)
  local out = string.format('%04d-%02d-%02d%s', ny, nm, nd, rest)
  if p.with_delta then return out .. '|' .. off end
  return out
end

local function dateoffset(p)
  local days = math.floor(math.abs(tonumber(p.days) or 180))
  if days == 0 then return '0' end
  return string.format('%d', key_offset(p.key, p.salt, days))
end

-- ======================================================================
-- 自由文本 PHI 脱敏（redact_text）—— 占位符式（MIMIC `[**Name1**]` 风格）
--   规则=数据（表驱动，可审计）：① 调用方字典（姓名等无法凭模式识别的词）
--   ② 内置模式规则：邮箱/URL/IPv4/日期/身份证/手机/银行卡
--   ③ 保守兜底：未分类的长数字串（≥ num_min 位）按 [**NUM**] 掩掉
--   同一原文 → 同一占位符（编号按首现顺序），便于对读与回溯对齐。
--   p.key 提供时日期不置占位符而是按 dateshift 同款 key 偏移
--   （默认 salt 同为 'dateshift' ⇒ 与结构化列 dateshift 结果一致，跨列跨文本同一时间轴）。
--   诚实边界：规则驱动只覆盖「规则表列出的模式 + 所给字典」，
--   未匹配的自由文本不保证无 PHI —— 输出里显式带 note 声明，不假装全覆盖。
-- ======================================================================
local REDACT_PH = {
  email = '[**EMAIL**]', url = '[**URL**]', ipv4 = '[**IP**]',
  date = '[**DATE**]', idcard = '[**ID**]', mobile = '[**PHONE**]',
  bankcard = '[**ACCT**]', longnum = '[**NUM**]',
}

-- 日期书写形态：pat 为带捕获的 Lua 模式（Lua 无 {n} 量词也无交替 → 逐形态列举）
-- 月/日用 %d%d? 容忍 1 位写法（如 2026年3月4日、2026-3-4）
local REDACT_DATE_FORMS = {
  { pat = '(%d%d%d%d)%-(%d%d?)%-(%d%d?)', sep = '-' },
  { pat = '(%d%d%d%d)/(%d%d?)/(%d%d?)',   sep = '/' },
  { pat = '(%d%d%d%d)%.(%d%d?)%.(%d%d?)', sep = '.' },
  { pat = '(%d%d%d%d)年(%d%d?)月(%d%d?)日', sep = 'cn' },
}

local function redact_valid_ymd(y, m, d)
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not (y and m and d) then return false end
  return m >= 1 and m <= 12 and d >= 1 and d <= 31
end

local function redact_valid_ipv4(t)
  local n = 0
  for oct in t:gmatch('%d+') do
    n = n + 1
    local v = tonumber(oct)
    if v > 255 or (#oct > 1 and oct:sub(1, 1) == '0') then return false end
  end
  return n == 4
end

-- 先到先得：与已占区间重叠的候选直接丢弃（= 规则优先级）
local function redact_free(marks, s0, e0)
  for i = 1, #marks do
    local m = marks[i]
    if not (e0 < m.s or s0 > m.e) then return false end
  end
  return true
end

local function redact_add_pattern(marks, s, pat, id)
  local pos = 1
  while true do
    local s0, e0 = s:find(pat, pos)
    if not s0 then break end
    if redact_free(marks, s0, e0) then
      marks[#marks + 1] = { s = s0, e = e0, id = id, ph = REDACT_PH[id] }
    end
    pos = e0 + 1
  end
end

-- 日期：逐形态匹配 + 月/日合法性校验（避免把 1234-56-78 当日期）
local function redact_add_dates(marks, s)
  for _, f in ipairs(REDACT_DATE_FORMS) do
    local pos = 1
    while true do
      local s0, e0, y, m, d = s:find(f.pat, pos)
      if not s0 then break end
      if redact_valid_ymd(y, m, d) and redact_free(marks, s0, e0) then
        marks[#marks + 1] = { s = s0, e = e0, id = 'date', ph = REDACT_PH.date, sep = f.sep }
      end
      pos = e0 + 1
    end
  end
end

-- 数字串：按长度/前缀分类（与 mask_cn 的 cn_detect 同口径），未分类的长串走保守兜底
local function redact_add_digit_runs(marks, s, num_min)
  local pos = 1
  while true do
    local s0, e0 = s:find('%d+', pos)
    if not s0 then break end
    local run = s:sub(s0, e0)
    local n = #run
    local nx = s:sub(e0 + 1, e0 + 1)
    local id = nil
    if n == 17 and nx:match('[Xx]') then          -- 18 位身份证末位 X
      e0 = e0 + 1
      id = 'idcard'
    elseif n == 18 or n == 15 then
      id = 'idcard'
    elseif n == 11 and run:sub(1, 1) == '1' and run:sub(2, 2):match('[3-9]') then
      id = 'mobile'
    elseif n >= 16 and n <= 19 then
      id = 'bankcard'
    elseif n >= num_min then
      id = 'longnum'
    end
    if id and redact_free(marks, s0, e0) then
      marks[#marks + 1] = { s = s0, e = e0, id = id, ph = REDACT_PH[id] }
    end
    pos = e0 + 1
  end
end

-- 字典词：字面查找（非模式），同原文共用同一编号
local function redact_add_dict(marks, s, dict, map, order)
  for _, w in ipairs(dict or {}) do
    local nm = tostring(w)
    if nm ~= '' then
      if not map[nm] then
        order[#order + 1] = nm
        map[nm] = '[**Name' .. #order .. '**]'
      end
      local pos = 1
      while true do
        local s0, e0 = s:find(nm, pos, true)
        if not s0 then break end
        if redact_free(marks, s0, e0) then
          marks[#marks + 1] = { s = s0, e = e0, id = 'name', ph = map[nm] }
        end
        pos = e0 + 1
      end
    end
  end
end

-- 日期平移（与 op='dateshift' 同款算法与默认盐 ⇒ 同 key 结果一致）
local function redact_shift_date(txt, sep, key, salt, days)
  local y, m, d
  if sep == 'cn' then
    y, m, d = txt:match('^(%d%d%d%d)年(%d%d?)月(%d%d?)日$')
  elseif sep == '-' then
    y, m, d = txt:match('^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$')
  elseif sep == '/' then
    y, m, d = txt:match('^(%d%d%d%d)/(%d%d?)/(%d%d?)$')
  else
    y, m, d = txt:match('^(%d%d%d%d)%.(%d%d?)%.(%d%d?)$')
  end
  if not y then return nil end
  local off = days == 0 and 0 or key_offset(key, salt, days)
  local ny, nm, nd = civil_from_days(days_from_civil(tonumber(y), tonumber(m), tonumber(d)) + off)
  if sep == 'cn' then return string.format('%04d年%02d月%02d日', ny, nm, nd) end
  return string.format('%04d%s%02d%s%02d', ny, sep, nm, sep, nd)
end

local function redact_text(p)
  local s = tostring(p.v or '')
  local marks, map, order = {}, {}, {}
  local num_min = math.floor(tonumber(p.num_min) or 9)
  if num_min < 1 then num_min = 1 end
  local days = math.floor(math.abs(tonumber(p.days) or 180))
  local shift = p.key ~= nil and p.key ~= '' or false
  local salt = p.salt or 'dateshift'

  -- 优先级：结构化模式（邮箱/URL/IP/日期 —— 占位符最具体、整体覆盖）→ 字典 → 数字串
  redact_add_pattern(marks, s, '[%w%.%-_%+]+@[%w%.%-]+%.[%a][%a]+', 'email')
  redact_add_pattern(marks, s, 'https?://[%w%.%-_/%?=&#:~%%%+]+', 'url')
  do
    local pos = 1
    while true do
      local s0, e0 = s:find('%d+%.%d+%.%d+%.%d+', pos)
      if not s0 then break end
      if redact_valid_ipv4(s:sub(s0, e0)) and redact_free(marks, s0, e0) then
        marks[#marks + 1] = { s = s0, e = e0, id = 'ipv4', ph = REDACT_PH.ipv4 }
      end
      pos = e0 + 1
    end
  end
  redact_add_dates(marks, s)
  -- 字典在数字串之前：字典词可能自带数字（如住院号 MRN123456789），整词命中优先于按数字串切
  redact_add_dict(marks, s, p.dict, map, order)
  redact_add_digit_runs(marks, s, num_min)

  -- 重建：按位置排序后拼接（重叠已在采集阶段排除）
  table.sort(marks, function(a, b) return a.s < b.s end)
  local out, cur = {}, 1
  for _, m in ipairs(marks) do
    if m.s > cur then out[#out + 1] = s:sub(cur, m.s - 1) end
    local rep = m.ph
    if m.id == 'date' and shift then
      rep = redact_shift_date(s:sub(m.s, m.e), m.sep, p.key, salt, days) or m.ph
    end
    out[#out + 1] = rep
    cur = m.e + 1
  end
  if cur <= #s then out[#out + 1] = s:sub(cur) end

  local counts = {}
  for _, m in ipairs(marks) do counts[m.id] = (counts[m.id] or 0) + 1 end
  return json_encode({
    text = table.concat(out),
    total = #marks,
    counts = counts,
    map = map,
    date_mode = shift and 'shift' or 'placeholder',
    num_min = num_min,
    chars_in = #s,
    note = 'rule-based: covers listed patterns + given dict only; unmatched free text is not guaranteed PHI-free',
  })
end

-- ======================================================================
-- 内联 JSON 编码器（零外部依赖）
-- ======================================================================
local function esc_str(s)
  return '"' .. tostring(s):gsub('[%z\1-\31"\\]', function(c)
    if c == '"' then return '\\"'
    elseif c == '\\' then return '\\\\'
    elseif c == '\n' then return '\\n'
    elseif c == '\r' then return '\\r'
    elseif c == '\t' then return '\\t'
    else return string.format('\\u%04x', c:byte()) end
  end) .. '"'
end
json_encode = function(v)
  local t = type(v)
  if t == 'nil' then return 'null'
  elseif t == 'boolean' then return v and 'true' or 'false'
  elseif t == 'number' then
    if v ~= v then return 'null' end
    return string.format('%g', v)
  elseif t == 'string' then return esc_str(v)
  elseif t == 'table' then
    local is_arr, n = true, #v
    for k in pairs(v) do if type(k) ~= 'number' or k < 1 or k > n then is_arr = false break end end
    local parts = {}
    if is_arr then
      for i = 1, n do parts[i] = json_encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      for k, val in pairs(v) do
        parts[#parts + 1] = json_encode(k) .. ':' .. json_encode(val)
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return 'null'
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'mask'
  if op == 'dp_count' then return dp_count(p)
  elseif op == 'dp_sum' then return dp_sum(p)
  elseif op == 'dp_mean' then return dp_mean(p)
  elseif op == 'laplace' then
    local rng = make_rng(p.seed or os.time())
    return string.format('%.6f', laplace(p.scale or 1.0, rng))
  elseif op == 'mask' then return mask(p)
  elseif op == 'mask_cn' then return mask_cn(p)
  elseif op == 'dateshift' then return dateshift(p)
  elseif op == 'dateoffset' then return dateoffset(p)
  elseif op == 'redact_text' then return redact_text(p)
  elseif op == 'kanon' then return kanon(p)
  elseif op == 'kanon_report' then return kanon_report(p)
  elseif op == 'dp_compose' then return dp_compose(p)
  elseif op == 'dp_alloc' then return dp_alloc(p)
  elseif op == 'dp_budget' then return dp_budget(p)
  end
  return ''
end

return function(p)
  return run(p)
end
