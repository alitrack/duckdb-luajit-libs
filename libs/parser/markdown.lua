-- @lib: markdown
-- @category: parser
-- @desc: Markdown 结构提取（纯 Lua，自包含）——从 .md 文本抽结构化元素，
--       返回 JSON 数组/对象（配 json_extract / json 展开）。不渲染 HTML，只做结构解析。
--       op 选项：
--         'toc'      → [{level, text, line}]  标题目录
--         'links'    → [{text, href}]         行内链接 [text](url) + 图片 ![..](url)
--         'code'     → [{lang, text, line}]   围栏代码块 ```lang ... ```
--         'lists'    → [{ordered, indent, text}]  列表项
--         'quotes'   → [{text}]               引用块 > ...
--         'stats'    → {headings, links, code, lists, quotes, lines}  计数
--         'plain'    → 纯文本（去全部 markdown 标记）
--       代码块内容先被"抠出"，其中的 #/[]/- 不会被误判为标题/链接/列表。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: 无
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='markdown');
--   toc:      SELECT luajit_s('markdown', {v: md, op: 'toc'});
--   抽 url:   SELECT json_extract(luajit_s('markdown', {v:=m, op:='links'}), '$[0].href');
--   统计:     SELECT json_extract(luajit_s('markdown', {v:=m, op:='stats'}), '$.headings');

-- ======================================================================
-- JSON 编码（自包含，与 tomlini 同风格）
-- ======================================================================
local function json_escape(s)
  return (tostring(s):gsub('([\\\"\n\t\r])', function(c)
    if c == '\\' then return '\\\\' elseif c == '"' then return '\\"'
    elseif c == '\n' then return '\\n' elseif c == '\t' then return '\\t'
    elseif c == '\r' then return '\\r' else return c end
  end))
end

local T = {}
function T.encode(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v % 1 == 0 and math.abs(v) < 1e15 then return string.format('%d', v) end
    return tostring(v)
  end
  if t == 'string' then return '"' .. json_escape(v) .. '"' end
  if t == 'table' then
    local isarr, n = true, 0
    for k in pairs(v) do
      n = n + 1
      if type(k) ~= 'number' then isarr = false break end
    end
    if isarr and n == #v then
      local parts = {}
      for i = 1, #v do parts[#parts + 1] = T.encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. T.encode(val)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

-- ======================================================================
-- 行工具
-- ======================================================================
local function trim(s) return (tostring(s):gsub('^%s*', ''):gsub('%s*$', '')) end

-- 稳健按单字符 split
local function text_split(s, c)
  local out, start = {}, 1
  while true do
    local i = s:find(c, start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  return out
end

-- 去掉行内 markdown 格式，保留可读文本
local function strip_inline(s)
  s = s:gsub('!%[', '[')                              -- 图片标记 → 链接
  s = (s:gsub('%*%*([^%*]+)%*%*', '%1'))              -- **bold**
  s = (s:gsub('__([^_]+)__', '%1'))                   -- __bold__
  s = (s:gsub('`+([^`]+)`+', '%1'))                   -- `code`
  s = (s:gsub('~~([^~]+)~~', '%1'))                   -- ~~del~~
  s = (s:gsub('%[([^%]]*)%]%(([^)]*)%)', '%1'))       -- [text](url) → text
  s = s:gsub('^%s*#+%s*', '')                         -- 残留 #
  s = s:gsub('^%s*>%s*', '')                          -- 残留 >
  return trim(s)
end

-- ======================================================================
-- 解析：拆成 (普通行带行号 + in_code 标记, 围栏代码块)
-- ======================================================================
local function parse(text)
  local code_blocks, lines = {}, {}
  local in_code, buf, lang, start_line = false, nil, '', 0
  for i, raw in ipairs(text_split(text, '\n')) do
    local line = raw:gsub('\r$', '')   -- CRLF → LF
    if in_code then
      if line:match('^%s*```') or line:match('^%s*~~~') then
        code_blocks[#code_blocks + 1] = {
          lang = lang, text = table.concat(buf, '\n'), line = start_line,
        }
        in_code = false
      else
        buf[#buf + 1] = line
      end
      lines[#lines + 1] = { no = i, text = line, in_code = true }
    else
      local fence = line:match('^%s*```(.*)$') or line:match('^%s*~~~(.*)$')
      if fence then
        in_code, lang, buf, start_line = true, trim(fence), {}, i
        lines[#lines + 1] = { no = i, text = line, in_code = true }
      else
        lines[#lines + 1] = { no = i, text = line }
      end
    end
  end
  if in_code and buf then
    code_blocks[#code_blocks + 1] = {
      lang = lang, text = table.concat(buf, '\n'), line = start_line,
    }
  end
  return lines, code_blocks
end

-- ======================================================================
-- 各 op 提取器（均跳过 in_code 行，避免把代码内容误判为结构）
-- ======================================================================
local function extract_toc(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if not l.in_code then
      local hashes, text = l.text:match('^(#+)%s+(.*)$')
      if hashes then
        out[#out + 1] = { level = #hashes, text = strip_inline(text), line = l.no }
      end
    end
  end
  return out
end

local function extract_links(lines)
  local out, seen = {}, {}
  for _, l in ipairs(lines) do
    if not l.in_code then
      for text, href in l.text:gmatch('%[([^%]]*)%]%(([^)]+)%)') do
        href = trim(href)
        if href ~= '' and not seen[href] then
          seen[href] = true
          out[#out + 1] = { text = strip_inline(text), href = href }
        end
      end
    end
  end
  return out
end

local function extract_lists(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if not l.in_code then
      local sp = l.text:match('^(%s*)')
      local ordered, item = l.text:match('^%s*(%d+)[.)][ \t]+(.*)$')
      if item then
        out[#out + 1] = { ordered = true, indent = #sp, text = strip_inline(item) }
      else
        local item2 = l.text:match('^%s*[-*+][ \t]+(.*)$')
        if item2 then
          out[#out + 1] = { ordered = false, indent = #sp, text = strip_inline(item2) }
        end
      end
    end
  end
  return out
end

local function extract_quotes(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if not l.in_code then
      local q = l.text:match('^%s*>+[%s]*(.*)$')
      if q then
        local t = strip_inline(q)
        if t ~= '' then out[#out + 1] = { text = t } end
      end
    end
  end
  return out
end

local function extract_plain(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if not l.in_code then
      local s = l.text
      s = s:gsub('^%s*```.*$', '')                     -- 围栏行
      s = s:gsub('^%s*#+%s*', '')                      -- 标题 #
      s = s:gsub('^%s*>+[%s]*', '')                    -- 引用
      s = s:gsub('^%s*%d+[.)][ \t]+', '')              -- 有序序号
      s = s:gsub('^%s*[-*+][ \t]+', '')                -- 无序符
      s = (s:gsub('%[([^%]]*)%]%(([^)]*)%)', '%1'))    -- 链接 → 文本
      s = strip_inline(s)
      out[#out + 1] = s
    end
  end
  return table.concat(out, '\n')
end

local function extract_stats(lines, code_blocks)
  return {
    headings = #extract_toc(lines),
    links = #extract_links(lines),
    code = #code_blocks,
    lists = #extract_lists(lines),
    quotes = #extract_quotes(lines),
    lines = #lines,
  }
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '[]' end
  local text = p.v or ''
  local op = p.op or 'stats'
  local lines, code_blocks = parse(text)

  if op == 'toc' then return T.encode(extract_toc(lines))
  elseif op == 'links' then return T.encode(extract_links(lines))
  elseif op == 'code' then return T.encode(code_blocks)
  elseif op == 'lists' then return T.encode(extract_lists(lines))
  elseif op == 'quotes' then return T.encode(extract_quotes(lines))
  elseif op == 'plain' then return extract_plain(lines)
  elseif op == 'stats' then return T.encode(extract_stats(lines, code_blocks))
  end
  return '[]'
end

return function(p)
  return run(p)
end
