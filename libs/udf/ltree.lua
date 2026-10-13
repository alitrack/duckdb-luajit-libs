-- @lib: ltree
-- @category: udf
-- @desc: 层级路径（移植 PostgreSQL ltree 扩展，逐位对拍 PG 回归测试）。ltree 是「点分层级路径」
--       类型（如 'Top.Child1.Child2'），用于分类树/目录树/分类编码的包含、公共祖先、子路径运算。
--       DuckDB 无原生 ltree 类型，本库把路径当字符串、按 '.' 切分层级，逐函数移植 PG 语义：
--       op='nlevel'   ：p.path → 层级数（PG `nlevel`），'1.2.3.4'→4
--       op='text'     ：p.path → 原样字符串（PG `ltree2text`，校验非空层级）
--       op='subltree' ：p.path + p.start + p.stop → 取 [start,stop) 层级（0 起，stop 不含）（PG `subltree`）
--                       'Top.Child1.Child2' start=1 stop=2 → 'Child1'
--       op='subpath'  ：p.path + p.start + (p.len 可选) → PG `subpath`（start/len 可为负，len=0 表到末尾）
--                       subpath(x,0)→全串；subpath(x,1)→从第 1 级；subpath(x,-1,1)→末级
--       op='lca'      ：p.paths（数组）→ 最长公共祖先（PG `lca`），无公共祖先/含空路径 → NULL（返回空串）
--                       lca('1.2.3','1.2.3.4.5.6')→'1.2'；lca('1')→NULL
--       op='isparent' ：p.parent + p.child → parent 是否 child 的前缀层级（PG `isparent`/`<@`）
--                       'Top' isparent 'Top.Child1'→true
--       op='desc'     ：child 是否为 parent 的子（含自身）——等价 isparent(parent,child)，PG `!@`
--       op='contains' ：p.a + p.b → b 是否作为连续子路径出现在 a 内（PG `@`/`ltree_index`>=0）
--                       'a.b.c.d' contains 'b.c'→true
--       op='concat'   ：p.a || p.b 层级拼接（PG `||`）
--       op='cmp'      ：p.a + p.b → 层级字典序比较 -1/0/1（PG `<=>`，供 SQL 物化键排序）
--       层级上限 65535（对齐 PG LTREE_MAX_LEVELS）。
-- @source: 移植自 PostgreSQL contrib/ltree/ltree_op.c（lca_inner/inner_subltree/inner_isparent）
-- @requires: none（纯 Lua，无 FFI）
-- @license: MIT (duckdb-luajit-libs project)；算法源自 PostgreSQL（PostgreSQL License，兼容）
-- @maturity: tested（对拍 PG ltree.out 回归期望值，见 test_ltree.lua）
-- 诚实边界：① ltree 的 GiST 索引（`<@`/`@` 走索引）无对应——DuckDB 无该索引抽象，逐行算。
--   ② lca 的「公共祖先长度 ≤ 首路径层数-1」语义严格照搬（首路径自身不算祖先）。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='ltree');
--   nlevel:   SELECT luajit_i('ltree', {path:'1.2.3.4', op:'nlevel'});          → 4
--   subpath:  SELECT luajit_s('ltree', {path:'Top.Child1.Child2', start:1, op:'subpath'}); → 'Child1.Child2'
--   lca:      SELECT luajit_s('ltree', {paths:['1.2.3','1.2.3.4.5.6'], op:'lca'});         → '1.2'
--   isparent: SELECT luajit_b('ltree', {parent:'Top', child:'Top.Child1', op:'isparent'}); → true

local MAX_LEVELS = 65535

-- 切分层级：按 '.' 分，保留空层级（PG 允许空 label）
local function split_levels(path)
  local out = {}
  if path == nil then return out end
  if path == '' then return out end
  for part in (path .. '.'):gmatch('(.-)%.') do
    out[#out + 1] = part
  end
  return out
end

local function join_levels(levels)
  return table.concat(levels, '.')
end

local function check_levels(n)
  if n > MAX_LEVELS then
    error(('number of ltree levels (%d) exceeds the maximum allowed (%d)'):format(n, MAX_LEVELS))
  end
end

local function nlevel(path)
  return #split_levels(path)
end

-- inner_subltree(path, start, end)：0 起，[start,end)，end 含到 numlevel 为止
local function inner_subltree(path, startpos, endpos)
  local levels = split_levels(path)
  local nl = #levels
  if startpos < 0 or endpos < 0 or startpos >= nl or startpos > endpos then
    error('invalid positions')
  end
  if endpos > nl then endpos = nl end
  local out = {}
  for i = startpos, endpos - 1 do out[#out + 1] = levels[i + 1] end
  check_levels(#out)
  return out
end

local function lca_inner(arr)
  local len = #arr
  if len <= 0 then return nil end
  local first = split_levels(arr[1])
  if #first == 0 then return nil end
  local num = #first - 1   -- 公共祖先长度 ≤ 首路径层数 - 1
  for idx = 2, len do
    local p = split_levels(arr[idx])
    if #p == 0 then
      return nil
    elseif #p == 1 then
      num = 0
    else
      local tmp = math.min(num, #p - 1)
      local n = 0
      for i = 0, tmp - 1 do
        if first[i + 1] == p[i + 1] then
          n = i + 1
        else
          break
        end
      end
      num = n
    end
  end
  local out = {}
  for i = 1, num do out[i] = first[i] end
  return out
end

local function isparent(parent, child)
  local pl = split_levels(parent)
  local cl = split_levels(child)
  if #pl > #cl then return false end
  for i = 1, #pl do
    if pl[i] ~= cl[i] then return false end
  end
  return true
end

-- ltree_index(a, b, start)：b 是否作为连续子路径出现在 a 内（从 start 级，0 起）
local function ltree_index(a, b, start)
  local al = split_levels(a)
  local bl = split_levels(b)
  if start < 0 then
    if -start >= #al then start = 0 else start = #al + start end
  end
  if #al - start < #bl or #al == 0 or #bl == 0 then return -1 end
  for i = start, #al - #bl do
    local ok = true
    for j = 1, #bl do
      if al[i + j] ~= bl[j] then ok = false break end
    end
    if ok then return i end
  end
  return -1
end

-- 层级字典序比较（PG ltree_compare：逐级 memcmp，长度不同取短长差，最后比层数）
local function cmp(a, b)
  local al, bl = split_levels(a), split_levels(b)
  local an, bn = #al, #bl
  local n = math.min(an, bn)
  for i = 1, n do
    if al[i] ~= bl[i] then
      if al[i] < bl[i] then return -1 end
      return 1
    end
    -- 同前缀但长度不同（一个 label 是另一个的真前缀）
    if #al[i] ~= #bl[i] then
      if #al[i] < #bl[i] then return -1 end
      return 1
    end
  end
  if an ~= bn then
    if an < bn then return -1 end
    return 1
  end
  return 0
end

local function run(p)
  if type(p) == 'string' then p = { path = p } end
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'text'
  if op == 'nlevel' then
    return nlevel(p.path)
  elseif op == 'text' then
    return tostring(p.path or '')
  elseif op == 'subltree' then
    local ls = inner_subltree(tostring(p.path), p.start, p.stop)
    return join_levels(ls)
  elseif op == 'subpath' then
    local path = tostring(p.path)
    local levels = split_levels(path)
    local nl = #levels
    local start = p.start
    local has_len = (p.len ~= nil)
    local len = has_len and p.len or 0
    if start < 0 then start = nl + start end   -- PG 先归一化 start
    local endp
    if len < 0 then
      endp = nl + len
    elseif len == 0 then
      -- PG: len==0 时，3-arg → end=start（空）；2-arg（未给 len）→ end=MAX（到末尾）
      endp = has_len and start or MAX_LEVELS
    else
      endp = start + len
    end
    if endp > nl then endp = nl end
    if start < 0 or endp < 0 or start >= nl or start > endp then
      return 'ERR: invalid positions'
    end
    local ls = inner_subltree(path, start, endp)
    return join_levels(ls)
  elseif op == 'lca' then
    local paths = p.paths
    if type(paths) == 'string' then paths = { paths } end
    if type(paths) ~= 'table' or #paths == 0 then return '' end
    local r = lca_inner(paths)
    if r == nil then return '' end   -- PG 返回 NULL
    return join_levels(r)
  elseif op == 'isparent' then
    return tostring(isparent(tostring(p.parent), tostring(p.child)))
  elseif op == 'desc' then
    return tostring(isparent(tostring(p.parent), tostring(p.child)))
  elseif op == 'contains' then
    return tostring(ltree_index(tostring(p.a), tostring(p.b), p.start or 0) >= 0)
  elseif op == 'concat' then
    local al, bl = split_levels(tostring(p.a)), split_levels(tostring(p.b))
    local out = {}
    for i = 1, #al do out[i] = al[i] end
    for i = 1, #bl do out[#out + 1] = bl[i] end
    check_levels(#out)
    return join_levels(out)
  elseif op == 'cmp' then
    return tostring(cmp(tostring(p.a), tostring(p.b)))
  end
  return ''
end

return function(p)
  return run(p)
end
