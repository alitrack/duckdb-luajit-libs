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
--   组合：ε 预算线性组合（顺序组合），多查询请自行累计 ε 并控制总预算。
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
--     诚实边界：简化版只做等权分裂（范围最宽维度优先），非严格 Mondrian 信息损失最小化；
--     l-diversity/t-closeness 未实现（生产需补）；DP 机制假设 SQL 侧已完成真实聚合（本 lib 不查表）。
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

local function kanon(p)
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

  -- 输出：每组泛化
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
  elseif op == 'kanon' then return kanon(p)
  end
  return ''
end

return function(p)
  return run(p)
end
