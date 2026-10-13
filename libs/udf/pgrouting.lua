-- @lib: pgrouting
-- @category: udf
-- @desc: 网络最短路（pgrouting 核心算子 shortest_path 的 Dijkstra 实现），纯 Lua、零 FFI、
--       单文件。输入一组边 (src_node, tgt_node, cost)，输出源→目的最短路径节点序列 + 总代价。
--       与 PG pgrouting 的 _pgr_dijkstra 语义对齐：按 cost 加权、无负权要求（Dijkstra）。
--       默认有向图（directed=true）；directed=false 时边视为双向（无向）。
--       多目标/多源：pgrouting 的 _pgr_kdijkstra 变体（k 条最短路径）可后续加。
--       参数（struct）：
--         edges   : array of [u, v, w]（u/v 整数节点，w 数值代价，必须 >0 或 >=0）
--         src     : 源节点（整数）
--         tgt     : 目的节点（整数）
--         directed: bool，默认 true
-- @source: Dijkstra 算法；接口对齐 pgrouting（https://pgrouting.github.io）
-- @requires: none（单文件自包含）
-- @license: MIT
-- @maturity: tested
-- Usage:
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'pgrouting');
--   SELECT luajit_s('pgrouting', {edges:[[1,2,1],[2,3,2],[1,3,5]], src:1, tgt:3, op:'shortest_path'});
--   -> {"path":[1,2,3],"cost":3,"exists":true}

-- 二叉堆优先队列（数组 [key, node]）
local function new_heap()
  local h = {a = {}, n = 0}
  local function up(i)
    while i > 1 do
      local p = math.floor(i / 2)
      if h.a[i][1] < h.a[p][1] then h.a[i], h.a[p] = h.a[p], h.a[i]; i = p else break end
    end
  end
  local function down(i)
    local n = h.n
    while 2 * i <= n do
      local c = 2 * i
      if c + 1 <= n and h.a[c+1][1] < h.a[c][1] then c = c + 1 end
      if h.a[i][1] > h.a[c][1] then h.a[i], h.a[c] = h.a[c], h.a[i]; i = c else break end
    end
  end
  h.push = function(key, node)
    h.n = h.n + 1
    h.a[h.n] = {key, node}
    up(h.n)
  end
  h.pop = function()
    local top = h.a[1]
    h.a[1] = h.a[h.n]
    h.n = h.n - 1
    if h.n > 0 then down(1) end
    return top[1], top[2]
  end
  h.empty = function() return h.n == 0 end
  return h
end

local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '\n' then return '\\n' elseif c == '\t' then return '\\t'
    elseif c == '\r' then return '\\r' elseif c == '\\' then return '\\\\'
    elseif c == '"' then return '\\"' end
    return ('\\u%04x'):format(c:byte())
  end))
end

local function build(d)
  assert(type(d) == 'table', 'pgrouting: expected data table (unused; stateless)')
  return function(p)
    if type(p) == 'string' then p = {v = p} end
    if type(p) ~= 'table' then return '{"error":"bad input"}' end
    local op = p.op or 'shortest_path'
    local edges = p.edges
    local src, tgt = p.src, p.tgt
    if op == 'shortest_path' then
      if type(edges) ~= 'table' then return '{"error":"missing edges"}' end
      if src == nil or tgt == nil then return '{"error":"missing src/tgt"}' end
      local directed = (p.directed ~= false)  -- default true
      -- build adjacency
      local adj = {}
      for _, e in ipairs(edges) do
        local u, v, w = e[1], e[2], e[3]
        if type(u) ~= 'number' or type(v) ~= 'number' or type(w) ~= 'number' then
          return '{"error":"edge must be [u,v,w] numeric"}'
        end
        adj[u] = adj[u] or {}
        adj[u][#adj[u]+1] = {to = v, w = w}
        if not directed then
          adj[v] = adj[v] or {}
          adj[v][#adj[v]+1] = {to = u, w = w}
        end
      end
      if src == tgt then
        return '{"path":[' .. tostring(src) .. '],"cost":0,"exists":true}'
      end
      -- Dijkstra
      local dist = {[src] = 0}
      local prev = {}
      local visited = {}
      local h = new_heap()
      h.push(0, src)
      while not h.empty() do
        local key, u = h.pop()
        if visited[u] then goto continue end
        visited[u] = true
        if u == tgt then break end
        for _, a in ipairs(adj[u] or {}) do
          local v, w = a.to, a.w
          if not visited[v] then
            local nd = key + w
            if dist[v] == nil or nd < dist[v] then
              dist[v] = nd
              prev[v] = u
              h.push(nd, v)
            end
          end
        end
        ::continue::
      end
      if dist[tgt] == nil then
        return '{"path":[],"cost":null,"exists":false}'
      end
      -- reconstruct path
      local path = {}
      local cur = tgt
      while cur ~= nil do
        path[#path+1] = cur
        cur = prev[cur]
      end
      local rev = {}
      for i = #path, 1, -1 do rev[#rev+1] = path[i] end
      local parts = {}
      for _, x in ipairs(rev) do parts[#parts+1] = tostring(x) end
      return '{"path":[' .. table.concat(parts, ',') .. '],"cost":' .. tostring(dist[tgt]) .. ',"exists":true}'
    else
      return '{"error":"unknown op ' .. json_escape(tostring(op)) .. '"}'
    end
  end
end

local DATA = {}
return build(DATA)
