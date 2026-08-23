-- @lib: jsonpatch
-- @category: parser
-- @desc: RFC 6902 JSON Patch（add/remove/replace/move/copy/test）+ RFC 6901 JSON Pointer
--       + 基础 diff —— DuckDB 内建 json_merge_patch（RFC 7386）但没有 RFC 6902 操作数组 /
--       JSON Pointer，本库补齐。自包含：内嵌一个纯 Lua JSON 编解码器（UTF-8 原样透传），
--       不依赖外部 json.lua，便于移植。
--       op 选项（doc / patch / value 均为 JSON 编码字符串）：
--         'apply' {doc, patch}         → 应用 patch（RFC 6902 数组）后的文档（JSON 字符串）
--         'get'   {doc, path}          → JSON Pointer 处的值（JSON 编码；缺失/空 → null）
--         'set'   {doc, path, value}   → 在该处 upsert value（父级须存在）后的文档
--         'test'  {doc, path, value}   → 该处值是否等于 value → "true"/"false"
--         'diff'  {a, b}               → 由 a 变换到 b 的 RFC 6902 patch（JSON 数组字符串，
--                                        数组等长逐元素递归、不等长整体 replace，非最小但正确）
--       诚实边界：patch 内 value 一律是已解码的 JSON 值；JSON null 与 key 缺失在 Lua 里同为 nil，
--       故 patch 中 "value":null 视为缺失（add 成 no-op）；循环引用编码为 null。
-- @source: 自包含（JSON 编解码参考 rxi/json.lua MIT 思路自写；RFC 6901/6902）
-- @requires: none
--
-- Usage:
--   SELECT luajit_s('jsonpatch', {op:'apply', doc:'{"a":1}',
--     patch:'[{"op":"add","path":"/b","value":2},{"op":"test","path":"/a","value":1}]'});
--   SELECT luajit_s('jsonpatch', {op:'get', doc:'[{"x":7},"y"]', path:'/0/x'});  -- 7
--   SELECT luajit_s('jsonpatch', {op:'diff', a:'{"a":1,"b":[1,2]}', b:'{"a":9,"c":true}'});

----------------------------------------------------------------------------
-- 内嵌 JSON 编解码（纯 Lua，UTF-8 原样透传）
----------------------------------------------------------------------------
local jp = {}

local ESC = { ['\\']='\\\\', ['"']='\\"', ['\n']='\\n', ['\t']='\\t',
              ['\r']='\\r', ['\b']='\\b', ['\f']='\\f' }
local function enc_str(s)
  return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
    if ESC[c] then return ESC[c] end
    return string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function is_array(t)
  if type(t) ~= 'table' then return false end
  local n, i = 0, 1
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  if n == 0 then return false end          -- 空表按对象
  while t[i] ~= nil do i = i + 1 end
  return i - 1 == n
end

local function utf8full(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0+math.floor(n/64), 0x80+(n%64)) end
  if n < 0x10000 then
    return string.char(0xE0+math.floor(n/4096), 0x80+(math.floor(n/64)%64), 0x80+(n%64))
  end
  return string.char(0xF0+math.floor(n/262144), 0x80+(math.floor(n/4096)%64),
                     0x80+(math.floor(n/64)%64), 0x80+(n%64))
end

local function encode(v, seen)
  seen = seen or {}
  if v == nil then return 'null' end
  local tv = type(v)
  if tv == 'boolean' then return v and 'true' or 'false' end
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.17g', v)
  end
  if tv == 'string' then return enc_str(v) end
  if tv == 'table' then
    if seen[v] then return 'null' end
    seen[v] = true
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = encode(v[i], seen) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts+1] = enc_str(tostring(k)) .. ':' .. encode(val, seen)
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return 'null'
end

local function decode(str)
  local pos = 1
  local function ws()
    while pos <= #str do
      local c = str:sub(pos,pos)
      if c==' ' or c=='\t' or c=='\n' or c=='\r' then pos = pos+1 else break end
    end
  end
  local err = function(msg) error('json: ' .. msg .. ' @' .. pos, 0) end
  local function hex4(s, i)
    local h = s:sub(i, i+3)
    local n = tonumber(h, 16)
    if not n then err('bad \\u') end
    return n, i + 4
  end
  local function parse_string()
    pos = pos + 1
    local out = {}
    while pos <= #str do
      local c = str:sub(pos,pos)
      if c == '"' then pos = pos + 1; return table.concat(out) end
      if c == '\\' then
        local e = str:sub(pos+1, pos+1)
        if e=='"' then out[#out+1]='"'; pos=pos+2
        elseif e=='\\' then out[#out+1]='\\'; pos=pos+2
        elseif e=='/' then out[#out+1]='/'; pos=pos+2
        elseif e=='b' then out[#out+1]='\b'; pos=pos+2
        elseif e=='f' then out[#out+1]='\f'; pos=pos+2
        elseif e=='n' then out[#out+1]='\n'; pos=pos+2
        elseif e=='r' then out[#out+1]='\r'; pos=pos+2
        elseif e=='t' then out[#out+1]='\t'; pos=pos+2
        elseif e=='u' then
          local cp, np = hex4(str, pos+2); pos = np
          if cp >= 0xD800 and cp <= 0xDBFF
             and str:sub(pos,pos+1)=='\\' and str:sub(pos+2,pos+2)=='u' then
            local lo, np2 = hex4(str, pos+2)
            if lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + ((cp - 0xD800) * 1024) + (lo - 0xDC00)
              pos = np2
            end
          end
          out[#out+1] = utf8full(cp)
        else err('bad escape') end
      else
        out[#out+1] = c; pos = pos + 1
      end
    end
    err('unterminated string')
  end
  local parse_value
  local function parse_number()
    local s = str:match('^%-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    if not s or s == '' then err('bad number') end
    pos = pos + #s
    return tonumber(s)
  end
  local function parse_array()
    pos = pos + 1; ws()
    local arr = {}
    if str:sub(pos,pos) == ']' then pos = pos + 1; return arr end
    while true do
      ws(); arr[#arr+1] = parse_value(); ws()
      local c = str:sub(pos,pos)
      if c == ',' then pos = pos + 1
      elseif c == ']' then pos = pos + 1; return arr
      else err('bad array') end
    end
  end
  local function parse_object()
    pos = pos + 1; ws()
    local obj = {}
    if str:sub(pos,pos) == '}' then pos = pos + 1; return obj end
    while true do
      ws()
      if str:sub(pos,pos) ~= '"' then err('expected key') end
      local k = parse_string(); ws()
      if str:sub(pos,pos) ~= ':' then err('expected :') end
      pos = pos + 1; ws()
      obj[k] = parse_value(); ws()
      local c = str:sub(pos,pos)
      if c == ',' then pos = pos + 1
      elseif c == '}' then pos = pos + 1; return obj
      else err('bad object') end
    end
  end
  parse_value = function()
    ws()
    local c = str:sub(pos,pos)
    if c == '"' then return parse_string() end
    if c == '{' then return parse_object() end
    if c == '[' then return parse_array() end
    if c == 't' then if str:sub(pos,pos+3)=='true' then pos=pos+4; return true end err('literal') end
    if c == 'f' then if str:sub(pos,pos+4)=='false' then pos=pos+5; return false end err('literal') end
    if c == 'n' then if str:sub(pos,pos+3)=='null' then pos=pos+4; return nil end err('literal') end
    if c == '-' or (c >= '0' and c <= '9') then return parse_number() end
    err('unexpected ' .. tostring(c))
  end
  return parse_value()
end

jp.encode = encode
jp.decode = decode

----------------------------------------------------------------------------
-- deep copy / equal
----------------------------------------------------------------------------
local function deep_copy(v)
  if type(v) ~= 'table' then return v end
  local c = {}
  for k, val in pairs(v) do c[k] = deep_copy(val) end
  return c
end

local function deep_eq(a, b)
  if a == nil or b == nil then return (a == nil and b == nil) or
    (type(a)=='table' and next(a)==nil and b==nil) or
    (type(b)=='table' and next(b)==nil and a==nil) end
  if type(a) ~= type(b) then
    -- {} 与 null 视为不等，但 Lua 无法区分；这里按类型严格
    return false
  end
  if type(a) ~= 'table' then return a == b end
  for k, val in pairs(a) do
    if not deep_eq(val, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil and not (type(a[k])=='table') then return false end
  end
  return true
end

----------------------------------------------------------------------------
-- RFC 6901 JSON Pointer
----------------------------------------------------------------------------
local function split_path(ptr)
  local tokens = {}
  if ptr == '' then return tokens end
  if ptr:sub(1,1) ~= '/' then error('pointer must be "" or start with /') end
  local i = 2
  while i <= #ptr do
    local j = ptr:find('/', i, true)
    if not j then j = #ptr + 1 end
    local tok = ptr:sub(i, j-1):gsub('~1','/'):gsub('~0','~')
    tokens[#tokens+1] = tok
    i = j + 1
  end
  return tokens
end

local function get_at(doc, tokens)
  local cur = doc
  for i = 1, #tokens do
    local tok = tokens[i]
    if is_array(cur) then
      local ix = tonumber(tok)
      if not ix or ix < 0 or ix >= #cur then error('index out of range at "'..tok..'"') end
      cur = cur[ix + 1]               -- RFC 6901 数组下标 0-based → Lua 1-based
    else
      cur = cur[tok]
    end
    if cur == nil and i < #tokens then error('pointer path missing at "'..tok..'"') end
  end
  return cur
end

local function resolve_parent(doc, tokens)
  local cur = doc
  for i = 1, #tokens - 1 do
    local tok = tokens[i]
    if is_array(cur) then
      local ix = tonumber(tok)
      if not ix or ix < 0 or ix >= #cur then error('index out of range at "'..tok..'"') end
      cur = cur[ix + 1]
    else
      cur = cur[tok]
    end
    if cur == nil then error('pointer path missing at "'..tok..'"') end
  end
  return cur, tokens[#tokens]
end

----------------------------------------------------------------------------
-- RFC 6902 操作
----------------------------------------------------------------------------
local function op_add(doc, ptr, val)
  local tokens = split_path(ptr)
  if #tokens == 0 then return deep_copy(val) end
  local parent, key = resolve_parent(doc, tokens)
  if is_array(parent) then
    if key == '-' then parent[#parent+1] = deep_copy(val)
    else
      local idx = tonumber(key)
      if not idx then error('bad array index "'..key..'"') end
      if idx < 0 or idx > #parent then error('index out of bounds') end
      for i = #parent, idx, -1 do parent[i+1] = parent[i] end   -- idx 0-based，插入位 = idx+1
      parent[idx+1] = deep_copy(val)
    end
  else
    parent[key] = deep_copy(val)
  end
  return doc
end

local function op_remove(doc, ptr)
  local tokens = split_path(ptr)
  if #tokens == 0 then error('cannot remove whole document') end
  local parent, key = resolve_parent(doc, tokens)
  if is_array(parent) then
    local idx = tonumber(key)
    if not idx or idx < 0 or idx >= #parent then error('bad index "'..key..'"') end
    for i = idx + 1, #parent - 1 do parent[i] = parent[i+1] end
    parent[#parent] = nil
  else
    if parent[key] == nil then error('key not found "'..key..'"') end
    parent[key] = nil
  end
  return doc
end

local function op_replace(doc, ptr, val)
  local tokens = split_path(ptr)
  if #tokens == 0 then return deep_copy(val) end
  local parent, key = resolve_parent(doc, tokens)
  if is_array(parent) then
    local idx = tonumber(key)
    if not idx or idx < 0 or idx >= #parent then error('index not found "'..key..'"') end
    parent[idx+1] = deep_copy(val)
  else
    if parent[key] == nil then error('key not found "'..key..'"') end
    parent[key] = deep_copy(val)
  end
  return doc
end

local function op_test(doc, ptr, val)
  local tokens = split_path(ptr)
  local v = (#tokens == 0) and doc or get_at(doc, tokens)
  return deep_eq(v, val)
end

local function op_move(doc, from, ptr)
  local ftokens = split_path(from)
  local val = (#ftokens == 0) and deep_copy(doc) or deep_copy(get_at(doc, ftokens))
  local newdoc = op_remove(doc, from)
  return op_add(newdoc, ptr, val)
end

local function op_copy(doc, from, ptr)
  local ftokens = split_path(from)
  local val = (#ftokens == 0) and deep_copy(doc) or deep_copy(get_at(doc, ftokens))
  return op_add(doc, ptr, val)
end

----------------------------------------------------------------------------
-- diff（a → b 的 RFC 6902 patch；非最小但正确）
----------------------------------------------------------------------------
local function esc_ptr(s)
  return s:gsub('~','~0'):gsub('/','~1')
end

local function diff(a, b, path)
  local patch = {}
  if deep_eq(a, b) then return patch end
  if type(a) ~= 'table' or type(b) ~= 'table' or
     (type(a)~='table') or (type(b)~='table') then
    table.insert(patch, {op='replace', path=path, value=deep_copy(b)})
    return patch
  end
  if is_array(a) and is_array(b) then
    if #a ~= #b then
      table.insert(patch, {op='replace', path=path, value=deep_copy(b)})
    else
      for i = 1, #a do
        local sub = diff(a[i], b[i], path .. '/' .. (i-1))
        for _, o in ipairs(sub) do patch[#patch+1] = o end
      end
    end
    return patch
  end
  local seen = {}
  for k, v in pairs(a) do
    local p = path .. '/' .. esc_ptr(tostring(k))
    if b[k] == nil then
      table.insert(patch, {op='remove', path=p})
    else
      local sub = diff(v, b[k], p)
      for _, o in ipairs(sub) do patch[#patch+1] = o end
      seen[k] = true
    end
  end
  for k, v in pairs(b) do
    if not seen[k] then
      table.insert(patch, {op='add', path=path .. '/' .. esc_ptr(tostring(k)), value=deep_copy(v)})
    end
  end
  return patch
end

----------------------------------------------------------------------------
-- 入口
----------------------------------------------------------------------------
local function run(p)
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local op = p.op

  local function jdec(s)
    local ok, v = pcall(jp.decode, tostring(s))
    if not ok then return nil, tostring(v) end
    return v
  end
  local function errj(msg) return '{"error":' .. enc_str(tostring(msg)) .. '}' end

  local doc, derr = jdec(p.doc)
  if p.doc ~= nil and derr then return errj('doc not valid json: ' .. derr) end
  if doc == nil then doc = {} end

  if op == 'apply' then
    local patch, perr = jdec(p.patch)
    if perr then return errj('patch not valid json: ' .. perr) end
    if not is_array(patch) then return errj('patch must be an array') end
    for i, o in ipairs(patch) do
      if type(o) ~= 'table' or o.op == nil then return errj('bad op at '..i) end
      local ok, res = pcall(function()
        if o.op == 'add' then doc = op_add(doc, o.path, o.value)
        elseif o.op == 'remove' then doc = op_remove(doc, o.path)
        elseif o.op == 'replace' then doc = op_replace(doc, o.path, o.value)
        elseif o.op == 'test' then
          if not op_test(doc, o.path, o.value) then error('test failed at "'..tostring(o.path)..'")') end
        elseif o.op == 'move' then
          local ft = split_path(o.from)
          local val = (#ft==0) and deep_copy(doc) or deep_copy(get_at(doc, ft))
          doc = op_remove(doc, o.from)
          doc = op_add(doc, o.to, val)
        elseif o.op == 'copy' then doc = op_copy(doc, o.from, o.to)
        else error('unknown op "'..tostring(o.op)..'"') end
      end)
      if not ok then return errj('op '..i..' ('..tostring(o.op)..') failed: '..tostring(res)) end
    end
    return jp.encode(doc)
  elseif op == 'get' then
    local ok, v = pcall(function()
      local tokens = split_path(tostring(p.path))
      return (#tokens == 0) and doc or get_at(doc, tokens)
    end)
    if not ok then return errj(tostring(v)) end
    return jp.encode(v)
  elseif op == 'set' then
    local val, verr = jdec(p.value)
    if verr then return errj('value not valid json: ' .. verr) end
    local ok, res = pcall(function()
      local tokens = split_path(tostring(p.path))
      if #tokens == 0 then doc = deep_copy(val); return end
      local parent, key = resolve_parent(doc, tokens)
      if is_array(parent) then
        local idx = tonumber(key)
        if not idx or idx < 0 or idx >= #parent then error('bad array index') end
        parent[idx+1] = deep_copy(val)
      else
        parent[key] = deep_copy(val)
      end
    end)
    if not ok then return errj(tostring(res)) end
    return jp.encode(doc)
  elseif op == 'test' then
    local val, verr = jdec(p.value)
    if verr then return errj('value not valid json: ' .. verr) end
    local ok, eq = pcall(function()
      local tokens = split_path(tostring(p.path))
      local v = (#tokens == 0) and doc or get_at(doc, tokens)
      return deep_eq(v, val)
    end)
    if not ok then return errj(tostring(eq)) end
    return (eq and 'true' or 'false')
  elseif op == 'diff' then
    local a, aerr = jdec(p.a)
    local b, berr = jdec(p.b)
    if aerr then return errj('a not valid json: ' .. aerr) end
    if berr then return errj('b not valid json: ' .. berr) end
    if a == nil then a = {} end
    if b == nil then b = {} end
    local patch = diff(a, b, '')
    return jp.encode(patch)
  end
  return '{"error":"unknown op"}'
end

return function(p)
  return run(p)
end
