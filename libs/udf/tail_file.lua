-- @lib: tail_file
-- @category: udf
-- @desc: 增量日志/文件 tail（纯 Lua）——从上次读到的字节偏移继续读，返回
--       新增行 + 新偏移，供轮询式增量消费（DuckDB 无内建 tail/增量读）。
--       无状态：调用方把返回的 offset 存回（DuckDB 状态表 / 应用变量），
--       下次传入，实现"只读增量"。
--       入参（scalar struct）：
--         v       : 文件路径；若该路径不存在则当作**内联全文**（offset 按字符偏移）
--         offset  : 上次读到的偏移（字节/字符），默认 0（从头）
--         max     : 最多返回多少行，默认 1000（0=不限制）
--       返回 JSON 对象：
--         {"offset": <新偏移>, "count": <本次行数>, "lines": ["行1", ...]}
--       诚实边界：按 **LF** 分行；文件被**截断/重建**（新长度 < offset）时自动
--       重置 offset=0 重新读（rotated log 场景）。末尾**未完结行**（无 \n）
--       暂不吐出，offset 停在最后一个 \n 之后，下次补读（避免半行）。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: 读文件需普通模式（非 trusted）；内联模式无需
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='tail_file');
--   首次:     SELECT luajit_s('tail_file', {v: '/var/log/app.log', offset: 0, max: 100});
--             → {"offset":1234,"count":3,"lines":["a","b","c"]}
--   增量:     把 1234 存回，下次传 offset:1234 只读新增。
--   展开:     SELECT l FROM (FROM json(luajit_s('tail_file',{v:=p,offset:=o,max:=100}),
--                          ['offset','count','lines'])), unnest(json['lines']) t(l);

-- ======================================================================
-- JSON 编码
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
-- 读完整文件内容；不存在则返回 nil（调用方改当内联）
-- ======================================================================
local function read_full(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  return d or ''
end

-- ======================================================================
-- 从 offset 起收集完整行。content 为全文（0-based 寻址）。
-- 返回 (new_offset, lines)。
--   · 只吐以 \n 结尾的完整行；末尾未完结行不吐，new_offset 停在最后 \n 之后。
--   · 截断/重建（offset > #content）→ offset 重置 0。
--   · max>0 时最多吐 max 行，new_offset 停在已吐行末尾（未读完整行下次补）。
-- ======================================================================
local function tail_content(content, offset, max)
  local n = #content
  if offset < 0 then offset = 0 end
  if offset > n then offset = 0 end
  local lines = {}
  local row_start = offset + 1                  -- 1-based 当前行起点
  local last_complete = offset                  -- 已消费到 0-based 偏移
  for i = row_start, n do
    if content:byte(i) == 10 then
      local line = content:sub(row_start, i - 1)
      line = line:gsub('\r$', '')
      lines[#lines + 1] = line
      last_complete = i                          -- \n 后一个位置的 0-based = i
      row_start = i + 1
      if max > 0 and #lines >= max then break end
    end
  end
  return last_complete, lines
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '{"offset":0,"count":0,"lines":[]}' end
  local src = p.v or ''
  local offset = tonumber(p.offset) or 0
  local max = tonumber(p.max) or 1000

  local content = read_full(src)
  if content == nil then content = src end   -- 非文件 → 内联全文

  local new_offset, lines = tail_content(content, offset, max)
  return T.encode({ offset = new_offset, count = #lines, lines = lines })
end

return function(p)
  return run(p)
end
