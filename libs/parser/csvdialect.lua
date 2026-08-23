-- @lib: csvdialect
-- @category: parser
-- @desc: CSV 方言探测 + 纯 Lua 解析（自含，无 FFI）—— DuckDB read_csv 的采样嗅探对
--       多行/引号内嵌分隔符/欧洲分号格式常误判，本库用确定性状态机做「探测方言 + 精确解析」。
--       op 选项（v = CSV 文本；或用 file = CSV 文件路径，库内 io.open 读取）：
--         'detect' → 方言 JSON：{delimiter, quotechar, doublequote, skipinitialspace, has_header, ncols}
--                    delimiter 取值 "," ";" "\t" "|" 或 "unknown"；quotechar 取 "\"" 或 "none"
--                    has_header = 启发式（首行多为非数字文本 且 后续行含数字 → true）
--         'parse'  → 解析后的二维数组 JSON（[[f1,f2..],[..]]），用探测出的方言（可 delimit/quote 覆盖）
--         'rows'   → 行数（数字）
--         'ncols'  → 各行列数是否一致（"rect" / "ragged:<min>x<max>"）
--       验证：libs/parser/csvdialect_verify.py（Python csv.Sniffer + csv.reader 交叉校验
--       delimiter/quotechar 与解析后的字段矩阵）。

local function read_input(p)
  local v = p.v
  if (not v or v == '') and p.file and p.file ~= '' then
    local f = io.open(p.file, 'r')
    if not f then return nil, 'cannot open '..tostring(p.file) end
    v = f:read('*a'); f:close()
  end
  return v
end

-- ============ 方言探测 ============
-- 统计每行中某分隔符在「引号外」出现的次数
local function count_per_line(s, delim)
  local counts = {}
  local inq = false
  local line = 1
  local cnt = 0
  local n = #s
  local i = 1
  local dl = #delim
  while i <= n do
    local c = s:sub(i,i)
    if inq then
      if c == '"' then inq = false end
      i = i + 1
    else
      if c == '"' then inq = true; i = i + 1
      elseif s:sub(i, i+dl-1) == delim then
        cnt = cnt + 1; i = i + dl
      elseif c == '\n' then
        counts[line] = cnt; line = line + 1; cnt = 0; i = i + 1
      else
        i = i + 1
      end
    end
  end
  counts[line] = cnt
  return counts
end

local parse_csv  -- 前置声明（detect_dialect 在 parse_csv 定义之前调用它）
local function detect_dialect(s)
  -- 去掉首尾空白行
  s = s:gsub('\r\n', '\n'):gsub('\n\n+$', '\n')
  local lines = {}
  for l in (s .. '\n'):gmatch('(.-)\n') do
    if l:gsub('^%s+',''):gsub('%s+$','') ~= '' then lines[#lines+1] = l end
  end
  local nlines = #lines
  local candidates = {',', ';', '\t', '|'}
  local best = nil; best_score = -1
  for _, cand in ipairs(candidates) do
    local counts = count_per_line(s, cand)
    local nonzero = 0; local first = nil; local all_eq = true
    for _, c in pairs(counts) do
      if c > 0 then
        nonzero = nonzero + 1
        if first == nil then first = c elseif c ~= first then all_eq = false end
      end
    end
    -- 有效：至少 1 行用到，且用到的行计数一致
    if nonzero >= 1 and all_eq then
      local score = nonzero  -- 覆盖行数越多越可信；并列时先出现者胜（,;|\t 顺序）
      if score > best_score then best_score = score; best = cand end
    end
  end
  local delimiter = best or 'unknown'

  -- quotechar
  local quotechar = 'none'
  if s:find('"') then quotechar = '"' end
  -- doublequote
  local doublequote = s:find('""') ~= nil
  -- skipinitialspace: 分隔符后紧跟空格（引号外，plain find 即可）
  local skipinitialspace = false
  if delimiter ~= 'unknown' then
    skipinitialspace = s:find(delimiter .. ' ', 1, true) ~= nil
  end
  -- ncols: 用探测出的分隔符切第一行（引号外）
  local ncols = 0
  if nlines >= 1 and delimiter ~= 'unknown' then
    local first = lines[1]
    local inq = false; local c = 0
    for i = 1, #first - (#delimiter - 1) do
      if first:sub(i,i) == '"' then inq = not inq
      elseif first:sub(i, i+#delimiter-1) == delimiter and not inq then c = c + 1 end
    end
    ncols = c + 1
  end

  -- has_header 启发式：解析后判断（首行全为非数字文本 且 第二行含数字 → true）
  local rows = parse_csv(s, delimiter ~= 'unknown' and delimiter or ',', quotechar ~= 'none' and quotechar or nil)
  local has_header = false
  local function is_num(f)
    return f:gsub('^%s+',''):gsub('%s+$',''):match('^%-?%d+%.?%d*$') ~= nil
  end
  if #rows >= 2 then
    local row1_nonnum = true
    for _, f in ipairs(rows[1]) do
      local t = f:gsub('^%s+',''):gsub('%s+$','')
      if t ~= '' and is_num(t) then row1_nonnum = false; break end
    end
    local row2_hasnum = false
    for _, f in ipairs(rows[2]) do
      if is_num(f:gsub('^%s+',''):gsub('%s+$','')) then row2_hasnum = true; break end
    end
    if row1_nonnum and row2_hasnum then has_header = true end
  end

  return {
    delimiter = delimiter,
    quotechar = quotechar,
    doublequote = doublequote,
    skipinitialspace = skipinitialspace,
    has_header = has_header,
    ncols = ncols,
  }
end

-- ============ 纯 Lua CSV 解析（状态机）============
parse_csv = function(s, delim, quote)
  delim = delim or ','
  quote = quote or '"'
  local rows, row, field = {}, {}, {}
  local inq = false
  local n = #s
  local i = 1
  local dl = #delim
  local function commit_field()
    row[#row+1] = table.concat(field); field = {}
  end
  local function commit_row()
    commit_field()
    rows[#rows+1] = row; row = {}
  end
  while i <= n do
    local c = s:sub(i,i)
    if inq then
      if c == quote then
        if s:sub(i+1, i+1) == quote then
          field[#field+1] = quote; i = i + 2
        else
          inq = false; i = i + 1
        end
      else
        field[#field+1] = c; i = i + 1
      end
    else
      if c == quote and (#field == 0) then
        inq = true; i = i + 1
      elseif s:sub(i, i+dl-1) == delim then
        commit_field(); i = i + dl
      elseif c == '\r' then
        commit_row(); i = i + 1
        if s:sub(i,i) == '\n' then i = i + 1 end
      elseif c == '\n' then
        commit_row(); i = i + 1
      else
        field[#field+1] = c; i = i + 1
      end
    end
  end
  -- 收尾
  if #field > 0 or #row > 0 then commit_row() end
  return rows
end

-- ============ JSON 编码（复用约定）============
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

-- ============ 入口 ============
return function(p)
  if type(p) == 'string' then p = {v = p} end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local v, err = read_input(p)
  if not v or v == '' then return '{"error":"missing v or file"}' end
  local op = p.op or 'detect'

  local dialect = detect_dialect(v)
  local delim = p.delimit or dialect.delimiter
  local quote = p.quote and p.quote ~= 'none' and p.quote or (dialect.quotechar ~= 'none' and dialect.quotechar or nil)
  local rows = parse_csv(v, delim ~= 'unknown' and delim or ',', quote)

  if op == 'detect' then
    return json_encode(dialect)
  elseif op == 'parse' then
    return json_encode(rows)
  elseif op == 'rows' then
    return json_encode(#rows)
  elseif op == 'ncols' then
    local mn, mx = nil, nil
    for _, r in ipairs(rows) do
      local c = #r
      if mn == nil or c < mn then mn = c end
      if mx == nil or c > mx then mx = c end
    end
    if mn == nil then return json_encode('rect') end
    if mn == mx then return '"rect"' end
    return '"ragged:'..mn..'x'..mx..'"'
  end
  return '{"error":"unknown op"}'
end
