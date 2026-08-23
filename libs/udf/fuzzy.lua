-- @lib: fuzzy
-- @category: udf
-- @desc: 字符串相似度/距离算法（纯 Lua，自包含，UTF-8 感知）。
--       op='lev'：编辑距离（Levenshtein，代码点级）；
--       op='normlev'：归一化编辑距离 = lev / max(len)，∈[0,1]，越小越像；
--       op='jaro'：Jaro 相似度 ∈[0,1]（对短串/姓名友好）；
--       op='jw'：Jaro-Winkler 相似度 ∈[0,1]（前缀加权，默认 p=0.25，`p.p` 可调）；
--       op='sim'：默认取 jw（`p.metric`='jw'|'jaro'|'lev' 选指标，lev 时为 1-normlev）；
--       op='simrank'：给定候选列表 `p.cands` + 目标 `p.v`，按相似度降序返回
--                     "idx:score" 列表（记录链接 / 姓名匹配 / 去重的打分核心）。
--       所有算法在 **UTF-8 解码后的 Unicode 代码点** 上进行（中文字符=1 个单元，
--       避免字节级退化：王小明 vs 王小民 字节级 jw 会错误得 1.0，代码点级得 0.875）。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: none
-- 诚实边界：Jaro-Winkler 前缀长度上限 4（经典定义）；`simrank` 候选数以百计为最佳，
-- 万级以上请改走 SQL 端 join + 本函数打分。lev 用 O(len_a × len_b) DP（短串最优）。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='fuzzy');
--   lev:      SELECT luajit_s('fuzzy', {a:'kitten', b:'sitting', op:'lev'});   → '3'
--   normlev:  SELECT luajit_s('fuzzy', {a:'kitten', b:'sitting', op:'normlev'});-- → '0.4286'
--   jw:       SELECT luajit_s('fuzzy', {a:'martha', b:'marhta', op:'jw'});    → '0.9861'
--   simrank:  SELECT luajit_s('fuzzy', {v:'北京',
--                cands: ['北京','北京上海','京','北京上海广州'], op:'simrank'});
--             → '1:1.0000 4:0.8750 2:0.7500 3:0.6250'  (idx 1-based, score=jw)

local fuzzy = {}

-- ======================================================================
-- UTF-8 解码：字符串 → 代码点数组（BMP + 增补平面）
-- ======================================================================
local function utf8cp(s)
  local cps = {}
  local i = 1
  local n = #s
  while i <= n do
    local b1 = s:byte(i)
    local cp, len
    if b1 < 0x80 then
      cp, len = b1, 1
    elseif b1 >= 0xC0 and b1 < 0xE0 then
      local b2 = s:byte(i + 1) or 0
      cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
      len = 2
    elseif b1 >= 0xE0 and b1 < 0xF0 then
      local b2, b3 = s:byte(i + 1) or 0, s:byte(i + 2) or 0
      cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
      len = 3
    elseif b1 >= 0xF0 and b1 < 0xF8 then
      local b2, b3, b4 = s:byte(i + 1) or 0, s:byte(i + 2) or 0, s:byte(i + 3) or 0
      cp = (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
      len = 4
    else
      cp, len = b1, 1  -- 非法起始字节：按单字节兜底
    end
    cps[#cps + 1] = cp
    i = i + len
  end
  return cps
end

-- ======================================================================
-- Levenshtein 编辑距离（代码点数组级，O(m·n) DP）
-- ======================================================================
local function lev_cp(A, B)
  local m, n = #A, #B
  if m == 0 then return n end
  if n == 0 then return m end
  if A == B then return 0 end
  local prev = {}
  for j = 0, n do prev[j] = j end
  for i = 1, m do
    local cur = { [0] = i }
    local ai = A[i]
    for j = 1, n do
      local c = (ai == B[j]) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + c)
    end
    prev = cur
  end
  return prev[n]
end

local function lev(a, b)
  if a == b then return 0 end
  local A, B = utf8cp(a), utf8cp(b)
  return lev_cp(A, B)
end

-- ======================================================================
-- Jaro 相似度（代码点数组级）
-- ======================================================================
local function jaro_cp(A, B)
  local m1, m2 = #A, #B
  if m1 == 0 and m2 == 0 then return 1 end
  if m1 == 0 or m2 == 0 then return 0 end
  if m1 == 1 and m2 == 1 then return (A[1] == B[1]) and 1 or 0 end
  local md = math.floor(math.max(m1, m2) / 2) - 1
  if md < 0 then md = 0 end
  local bused, amatched, m = {}, {}, 0
  for i = 1, m1 do
    local lo = i > md and (i - md) or 1
    local hi = i + md <= m2 and (i + md) or m2
    for j = lo, hi do
      if not bused[j] and A[i] == B[j] then
        bused[j] = true
        amatched[i] = true
        m = m + 1
        break
      end
    end
  end
  if m == 0 then return 0 end
  local trans, k = 0, 1
  for i = 1, m1 do
    if amatched[i] then
      while not bused[k] do k = k + 1 end
      if A[i] ~= B[k] then trans = trans + 1 end
      k = k + 1
    end
  end
  local d = trans / 2
  return (m / m1 + m / m2 + (m - d) / m) / 3
end

local function jaro(a, b)
  return jaro_cp(utf8cp(a), utf8cp(b))
end

-- ======================================================================
-- Jaro-Winkler（前缀加权，经典前缀上限 4）
-- ======================================================================
local function jw_cp(A, B, p)
  p = p or 0.25
  local m1, m2 = #A, #B
  if m1 == 0 and m2 == 0 then return 1 end
  if m1 == 0 or m2 == 0 then return 0 end
  local j = jaro_cp(A, B)
  if j > 0.7 then
    local l = 0
    while l < 4 and l < m1 and l < m2 and A[l + 1] == B[l + 1] do
      l = l + 1
    end
    if l > 0 then j = j + l * p * (1 - j) end
  end
  return j
end

local function jw(a, b, p)
  return jw_cp(utf8cp(a), utf8cp(b), p)
end

local function normlev(a, b)
  local A, B = utf8cp(a), utf8cp(b)
  local mx = math.max(#A, #B)
  if mx == 0 then return 0 end
  return lev_cp(A, B) / mx
end

local function fmt4(x)
  return string.format('%.4f', x + 0)
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '' end
  local a = p.a or ''
  local b = p.b or ''
  local op = p.op or 'jw'
  if op == 'lev' then
    return string.format('%d', lev(a, b))
  elseif op == 'normlev' then
    return fmt4(normlev(a, b))
  elseif op == 'jaro' then
    return fmt4(jaro(a, b))
  elseif op == 'jw' then
    return fmt4(jw(a, b, p.p or 0.25))
  elseif op == 'sim' then
    local metric = p.metric or 'jw'
    if metric == 'jw' then return fmt4(jw(a, b, p.p or 0.25))
    elseif metric == 'jaro' then return fmt4(jaro(a, b))
    else return fmt4(1 - normlev(a, b)) end
  elseif op == 'simrank' then
    local target = p.v or a
    local cands = p.cands
    if type(cands) == 'string' then
      -- 兼容：以换行或竖线分隔
      cands = {}
      for part in (cands .. '\n'):gmatch('(.-)\n') do
        if part ~= '' then cands[#cands + 1] = part end
      end
    end
    if type(cands) ~= 'table' then cands = {} end
    local p0 = p.p or 0.25
    local scored = {}
    for i, c in ipairs(cands) do
      scored[#scored + 1] = { idx = i, score = jw(target, tostring(c), p0) }
    end
    table.sort(scored, function(x, y)
      if x.score ~= y.score then return x.score > y.score end
      return x.idx < y.idx
    end)
    local parts = {}
    for i, s in ipairs(scored) do
      parts[#parts + 1] = string.format('%d:%s', s.idx, fmt4(s.score))
    end
    return table.concat(parts, ' ')
  end
  return ''
end

return function(p)
  return run(p)
end
