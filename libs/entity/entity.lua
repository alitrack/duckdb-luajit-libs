-- @lib: entity
-- @category: entity
-- @desc: 实体解析/记录链接管道（纯 Lua，自包含，UTF-8 感知）——blocking → 相似度打分 → 连通分量聚类。
--       op='block'：生成 blocking 键。p.v 字符串；p.mode:
--         'soundex'（英文姓氏经典 Soundex，4 字符）；
--         'first3'（标准化后首 3 字符，中英文通用）；
--         'ngram'（bigram 集合按分隔符拼键，p.n 默认 2）；
--         'norm'（只做标准化：小写/去空白/去标点，返回全串）。
--       标准化统一：小写 → 折叠空白 → 去标点（保留 CJK 字母数字）。
--       op='match'：两串相似度 ∈[0,1]。默认 Jaro-Winkler（前缀加权 p=0.25，p.p 可调）；
--         p.metric='jaro'|'jw'|'lev'（lev 时为 1−归一化编辑距离）。
--       op='resolve'：完整管道（小规模原型，几百条内）。p.records = { {id=..., name=..., city=..., ...}, ... }；
--         p.key_fields = { 'name', 'city' }（参与 blocking+打分的字段，默认 {'name'}）；
--         p.threshold = 打分阈值（默认 0.88，JW 口径）；
--         p.block_mode = 'first3'|'soundex'（默认 first3，中英文通用）。
--       流程：逐记录生成 blocking 键 → 同键组内两两打分（多字段取加权平均，p.weights 可调）
--       → 超阈值连边 → union-find 连通分量 → canonical 取组内 name 最长记录。
--       返回 JSON：{ clusters: [ {cluster, ids:[...], canonical, size, members:[{id,name,score}]}, ... ],
--                    pairs: 连边数, uniq: 原始记录数 }
-- 诚实边界：soundex 只对英文有效（中文名请用 first3/ngram）；blocking 是召回控制，漏了
-- 键就漏了配对——生产建议多键并联（首3 + soundex + ngram 各跑一遍再并）；打分阈值需按
-- 数据分布调（原型 0.88 是英文名经验值，中文名建议 0.85~0.90 实测）。resolve 是全内存
-- 实现，万级以上请改 SQL 端 join + match 打分（fuzzy.simrank 的思路）。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='entity');
--   block:    SELECT luajit_s('entity', {v:'John Smith', mode:'soundex', op:'block'});  → 'J532'
--   match:    SELECT luajit_s('entity', {a:'martha', b:'marhta', op:'match'});          → '0.9861'
--   resolve:  SELECT luajit_s('entity', {records:[{id:1,name:'Alice Chen',city:'HZ'},
--             {id:2,name:'Alice Chen',city:'Hangzhou'},{id:3,name:'Bob',city:'SH'}],
--             key_fields:['name','city'], op:'resolve'});
--             → '{"clusters":[{"cluster":1,"ids":[1,2],"canonical":"Alice Chen",...}]}'

local entity = {}
local json_encode  -- 前向声明（定义在文件后部，调用发生在 chunk 加载完成后）

-- ======================================================================
-- UTF-8 代码点（与 fuzzy lib 同约定）
-- ======================================================================
local function utf8cp(s)
  local cps = {}
  local i, n = 1, #s
  while i <= n do
    local b1 = s:byte(i)
    local cp, len
    if b1 < 0x80 then cp, len = b1, 1
    elseif b1 >= 0xC0 and b1 < 0xE0 then
      cp = (b1 - 0xC0) * 64 + ((s:byte(i + 1) or 0) - 0x80); len = 2
    elseif b1 >= 0xE0 and b1 < 0xF0 then
      local b2, b3 = s:byte(i + 1) or 0, s:byte(i + 2) or 0
      cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80); len = 3
    elseif b1 >= 0xF0 and b1 < 0xF8 then
      local b2, b3, b4 = s:byte(i + 1) or 0, s:byte(i + 2) or 0, s:byte(i + 3) or 0
      cp = (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80); len = 4
    else cp, len = b1, 1 end
    cps[#cps + 1] = cp
    i = i + len
  end
  return cps
end

local function is_alnum(cp)
  return (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122)
    or cp >= 0x4E00 and cp <= 0x9FFF  -- CJK 基本区
end

-- 标准化：小写 + 折叠空白 + 去标点（保留字母数字与 CJK）
local function norm(s)
  local out = {}
  local prev_space = false
  for _, cp in ipairs(utf8cp(s)) do
    if cp >= 65 and cp <= 90 then cp = cp + 32 end
    if is_alnum(cp) then
      out[#out + 1] = cp
      prev_space = false
    elseif cp == 32 or cp == 9 then
      if not prev_space and #out > 0 then out[#out + 1] = 32 end
      prev_space = true
    end
  end
  return out
end

local function tostr(cps)
  local parts = {}
  for _, cp in ipairs(cps) do
    if cp <= 0x7F then
      parts[#parts + 1] = string.char(cp)
    elseif cp <= 0x7FF then
      parts[#parts + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp <= 0xFFFF then
      parts[#parts + 1] = string.char(0xE0 + math.floor(cp / 4096),
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    else
      parts[#parts + 1] = string.char(0xF0 + math.floor(cp / 262144),
        0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
  end
  return table.concat(parts)
end

-- ======================================================================
-- Jaro / Jaro-Winkler / Levenshtein（代码点级）
-- ======================================================================
local function jaro(A, B)
  local la, lb = #A, #B
  if la == 0 and lb == 0 then return 1 end
  if la == 0 or lb == 0 then return 0 end
  local match_dist = math.floor(math.max(la, lb) / 2) - 1
  if match_dist < 0 then match_dist = 0 end
  local a_match, b_match = {}, {}
  local matches = 0
  for i = 1, la do
    local lo = math.max(1, i - match_dist)
    local hi = math.min(lb, i + match_dist)
    for j = lo, hi do
      if not b_match[j] and A[i] == B[j] then
        a_match[i], b_match[j] = true, true
        matches = matches + 1
        break
      end
    end
  end
  if matches == 0 then return 0 end
  local t, k = 0, 1
  for i = 1, la do
    if a_match[i] then
      while not b_match[k] do k = k + 1 end
      if A[i] ~= B[k] then t = t + 1 end
      k = k + 1
    end
  end
  local m = matches
  return (m / la + m / lb + (m - t / 2) / m) / 3
end

local function jw(A, B, p)
  local j = jaro(A, B)
  -- 共同前缀（上限 4）
  local l = 0
  for i = 1, math.min(#A, #B, 4) do
    if A[i] == B[i] then l = l + 1 else break end
  end
  return j + l * (p or 0.25) * (1 - j)
end

local function lev(A, B)
  local m, n = #A, #B
  if m == 0 then return n end
  if n == 0 then return m end
  local prev = {}
  for j = 0, n do prev[j] = j end
  for i = 1, m do
    local cur = { [0] = i }
    local ai = A[i]
    for j = 1, n do
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ai == B[j] and 0 or 1))
    end
    prev = cur
  end
  return prev[n]
end

-- ======================================================================
-- Soundex（英文；非字母开头返回 ''）
-- ======================================================================
local SOUNDEX_MAP = { ['b']='1',['f']='1',['p']='1',['v']='1',
  ['c']='2',['g']='2',['j']='2',['k']='2',['q']='2',['s']='2',['x']='2',['z']='2',
  ['d']='3',['t']='3',['l']='4',['m']='5',['n']='5',['r']='6' }
local VOWELS = { a = true, e = true, i = true, o = true, u = true, y = true }

local function soundex(s)
  local out = {}
  local prev_code
  for i = 1, #s do
    local c = s:sub(i, i):lower()
    if i == 1 then
      out[1] = string.upper(c)
    elseif SOUNDEX_MAP[c] then
      local code = SOUNDEX_MAP[c]
      if code ~= prev_code then
        out[#out + 1] = code
        prev_code = code
      end
    elseif VOWELS[c] then
      prev_code = nil  -- 元音分隔：允许同码再现
    end
    if #out >= 4 then break end
  end
  while #out < 4 do out[#out + 1] = '0' end
  return table.concat(out)
end

-- ======================================================================
-- Blocking 键
-- ======================================================================
local function block_key(v, mode, n)
  local cps = norm(v)
  if #cps == 0 then return '' end
  mode = mode or 'first3'
  if mode == 'norm' then
    return tostr(cps)
  elseif mode == 'soundex' then
    return soundex(tostr(cps))
  elseif mode == 'ngram' then
    local k = n or 2
    local grams = {}
    if #cps < k then return tostr(cps) end
    for i = 1, #cps - k + 1 do
      grams[#grams + 1] = tostring(cps[i])
    end
    table.sort(grams)
    return table.concat(grams, ',')
  else  -- first3
    local out = {}
    for i = 1, math.min(3, #cps) do out[#out + 1] = cps[i] end
    return tostr(out)
  end
end

-- ======================================================================
-- 相似度（多字段加权）
-- ======================================================================
local function field_score(r1, r2, fields, weights, metric, p)
  local total_w, acc = 0, 0
  for i, f in ipairs(fields) do
    local v1, v2 = r1[f], r2[f]
    if v1 ~= nil and v2 ~= nil and tostring(v1) ~= '' and tostring(v2) ~= '' then
      local A, B = norm(tostring(v1)), norm(tostring(v2))
      local sc
      if metric == 'lev' then
        sc = 1 - lev(A, B) / math.max(#A, #B, 1)
      else
        sc = jw(A, B, p.p or 0.25)
      end
      local w = weights and weights[i] or 1
      total_w, acc = total_w + w, acc + w * sc
    end
  end
  if total_w == 0 then return 0 end
  return acc / total_w
end

-- ======================================================================
-- Union-Find
-- ======================================================================
local function make_uf(n)
  return setmetatable({ parent = {}, size = {} }, {
    __index = {
      find = function(self, x)
        local p = self.parent
        while p[x] ~= x do p[x] = p[p[x]]; x = p[x] end
        return x
      end,
      union = function(self, x, y)
        local p, s = self.parent, self.size
        local rx, ry = self:find(x), self:find(y)
        if rx == ry then return end
        if s[rx] < s[ry] then rx, ry = ry, rx end
        p[ry] = rx; s[rx] = s[rx] + s[ry]
      end
    }
  })
end

-- ======================================================================
-- resolve：完整管道
-- ======================================================================
local function resolve(p)
  local records = p.records
  if type(records) ~= 'table' or #records == 0 then
    -- 并行数组模式（SQL 侧兼容：LIST-of-STRUCT 桥接暂不支持，用多列 LIST 代替）
    -- 例：{'op':'resolve', 'name':['Alice Chen','Bob Li'], 'city':['Hangzhou','SH'], 'id':[1,2]}
    local arrs, n = {}, 0
    local CONTROL = { op = true, records = true, key_fields = true, weights = true,
                      threshold = true, block_mode = true, metric = true, p = true }
    for k, v in pairs(p) do
      if type(v) == 'table' and type(v[1]) ~= 'nil' and not CONTROL[k] then
        arrs[k] = v
        n = math.max(n, #v)
      end
    end
    if n == 0 then return '{"error":"records required","clusters":[]}' end
    records = {}
    for i = 1, n do
      records[i] = {}
      for k, v in pairs(arrs) do
        if v[i] ~= nil then records[i][k] = v[i] end
      end
    end
    if not p.key_fields then
      local ks = {}
      for k in pairs(arrs) do if k ~= 'id' then ks[#ks + 1] = k end end
      p.key_fields = ks
    end
  end
  local fields = p.key_fields or { 'name' }
  local weights = p.weights
  local threshold = p.threshold or 0.88
  local block_mode = p.block_mode or 'first3'
  local metric = p.metric or 'jw'

  -- 1. blocking：键 → 记录下标组
  local buckets = {}
  local uniq = 0
  for i, r in ipairs(records) do
    local key = block_key(tostring(r[fields[1]] or ''), block_mode)
    if key ~= '' then
      uniq = uniq + 1
      buckets[key] = buckets[key] or {}
      buckets[key][#buckets[key] + 1] = i
    end
  end

  -- 2. 组内两两打分 → 超阈值连边
  local n = #records
  local uf = make_uf(n)
  for i = 1, n do uf.parent[i], uf.size[i] = i, 1 end
  local pair_count = 0
  local seen = {}
  for key, idxs in pairs(buckets) do
    if #idxs > 1 then
      for a = 1, #idxs - 1 do
        for b = a + 1, #idxs do
          local i, j = idxs[a], idxs[b]
          local edge_key = i < j and (i * 100000 + j) or (j * 100000 + i)
          if not seen[edge_key] then
            seen[edge_key] = true
            local sc = field_score(records[i], records[j], fields, weights, metric, p)
            if sc >= threshold then
              uf:union(i, j)
              pair_count = pair_count + 1
            end
          end
        end
      end
    end
  end

  -- 3. 连通分量 → 输出
  local groups = {}
  for i = 1, n do
    local root = uf:find(i)
    groups[root] = groups[root] or {}
    groups[root][#groups[root] + 1] = i
  end
  local clusters, cid = {}, 0
  for root, ids in pairs(groups) do
    cid = cid + 1
    local canon, canon_len = '', 0
    local members = {}
    for _, i in ipairs(ids) do
      local name = tostring(records[i][fields[1]] or '')
      members[#members + 1] = { id = records[i].id or i, name = name }
      if #name > canon_len then canon, canon_len = name, #name end
    end
    table.sort(members, function(x, y) return tostring(x.id) < tostring(y.id) end)
    clusters[cid] = { cluster = cid, ids = {}, canonical = canon, size = #ids, members = members }
    for _, m in ipairs(members) do clusters[cid].ids[#clusters[cid].ids + 1] = m.id end
  end

  local out = { clusters = clusters, pairs = pair_count, uniq = uniq, records = n }
  return json_encode(out)
end

-- ======================================================================
-- 内联 JSON 编码器（只编码本 lib 自产结构，零外部依赖）
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
  local op = p.op or 'match'
  if op == 'block' then
    return block_key(p.v or '', p.mode, p.n)
  elseif op == 'match' then
    local A, B = norm(tostring(p.a or '')), norm(tostring(p.b or ''))
    local metric = p.metric or 'jw'
    if metric == 'jaro' then return string.format('%.4f', jaro(A, B))
    elseif metric == 'lev' then
      return string.format('%.4f', 1 - lev(A, B) / math.max(#A, #B, 1))
    else
      return string.format('%.4f', jw(A, B, p.p or 0.25))
    end
  elseif op == 'resolve' then
    return resolve(p)
  end
  return ''
end

return function(p)
  return run(p)
end
