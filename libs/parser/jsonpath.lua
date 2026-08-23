-- @lib: jsonpath
-- @category: parser
-- @desc: RFC 9535 JSONPath 实用子集（自含纯 Lua，无 FFI）—— DuckDB 内建 json_extract
--       只支持简单成员/索引路径，不支持通配 *、递归下降 $..x、过滤谓词 [?(@.a>1)]。
--       本库补齐，query(doc, expr) → 命中值 JSON 数组（文档顺序，保留重复）。
--       支持子集：$ 根；.name / ['name'] 成员；* 通配；[n]/[-n] 数组索引；
--       $..name / ..name 递归下降；[?(@.path op literal)] 过滤（op: = != < <= > >=，
--       可 and 组合，@.key 无 op 时表存在性）。
--       op 选项（v = JSON 文档字符串，e = JSONPath 表达式）：
--         'query'  → 命中值 JSON 数组（默认）
--         'exists' → true/false（是否至少一个命中）
--         'count'  → 命中个数（数字）
--         'first'  → 首个命中值（无则 null）
--       注意：Lua 表存不了 null，值里的 null 按缺失处理；数组以 1-based 表存储，
--       JSONPath 的 0-based 下标内部转换（负下标 [-1]=末位）。
--       验证：libs/parser/jsonpath_verify.py（Python 参考实现 + RFC 9535 锚点交叉校验）。

local jp = {}

-- ===================== 自含 JSON 解码 =====================
-- 记录对象键的**文档（文本）顺序**（RFC 9535 结果须按文档顺序，而 Lua 表无序）。
-- 用弱注册表避免引用泄漏；解码后 sorted_keys() 按此顺序输出。
local key_order = setmetatable({}, {__mode = 'k'})
local function json_decode(s)
  local pos = 1
  local function err(m, p) error('json: '..m..(p and (' @ '..p) or ''), 0) end
  local function ws()
    while true do
      local c = s:sub(pos,pos)
      if c==' ' or c=='\t' or c=='\n' or c=='\r' then pos = pos+1 else break end
    end
  end
  local parse_value
  local function parse_string()
    if s:sub(pos,pos) ~= '"' then err('expected string', pos) end
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos,pos)
      if c == '' then err('unterminated string', pos) end
      if c == '"' then pos = pos + 1; break end
      if c == '\\' then
        local e = s:sub(pos+1,pos+1); pos = pos + 2
        if e=='"' then table.insert(buf,'"')
        elseif e=='\\' then table.insert(buf,'\\')
        elseif e=='/' then table.insert(buf,'/')
        elseif e=='b' then table.insert(buf,'\b')
        elseif e=='f' then table.insert(buf,'\f')
        elseif e=='n' then table.insert(buf,'\n')
        elseif e=='r' then table.insert(buf,'\r')
        elseif e=='t' then table.insert(buf,'\t')
        elseif e=='u' then
          local h = s:sub(pos,pos+3); pos = pos + 4
          local cp = tonumber(h,16) or 0
          if cp < 0x80 then table.insert(buf, string.char(cp))
          elseif cp < 0x800 then table.insert(buf, string.char(0xC0+math.floor(cp/64), 0x80+cp%64))
          else table.insert(buf, string.char(0xE0+math.floor(cp/4096), 0x80+math.floor(cp/64)%64, 0x80+cp%64)) end
        else err('bad escape', pos-2) end
      else table.insert(buf, c); pos = pos + 1 end
    end
    return table.concat(buf)
  end
  parse_value = function()
    ws()
    local c = s:sub(pos,pos)
    if c == '' then err('unexpected end', pos) end
    if c == '"' then return parse_string() end
    if c == '{' then
      pos = pos + 1; local t = {}
      ws()
      if s:sub(pos,pos) == '}' then pos = pos + 1; return t end
      key_order[t] = {}
      while true do
        ws()
        local k = parse_string()
        key_order[t][#key_order[t]+1] = k
        ws()
        if s:sub(pos,pos) ~= ':' then err('expected :', pos) end
        pos = pos + 1
        local v = parse_value()
        t[k] = v
        ws()
        local c2 = s:sub(pos,pos)
        if c2 == ',' then pos = pos + 1
        elseif c2 == '}' then pos = pos + 1; break
        else err('expected , or }', pos) end
      end
      return t
    end
    if c == '[' then
      pos = pos + 1; local t = {}
      ws()
      if s:sub(pos,pos) == ']' then pos = pos + 1; return t end
      local n = 0
      while true do
        local v = parse_value(); n = n + 1; t[n] = v
        ws()
        local c2 = s:sub(pos,pos)
        if c2 == ',' then pos = pos + 1
        elseif c2 == ']' then pos = pos + 1; break
        else err('expected , or ]', pos) end
      end
      return t
    end
    if c == 't' then if s:sub(pos,pos+3)=='true' then pos=pos+4; return true end err('bad literal', pos) end
    if c == 'f' then if s:sub(pos,pos+4)=='false' then pos=pos+5; return false end err('bad literal', pos) end
    if c == 'n' then if s:sub(pos,pos+3)=='null' then pos=pos+4; return nil end err('bad literal', pos) end
    local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    if num and num ~= '' then pos = pos + #num; return tonumber(num) end
    err('unexpected char '..c, pos)
  end
  local v = parse_value()
  ws()
  if pos <= #s then err('trailing data', pos) end
  return v
end

-- ===================== 自含 JSON 编码 =====================
local function json_escape(str)
  return (str:gsub('[%z\1-\31\\"]', function(c)
    local m = { ['\\']='\\\\', ['"']='\\"', ['\n']='\\n', ['\r']='\\r',
                ['\t']='\\t', ['\b']='\\b', ['\f']='\\f' }
    if m[c] then return m[c] end
    return string.format('\\u%04x', str:byte())
  end))
end
local json_encode
local function encode(v)
  if v == nil then return 'null' end
  local t = type(v)
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.15g', v)
  end
  if t == 'string' then return '"'..json_escape(v)..'\"' end
  if t == 'table' then
    local isarr, n = true, 0
    for k in pairs(v) do
      n = n + 1
      if type(k) ~= 'number' then isarr = false break end
    end
    if isarr then
      local parts = {}
      for i = 1, n do parts[i] = encode(v[i]) end
      return '['..table.concat(parts, ',')..']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = '"'..json_escape(k)..'": '..encode(v[k]) end
    return '{'..table.concat(parts, ', ')..'}'
  end
  return 'null'
end
json_encode = encode

-- ===================== 工具 =====================
local function is_array(t)
  if type(t) ~= 'table' then return false end
  for k in pairs(t) do if type(k) ~= 'number' then return false end end
  return true
end

local function sorted_keys(t)
  local rec = key_order[t]
  if rec then
    -- 文档（文本）顺序：过滤掉已不在表中的键
    local out = {}
    for _, k in ipairs(rec) do if t[k] ~= nil then out[#out+1] = k end end
    if #out > 0 then return out end
  end
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
  return keys
end

-- 按成员路径取 0-based 下标（数组）或键（对象）
local function get_path(node, keys)
  local cur = node
  for i = 1, #keys do
    local k = keys[i]
    if cur == nil or type(cur) ~= 'table' then return nil end
    if is_array(cur) and k:match('^%-?%d+$') then
      local idx = tonumber(k)
      if idx < 0 then idx = #cur + idx + 1 else idx = idx + 1 end
      if idx < 1 or idx > #cur then return nil end
      cur = cur[idx]
    else
      cur = cur[k]
      if cur == nil then return nil end
    end
  end
  return cur
end

-- 把相对成员路径 "a.b[0].c" 解析成 keys 数组
local function parse_member_path(p)
  local keys = {}
  local i, n = 1, #p
  local function read_name()
    local j = i
    while j <= n and p:sub(j,j) ~= '.' and p:sub(j,j) ~= '[' do j = j + 1 end
    local name = p:sub(i, j-1)
    if name ~= '' then keys[#keys+1] = name end
    return j
  end
  while i <= n do
    local c = p:sub(i,i)
    if c == '.' then
      i = i + 1
      i = read_name()
    elseif c == '[' then
      local close = p:find(']', i)
      if not close then break end
      local inner = p:sub(i+1, close-1)
      local q = inner:match('^"(.*)"$') or inner:match("^'(.*)'$")
      keys[#keys+1] = q or inner
      i = close + 1
    else
      -- 引导段（首个字符是名字的一部分，如 "price" / "a.b" 的 "a"）
      i = read_name()
    end
  end
  return keys
end

-- ===================== 过滤求值 =====================
local eval_clause
local function eval_filter(node, expr)
  -- expr 形如 '?(@.a > 3 and @.b = "x")' → 抽出 @.a... 部分
  local body = expr:match('^%?%((.*)%)%s*$') or expr
  body = body:gsub('^%s+',''):gsub('%s+$','')
  -- 按 " and " 拆子句
  local clauses, cur, i = {}, '', 1
  local function flush() if cur ~= '' then clauses[#clauses+1] = cur end cur = '' end
  while i <= #body do
    if body:sub(i,i+2) == 'and' and body:sub(i-1,i-1)==' ' and body:sub(i+3,i+3)==' ' then
      flush(); i = i + 3
      while body:sub(i,i) == ' ' do i = i + 1 end
    else
      cur = cur .. body:sub(i,i); i = i + 1
    end
  end
  flush()
  for _, cl in ipairs(clauses) do
    if not eval_clause(node, cl) then return false end
  end
  return true
end

-- 在子句中找到第一个比较运算符的位置（引号内的运算符不算）。返回 op, left, right。
local function find_op(clause)
  local i = 1
  local n = #clause
  local inq = nil
  while i <= n do
    local c = clause:sub(i,i)
    if inq then
      if c == inq then inq = nil end
      i = i + 1
    else
      if c == '"' or c == "'" then
        inq = c; i = i + 1
      else
        -- 先试两位运算符，再试一位
        local two = clause:sub(i, i+1)
        if two == '<=' or two == '>=' or two == '!=' then
          local left = clause:sub(1, i-1):gsub('%s+$','')
          local right = clause:sub(i+2):gsub('^%s+',''):gsub('%s+$','')
          return two, left, right
        end
        if c == '<' or c == '>' or c == '=' then
          local left = clause:sub(1, i-1):gsub('%s+$','')
          local right = clause:sub(i+1):gsub('^%s+',''):gsub('%s+$','')
          return c, left, right
        end
        i = i + 1
      end
    end
  end
  return nil, nil, nil
end

eval_clause = function(node, clause)
  clause = clause:gsub('^%s+',''):gsub('%s+$','')
  local op, left, right = find_op(clause)
  -- 无运算符 → 存在性
  if not op then
    local rel = clause:gsub('^@%.',''):gsub('^@','')
    local lkeys = parse_member_path(rel)
    local lval = (#lkeys == 0) and node or get_path(node, lkeys)
    return lval ~= nil
  end
  -- 比较式
  local rel = left:gsub('^@%.',''):gsub('^@','')
  local lkeys = parse_member_path(rel)
  local lval = (#lkeys == 0) and node or get_path(node, lkeys)
  -- 右字面量
  local rval
  if right == 'true' then rval = true
  elseif right == 'false' then rval = false
  elseif right == 'null' or right == 'nil' then rval = nil
  elseif right:match('^%-?%d+%.?%d*$') then rval = tonumber(right)
  else
    local q = right:match('^"(.*)"$') or right:match("^'(.*)'$")
    rval = q or right
  end
  if op == '=' then return lval == rval end
  if op == '!=' then return lval ~= rval end
  local a, b = tonumber(lval), tonumber(rval)
  if a == nil or b == nil then return false end
  if op == '<' then return a < b end
  if op == '<=' then return a <= b end
  if op == '>' then return a > b end
  return a >= b
end

-- ===================== JSONPath 求值 =====================
local function query(root, expr)
  expr = expr:gsub('^%s+',''):gsub('%s+$','')
  if expr == '' or expr:sub(1,1) ~= '$' then error('jsonpath: must start with $', 0) end
  -- 解析成 steps
  local steps = {}
  local i, n = 2, #expr
  while i <= n do
    local c = expr:sub(i,i)
    if c == '.' then
      if expr:sub(i, i+1) == '..' then
        i = i + 2
        local j = i
        while j <= n and expr:sub(j,j) ~= '.' and expr:sub(j,j) ~= '[' do j = j + 1 end
        local name = expr:sub(i, j-1)
        if name ~= '' then steps[#steps+1] = {kind='recursive', name=name} end
        i = j
      else
        i = i + 1
        if expr:sub(i,i) == '*' then
          steps[#steps+1] = {kind='wildcard'}
          i = i + 1
        else
          local j = i
          while j <= n and expr:sub(j,j) ~= '.' and expr:sub(j,j) ~= '[' do j = j + 1 end
          local name = expr:sub(i, j-1)
          if name == '' then error('jsonpath: empty member', 0) end
          steps[#steps+1] = {kind='member', name=name}
          i = j
        end
      end
    elseif c == '*' then
      steps[#steps+1] = {kind='wildcard'}
      i = i + 1
    elseif c == '[' then
      local j, inq = i + 1, nil
      while j <= n do
        local ch = expr:sub(j,j)
        if inq then
          if ch == inq and expr:sub(j-1,j-1) ~= '\\' then inq = nil end
        else
          if ch == '"' or ch == "'" then inq = ch
          elseif ch == ']' then break end
        end
        j = j + 1
      end
      if not (j <= n) then error('jsonpath: unterminated [', 0) end
      local inner = expr:sub(i+1, j-1)
      i = j + 1
      if inner:match('^%-?%d+$') then
        steps[#steps+1] = {kind='index', idx=tonumber(inner)}
      elseif inner:sub(1,1) == '?' then
        steps[#steps+1] = {kind='filter', expr=inner}
      elseif inner:match('^"') or inner:match("^'") then
        local q = inner:match('^"(.*)"$') or inner:match("^'(.*)'$")
        steps[#steps+1] = {kind='member', name=q}
      elseif inner == '*' then
        steps[#steps+1] = {kind='wildcard'}
      else
        steps[#steps+1] = {kind='member', name=inner}
      end
    else
      error('jsonpath: unexpected char '..c..' @ '..i, 0)
    end
  end

  local current = { {path='', value=root} }
  for _, step in ipairs(steps) do
    local next = {}
    if step.kind == 'member' then
      for _, m in ipairs(current) do
        local node = m.value
        if type(node) == 'table' and node[step.name] ~= nil then
          next[#next+1] = {path=m.path..'.'..step.name, value=node[step.name]}
        end
      end
    elseif step.kind == 'index' then
      for _, m in ipairs(current) do
        local node = m.value
        if type(node) == 'table' and is_array(node) then
          local idx = step.idx
          if idx < 0 then idx = #node + idx + 1 else idx = idx + 1 end
          if idx >= 1 and idx <= #node then
            next[#next+1] = {path=m.path..'['..tostring(step.idx)..']', value=node[idx]}
          end
        end
      end
    elseif step.kind == 'wildcard' then
      for _, m in ipairs(current) do
        local node = m.value
        if type(node) == 'table' then
          if is_array(node) then
            for idx = 1, #node do next[#next+1] = {path=m.path..'['..(idx-1)..']', value=node[idx]} end
          else
            for _, k in ipairs(sorted_keys(node)) do
              next[#next+1] = {path=m.path..'.'..k, value=node[k]}
            end
          end
        end
      end
    elseif step.kind == 'recursive' then
      local function find_all(node, path)
        if node == nil or type(node) ~= 'table' then return end
        if is_array(node) then
          for idx = 1, #node do find_all(node[idx], path..'['..(idx-1)..']') end
        else
          for _, k in ipairs(sorted_keys(node)) do
            local cp = path..'.'..k
            if k == step.name then next[#next+1] = {path=cp, value=node[k]} end
            find_all(node[k], cp)
          end
        end
      end
      for _, m in ipairs(current) do find_all(m.value, m.path) end
    elseif step.kind == 'filter' then
      -- 过滤：若节点是数组，对每个**元素**求 @（JSONPath 经典语义，同 jq/gjson/Goessner）；
      -- 否则对整个节点求 @。命中即输出该（元素）值。
      local function filter_node(node, path)
        if is_array(node) then
          for idx = 1, #node do
            if eval_filter(node[idx], step.expr) then
              next[#next+1] = {path=path..'['..(idx-1)..']', value=node[idx]}
            end
          end
        elseif eval_filter(node, step.expr) then
          next[#next+1] = {path=path, value=node}
        end
      end
      for _, m in ipairs(current) do filter_node(m.value, m.path) end
    end
    current = next
  end
  return current
end

-- ===================== 入口 =====================
return function(p)
  if type(p) == 'string' then p = {v = p, e = '$'} end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local doc = p.v
  if not doc or doc == '' then return '{"error":"missing v (json doc)"}' end
  local expr = p.e or p.expr or '$'
  local op = p.op or 'query'

  local ok, parsed = pcall(json_decode, doc)
  if not ok then return '{"error":"invalid json doc: ' .. json_escape(tostring(parsed)) .. '"}' end

  local ok2, matched = pcall(query, parsed, expr)
  if not ok2 then return '{"error":"jsonpath: ' .. json_escape(tostring(matched)) .. '"}' end

  if op == 'count' then
    return json_encode(#matched)
  elseif op == 'exists' then
    return json_encode(#matched > 0)
  elseif op == 'first' then
    return json_encode(matched[1] and matched[1].value or nil)
  else
    local vals = {}
    for _, m in ipairs(matched) do vals[#vals+1] = m.value end
    return json_encode(vals)
  end
end
