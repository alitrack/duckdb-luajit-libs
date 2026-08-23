-- @lib: rss
-- @category: parser
-- @desc: RSS / Atom feed 解析（纯 Lua，自包含）—— DuckDB 无内建 RSS/Atom/XPath，
--       本库把 feed 规整为统一 JSON：{type, title, link, description, updated, items:[...]}。
--       支持 RSS 2.0、RSS 1.0 (RDF)、Atom 1.0。
--       op 选项（v = feed XML 文本；或用 file = feed 文件路径，库内 io.open 读取）：
--         'detect' → "rss2" | "rss10" | "atom" | "unknown"
--         'feed'   → 规整后的 feed JSON 对象
--         'items'  → items 数组的 JSON（每条 {title,link,pubDate,description,author,content}，缺失字段省略）
--         'count'  → 条目数（整数字符串）
--       字段映射（诚实边界）：
--         RSS2 <item> : title/link/pubDate/description/author(或 dc:creator)/content:encoded
--         RSS10 <item> (RDF resource) : title/link/description/dc:date/dc:creator
--         Atom <entry> : title/link[@href](首选 alternate)/updated 或 published/summary/content/author/name
--       未支持：feed 级图片/订阅按钮、命名空间深度解析（dc: 前缀按标签名保留）、分页/多 feed。
--       解析器移植自本仓库 xml.lua（proven：实体/CDATA/PI/声明/属性/嵌套）。
-- @source: 自包含（解析器源自本仓库 xml.lua）
-- @requires: none
--
-- Usage:
--   SELECT luajit_s('rss', {op:'detect', v:'<rss version="2.0"><channel>...</channel></rss>'});  -- rss2
--   SELECT luajit_s('rss', {op:'feed',  v: feedxml});
--   SELECT json_extract(luajit_s('rss',{op:'items',v:feedxml}), '$[0].title');

-- ==========================================================================
-- XML 解析器（移植自本仓库 xml.lua，proven）
-- ==========================================================================
local ENT = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }
local function decode_entities(s)
  s = (s:gsub('&#x([0-9a-fA-F]+);', function(h)
    local c = tonumber(h, 16); return c and c < 128 and string.char(c) or '?' end))
  s = (s:gsub('&#([0-9]+);', function(h)
    local c = tonumber(h); return c and c < 128 and string.char(c) or '?' end))
  s = (s:gsub('&([%a][%w]*);', function(n) return ENT[n] or ('&' .. n .. ';') end))
  return s
end
local function make_node(name) return { name = name, attrs = {}, content = {}, children = {} } end
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
    if not name then error('xml: 非法属性名 @' .. i) end
    i = i + #name; i = skip_ws(s, i)
    if s:sub(i, i) ~= '=' then error('xml: 属性缺 = @' .. i) end
    i = skip_ws(s, i + 1)
    local q = s:sub(i, i)
    if q ~= '"' and q ~= "'" then error('xml: 属性值缺引号 @' .. i) end
    local e = s:find(q, i + 1, true)
    if not e then error('xml: 属性引号未闭合') end
    attrs[name] = decode_entities(s:sub(i + 1, e - 1))
    i = e + 1
  end
end
parse_element = function(s, i)
  local name = s:match('[%a_%:%-][%w%:%.%-]*', i + 1)
  if not name then error('xml: 非法元素名 @' .. i) end
  i = i + 1 + #name
  local node = make_node(name)
  local attrs, j = parse_attributes(s, i)
  node.attrs = attrs; i = j
  local c = s:sub(i, i)
  if c == '/' then
    if s:sub(i + 1, i + 1) ~= '>' then error('xml: 自闭合非法') end
    return node, i + 2
  elseif c == '>' then i = i + 1
  else error('xml: 标签结束非法 @' .. i) end
  local content = node.content
  while i <= #s do
    if s:sub(i, i) == '<' then
      local c2 = s:sub(i + 1, i + 1)
      if c2 == '/' then
        local e = s:find('>', i)
        if not e then error('xml: 结束标签未闭合') end
        local inner = s:sub(i + 2, e - 1)
        local ename = inner:match('^([%a_%:%-][%w%:%.%-]*)%s*$')
        if not ename or ename ~= name then error('xml: 标签不匹配') end
        return node, e + 1
      elseif c2 == '!' then
        if s:sub(i + 1, i + 8) == '![CDATA[' then
          local e = s:find(']]>', i, true)
          if not e then error('xml: CDATA 未闭合') end
          table.insert(content, { t = 'text', v = s:sub(i + 9, e - 1) }); i = e + 3
        elseif s:sub(i + 1, i + 3) == '!--' then
          local e = s:find('-->', i, true); i = e + 3
        else
          local e = s:find('>', i, true); i = e + 1
        end
      elseif c2 == '?' then
        local e = s:find('?>', i, true); i = e + 2
      else
        local child, ni = parse_element(s, i)
        node.children[#node.children + 1] = child
        table.insert(content, { t = 'el', v = child }); i = ni
      end
    else
      local e = s:find('<', i)
      local chunk
      if e then chunk = s:sub(i, e - 1); i = e
      else chunk = s:sub(i); i = #s + 1 end
      table.insert(content, { t = 'text', v = decode_entities(chunk) })
    end
  end
  error('xml: 元素 ' .. name .. ' 未闭合')
end
local function parse_document(s)
  s = (s:gsub('^%bom', ''))
  local i = skip_ws(s, 1)
  local root = nil
  while i <= #s do
    if s:sub(i, i) == '<' then
      local c2 = s:sub(i + 1, i + 1)
      if c2 == '!' then local e = s:find('>', i, true); i = e + 1
      elseif c2 == '?' then local e = s:find('?>', i, true); i = e + 2
      else
        local node, ni = parse_element(s, i)
        if root == nil then root = node
        else
          local wrapper = make_node('#root')
          wrapper.children[#wrapper.children + 1] = root
          wrapper.children[#wrapper.children + 1] = node
          root = wrapper
        end
        i = ni; i = skip_ws(s, i)
      end
    else i = i + 1 end
  end
  if not root then error('xml: 空文档') end
  return root
end

-- 节点 → 纯文本
local function node_text(node)
  local out = {}
  for _, it in ipairs(node.content) do
    if it.t == 'text' then out[#out + 1] = it.v
    else
      local sub = node_text(it.v)
      if sub ~= '' then out[#out + 1] = sub end
    end
  end
  return (table.concat(out):gsub('%s+', ' '):match('^%s*(.-)%s*$'))
end

-- 在 node 的直接子元素中按标签名取值（命名空间容忍：先精确，再按 ':' 后段）
local function child(node, name)
  for _, ch in ipairs(node.children) do
    if ch.name == name then return ch end
  end
  local base = name:match('([^:]+)$') or name
  if base ~= name then
    for _, ch in ipairs(node.children) do
      local bn = ch.name:match('([^:]+)$') or ch.name
      if bn == base then return ch end
    end
  end
  return nil
end
-- 取所有匹配标签名的直接子元素
local function children(node, name)
  local out = {}
  for _, ch in ipairs(node.children) do
    if ch.name == name then out[#out + 1] = ch end
  end
  return out
end

-- JSON 编码（移植自 xml.lua，自包含）
local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == '\\' then return '\\\\'
    elseif c == '\n' then return '\\n' elseif c == '\r' then return '\\r'
    elseif c == '\t' then return '\\t' else return string.format('\\u%04x', c:byte()) end
  end))
end
local function is_array(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for k in pairs(t) do if type(k) ~= 'number' then return false end n = n + 1 end
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end
local jenc
jenc = function(v)
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
      local p = {}
      for i = 1, #v do p[i] = jenc(v[i]) end
      return '[' .. table.concat(p, ',') .. ']'
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local p = {}
      for _, k in ipairs(keys) do p[#p + 1] = '"' .. json_escape(tostring(k)) .. '":' .. jenc(v[k]) end
      return '{' .. table.concat(p, ',') .. '}'
    end
  end
  return 'null'
end

-- 从 feed 对象里稳健取字段（值可能是 string 或 table）
local function val_of(node, names)
  for _, nm in ipairs(names) do
    local c = child(node, nm)
    if c then
      local t = node_text(c)
      if t ~= '' then return t end
    end
  end
  return nil
end

local function detect_type(root)
  local nm = root.name
  if nm == 'rss' then return 'rss2' end
  if nm == 'RDF' or nm == 'rdf:RDF' or nm == 'rdf' then return 'rss10' end
  if nm == 'feed' then return 'atom' end
  return 'unknown'
end

local function map_rss2_item(node)
  local it = {}
  it.title = val_of(node, {'title'})
  it.link = val_of(node, {'link'})
  it.pubDate = val_of(node, {'pubDate'})
  it.description = val_of(node, {'description'})
  it.author = val_of(node, {'author', 'dc:creator'})
  it.content = val_of(node, {'content:encoded', 'encoded'})
  return it
end
local function map_rss10_item(node)
  local it = {}
  it.title = val_of(node, {'title'})
  it.link = val_of(node, {'link'})
  it.pubDate = val_of(node, {'dc:date', 'date'})
  it.description = val_of(node, {'description', 'abstract'})
  it.author = val_of(node, {'dc:creator', 'creator'})
  return it
end
local function map_atom_entry(node)
  local it = {}
  it.title = val_of(node, {'title'})
  -- link：优先 rel=alternate 的 href，否则任意 href
  local href = nil
  for _, ch in ipairs(node.children) do
    if ch.name == 'link' or ch.name:match('link$') then
      local h = ch.attrs['href']
      if h and (href == nil or (ch.attrs['rel'] or 'alternate') == 'alternate') then
        href = h
        if (ch.attrs['rel'] or 'alternate') == 'alternate' then break end
      end
    end
  end
  it.link = href
  it.pubDate = val_of(node, {'published'}) or val_of(node, {'updated'})
  it.description = val_of(node, {'summary'})
  it.content = val_of(node, {'content'})
  -- author/name
  local author = val_of(node, {'author', 'name', 'dc:creator'})
  if not author then
    for _, ch in ipairs(node.children) do
      if ch.name == 'author' or ch.name:match('author$') then
        local nm = val_of(ch, {'name'})
        if nm then author = nm; break end
      end
    end
  end
  it.author = author
  return it
end

local function strip_empty(t)
  local out = {}
  for k, v in pairs(t) do if v ~= nil and v ~= '' then out[k] = v end end
  return out
end

local function feed_meta(root, feedtype)
  local meta = { type = feedtype }
  if feedtype == 'rss2' then
    local ch = child(root, 'channel')
    if ch then
      meta.title = val_of(ch, {'title'})
      meta.link = val_of(ch, {'link'})
      meta.description = val_of(ch, {'description'})
      meta.updated = val_of(ch, {'lastBuildDate', 'lastbuilddate'})
    end
  elseif feedtype == 'rss10' then
    local ch = child(root, 'channel')
    if ch then
      meta.title = val_of(ch, {'title'})
      meta.link = val_of(ch, {'link'})
      meta.description = val_of(ch, {'description'})
    end
  elseif feedtype == 'atom' then
    meta.title = val_of(root, {'title'})
    meta.description = val_of(root, {'subtitle'})
    meta.updated = val_of(root, {'updated'})
    local href = nil
    for _, ch in ipairs(root.children) do
      if ch.name == 'link' or ch.name:match('link$') then
        local h = ch.attrs['href']
        if h and (href == nil or (ch.attrs['rel'] or 'alternate') == 'alternate') then
          href = h
          if (ch.attrs['rel'] or 'alternate') == 'alternate' then break end
        end
      end
    end
    meta.link = href
  end
  return strip_empty(meta)
end

local function collect_items(root, feedtype)
  local items = {}
  if feedtype == 'rss2' then
    local ch = child(root, 'channel')
    if ch then
      for _, it in ipairs(children(ch, 'item')) do
        items[#items + 1] = strip_empty(map_rss2_item(it))
      end
    end
  elseif feedtype == 'rss10' then
    for _, it in ipairs(children(root, 'item')) do
      items[#items + 1] = strip_empty(map_rss10_item(it))
    end
  elseif feedtype == 'atom' then
    for _, it in ipairs(children(root, 'entry')) do
      items[#items + 1] = strip_empty(map_atom_entry(it))
    end
  end
  return items
end

return function(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local v = p.v
  if not v or v == '' then
    -- 允许从文件读取（io.open 仅在函数体内，模块顶层禁止）
    if p.file and p.file ~= '' then
      local f = io.open(p.file, 'r')
      if not f then return '{"error":"cannot open ' .. json_escape(p.file) .. '"}' end
      v = f:read('*a'); f:close()
    end
  end
  if not v or v == '' then return '{"error":"missing v or file"}' end
  local op = p.op or 'feed'
  local ok, root = pcall(parse_document, v)
  if not ok then return '{"error":"xml: ' .. json_escape(tostring(root)) .. '"}' end
  local feedtype = detect_type(root)
  if op == 'detect' then return '"' .. feedtype .. '"' end
  if feedtype == 'unknown' then
    return '{"error":"unknown feed type (root <' .. json_escape(root.name) .. '>)"}'
  end
  if op == 'count' then return tostring(#collect_items(root, feedtype)) end
  if op == 'items' then return jenc(collect_items(root, feedtype)) end
  if op == 'feed' then
    local meta = feed_meta(root, feedtype)
    meta.items = collect_items(root, feedtype)
    return jenc(meta)
  end
  return '{"error":"unknown op"}'
end
