-- @lib: csvdialect
-- @category: parser
-- @desc: CSV 方言探测 + 纯 Lua 解析（自含，无 FFI）—— DuckDB read_csv 的采样嗅探对
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--       多行/引号内嵌分隔符/欧洲分号格式常误判，本库用确定性状态机做「探测方言 + 精确解析」。
--       支持 whitespace-delimited 定长/空隔表（连续空白=分隔符，NOAA Keeling 曲线式，
--       补 duckdb/duckdb#18413 读不了的格式）：4 种定长分隔符全 miss 时自动回退探测，
--       或显式 delimit='whitespace' 强制。
--       注释行：NOAA 式 # 注释头自动处理——首非空行以 '#' 开头时自动剥离重探
--       （剥后探测不成立则保留原样，# 视为数据），成功则 detect 输出带 "comment":"#"
--       且 parse 自动跳过注释行；也可显式 comment='#'（或 '//' 等任意首字符）强制剥离。
--       **表函数形态**（read_csv_dialect 式一行直读，含 http(s) URL，FFI 优先/curl 回退）：
--         SELECT * FROM luajit_table('csvdialect', list := 'https://gml.noaa.gov/.../co2_mm_mlo.txt');
--         SELECT * FROM luajit_table('csvdialect', list := '/path/to/file');
--         SELECT * FROM luajit_table('csvdialect', list := '{"url":"...","delimit":"...","comment":"#","skip_header":true}');
--       输出 row_idx|val，val = 该记录字段管道拼接串（字段内 | 转义为 ¦、换行转 \n），
--       用 split_part(val,'|',N) 取第 N 列；表函数源只认 path/URL，inline 文本走标量形态。
--       op 选项（标量形态；v = CSV 文本；file = 本地路径；url = http(s) 地址）：
--         'detect' → 方言 JSON：{delimiter, quotechar, doublequote, skipinitialspace, has_header, ncols}
--                    delimiter 取值 "," ";" "\t" "|" "whitespace" 或 "unknown"；quotechar 取 "\"" 或 "none"
--                    has_header = 启发式（首行多为非数字文本 且 后续行含数字 → true）
--         'parse'  → 解析后的二维数组 JSON（[[f1,f2..],[..]]），用探测出的方言（可 delimit/quote 覆盖）
--         'rows'   → 行数（数字）
--         'ncols'  → 各行列数是否一致（"rect" / "ragged:<min>x<max>"）
--       验证：libs/parser/csvdialect_verify.py（Python csv.Sniffer + csv.reader 交叉校验
--       delimiter/quotechar 与解析后的字段矩阵）。

-- ============ HTTP 取数（FFI 优先，curl CLI 回退；复用 jev_ask 的传输层模式）============
local IS_WINDOWS = (os.getenv('PROCESSOR_ARCHITECTURE') ~= nil or os.getenv('COMPUTERNAME') ~= nil)
local function sq(s)
  if IS_WINDOWS then return '"' .. s .. '"' end
  return "'" .. s .. "'"
end
local NOPROXY_STAR = IS_WINDOWS and '*' or "'*'"

local function fetch_source(url)
  local res, ferr
  local ffi_post = _G._curl_ffi_post
  if ffi_post then
    res, ferr = ffi_post({ url = url, timeout = 120 })
    if not res then ferr = tostring(ferr or 'curl_ffi transport failed'):sub(8) end
  end
  if not res then
    -- -w 参数必须 shell 引用（sq 包单/双引号），curl 自己解释格式里的 \n 换行；
    -- 裸 \n 会被 shell 当转义吃掉 → curl 不输出换行 → 状态码正则匹配失败。
    -- （与 jev_ask.lua 的 http_post 同款拼法，勿"简化"。）
    local warg = sq('\\n%{http_code}')
    local pipe = io.popen(string.format(
      'curl -s --noproxy %s --max-time 120 -w %s %s',
      NOPROXY_STAR, warg, sq(url)))
    if pipe then
      local out = pipe:read('*a'); pipe:close()
      if out then
        local code = out:match('\n(%d+)$')
        local payload = out:match('^(.*)\n%d+$') or out
        if code and tonumber(code) >= 200 and tonumber(code) < 300 then
          res = payload
        else
          ferr = string.format('HTTP %s from %s: %s',
            tostring(code), url, payload:sub(1, 200))
        end
      else
        ferr = 'no response from ' .. url
      end
    else
      ferr = 'io.popen failed (needs normal mode) fetching ' .. url
    end
  end
  if not res then return nil, ferr or 'http fetch failed for ' .. tostring(url) end
  return res
end

local function read_input(p)
  -- 本地文件
  local v = p.v
  if (not v or v == '') and p.file and p.file ~= '' then
    local f = io.open(p.file, 'r')
    if not f then return nil, 'cannot open '..tostring(p.file) end
    v = f:read('*a'); f:close()
  end
  -- HTTP(S) URL（FFI 优先，curl CLI 回退；复用 jev_ask 的传输层模式）
  if (not v or v == '') and p.url and p.url ~= '' then
    local res, ferr
    v, ferr = fetch_source(p.url)
    if not v then return nil, ferr or 'http fetch failed for ' .. tostring(p.url) end
  end
  return v
end

-- 表函数用：按路径/URL 取数（不经过 p.v，避免 table 函数误把 list 当 v）
local function read_source(path)
  if not path or path == '' then return nil, 'no source' end
  if path:match('^https?://') then
    return fetch_source(path)
  end
  local f = io.open(path, 'r')
  if not f then return nil, 'cannot open '..tostring(path) end
  local v = f:read('*a'); f:close()
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

-- ============ whitespace 解析（duckdb/duckdb#18413：连续空白=分隔符）============
local function split_ws_line(l)
  local fields = {}
  for f in l:gmatch('%S+') do fields[#fields+1] = f end
  return fields
end

local function detect_whitespace(lines)
  -- 所有非空行按空白切分后列数一致且 >=2 → whitespace-delimited
  local first = #split_ws_line(lines[1])
  if first < 2 then return false, 0 end
  for i = 2, #lines do
    if #split_ws_line(lines[i]) ~= first then return false, 0 end
  end
  return true, first
end

local function parse_ws(s)
  s = s:gsub('\r\n', '\n'):gsub('\r', '\n')
  local rows = {}
  for l in (s .. '\n'):gmatch('(.-)\n') do
    local trimmed = l:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed ~= '' then rows[#rows+1] = split_ws_line(trimmed) end
  end
  return rows
end

-- ============ 注释行过滤（NOAA 式 # 头，duckdb/duckdb#18413）============
local function is_comment(l, ch)
  local p = l:match('^%s*') or ''
  return l:sub(#p + 1, #p + #ch) == ch
end

local function strip_comment_lines(s, ch)
  local out = {}
  for l in (s .. '\n'):gmatch('(.-)\n') do
    if not is_comment(l, ch) then out[#out+1] = l end
  end
  return table.concat(out, '\n')
end

local function nonempty_lines(t)
  local out = {}
  for l in (t .. '\n'):gmatch('(.-)\n') do
    if l:gsub('^%s+',''):gsub('%s+$','') ~= '' then out[#out+1] = l end
  end
  return out
end

-- 定长分隔符候选（,;|\t 优先级）：所有用到它的行计数一致才有效
local function find_fixed_delim(s)
  local candidates = {',', ';', '\t', '|'}
  local best = nil; local best_score = -1
  for _, cand in ipairs(candidates) do
    local counts = count_per_line(s, cand)
    local nonzero = 0; local first = nil; local all_eq = true
    for _, c in pairs(counts) do
      if c > 0 then
        nonzero = nonzero + 1
        if first == nil then first = c elseif c ~= first then all_eq = false end
      end
    end
    if nonzero >= 1 and all_eq then
      local score = nonzero  -- 覆盖行数越多越可信；并列时先出现者胜（,;|\t 顺序）
      if score > best_score then best_score = score; best = cand end
    end
  end
  return best
end

local parse_csv  -- 前置声明（detect_dialect 在 parse_csv 定义之前调用它）
local function detect_once(s)
  -- 去掉首尾空白行
  s = s:gsub('\r\n', '\n'):gsub('\n\n+$', '\n')
  local lines = {}
  for l in (s .. '\n'):gmatch('(.-)\n') do
    if l:gsub('^%s+',''):gsub('%s+$','') ~= '' then lines[#lines+1] = l end
  end
  local nlines = #lines
  local delimiter = find_fixed_delim(s)
  -- whitespace 回退（duckdb/duckdb#18413）：定长分隔符全 miss 时，
  -- 所有行按连续空白切分列数一致且 >=2 → whitespace-delimited
  if not delimiter and nlines >= 2 then
    local ws_ok, ws_nc = detect_whitespace(lines)
    if ws_ok then delimiter = 'whitespace' end
  end
  if not delimiter then delimiter = 'unknown' end

  -- quotechar
  local quotechar = 'none'
  if s:find('"') then quotechar = '"' end
  -- doublequote
  local doublequote = s:find('""') ~= nil
  -- skipinitialspace: 分隔符后紧跟空格（引号外，plain find 即可；whitespace 无此概念）
  local skipinitialspace = false
  if delimiter ~= 'unknown' and delimiter ~= 'whitespace' then
    skipinitialspace = s:find(delimiter .. ' ', 1, true) ~= nil
  end
  -- ncols: 用探测出的分隔符切第一行（引号外）
  local ncols = 0
  if nlines >= 1 then
    if delimiter == 'whitespace' then
      ncols = #split_ws_line(lines[1])
    elseif delimiter ~= 'unknown' then
      local first = lines[1]
      local inq = false; local c = 0
      for i = 1, #first - (#delimiter - 1) do
        if first:sub(i,i) == '"' then inq = not inq
        elseif first:sub(i, i+#delimiter-1) == delimiter and not inq then c = c + 1 end
      end
      ncols = c + 1
    end
  end

  -- has_header 启发式：解析后判断（首行全为非数字文本 且 第二行含数字 → true）
  local rows
  if delimiter == 'whitespace' then
    rows = parse_ws(s)
  else
    rows = parse_csv(s, delimiter ~= 'unknown' and delimiter or ',', quotechar ~= 'none' and quotechar or nil)
  end
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

-- 外层入口：注释行处理（comment 参数；或自动 # 注释头剥离）。
-- 自动规则：首非空行以 '#' 开头 → 视为注释头（NOAA 式文件惯例），优先采用
-- 剥离后重探的结果（原始探测会被注释行自身的字符污染，如注释里的逗号）；
-- 剥离后探测不成立 → 保留原始（# 视为数据）。
local function detect_dialect(s, comment)
  -- 显式注释符：剥后重探
  if comment and comment ~= 'none' and comment ~= '' then
    local d = detect_once(strip_comment_lines(s, comment))
    if d.delimiter ~= 'unknown' then d.comment = comment; return d end
  end
  local d = detect_once(s)
  if not comment then
    local first_line = nil
    for l in (s .. '\n'):gmatch('(.-)\n') do
      if l:gsub('^%s+',''):gsub('%s+$','') ~= '' then first_line = l; break end
    end
    if first_line and is_comment(first_line, '#') then
      local d2 = detect_once(strip_comment_lines(s, '#'))
      if d2.delimiter ~= 'unknown' then
        d2.comment = '#'
        return d2
      end
    end
  end
  return d
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
-- 双形态：
--  (1) 标量：luajit_s('csvdialect', {op:.., v:/file:/url:..}) → JSON（detect/parse/rows/ncols）
--  (2) 表函数：luajit_table('csvdialect', list := '<path|URL>' | '<json spec>')
--      → 每数据行 1 个管道拼接串（字段内的 | 与换行按约定转义），read_csv_dialect 式直读：
--        SELECT * FROM luajit_table('csvdialect', list := 'https://gml.noaa.gov/.../co2_mm_mlo.txt');
--      list 为裸路径/URL，或 JSON spec {"url":..,"delimit":..,"comment":..,"skip_header":true}
local function pipe_escape(s)
  s = tostring(s)
  return (s:gsub('|', '¦'):gsub('\n', '\\n'):gsub('\r', ''))
end

-- 极简 spec 提取（自含，避免 dofile 别的库）：从 JSON 串里抠出我们认的键。
-- ⚠️ Lua pattern 无 `|` 交替，布尔值用 `([%a]+)` 捕获单词再比较（勿写 (true|false)）。
local function spec_get(spec, key)
  local pat = string.format('"%s"[ ]*:[ ]*"([^"]*)"', key)
  local val = spec:match(pat)
  if val then return val end
  local b = spec:match(string.format('"%s"[ ]*:[ ]*(%%a+)', key))
  if b == 'true' then return true end
  if b == 'false' then return false end
  return nil
end

local function run_table(list)
  -- 取 source + 可选 spec
  local spec, path
  if list:match('^%s*%{') then
    spec = list
    path = spec_get(spec, 'url') or spec_get(spec, 'file')
  else
    path = list:gsub('^%s+', ''):gsub('%s+$', '')
  end
  if not path or path == '' then
    return { 'ERR: list must be a path/URL or a json spec with url/file' }
  end
  local v, ferr = read_source(path)
  if not v or v == '' then return { 'ERR: ' .. tostring(ferr) } end

  local delimit  = spec and spec_get(spec, 'delimit')
  local comment  = spec and spec_get(spec, 'comment')
  local skiphdr  = spec and spec_get(spec, 'skip_header')
  local dialect = detect_dialect(v, comment)
  if dialect.comment and dialect.comment ~= '' then
    v = strip_comment_lines(v, dialect.comment)
  end
  local delim = delimit or dialect.delimiter
  local quote = (spec and spec_get(spec, 'quote'))
  if quote == 'none' then quote = nil end
  if not quote then
    quote = (dialect.quotechar ~= 'none') and dialect.quotechar or nil
  end
  local rows
  if delim == 'whitespace' then rows = parse_ws(v)
  else rows = parse_csv(v, (delim ~= 'unknown' and delim or ','), quote) end

  if skiphdr == true and #rows >= 1 then table.remove(rows, 1) end

  local out = {}
  for _, r in ipairs(rows) do
    local parts = {}
    for _, f in ipairs(r) do parts[#parts+1] = pipe_escape(f) end
    out[#out+1] = table.concat(parts, '|')
  end
  if #out == 0 then out[#out+1] = 'ERR: 0 rows parsed (path wrong / empty / unsupported layout)' end
  return out
end

return function(p)
  if type(p) == 'string' then return run_table(p) end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local v, err = read_input(p)
  if not v or v == '' then return '{"error":"missing v or file"}' end
  local op = p.op or 'detect'

  local dialect = detect_dialect(v, p.comment)
  -- 探测采纳了注释剥离（显式 comment 或自动 # 回退）→ 解析前先剥
  if dialect.comment and dialect.comment ~= '' then
    v = strip_comment_lines(v, dialect.comment)
  end
  local delim = p.delimit or dialect.delimiter
  local quote = p.quote and p.quote ~= 'none' and p.quote or (dialect.quotechar ~= 'none' and dialect.quotechar or nil)
  local rows
  if delim == 'whitespace' then
    rows = parse_ws(v)
  else
    rows = parse_csv(v, delim ~= 'unknown' and delim or ',', quote)
  end

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
