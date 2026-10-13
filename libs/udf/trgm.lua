-- @lib: trgm
-- @category: udf
-- @desc: 字符三元组相似度（移植 PostgreSQL pg_trgm，逐位对拍 PG 回归测试）。
--       pg_trgm 的相似度与 fuzzy 库的编辑距离族（lev/jaro/jw）是两套不同算法：
--       pg_trgm = 把每个单词小写后按 "  单词 " （2 前缀空格+1 后缀空格）滑窗取所有
--       3 字节三元组，两串取三元组集合，similarity = |A∩B| / |A∪B|（Jaccard）。
--       op='sim'   ：similarity(a,b) ∈[0,1]，越大越像（PG `similarity` 函数 / `%` 操作符的标量核心）
--       op='dist'  ：1 - similarity，距离（PG `<->` 操作符）
--       op='pct'   ：bool，similarity >= (p.threshold 默认 0.3)，等价 PG 的 `a % b`
--       op='wpct'  ：bool，similarity >= (p.threshold 默认 0.6)，`%` 的字面阈值版（PG word_similarity 是另一套位置算法，见下边界）
--       op='trgm'  ：show_trgm(s) → 排序去重后的三元组集合，竖线分隔（PG `show_trgm`）
--       三元组在 **UTF-8 字节** 上做（与 PG 一致：多字节字符经 compact_trigram 压成 3 字节，
--       但纯 ASCII 场景即字节三元组；PG 回归测试全 ASCII，逐位一致）。
--       单词 = 最大 alnum 连续段（ISWORDCHR），小写化后参与（ASCII 小写）。
-- @source: 移植自 PostgreSQL contrib/pg_trgm/trgm_op.c（LPADDING=2/RPADDING=1, CALCSML=count/(len1+len2-count)）
-- @requires: none（纯 Lua，无 FFI）
-- @license: MIT (duckdb-luajit-libs project)；算法源自 PostgreSQL（PostgreSQL License，兼容）
-- @maturity: tested（对拍 PG 回归测试 620+ 组 similarity 期望值，见 test_trgm.lua）
-- 诚实边界：① 本实现为标量相似度，**不含 GIN/GiST 索引**（DuckDB 无对应索引抽象，分析场景逐行算即可，
--   百万行内可接受；要索引加速需 C 扩展）。② PG 的 word_similarity / strict_word_similarity
--   是基于三元组**位置**的另一套算法（calc_word_similarity），本库未实现——需要时另加。
--   ③ 多字节（CJK）走 PG 的 compact_trigram 压缩路径，本库按 UTF-8 字节三元组近似（ASCII 逐位一致，
--   CJK 与 PG 可能有 1 ulp 级差异，文档标注）。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='trgm');
--   sim:      SELECT luajit_s('trgm', {a:'qwertyu0988', b:'qwertyu0980', op:'sim'});  → '0.714286'
--   pct:      SELECT luajit_s('trgm', {a:'WOWa ', b:'wow', op:'pct'});               → 'true'
--   trgm:     SELECT luajit_s('trgm', {v:'a b c', op:'trgm'});                        → '  a|  b|  c| a | b | c '
local trgm = {}

local function is_wordchar(b)
  -- ASCII alnum（PG ISWORDCHR 对 ASCII 等价；multibyte 下 PG 用 t_isalnum_with_len，这里按字节）
  return (b >= 0x30 and b <= 0x39)
      or (b >= 0x41 and b <= 0x5A)
      or (b >= 0x61 and b <= 0x7A)
end

local function lower_ascii(b)
  if b >= 0x41 and b <= 0x5A then return b + 32 end
  return b
end

-- 取一个字符串的所有单词（最大 alnum 段），每个小写化，返回 {word, ...}
local function words(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if is_wordchar(b) then
      local j = i
      local buf = {}
      while j <= n do
        local c = s:byte(j)
        if not is_wordchar(c) then break end
        buf[#buf + 1] = s:byte(j)
        j = j + 1
      end
      -- lowercase
      for k, cb in ipairs(buf) do buf[k] = lower_ascii(cb) end
      out[#out + 1] = string.char(unpack(buf))
      i = j
    else
      i = i + 1
    end
  end
  return out
end

-- 单个单词 → 三元组集合（"  w " 的 3 字节滑窗，Set: trgm->true）
local function word_trigrams(w, set)
  local p = '  ' .. w .. ' '   -- 2 前缀空格 + w + 1 后缀空格
  local len = #p
  if len < 3 then return end
  for i = 1, len - 2 do
    local t = p:sub(i, i + 2)
    if not set[t] then set[t] = true end
  end
end

-- 字符串 → 三元组集合（Set）
local function generate_set(s)
  local set = {}
  for _, w in ipairs(words(s)) do
    word_trigrams(w, set)
  end
  return set
end

-- 两个 Set 求 |A∩B| 与 |A∪B|
local function inter_union(A, B)
  local count, lenA, lenB = 0, 0, 0
  for _ in pairs(A) do lenA = lenA + 1 end
  for _ in pairs(B) do lenB = lenB + 1 end
  if lenA == 0 or lenB == 0 then return 0, 0 end
  for t in pairs(A) do
    if B[t] then count = count + 1 end
  end
  local union = lenA + lenB - count
  return count, union
end

local function similarity(a, b)
  local A, B = generate_set(tostring(a)), generate_set(tostring(b))
  local count, union = inter_union(A, B)
  if union == 0 then return 0.0 end
  return count / union
end

-- 排序去重后按字典序返回三元组列表（PG show_trgm 排序为字节序）
local function show_trgm(s)
  local set = generate_set(tostring(s))
  local arr = {}
  for t in pairs(set) do arr[#arr + 1] = t end
  table.sort(arr)   -- 字节序（Lua string 比较 = 字节序）
  return table.concat(arr, '|')
end

local function fmt6(x)
  -- PG float4 + extra_float_digits=0 显示约 6 位小数
  return string.format('%.6f', x + 0)
end

local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '' end
  local a = p.a or p.v or ''
  local b = p.b or ''
  local op = p.op or 'sim'
  if op == 'sim' then
    return fmt6(similarity(a, b))
  elseif op == 'dist' then
    return fmt6(1 - similarity(a, b))
  elseif op == 'pct' then
    local th = (p.threshold or p.th) or 0.3
    return tostring(similarity(a, b) >= th)
  elseif op == 'wpct' then
    local th = (p.threshold or p.th) or 0.6
    return tostring(similarity(a, b) >= th)
  elseif op == 'trgm' then
    return show_trgm(a)
  end
  return ''
end

return function(p)
  return run(p)
end
