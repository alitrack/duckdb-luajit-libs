-- @lib: dp
-- @category: stats
-- @desc: 差分隐私（Differential Privacy）机制 —— Laplace 机制的 count/sum/mean，
--        纯 Lua 零外部依赖（自实现 Laplace 采样 + Park-Miller 种子 RNG，与 fake 同内核，
--        同 seed 跨平台逐位一致）。面向 NPP 医疗/合规场景：发布聚合统计前先加隐私预算噪声，
--        使单条记录的加入/移除无法被输出反推。ε 越小越私密（噪声越大）。
-- @source: duckdb-luajit-libs libs/stats (self-contained, no FFI)
-- @requires: none (pure LuaJIT)
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--
-- 差分隐私核心（一句话）：输出 = 真值 + Laplace(敏感度 / ε) 噪声。
--   · count   敏感度 = 1（多一条记录 count 最多变 1）
--   · sum     敏感度 = (hi - lo)（先把每条裁剪到 [lo,hi]，再多一条最多让 sum 变 hi-lo）
--   · mean    敏感度 = (hi - lo) / n（n 是公共行数，mean = sum/n）
-- 加噪后：
--   · count  round 到整数并 floor 到 ≥ 0
--   · sum/mean 保留 DOUBLE
--
-- 用法（duckdb-luajit，quick_compile / install 后）：
--   -- 载入本库：
--   SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'dp',
--     source := 'return dofile(\'/path/to/dp.lua\')');
--   -- count（ε=1）：
--   SELECT luajit_s('dp', {op:'count', data:list(v), eps:1}) FROM t;
--   -- sum（裁剪到 [0,100]，ε=0.5）：
--   SELECT luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:100, eps:0.5}) FROM t;
--   -- mean（ε=0.5）：
--   SELECT luajit_s('dp', {op:'mean', data:list(v), lo:0, hi:100, eps:0.5}) FROM t;
--   -- 原始 Laplace 噪声（调试/自定义机制用）：
--   SELECT luajit_s('dp', {op:'lap', scale:2, seed:42});
--
-- 参数：
--   op      : 'count' / 'sum' / 'mean' / 'lap' / 'lap_vec' / 'mechanisms'
--   data    : LIST<数值>（op=count/sum/mean）。SQL 侧传 list(col) 或 [..] 字面量
--   eps     : 隐私预算 ε > 0（必需；count/sum/mean）。越小越私密
--   lo, hi  : 裁剪边界（sum/mean 必需）；NULL 行自动剔除
--   scale   : op='lap'/'lap_vec' 的 Laplace 尺度 b
--   n       : op='lap_vec' 的采样次数（同流连续 n 次，返回 JSON 数组）
--   seed    : 复现种子（任意 op 可选；同 seed 逐位一致）
-- 成功返回裸数值（VARCHAR 渲染）；失败返回 {"status":"Error","message":...}。

local json = (function()
  local ok, m = pcall(require, 'json')
  if ok and m then return m end
  -- 极简兜底 encode（仅用于错误对象，无依赖）
  local function esc(s)
    return (tostring(s):gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      return string.format('\\u%04x', c:byte())
    end))
  end
  return {
    encode = function(v)
      if type(v) ~= 'table' then return tostring(v) end
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = '"' .. esc(k) .. '":"' .. esc(val) .. '"'
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end,
  }
end)()

local function err(msg) return json.encode({ status = 'Error', message = msg }) end

-- ======================================================================
-- 种子化 PRNG（Park–Miller MINSTD LCG：s = s*16807 mod (2^31-1)）
-- 与 fake.lua 同款：同 seed 同序列，跨平台一致，全程 double 精确
-- （最大乘积 ~3.6e13 < 2^53）。返回 () -> [0,1) 均匀随机数。
-- ======================================================================
local M2147483647 = 2147483647 -- 2^31 - 1
local function make_rng(seed)
  local s = math.floor(seed or os.time()) % M2147483647
  if s <= 0 then s = s + M2147483647 - 1 end
  return function()
    s = (s * 16807) % M2147483647
    return (s - 1) / (M2147483647 - 1) -- [0,1)
  end
end

-- ======================================================================
-- Laplace 采样（逆 CDF 法）：x = -b * sign(v-0.5) * ln(1 - 2|v - 0.5|)
-- v ~ U(0,1)。b 为尺度（b = 敏感度/ε）。数值上 v 严格避开 0.5 两侧边界。
-- ======================================================================
local function laplace(rng, b)
  local v = rng()
  while v >= 1.0 do v = rng() end -- 防御（[0,1) 不应触到 1，但保险）
  local s = v < 0.5 and -1 or 1
  return -b * s * math.log(1 - 2 * math.abs(v - 0.5))
end

local function as_num(x, what)
  if type(x) == 'number' then return x end
  if type(x) == 'string' then
    local n = tonumber(x)
    if n then return n end
  end
  return nil, what .. ' must be numeric'
end

local function to_list(data)
  if type(data) ~= 'table' then
    return nil, 'data must be a LIST (pass list(col) or [..])'
  end
  -- 已是数组（1..n）直接用；否则转数组
  local out = {}
  for i = 1, #data do out[i] = data[i] end
  return out
end

local function get_eps(p)
  local e = tonumber(p.eps)
  if not e or e <= 0 then return nil, 'eps must be a number > 0' end
  return e
end

local function get_bounds(p)
  local lo = tonumber(p.lo)
  local hi = tonumber(p.hi)
  if lo == nil or hi == nil then return nil, 'sum/mean require lo and hi (clip bounds)' end
  if hi < lo then return nil, 'hi must be >= lo' end
  return lo, hi
end

-- ======================================================================
-- op 实现
-- ======================================================================
local function op_count(p, rng)
  local e = get_eps(p)
  if not e then return err(e) end
  local data, dmsg = to_list(p.data)
  if not data then return err(dmsg) end
  local n = 0
  for i = 1, #data do
    local v = as_num(data[i], 'data element')
    if v ~= nil then n = n + 1 end -- 与 sum/mean 一致：只数非 NULL 行
  end
  local noisy = n + laplace(rng, 1.0 / e) -- 敏感度 = 1
  noisy = math.floor(noisy + 0.5)          -- round
  if noisy < 0 then noisy = 0 end          -- floor ≥ 0
  return tostring(noisy)
end

local function op_sum(p, rng)
  local e = get_eps(p)
  if not e then return err(e) end
  local lo, hi, bmsg = get_bounds(p)
  if not lo then return err(bmsg) end
  local data, dmsg = to_list(p.data)
  if not data then return err(dmsg) end
  local s = 0
  for i = 1, #data do
    local v, msg = as_num(data[i], 'data element')
    if v ~= nil then
      if v < lo then v = lo elseif v > hi then v = hi end -- 裁剪
      s = s + v
    end
  end
  local noisy = s + laplace(rng, (hi - lo) / e) -- 敏感度 = (hi-lo)
  return string.format('%.10g', noisy)
end

local function op_mean(p, rng)
  local e = get_eps(p)
  if not e then return err(e) end
  local lo, hi, bmsg = get_bounds(p)
  if not lo then return err(bmsg) end
  local data, dmsg = to_list(p.data)
  if not data then return err(dmsg) end
  local s, n = 0, 0
  for i = 1, #data do
    local v, msg = as_num(data[i], 'data element')
    if v ~= nil then
      if v < lo then v = lo elseif v > hi then v = hi end
      s = s + v; n = n + 1
    end
  end
  if n == 0 then return err('no non-null values in data') end
  local mean = s / n
  local noisy = mean + laplace(rng, (hi - lo) / (e * n)) -- 敏感度 = (hi-lo)/n
  return string.format('%.10g', noisy)
end

local function op_lap(p, rng)
  local b = tonumber(p.scale)
  if not b or b < 0 then return err('scale must be a number >= 0') end
  return string.format('%.10g', laplace(rng, b))
end

-- op_lap_vec：单流连续 n 次采样。mode='array'（默认）返回 JSON 数组；
-- mode='stats' 返回 {n,mean,stddev,min,max} 的 JSON 对象（库内算好，便于 SQL 侧断言）。
-- 注意：与 op_lap 不同，这里 n 个值来自同一 rng 流的连续调用（不重设 seed），
-- 因此零均值/尺度等分布性质在 n 足够大时才显现（op_lap 每次单抽，
-- 小 seed 首值有偏向，勿用它做分布检验）。
local function op_lap_vec(p, rng)
  local b = tonumber(p.scale)
  if not b or b < 0 then return err('scale must be a number >= 0') end
  local n = math.floor(tonumber(p.n))
  if not n or n <= 0 or n > 1000000 then return err('n must be an integer in [1, 1000000]') end
  local vals = {}
  local sum, sumsq, mn, mx = 0, 0, math.huge, -math.huge
  for i = 1, n do
    local x = laplace(rng, b)
    vals[i] = x
    sum = sum + x
    sumsq = sumsq + x * x
    if x < mn then mn = x end
    if x > mx then mx = x end
  end
  if p.mode == 'stats' then
    local mean = sum / n
    local var = (sumsq / n) - mean * mean
    if var < 0 then var = 0 end
    return json.encode({
      n = n,
      mean = string.format('%.6f', mean),
      stddev = string.format('%.6f', math.sqrt(var)),
      min = string.format('%.6f', mn),
      max = string.format('%.6f', mx),
    })
  end
  local out = {}
  for i = 1, n do out[i] = string.format('%.6f', vals[i]) end
  return '[' .. table.concat(out, ',') .. ']'
end

local function op_mechanisms()
  return json.encode({
    count  = 'Laplace, sensitivity=1, noise b=1/eps, output rounded & floored>=0',
    sum    = 'Laplace, clip data to [lo,hi], sensitivity=(hi-lo), noise b=(hi-lo)/eps',
    mean   = 'Laplace, clip data to [lo,hi], sensitivity=(hi-lo)/n, noise b=(hi-lo)/(eps*n)',
    note   = 'Pure Laplace mechanism. Deterministic for a given seed (Park-Miller). eps>0; smaller eps = more private = more noise.',
  })
end

-- ======================================================================
-- 单一顶层函数返回（quick_compile 契约：chunk 顶层 return function）
-- arg 为 struct（DuckDB struct 字面量 / 解析后的 JSON 表），按 p.op 分派。
-- ======================================================================
return function(arg)
  local p = arg
  if type(p) == 'string' then
    -- 容忍 JSON 字符串入参
    local ok, t = pcall(json.decode, p)
    if not ok or type(t) ~= 'table' then
      -- 非 JSON 字符串不是 dp 的合法入参（dp 无裸值形态）
      return err('dp expects a struct {op, data, eps, ...}')
    end
    p = t
  end
  if type(p) ~= 'table' then
    return err('dp expects a struct {op, data, eps, ...}')
  end
  local op = p.op
  local rng = make_rng(p.seed)
  if op == 'count' then return op_count(p, rng)
  elseif op == 'sum' then return op_sum(p, rng)
  elseif op == 'mean' then return op_mean(p, rng)
  elseif op == 'lap' then return op_lap(p, rng)
  elseif op == 'lap_vec' then return op_lap_vec(p, rng)
  elseif op == 'mechanisms' then return op_mechanisms()
  else return err('unknown op: ' .. tostring(op)) end
end
