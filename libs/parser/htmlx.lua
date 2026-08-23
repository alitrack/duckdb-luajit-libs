-- @lib: htmlx
-- @category: parser
-- @desc: HTML → 结构化抽取（纯 Lua，自包含，无 FFI）—— 从 HTML 文本提取 title / 链接 /
--       表格 / 纯文本，配 rss 做内容抽取。DuckDB 无内建 HTML 解析。
--       op 选项（v = HTML 文本；或用 file = HTML 文件路径，库内 io.open 读取）：
--         'title' → <title> 文本（无则 null）
--         'links' → 链接数组 [{href, text}]（<a href>，text=折叠后的锚文本，无 href 的 a 省略）
--         'tables' → 表格数组 [{rows: [[cell,...],...]}]（cell=折叠后的 <td>/<th> 文本）
--         'text'  → 去标签可见纯文本（剔除 head/script/style/noscript/template，空白折叠）
--         'feed'  → {title, links, tables, text} 一次全取
--       HTML 容错：大小写不敏感标签、未闭合标签自动闭合、void 元素（br/img/input…）不压栈、
--         注释/CDATA/DOCTYPE 忽略、属性值带引号/不带引号均支持。
--       验证：libs/parser/htmlx_verify.py（Python html.parser 独立解析交叉校验 title/links/tables）。

local VOID = { br=1, img=1, input=1, hr=1, meta=1, link=1, area=1, base=1,
               col=1, embed=1, source=1, track=1, wbr=1, frame=1 }
local SKIP = { script=1, style=1, noscript=1, template=1, head=1 }

-- 属性解析：key -> value（布尔属性 -> true）
local function parse_attrs(str)
  local attrs = {}
  local i, n = 1, #str
  while i <= n do
    while i <= n and str:sub(i,i):match('%s') do i = i + 1 end
    if i > n then break end
    local ks = i
    while i <= n and str:sub(i,i):match('[%w:_-]') do i = i + 1 end
    local key = str:sub(ks, i-1):lower()
    if key == '' then i = i + 1 end
    while i <= n and str:sub(i,i):match('%s') do i = i + 1 end
    if str:sub(i,i) == '=' then
      i = i + 1
      while i <= n and str:sub(i,i):match('%s') do i = i + 1 end
      local c = str:sub(i,i)
      if c == '"' or c == "'" then
        local q = c; i = i + 1
        local vs = i
        while i <= n and str:sub(i,i) ~= q do i = i + 1 end
        attrs[key] = str:sub(vs, i-1)
        i = i + 1
      else
        local vs = i
        while i <= n and not str:sub(i,i):match('%s') do i = i + 1 end
        attrs[key] = str:sub(vs, i-1)
      end
    else
      attrs[key] = true
    end
  end
  return attrs
end

-- 分词：产出事件列表（{tag=,close=,attrs=,selfclose=} 或 {text=}）
local function tokenize(s)
  local events = {}
  local i, n = 1, #s
  while i <= n do
    if s:sub(i,i) == '<' then
      local four = s:sub(i, i+3):lower()
      if four == '<!--' then
        local close = s:find('-->', i, true)
        i = close and (close + 3) or (n + 1)
      elseif s:sub(i, i+1) == '</' then
        local name = s:match('</%s*([%w:-]+)', i)
        if name then
          events[#events+1] = {tag=name:lower(), close=true}
          local close = s:find('>', i)
          i = close and (close + 1) or (n + 1)
        else i = i + 1 end
      elseif s:sub(i, i+1) == '<?' or s:sub(i, i+8):lower() == '<![cdata[' or s:sub(i, i+9):lower() == '<!doctype' then
        local close = s:find('>', i)
        i = close and (close + 1) or (n + 1)
      else
        local name = s:match('<%s*([%w:-]+)', i)
        if name then
          local rest = s:sub(i+1)
          local gt, inq = nil, nil
          for j = 1, #rest do
            local c = rest:sub(j,j)
            if inq then
              if c == inq then inq = nil end
            else
              if c == '"' or c == "'" then inq = c
              elseif c == '>' then gt = j; break end
            end
          end
          if gt then
            local attrstr = rest:sub(1, gt-1)
            local selfclose = attrstr:sub(-1) == '/'
            events[#events+1] = {tag=name:lower(), attrs=parse_attrs(attrstr), selfclose=selfclose}
            i = i + gt + 1  -- rest 从 i+1 起，gt 是 rest 内 '>' 的下标 → 绝对位 i+gt，跨过去需 +1
          else
            i = n + 1
          end
        else
          i = i + 1
        end
      end
    else
      local close = s:find('<', i)
      local endpos = close or (n + 1)
      local txt = s:sub(i, endpos-1)
      if txt ~= '' then events[#events+1] = {text=txt} end
      i = endpos
    end
  end
  return events
end

local function collapse(t)
  return (t:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function process(events)
  local title, in_title = nil, false
  local links = {}
  local tables = {}
  local text_parts = {}
  local stack = {}
  local cur_link, cur_cell, cur_row, cur_table = nil, nil, nil, nil

  local function visible()
    for _, e in ipairs(stack) do
      if SKIP[e] then return false end
    end
    return true
  end

  for _, ev in ipairs(events) do
    if ev.tag then
      if ev.close then
        local name = ev.tag
        if name == 'a' and cur_link then
          cur_link.text = collapse(table.concat(cur_link.parts, ' '))
          cur_link.parts = nil
          links[#links+1] = cur_link
          cur_link = nil
        elseif (name == 'td' or name == 'th') and cur_cell then
          cur_row[#cur_row+1] = collapse(table.concat(cur_cell.parts, ' '))
          cur_cell = nil
        elseif name == 'tr' and cur_row then
          cur_table.rows[#cur_table.rows+1] = cur_row
          cur_row = nil
        elseif name == 'table' and cur_table then
          tables[#tables+1] = cur_table
          cur_table = nil
        elseif name == 'title' then
          in_title = false
        end
        for k = #stack, 1, -1 do
          if stack[k] == name then table.remove(stack, k); break end
        end
      else
        local name, attrs = ev.tag, (ev.attrs or {})
        if name == 'title' then in_title = true end
        if name == 'a' and attrs.href ~= nil then
          cur_link = {href=attrs.href, parts={}}
        elseif name == 'td' or name == 'th' then
          if not cur_table then cur_table = {rows={}}; tables[#tables+1] = cur_table end
          if not cur_row then cur_row = {} end
          cur_cell = {parts={}}
        elseif name == 'tr' then
          if not cur_table then cur_table = {rows={}}; tables[#tables+1] = cur_table end
          cur_row = {}
        elseif name == 'table' then
          cur_table = {rows={}}
        end
        if not VOID[name] and not ev.selfclose then
          stack[#stack+1] = name
        end
      end
    else
      local txt = ev.text
      if in_title then
        if title == nil then title = collapse(txt) else title = title..' '..collapse(txt) end
      end
      if cur_cell then cur_cell.parts[#cur_cell.parts+1] = txt end
      if cur_link and not in_title and visible() then
        cur_link.parts[#cur_link.parts+1] = txt
      end
      if visible() and not in_title then
        text_parts[#text_parts+1] = txt
      end
    end
  end
  -- 收尾：未闭合的 table/row 也输出
  if cur_table and not (cur_table == tables[#tables]) then tables[#tables+1] = cur_table end
  if cur_row and cur_table then cur_table.rows[#cur_table.rows+1] = cur_row end
  return title, links, tables, collapse(table.concat(text_parts, ' '))
end

-- ===================== JSON 编码 =====================
local function json_escape(str)
  return (str:gsub('[%z\1-\31\\"]', function(c)
    local m = { ['\\']='\\\\', ['"']='\\"', ['\n']='\\n', ['\r']='\\r',
                ['\t']='\\t', ['\b']='\\b', ['\f']='\\f' }
    if m[c] then return m[c] end
    return string.format('\\u%04x', c:byte())
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
    local isarr = true
    for k in pairs(v) do if type(k) ~= 'number' then isarr = false break end end
    if isarr then
      local parts = {}
      for i = 1, #v do parts[i] = encode(v[i]) end
      return '['..table.concat(parts, ',')..']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = '"'..json_escape(k)..'": '..encode(v[k]) end
    return '{'..table.concat(parts, ', ')..'}'
  end
  return 'null'
end
json_encode = encode

-- ===================== 入口 =====================
return function(p)
  if type(p) == 'string' then p = {v = p} end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local v = p.v
  if (not v or v == '') and p.file and p.file ~= '' then
    local f = io.open(p.file, 'r')
    if not f then return '{"error":"cannot open '..tostring(p.file)..'"}' end
    v = f:read('*a'); f:close()
  end
  if not v or v == '' then return '{"error":"missing v or file"}' end

  local op = p.op or 'feed'
  local events = tokenize(v)
  local title, links, tables, text = process(events)

  if op == 'title' then return json_encode(title)
  elseif op == 'links' then return json_encode(links)
  elseif op == 'tables' then return json_encode(tables)
  elseif op == 'text' then return json_encode(text)
  else
    return json_encode({title=title, links=links, tables=tables, text=text})
  end
end
