-- @lib: xml
-- @category: parser
-- @desc: XML 解析（纯 Lua，自包含）。xml2js 风格对象化：属性 → @名，重复子标签 → 数组，
--       叶子文本 → 字符串。op='load'：XML 文本 → JSON 字符串（配 json_extract 展开）；
--       op='find'：简单路径 //tag/sub → 匹配节点 JSON 数组（tag 或 '*'）；
--       op='attr'：路径+属性名 → 属性值；op='text'：去除所有标签的纯文本。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: none
-- 支持子集（诚实边界）：元素/属性/文本/CDATA/注释/PI/声明/实体(&amp;等+&#NN;+&#xNN;)。
-- 未支持：命名空间前缀（保留原样作 tag 名）、DTD 实体定义、XSD。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='xml');
--   load:     SELECT luajit_s('xml', {v: '<a><b>1</b><b>2</b></a>', op: 'load'});
--             → {"a":{"b":["1","2"]}}
--   drill:    SELECT json_extract(luajit_s('xml', {v: x, op: 'load'}), '$.a.b[0]');
--   find:     SELECT luajit_s('xml', {v: x, op: 'find', path: '//book/title'});
--   attr:     SELECT luajit_s('xml', {v: x, op: 'attr', path: '//book', name: 'id'});
--   text:     SELECT luajit_s('xml', {v: '<p>hi <b>bold</b></p>', op: 'text'});  → "hi bold"

local xml = {}

-- ======================================================================
-- 实体解码
-- ======================================================================
local ENT = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

local function decode_entities(s)
  s = (s:gsub('&#x([0-9a-fA-F]+);', function(h)
    local c = tonumber(h, 16)
    return c and c < 128 and string.char(c) or '?'
  end))
  s = (s:gsub('&#([0-9]+);', function(h)
    local c = tonumber(h)
    return c and c < 128 and string.char(c) or '?'
  end))
  s = (s:gsub('&([%a][%w]*);', function(n) return ENT[n] or ('&' .. n .. ';') end))
  return s
end

-- ======================================================================
-- 词法 → 语法树
-- ======================================================================
local function make_node(name)
  return { name = name, attrs = {}, content = {}, children = {} }
end

-- 在 pos 处解析一个完整元素，返回 (node, newpos)
local parse_element

local function skip_ws(s, i)
  while i <= #s and s:sub(i, i):match('%s') do i = i + 1 end
  return i
end

local function parse_attributes(s, i)
  local attrs = {}
  while true do
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '/' or c == '>' or c == '' then return attrs, i end
    local name = s:match('([%a_%:%-][%w%:%.%-]*)', i)
    if not name then error('xml: 非法属性名，位置 ' .. i) end
    i = i + #name
    i = skip_ws(s, i)
    if s:sub(i, i) ~= '=' then error('xml: 属性 ' .. name .. ' 缺 =，位置 ' .. i) end
    i = skip_ws(s, i + 1)
    local q = s:sub(i, i)
    if q ~= '"' and q ~= "'" then
      error('xml: 属性 ' .. name .. ' 值缺引号，位置 ' .. i)
    end
    local e = s:find(q, i + 1, true)
    if not e then error('xml: 属性 ' .. name .. ' 引号未闭合') end
    attrs[name] = decode_entities(s:sub(i + 1, e - 1))
    i = e + 1
  end
end

parse_element = function(s, i)
  -- s[i] == '<'，s[i+1] 是名称首字符
  local name = s:match('[%a_%:%-][%w%:%.%-]*', i + 1)
  if not name then error('xml: 非法元素名，位置 ' .. i) end
  i = i + 1 + #name
  local node = make_node(name)
  local attrs, j = parse_attributes(s, i)
  node.attrs = attrs
  i = j
  local c = s:sub(i, i)
  if c == '/' then
    -- 自闭合
    if s:sub(i + 1, i + 1) ~= '>' then error('xml: 自闭合标签 ' .. name .. ' 非法') end
    return node, i + 2
  elseif c == '>' then
    i = i + 1
  else
    error('xml: 元素 ' .. name .. ' 标签结束非法，位置 ' .. i)
  end
  -- 内容：有序 (text|element) 列表，直到 </name>
  local content = node.content
  while i <= #s do
    if s:sub(i, i) == '<' then
      local c2 = s:sub(i + 1, i + 1)
      if c2 == '/' then
        -- 结束标签
        local e = s:find('>', i)
        if not e then error('xml: 结束标签未闭合，位置 ' .. i) end
        local inner = s:sub(i + 2, e - 1)
        local ename = inner:match('^([%a_%:%-][%w%:%.%-]*)%s*$')
        if not ename then error('xml: 结束标签非法，位置 ' .. i) end
        if ename ~= name then
          error('xml: 标签不匹配，期望 </' .. name .. '>，位置 ' .. i)
        end
        return node, e + 1
      elseif c2 == '!' then
        -- CDATA 或 注释 或 DOCTYPE
        if s:sub(i + 1, i + 8) == '![CDATA[' then
          local e = s:find(']]>', i, true)
          if not e then error('xml: CDATA 未闭合') end
          table.insert(content, { t = 'text', v = s:sub(i + 9, e - 1) })
          i = e + 3
        elseif s:sub(i + 1, i + 3) == '!--' then
          local e = s:find('-->', i, true)
          if not e then error('xml: 注释未闭合') end
          i = e + 3
        else
          -- DOCTYPE / 其他声明，跳过到 >
          local e = s:find('>', i, true)
          if not e then error('xml: 声明未闭合') end
          i = e + 1
        end
      elseif c2 == '?' then
        -- PI <? ... ?>
        local e = s:find('?>', i, true)
        if not e then error('xml: PI 未闭合') end
        i = e + 2
      else
        -- 子元素
        local child, ni = parse_element(s, i)
        node.children[#node.children + 1] = child
        table.insert(content, { t = 'el', v = child })
        i = ni
      end
    else
      -- 文本：累积到下一个 '<'
      local e = s:find('<', i)
      local chunk
      if e then
        chunk = s:sub(i, e - 1)
        i = e
      else
        chunk = s:sub(i)
        i = #s + 1
      end
      table.insert(content, { t = 'text', v = decode_entities(chunk) })
    end
  end
  error('xml: 元素 ' .. name .. ' 未闭合')
end

local function parse_document(s)
  -- 去掉 BOM
  s = (s:gsub('^%bom', ''))
  local i = skip_ws(s, 1)
  local root = nil
  while i <= #s do
    if s:sub(i, i) == '<' then
      local c2 = s:sub(i + 1, i + 1)
      if c2 == '!' then
        local e = s:find('>', i, true)
        if not e then error('xml: 声明未闭合') end
        i = e + 1
      elseif c2 == '?' then
        local e = s:find('?>', i, true)
        if not e then error('xml: PI 未闭合') end
        i = e + 2
      else
        local node, ni = parse_element(s, i)
        if root == nil then
          root = node
        else
          -- 多根：包一层
          local wrapper = make_node('#root')
          wrapper.children[#wrapper.children + 1] = root
          wrapper.children[#wrapper.children + 1] = node
          root = wrapper
        end
        i = ni
        i = skip_ws(s, i)
      end
    else
      i = i + 1
    end
  end
  if not root then error('xml: 空文档') end
  return root
end

-- ======================================================================
-- 树 → xml2js 风格 JSON 兼容表
-- ======================================================================
local function collect_text(node)
  local out = {}
  for _, it in ipairs(node.content) do
    if it.t == 'text' then
      out[#out + 1] = it.v
    else
      local sub = collect_text(it.v)
      if sub ~= '' then out[#out + 1] = sub end
    end
  end
  return (table.concat(out):gsub('%s+', ' '):match('^%s*(.-)%s*$'))
end

local function objectify(node)
  local has_el = #node.children > 0
  -- 从有序 content 提取文本
  local text_items = {}
  for _, it in ipairs(node.content) do
    if it.t == 'text' then text_items[#text_items + 1] = it.v end
  end
  local rawtxt = table.concat(text_items)
  local txt = rawtxt:match('^%s*(.-)%s*$')
  if not has_el then
    -- 叶子
    if next(node.attrs) then
      local result = {}
      for k, v in pairs(node.attrs) do result['@' .. k] = v end
      if txt ~= '' then result['#text'] = txt end
      return result
    end
    return txt
  end
  -- 有子元素
  local result = {}
  for k, v in pairs(node.attrs) do result['@' .. k] = v end
  local groups, order = {}, {}
  for _, ch in ipairs(node.children) do
    if groups[ch.name] == nil then
      groups[ch.name] = {}
      order[#order + 1] = ch.name
    end
    table.insert(groups[ch.name], ch)
  end
  if txt ~= '' then result['#text'] = txt end
  for _, nm in ipairs(order) do
    local list = groups[nm]
    if #list == 1 then
      result[nm] = objectify(list[1])
    else
      local arr = {}
      for _, ch in ipairs(list) do arr[#arr + 1] = objectify(ch) end
      result[nm] = arr
    end
  end
  return result
end

-- ======================================================================
-- 路径匹配（//descendant 与 /child）
-- ======================================================================
local function split(s, sep)
  local out = {}
  local start = 1
  while true do
    local a, b = s:find(sep, start)
    if a then
      out[#out + 1] = s:sub(start, a - 1)
      start = b + 1
    else
      out[#out + 1] = s:sub(start)
      break
    end
  end
  return out
end

local function parse_path(path)
  local steps = {}
  local marked = path:gsub('//', '/^/')  -- 连续斜杠标记为后代
  local desc = false
  for _, part in ipairs(split(marked, '/')) do
    if part == '' then
      -- 无
    elseif part == '^' then
      desc = true
    else
      steps[#steps + 1] = { tag = part, mode = desc and 'desc' or 'child' }
      desc = false
    end
  end
  return steps
end

local function all_descendants(node, out)
  for _, ch in ipairs(node.children) do
    out[#out + 1] = ch
    all_descendants(ch, out)
  end
end

local function match_path(root, path)
  local steps = parse_path(path)
  if #steps == 0 then return {} end
  local set = { root }
  local seen = {}
  for _, step in ipairs(steps) do
    local next_set = {}
    for _, node in ipairs(set) do
      local cands
      if step.mode == 'desc' then
        cands = {}
        all_descendants(node, cands)
      else
        cands = node.children
      end
      for _, ch in ipairs(cands) do
        if (ch.name == step.tag or step.tag == '*') and not seen[ch] then
          seen[ch] = true
          next_set[#next_set + 1] = ch
        end
      end
    end
    set = next_set
  end
  return set
end

-- ======================================================================
-- JSON 编解码（与 yaml 库一致的精简实现，自包含）
-- ======================================================================
local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"'
    elseif c == '\\' then return '\\\\'
    elseif c == '\n' then return '\\n'
    elseif c == '\r' then return '\\r'
    elseif c == '\t' then return '\\t'
    else return string.format('\\u%04x', c:byte()) end
  end))
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local json_encode_val

json_encode_val = function(v)
  if v == nil then return 'null' end
  local tv = type(v)
  if tv == 'boolean' then return v and 'true' or 'false' end
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    return string.format('%g', v)
  end
  if tv == 'string' then return '"' .. json_escape(v) .. '"' end
  if tv == 'table' then
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = json_encode_val(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode_val(v[k])
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return 'null'
end

local function json_encode(v) return json_encode_val(v) end

-- ======================================================================
-- UDF 分发包装
-- ======================================================================
local function load_wrapped(src)
  local root = parse_document(src)
  return { [root.name] = objectify(root) }
end

return function(p)
  if type(p) == 'string' then
    return json_encode(load_wrapped(p))
  end
  if type(p) ~= 'table' then return '' end
  local v = p.v or ''
  if v == '' then return '' end
  local op = p.op or 'load'
  local root = parse_document(v)
  if op == 'load' then
    return json_encode({ [root.name] = objectify(root) })
  elseif op == 'find' then
    local nodes = match_path(root, p.path or '')
    local arr = {}
    for _, n in ipairs(nodes) do
      arr[#arr + 1] = objectify(n)
    end
    return json_encode(arr)
  elseif op == 'attr' then
    local nodes = match_path(root, p.path or '')
    if #nodes > 0 and nodes[1].attrs[p.name] ~= nil then
      return nodes[1].attrs[p.name]
    end
    return nil
  elseif op == 'text' then
    return collect_text(root)
  end
  return ''
end
