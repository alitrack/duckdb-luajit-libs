-- @lib: psi
-- @category: quality
-- @desc: 数据漂移检测（纯 Lua，自包含）——PSI（Population Stability Index）/ KL 散度 / 卡方。
--       op='psi'：两个分布之间的 PSI（占比分箱版）。输入 p.e = 期望(参考)占比数组、p.a = 实际占比数组；
--                 或 p.raw_e/p.raw_a = 原始数值数组（自动等宽分箱，p.bins 默认 10）；
--                 或 p.raw_e/p.raw_a + p.breaks = 显式边界数组（自动做占比换算）。
--       公式：PSI = Σ_i (A_i − E_i) × ln(A_i / E_i)，占比为 0 时按 0.0001 下限处理（业界惯例）。
--       判读（风控/模型监控惯例）：PSI < 0.10 无漂移；0.10~0.25 中等漂移；> 0.25 显著漂移（需调查）。
--       op='kl'：KL 散度 D_KL(A‖E)（nats），同分箱约定。
--       op='chi2'：卡方统计量 Σ (A_i−E_i)²/E_i（频数版需 p.counts_a；占比版自动按 N 换算，N=p.n）。
--       op='report'：一次返回 {psi, kl, chi2, bins, verdict, n} JSON 字符串（SQL 侧 json_extract）。
-- 诚实边界：等宽分箱对长尾分布敏感——重尾数据请显式传 p.breaks；占比数组必须等长；PSI 是
-- 无方向指标（不区分谁高谁低），配合逐箱差异看方向。统计显著性请配合卡方临界值在 SQL 侧判断。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='psi');
--   psi:      SELECT luajit_s('psi', {raw_e:[1,2,3,4,5], raw_a:[1,2,4,8,16], op:'psi'});
--             → '0.1156'（期望均匀 vs 实际指数：中等漂移）
--   report:   SELECT luajit_s('psi', {raw_e:[...], raw_a:[...], op:'report'});  → '{"psi":0.12,...}'

local psi = {}

-- ======================================================================
-- 工具
-- ======================================================================
local function as_array(x)
  if type(x) == 'string' then
    local out = {}
    for part in (x .. ','):gmatch('(.-),') do
      out[#out + 1] = tonumber(part) or 0
    end
    return out
  end
  return x
end

-- 等宽分箱：把数值数组压成 bins 个桶的计数
local function hist_equal(values, bins, lo, hi)
  local n = #values
  if n == 0 then return {} end
  lo = lo or math.huge
  hi = hi or -math.huge
  for i = 1, n do
    local v = values[i]
    if v < lo then lo = v end
    if v > hi then hi = v end
  end
  if hi <= lo then hi = lo + 1 end  -- 常量列：单桶兜底
  local w = (hi - lo) / bins
  local counts = {}
  for i = 1, bins do counts[i] = 0 end
  for i = 1, n do
    local b = math.floor((values[i] - lo) / w) + 1
    if b < 1 then b = 1 elseif b > bins then b = bins end
    counts[b] = counts[b] + 1
  end
  return counts, lo, hi
end

-- 显式边界分箱（p.breaks = 升序边界数组，如 {-1,0,1,10} → 4 个桶）
local function hist_breaks(values, breaks)
  local counts = {}
  for i = 1, #breaks + 1 do counts[i] = 0 end
  for i = 1, #values do
    local v = values[i]
    local b = #breaks + 1
    for j = 1, #breaks do
      if v <= breaks[j] then b = j break end
    end
    counts[b] = counts[b] + 1
  end
  return counts
end

-- 计数 → 占比（下限 0.0001 防除零，业界 PSI 惯例）
local function to_share(counts, n)
  local share = {}
  for i = 1, #counts do
    share[i] = (counts[i] or 0) / math.max(n, 1)
    if share[i] < 0.0001 then share[i] = 0.0001 end
  end
  return share
end

local function fmt4(x) return string.format('%.4f', x + 0) end
local function round4(x) return math.floor(x * 10000 + 0.5) / 10000 end

-- ======================================================================
-- 核心：PSI / KL / Chi2（占比数组级）
-- ======================================================================
local function psi_core(share_e, share_a)
  local total = 0
  for i = 1, #share_e do
    local e, a = share_e[i], share_a[i]
    total = total + (a - e) * math.log(a / e)
  end
  return total
end

local function kl_core(share_e, share_a)
  local total = 0
  for i = 1, #share_e do
    local e, a = share_e[i], share_a[i]
    total = total + a * math.log(a / e)
  end
  return total
end

local function chi2_core(counts_e, counts_a, n_a)
  local total = 0
  for i = 1, #counts_e do
    local e = counts_e[i] or 0
    local a = counts_a[i] or 0
    if e > 0 then
      total = total + (a - e * n_a / (counts_e.total_n or #counts_e)) ^ 2 / e
    end
  end
  return total
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'psi'

  -- 归一化输入：优先原始数值数组（自动分箱），其次显式占比数组
  local share_e, share_a, counts_e, counts_a
  if p.raw_e and p.raw_a then
    local ve, va = as_array(p.raw_e), as_array(p.raw_a)
    if p.breaks and type(p.breaks) == 'table' then
      counts_e, counts_a = hist_breaks(ve, p.breaks), hist_breaks(va, p.breaks)
    else
      local bins = p.bins or 10
      local ce, lo, hi = hist_equal(ve, bins)
      local ca = hist_equal(va, bins, lo, hi)  -- 对齐到同一边界
      counts_e, counts_a = ce, ca
    end
    local ne, na = #ve, #va
    counts_e.total_n, counts_a.total_n = ne, na
    share_e, share_a = to_share(counts_e, ne), to_share(counts_a, na)
  else
    share_e, share_a = as_array(p.e), as_array(p.a)
    if #share_e ~= #share_a then return '{"error":"share arrays length mismatch"}' end
    for i = 1, #share_e do
      if share_e[i] < 0.0001 then share_e[i] = 0.0001 end
      if share_a[i] < 0.0001 then share_a[i] = 0.0001 end
    end
  end

  if op == 'psi' then return fmt4(psi_core(share_e, share_a)) end
  if op == 'kl' then return fmt4(kl_core(share_e, share_a)) end
  if op == 'chi2' then
    if not counts_e then return '{"error":"chi2 needs raw arrays"}' end
    return fmt4(chi2_core(counts_e, counts_a, counts_a.total_n or 1))
  end
  if op == 'report' then
    local psiv = psi_core(share_e, share_a)
    local klv = kl_core(share_e, share_a)
    local chi2v = counts_e and chi2_core(counts_e, counts_a, counts_a.total_n or 1) or nil
    local verdict
    if psiv < 0.10 then verdict = 'no-drift'
    elseif psiv <= 0.25 then verdict = 'moderate-drift'
    else verdict = 'significant-drift' end
    return string.format(
      '{"psi":%s,"kl":%s,"chi2":%s,"verdict":"%s","bins":%d}',
      string.format('%.4f', round4(psiv)),
      string.format('%.4f', round4(klv)),
      chi2v and string.format('%.4f', round4(chi2v)) or 'null',
      verdict, #share_e)
  end
  return ''
end

return function(p)
  return run(p)
end
