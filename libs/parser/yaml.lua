-- @lib: yaml
-- @category: parser
-- @desc: YAML 解析/编码（纯 Lua，自包含）。支持：嵌套映射/序列、行内流式 [..] {..}、
--       引号/裸标量（int/float/hex/bool/null）、注释、块标量 | 与 >。
--       op='load'：YAML 文本 → JSON 字符串（配 json_extract 展开）；
--       op='encode'：JSON 字符串 → YAML 文本。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖；JSON 编解码为精简内嵌实现）
-- @requires: none
-- 支持子集（诚实边界）：块映射/序列/流集合/引号与裸标量/注释/块标量(|,>)。
-- 未支持：锚点 & 别名 *、多文档 ---、行内标签 !!、复杂多行裸标量折行。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='yaml');
--   load:     SELECT luajit_s('yaml', {v: 'a: 1\nb:\n  c: 2', op: 'load'});
--             → '{"a":1,"b":{"c":2}}'
--   drill:    SELECT json_extract(luajit_s('yaml', {v:=yaml_text, op:='load'}), '$.b.c');
--   encode:   SELECT luajit_s('yaml', {v: '{"a":1,"b":[1,2]}', op: 'encode'});
--             → 'a: 1\nb:\n  - 1\n  - 2\n'

local yaml = {}

-- ======================================================================
-- 标量解析
-- ======================================================================
local YNULL = { __ynull = true }   -- YAML null 哨兵（JSON 编码为 null）

local function dq_unescape(s)
  return (s:gsub('%[(\\)."\n\t\r/0abfuv%]', function(c)
    if c == 'n' then return '\n'
    elseif c == 't' then return '\t'
    elseif c == 'r' then return '\r'
    elseif c == '0' then return '\0'
    elseif c == 'a' then return '\a'
    elseif c == 'b' then return '\b'
    elseif c == 'f' then return '\f'
    elseif c == 'v' then return '\v'
    elseif c == 'u' then
      -- \uXXXX 在纯 ASCII 子集内解码；非 ASCII 返回占位（罕见于配置）
      local hex = c  -- placeholder; real handling below
      return '?'
    end
    return c
  end))
end

local function parse_number(s)
  if s:match('^0[xX][0-9a-fA-F]+$') then return tonumber(s, 16) end
  if s:match('^[-+]?%d+$') then return tonumber(s) end
  if s:match('^[-+]?%d+%.%d*$') or s:match('^[-+]?%d*%.%d+$') then
    return tonumber(s)
  end
  if s:match('^[-+]?%d+%.?%d*[eE][-+]?%d+$') then return tonumber(s) end
  return nil
end

local function parse_scalar(raw)
  local s = raw:match('^%s*(.-)%s*$')  -- trim
  if s == '' or s == '~' or s:lower() == 'null' then return YNULL end
  local low = s:lower()
  if low == 'true' or low == 'yes' or low == 'on' then return true end
  if low == 'false' or low == 'no' or low == 'off' then return false end
  if s:match('^".*"') then
    local body = s:sub(2, -2)
    -- 处理转义（含 \uXXXX 基础 ASCII）
    body = body:gsub('\\u(%x%x%x%x)', function(h)
      local code = tonumber(h, 16)
      if code and code < 128 then return string.char(code) end
      return '?'
    end)
    body = dq_unescape(body)
    return body
  end
  if s:match("^'.*'") then
    return (s:sub(2, -2):gsub("''", "'"))
  end
  local n = parse_number(s)
  if n ~= nil then return n end
  return s
end

-- ======================================================================
-- 行内流集合  [ .. ] / { .. }
-- ======================================================================
local function skip_ws(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c == ' ' or c == '\t' then i = i + 1 else break end
  end
  return i
end

local parse_flow  -- 前向声明（flow_value 递归调用它）

local function flow_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '[' or c == '{' then
    local v, j = parse_flow(s, i)
    return v, j
  end
  if c == '"' then
    local j = i + 1
    while j <= #s do
      if s:sub(j, j) == '\\' then j = j + 2
      elseif s:sub(j, j) == '"' then break
      else j = j + 1 end
    end
    return parse_scalar(s:sub(i, j)), j + 1
  end
  if c == "'" then
    local j = i + 1
    while j <= #s do
      if s:sub(j, j + 1) == "''" then j = j + 2
      elseif s:sub(j, j) == "'" then break
      else j = j + 1 end
    end
    return parse_scalar(s:sub(i, j)), j + 1
  end
  -- 裸标量：读到 , ] } :（映射键的冒号）为止
  local start = i
  while i <= #s do
    local c = s:sub(i, i)
    if c == ',' or c == ']' or c == '}' or c == ':' then break end
    i = i + 1
  end
  return parse_scalar(s:sub(start, i - 1)), i
end

parse_flow = function(s, i)
  local c = s:sub(i, i)
  if c == '[' then
    local arr, out = {}, {}
    i = i + 1
    while true do
      i = skip_ws(s, i)
      if s:sub(i, i) == ']' then return out, i + 1 end
      local v, j = flow_value(s, i)
      out[#out + 1] = v
      i = skip_ws(s, j)
      if s:sub(i, i) == ',' then i = i + 1
      elseif s:sub(i, i) == ']' then return out, i + 1
      else error('yaml: flow list 期望 , 或 ]，位置 ' .. i) end
    end
  elseif c == '{' then
    local out = {}
    i = i + 1
    while true do
      i = skip_ws(s, i)
      if s:sub(i, i) == '}' then return out, i + 1 end
      -- key
      local key, j
      if s:sub(i, i) == '"' or s:sub(i, i) == "'" then
        key, j = flow_value(s, i)
        key = tostring(key)
        i = skip_ws(s, j)
      else
        local start = i
        while i <= #s and s:sub(i, i) ~= ':' do i = i + 1 end
        key = (s:sub(start, i - 1):match('^%s*(.-)%s*$'))
        i = i + 1  -- 跳过 ':'
      end
      local v, j2 = flow_value(s, i)
      out[key] = v
      i = skip_ws(s, j2)
      if s:sub(i, i) == ',' then i = i + 1
      elseif s:sub(i, i) == '}' then return out, i + 1
      else error('yaml: flow map 期望 , 或 }，位置 ' .. i) end
    end
  end
  error('yaml: 非法流集合起始')
end

-- 判断值是否为流集合
local function is_flow(s)
  local t = s:match('^%s*(.*)$')
  return t:sub(1, 1) == '[' or t:sub(1, 1) == '{'
end

local function parse_value_inline(s)
  if is_flow(s) then
    local start = #s:match('^%s*') + 1
    local v = parse_flow(s, start)
    return v
  end
  return parse_scalar(s)
end

-- ======================================================================
-- 注释剥离
-- ======================================================================
local function strip_comment(line)
  local in_s, in_d = false, false
  for i = 1, #line do
    local c = line:sub(i, i)
    if in_d then
      if c == '\\' then i = i + 1
      elseif c == '"' then in_d = false end
    elseif in_s then
      if c == "'" then in_s = false end
    else
      if c == '"' then in_d = true
      elseif c == "'" then in_s = true
      elseif c == '#' then
        if i == 1 or line:sub(i - 1, i - 1):match('%s') then
          return line:sub(1, i - 1)
        end
      end
    end
  end
  return line
end

local function is_map_line(text)
  -- key 后紧跟 ': ' 或行尾 ':'
  return text:match('^([^:%s][^:]*%s*):%s*(.*)$') or
         text:match('^(".*?"):(.*)$') or
         text:match("^(.*?'):(.*)$")
end

-- ======================================================================
-- 主块解析器
-- ======================================================================
local parse_sequence  -- 前向声明（parse_block 递归调用）
local parse_mapping   -- 前向声明（parse_block 递归调用）

local function parse_block(lines, i, indent)
  local line = lines[i]
  if not line then return YNULL, i end
  local t = line.text
  -- 序列项
  if t == '-' or t:sub(1, 2) == '- ' then
    return parse_sequence(lines, i, indent)
  end
  -- 映射
  if t:match('^([^:%s][^:]*%s*):%s*(.*)$') or t:match('^"') and t:match('^"%s*":') then
    return parse_mapping(lines, i, indent)
  end
  -- 裸标量
  return parse_scalar(t), i + 1
end

local function split_key(text)
  -- 优先：未加引号 key（首个 ': ' 或行尾 ':'）
  local key, val = text:match('^([^:%s][^:]*%s*):%s*(.*)$')
  if key then return key, val end
  -- 双引号 key
  key, val = text:match('^("(.-)"):(.*)$')
  if key then return key, val end
  -- 单引号 key
  key, val = text:match("^(\'(.-)\'):(.*)$")
  if key then return key, val end
  return nil, nil
end

parse_mapping = function(lines, i, indent)
  local out = {}
  while i <= #lines do
    local line = lines[i]
    if line.indent < indent then break end
    if line.indent > indent then
      error('yaml: 意外缩进（行内容 ' .. line.text .. '）')
    end
    if line.text == '-' or line.text:sub(1, 2) == '- ' then break end
    local key, val = split_key(line.text)
    if not key then
      error('yaml: 无法解析映射行 "' .. line.text .. '"')
    end
    -- 解引号 key
    key = key:match('^%s*(.-)%s*$')
    if key:sub(1, 1) == '"' then key = key:sub(2, -2)
    elseif key:sub(1, 1) == "'" then key = (key:sub(2, -2):gsub("''", "'")) end

    local vtrim = val:match('^%s*(.-)%s*$') or ''
    if vtrim == '' then
      -- 空值：要么嵌套块，要么 null
      local nx = lines[i + 1]
      if nx and nx.indent > indent and not (nx.text == '-' or nx.text:sub(1,2)=='- ') then
        local child, i2 = parse_block(lines, i + 1, nx.indent)
        out[key] = child
        i = i2
      elseif nx and nx.indent > indent and (nx.text == '-' or nx.text:sub(1,2)=='- ') then
        local child, i2 = parse_sequence(lines, i + 1, nx.indent)
        out[key] = child
        i = i2
      else
        out[key] = YNULL
        i = i + 1
      end
    elseif vtrim:match('^[%|>][%+-]?%s*%d*$') then
      -- 块标量 | 或 >
      local folded = vtrim:sub(1, 1) == '>'
      local content_indent, gathered = nil, {}
      local j = i + 1
      while j <= #lines do
        local nl = lines[j]
        if nl.indent <= indent and nl.indent >= 0 and nl.indent ~= indent then
          -- 缩进回落到同级 → 结束
          break
        end
        if nl.indent < indent then break end
        if nl.indent == indent then break end  -- 同级新 key
        if content_indent == nil then content_indent = nl.indent end
        gathered[#gathered + 1] = nl.text
        j = j + 1
      end
      local joined
      if folded then
        -- 折叠：单换行→空格，空行→换行（简化：全部以空格连接，保留段落空行）
        joined = table.concat(gathered, ' ')
      else
        joined = table.concat(gathered, '\n')
      end
      out[key] = joined
      i = j
    else
      out[key] = parse_value_inline(vtrim)
      i = i + 1
    end
  end
  return out, i
end

parse_sequence = function(lines, i, indent)
  local out = {}
  while i <= #lines do
    local line = lines[i]
    if line.indent ~= indent then break end
    if not (line.text == '-' or line.text:sub(1, 2) == '- ') then break end
    local content = line.text:sub(2)
    local lead = #content:match('^%s*')  -- 破折号后的空格数（'- ' 通常为 1）
    local content_indent = indent + 1 + lead
    -- 合并本项：首行（若 content 非空）+ 后续缩进 >= content_indent 的行
    local merged = {}
    if (content:match('^%s*(.-)%s*$')) ~= '' then
      merged[#merged + 1] = { indent = content_indent, text = content:match('^%s*(.-)%s*$') }
    end
    i = i + 1
    while i <= #lines and lines[i].indent >= content_indent do
      merged[#merged + 1] = lines[i]
      i = i + 1
    end
    if #merged == 0 then
      out[#out + 1] = YNULL
    else
      out[#out + 1] = parse_block(merged, 1, content_indent)
    end
  end
  return out, i
end

local function prepare_lines(src)
  local lines = {}
  for raw in (src .. '\n'):gmatch('([^\n]*)\n') do
    local no_comment = strip_comment(raw)
    -- 忽略空行 / 仅缩进
    if no_comment:match('^%s*$') then goto continue end
    -- 文档分隔符 --- 暂按结束当前块处理（单文档，直接跳过）
    if no_comment:match('^%s*%-%--%s*$') then goto continue end
    local indent = #(no_comment:match('^%s*') or '')
    local text = no_comment:match('^%s*(.*)$')
    if text:match('\t') then
      -- 缩进内出现 tab：YAML 禁用，宽松处理为报错
      error('yaml: 缩进中不允许使用制表符')
    end
    lines[#lines + 1] = { indent = indent, text = text }
    ::continue::
  end
  return lines
end

function yaml.load(src)
  if type(src) ~= 'string' then return nil end
  if src:match('^%s*$') then return YNULL end
  -- 去掉 BOM
  src = (src:gsub('^%bom', ''))
  local lines = prepare_lines(src)
  if #lines == 0 then return YNULL end
  local val = parse_block(lines, 1, lines[1].indent)
  return val
end

-- ======================================================================
-- JSON 内嵌编解码（精简，自包含）
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
  if v == YNULL then return 'null' end
  local tv = type(v)
  if tv == 'boolean' then return v and 'true' or 'false' end
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end  -- NaN/Inf
    return string.format('%g', v)
  end
  if tv == 'string' then return '"' .. json_escape(v) .. '"' end
  if tv == 'table' then
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = json_encode_val(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, val in pairs(v) do
        if val ~= nil then
          parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode_val(val)
        end
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return 'null'
end

local function json_encode(v) return json_encode_val(v) end

local function json_decode(s)
  local pos = 1
  local function ws()
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then pos = pos + 1 else break end
    end
  end
  local function value()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      pos = pos + 1
      local t = {}
      ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        ws()
        local k
        if s:sub(pos, pos) ~= '"' then error('json: 期望字符串键') end
        local _, e = s:find('"', pos, true)
        -- 找到未转义引号
        local j = pos + 1
        while j <= #s do
          if s:sub(j, j) == '\\' then j = j + 2
          elseif s:sub(j, j) == '"' then break
          else j = j + 1 end
        end
        k = (s:sub(pos + 1, j - 1):gsub('\\(.)', function(x)
          if x == 'n' then return '\n' elseif x == 't' then return '\t' else return x end
        end))
        pos = j + 1
        ws()
        if s:sub(pos, pos) ~= ':' then error('json: 期望 :') end
        pos = pos + 1
        t[k] = value()
        ws()
        if s:sub(pos, pos) == ',' then pos = pos + 1
        elseif s:sub(pos, pos) == '}' then pos = pos + 1 return t
        else error('json: 期望 , 或 }') end
      end
    elseif c == '[' then
      pos = pos + 1
      local arr = {}
      ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = value()
        ws()
        if s:sub(pos, pos) == ',' then pos = pos + 1
        elseif s:sub(pos, pos) == ']' then pos = pos + 1 return arr
        else error('json: 期望 , 或 ]') end
      end
    elseif c == '"' then
      local j = pos + 1
      while j <= #s do
        if s:sub(j, j) == '\\' then j = j + 2
        elseif s:sub(j, j) == '"' then break
        else j = j + 1 end
      end
      local body = s:sub(pos + 1, j - 1)
      body = (body:gsub('\\u(%x%x%x%x)', function(h)
        local code = tonumber(h, 16)
        if code and code < 128 then return string.char(code) end
        return '?'
      end))
      body = (body:gsub('\\(.)', function(x)
        if x == 'n' then return '\n' elseif x == 't' then return '\t'
        elseif x == 'r' then return '\r' elseif x == '/' then return '/'
        elseif x == 'b' then return '\b' elseif x == 'f' then return '\f' else return x end
      end))
      pos = j + 1
      return body
    elseif c == 't' then pos = pos + 4 return true
    elseif c == 'f' then pos = pos + 5 return false
    elseif c == 'n' then pos = pos + 4 return YNULL
    else
      local num = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
      if num then pos = pos + #num return tonumber(num) end
      error('json: 无法解析值，位置 ' .. pos)
    end
  end
  return value()
end

-- ======================================================================
-- YAML 编码（table → 文本）
-- ======================================================================
local function needs_quote(s)
  if s == '' then return true end
  if s:match('^%s') or s:match('%s$') then return true end
  if s:match('^[-?:,#&*!|>%@`"\']') then return true end
  if s:match('[:%s]') then return true end          -- 冒号或空白
  if s:lower() == 'true' or s:lower() == 'false' or s:lower() == 'null'
     or s:lower() == 'yes' or s:lower() == 'no' or s:lower() == 'on' or s:lower() == 'off' then
    return true
  end
  if tonumber(s) ~= nil then return true end
  if s:match('[%c]') then return true end
  return false
end

local function encode_scalar(v)
  if v == nil or v == YNULL then return '~' end
  if type(v) == 'boolean' then return v and 'true' or 'false' end
  if type(v) == 'number' then return string.format('%g', v) end
  local s = tostring(v)
  if needs_quote(s) then
    return '"' .. json_escape(s) .. '"'
  end
  return s
end

local function encode_table(t, indent)
  local pad = string.rep('  ', indent)
  local out = {}
  if is_array(t) then
    if #t == 0 then return '[]' end
    for i = 1, #t do
      local v = t[i]
      if type(v) == 'table' and not (v == YNULL) then
        -- 内联表：缩进一层
        local sub = encode_table(v, indent + 1)
        if is_array(v) then
          out[#out + 1] = pad .. '-\n' .. sub
        else
          out[#out + 1] = pad .. '-\n' .. sub
        end
      else
        out[#out + 1] = pad .. '- ' .. encode_scalar(v)
      end
    end
    return table.concat(out, '\n')
  else
    local nkeys = 0
    for _ in pairs(t) do nkeys = nkeys + 1 end
    if nkeys == 0 then return '{}' end
    -- 稳定顺序：数字键升序，其余按出现顺序近似（pairs 顺序不定，做简单排序）
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      if type(a) ~= type(b) then return type(a) < type(b) end
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      local v = t[k]
      local keystr = type(k) == 'string' and (needs_quote(k) and ('"' .. json_escape(k) .. '"') or k) or tostring(k)
      if type(v) == 'table' and v ~= YNULL then
        if (is_array(v) and #v == 0) or ((not is_array(v)) and (function() local c=0 for _ in pairs(v) do c=c+1 end return c==0 end)()) then
          out[#out + 1] = pad .. keystr .. ': ' .. (is_array(v) and '[]' or '{}')
        else
          out[#out + 1] = pad .. keystr .. ':'
          out[#out + 1] = encode_table(v, indent + 1)
        end
      else
        out[#out + 1] = pad .. keystr .. ': ' .. encode_scalar(v)
      end
    end
    return table.concat(out, '\n')
  end
end

function yaml.encode(t)
  if t == nil or t == YNULL then return '~\n' end
  if type(t) ~= 'table' then return encode_scalar(t) .. '\n' end
  return encode_table(t, 0) .. '\n'
end

-- ======================================================================
-- UDF 分发包装
-- ======================================================================
return function(p)
  if type(p) == 'string' then
    return json_encode(yaml.load(p))
  end
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'load'
  if op == 'load' then
    return json_encode(yaml.load(p.v or ''))
  elseif op == 'encode' then
    local t = p.v
    if type(t) == 'string' then t = json_decode(t) end
    return yaml.encode(t)
  elseif op == 'encode_from_lua' then
    -- p.v 直接是 Lua 表（DuckDB LIST/STRUCT 传入）
    return yaml.encode(p.v)
  end
  return ''
end
