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
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='privacy');
--   dp_count: SELECT luajit_s('privacy', {true_count:1000, epsilon:1.0, op:'dp_count'});
--   dp_mean:  SELECT luajit_s('privacy', {true_sum:50000, true_count:100, range:1000, epsilon:0.5, op:'dp_mean'});
--   mask:     SELECT luajit_s('privacy', {v:'13800138000', mode:'star', op:'mask'});  → '1***0'
--   kanon:    SELECT luajit_s('privacy', {records:[{id:1,qi:{age:25,city:'hz'}},{id:2,qi:{age:26,city:'hz'}},
--             {id:3,qi:{age:60,city:'sh'}},{id:4,qi:{age:61,city:'sh'}}], k:2, op:'kanon'});
--             → 两组各 2 条：age 泛化为 [25,26]/[60,61]，city 保留共享前缀

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
  elseif op == 'kanon' then return kanon(p)
  end
  return ''
end

return function(p)
  return run(p)
end
