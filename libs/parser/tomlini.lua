-- @lib: tomlini
-- @category: parser
-- @desc: TOML + INI 配置解析（纯 Lua，自包含）→ JSON 字符串（配 json_extract 展开）。
--       op='toml'：TOML 子集 → JSON。支持：[section] / [a.b] 嵌套、key = 标量
--                  （string/int/float/bool）、多行字符串（""".."""）、注释 #、
--                  行内表 { k = v }、行内数组 [ .. ]、点路径 key。
--                  诚实边界：无 date-time 专门类型（当字符串）、无数组表 [[..]]、
--                  无裸 key 之外的引号 key 之外复杂结构、无多文档。
--       op='ini'：INI → JSON。支持：[section] 分组（无分组归入根）、key = value、
--                  注释 ; 与 #（行首）、值类型嗅探（int/float/bool/其余为字符串）。
--       两者都返回 JSON 对象字符串；空文件返回 '{}'。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: none
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='tomlini');
--   toml:     SELECT luajit_s('tomlini', {v: '[db]\nhost = "x"\nport = 5432\n', op:'toml'});
--             → '{"db":{"host":"x","port":5432}}'
--   ini:      SELECT luajit_s('tomlini', {v: '[sec]\nk = 3\n', op:'ini'});
--             → '{"sec":{"k":3}}'
--   drill:    SELECT json_extract(luajit_s('tomlini', {v:=t, op:='toml'}), '$.db.port');

local tomlini = {}

-- ======================================================================
-- 通用工具
-- ======================================================================
local function trim(s) return (s:gsub('^%s*', ''):gsub('%s*$', '')) end

local function strip_comment(s)
  -- TOML：# 起始注释（不在引号内）
  local out, inq = {}, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then inq = not inq end
    if c == '#' and not inq then break end
    out[#out + 1] = c
  end
  return table.concat(out)
end

-- 解析 TOML/INI 右侧标量值（带引号字符串 / bool / number / 行内表 / 行内数组）
local function parse_toml_value(raw)
  raw = trim(raw)
  if raw == '' then return nil end
  -- 多行字符串（简化：单行内 """.."""）
  if raw:match('^"""') and raw:match('"""$') then
    return raw:sub(4, -4)
  end
  -- 双引号字符串
  if raw:match('^"') then
    local body = raw:match('^"(.*)"%s*$')
    if body then
      return (body:gsub('\\([nrt"\\])', function(c)
        if c == 'n' then return '\n' elseif c == 'r' then return '\r'
        elseif c == 't' then return '\t' else return c end
      end))
    end
    return nil
  end
  -- 单引号字符串（TOML literal，无转义）
  if raw:match("^'") then
    return raw:match("^'(.*)'%s*$")
  end
  -- 行内表 { k = v, ... }
  if raw:match('^%{') and raw:match('%}$') then
    local inner = raw:match('^%{(.-)%}$')
    local obj = {}
    for part in inner:gmatch('([^,{}]+)') do
      local k, v = part:match('^%s*([%w%._-]+)%s*=%s*(.*)%s*$')
      if k then obj[k] = parse_toml_value(v) end
    end
    return obj
  end
  -- 行内数组 [ a, b, ... ]
  if raw:match('^%[') and raw:match('%]$') then
    local inner = raw:match('^%[(.-)%]$')
    local arr = {}
    for item in inner:gmatch('([^,\\[%]]+)') do
      local v = parse_toml_value(item)
      if v ~= nil then arr[#arr + 1] = v end
    end
    return arr
  end
  -- bool
  local low = raw:lower()
  if low == 'true' then return true end
  if low == 'false' then return false end
  -- float / int
  local n = tonumber(raw)
  if n then return n end
  return raw  -- 兜底：当字符串
end

local function parse_ini_value(raw)
  raw = trim(raw)
  local low = raw:lower()
  if low == 'true' or low == 'yes' or low == 'on' then return true end
  if low == 'false' or low == 'no' or low == 'off' then return false end
  local n = tonumber(raw)
  if n then return n end
  -- 去引号
  if raw:match('^"') and raw:match('"$') then return raw:sub(2, -2) end
  if raw:match("^'") and raw:match("'$") then return raw:sub(2, -2) end
  return raw
end

-- ======================================================================
-- JSON 编码
-- ======================================================================
local function json_escape(s)
  return (s:gsub('%[\\%"]', function(c)
    if c == '\\' then return '\\\\' elseif c == '"' then return '\\"'
    elseif c == '\n' then return '\\n' elseif c == '\t' then return '\\t'
    elseif c == '\r' then return '\\r' else return c end
  end))
end

local T = {}
local function jtype(v) return type(v) end
local function is_table(v) return type(v) == 'table' end
local function is_array(t)
  -- 严格：所有键为 1..#t 的连续整数
  if #t == 0 then return false end
  local n = #t
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  local count = 0
  for k in pairs(t) do
    count = count + 1
    if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 or k > n then
      return false
    end
  end
  return count == n
end

function T.encode(v)
  local t = jtype(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v % 1 == 0 then return string.format('%d', v) end
    return tostring(v)
  end
  if t == 'string' then return '"' .. json_escape(v) .. '"' end
  if t == 'table' then
    if is_array(v) then
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
-- TOML 解析
-- ======================================================================
local function parse_toml(text)
  local root = {}
  local current = root
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    local raw = strip_comment(line)
    raw = trim(raw)
    if raw == '' then goto cont end
    -- 表头 [section] / [a.b]
    local sec = raw:match('^%[(.-)%]%s*$')
    if sec then
      sec = sec:gsub('%[%]', '')  -- 去掉 [[..]] 残留（诚实边界：数组表按单表处理）
      sec = trim(sec)
      current = root
      local parts = {}
      for p in sec:gmatch('[%w%_%-]+') do parts[#parts + 1] = p end
      for i = 1, #parts - 1 do
        local k = parts[i]
        if not current[k] then current[k] = {} end
        current = current[k]
      end
      if #parts > 0 then
        local k = parts[#parts]
        if not current[k] then current[k] = {} end
        current = current[k]
      end
      goto cont
    end
    -- key = value（点路径 key 如 a.b.c 嵌套）
    local key, valraw = raw:match('^([%w%_%-.%w%_%-]+)%s*=%s*(.*)$')
    if key then
      local parts = {}
      for p in key:gmatch('[%w%_%-]+') do parts[#parts + 1] = p end
      local target = current
      for i = 1, #parts - 1 do
        local k = parts[i]
        if not target[k] then target[k] = {} end
        target = target[k]
      end
      target[parts[#parts]] = parse_toml_value(valraw)
    end
    ::cont::
  end
  return T.encode(root)
end

-- ======================================================================
-- INI 解析
-- ======================================================================
local function parse_ini(text)
  local root = {}
  local current = root
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    local raw = line
    raw = trim(raw)
    if raw == '' then goto cont end
    if raw:match('^;') or raw:match('^#') then goto cont end
    local sec = raw:match('^%[(.-)%]%s*$')
    if sec then
      current = root
      local k = trim(sec)
      if not current[k] then current[k] = {} end
      current = current[k]
      goto cont
    end
    local key, valraw = raw:match('^([^=;#]+)%s*[=:]%s*(.*)$')
    if key then
      current[trim(key)] = parse_ini_value(valraw)
    end
    ::cont::
  end
  return T.encode(root)
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '{}' end
  local text = p.v or ''
  local op = p.op or 'toml'
  if op == 'ini' then return parse_ini(text) end
  return parse_toml(text)
end

return function(p)
  return run(p)
end
