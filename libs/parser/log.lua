-- @lib: log
-- @category: parser
-- @desc: 日志归一化表函数——把原始日志行解析成 (line_no|ts|level|msg|kvs_json)，
--       自动识别 4 类：JSON-lines（level/msg 字段）、nginx access（$remote_addr|$user|
--       时间|方法|路径|协议|状态|字节|referer|UA）、syslog（"Oct  2 10:00:00 host tag: msg"）、
--       通用行（时间戳锚定 + [LEVEL] 标记）。ts 统一输出 ISO8601（epoch 秒/毫秒、ISO、syslog 无年份→2000）。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: 无（普通模式需读文件；trusted 模式不可用）
-- 诚实边界：ts 解析为启发式锚定（取行首/首个可识别时间戳）；msg 中保留原始文本，
--   仅剔除已抽取的 ts/level 前缀；kvs 抽取 JSON 顶层字符串/数值字段。
--
-- Usage (luajit_table, table mode):
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='log');
--   call:    SELECT * FROM luajit_table('log', list := '/var/log/app.log');
--   列:      line_no | ts | level | msg | kvs（JSON，可 json_extract）
--   例:      SELECT ts, level, json_extract(kvs, '$.trace_id') FROM log_t WHERE level='ERROR';

local function escape_pipe(s)
  return (tostring(s):gsub('|', '¦'):gsub('\n', ' '):gsub('\r', ' '))
end

-- ======================================================================
-- 时间戳规范化 → ISO8601（YYYY-MM-DDTHH:MM:SS）
-- ======================================================================
local function iso_from_parts(y, m, d, hh, mm, ss)
  return string.format('%04d-%02d-%02dT%02d:%02d:%02d',
    y or 2000, m or 1, d or 1, hh or 0, mm or 0, ss or 0)
end

-- ISO: 2024-01-02T15:04:05 或 2024/01/02 15:04:05（可选 .123 / Z / 时区）
local function try_iso(s)
  local y, m, d, hh, mm, ss = s:match('^(%d%d%d%d)[-/%s](%d%d)[-/%s](%d%d)[T ](%d%d):(%d%d):(%d%d)')
  if y then return iso_from_parts(tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss)) end
  return nil
end

-- epoch 秒（10 位）/毫秒（13 位）→ 本地 ISO（无时区处理，UTC 近似）
local function try_epoch(s)
  local e = s:match('^(%d%d%d%d%d%d%d%d%d%d)$')
  if e then
    local t = tonumber(e)
    if t > 0 and t < 4102444800 then
      local d = os.date('!*t', math.floor(t))
      return iso_from_parts(d.year, d.month, d.day, d.hour, d.min, d.sec)
    end
  end
  local ems = s:match('^(%d%d%d%d%d%d%d%d%d%d%d%d%d)$')
  if ems then
    local t = math.floor(tonumber(ems) / 1000)
    if t > 0 and t < 4102444800 then
      local d = os.date('!*t', t)
      return iso_from_parts(d.year, d.month, d.day, d.hour, d.min, d.sec)
    end
  end
  return nil
end

local MON = { Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6, Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12 }

-- syslog: 2024-10-02T... 或 "Oct  2 10:00:00"（无年）
local function try_syslog(s)
  local m, d, hh, mm, ss = s:match('^([%a][%a][%a])%s+(%d%d?)[%s ](%d%d):(%d%d):(%d%d)')
  if m and MON[m] then
    return iso_from_parts(2000, MON[m], tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss))
  end
  return nil
end

local function normalize_ts(s)
  if not s then return '' end
  s = s:match('^%s*(.-)%s*$') or s
  return try_iso(s) or try_epoch(s) or try_syslog(s) or ''
end

-- ======================================================================
-- JSON 极简解析（取顶层标量字段，供 kvs 抽取；失败返回 nil）
-- ======================================================================
local function json_escape(s)
  return (tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == '\\' then return '\\\\'
    elseif c == '\n' then return '\\n' else return c end
  end))
end

-- kvs（value 为原始 JSON token）→ JSON 字符串（保证合法）
local function kvs_to_json(kv)
  local parts = {}
  for k, v in pairs(kv) do
    parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. tostring(v)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- 解析一行 JSON 对象为 { field = raw_json_token }（浅层；值保留原始 token 保证 kvs 合法）
local function parse_json_line(s)
  s = s:match('^%s*(.-)%s*$')
  if not s:match('^%{') or not s:match('%}$') then return nil end
  local inner = s:match('^%{(.-)%}$')
  local out = {}
  local pos = 1
  local n = #inner
  while pos <= n do
    local q = inner:sub(pos, pos)
    if q == ',' or q == ' ' or q == ':' then pos = pos + 1
    elseif q == '"' then
      -- key
      local e = pos + 1
      while e <= n do
        if inner:sub(e, e) == '\\' then e = e + 2
        elseif inner:sub(e, e) == '"' then break else e = e + 1 end
      end
      local key = inner:sub(pos + 1, e - 1)
      pos = e + 1
      -- 跳过 :
      pos = pos + 1
      while pos <= n and (inner:sub(pos, pos) == ' ') do pos = pos + 1 end
      -- value（存原始 JSON token，保证 kvs 输出合法）
      local vq = inner:sub(pos, pos)
      if vq == '"' then
        local ve = pos + 1
        while ve <= n do
          if inner:sub(ve, ve) == '\\' then ve = ve + 2
          elseif inner:sub(ve, ve) == '"' then break else ve = ve + 1 end
        end
        out[key] = inner:sub(pos, ve)  -- 含引号
        pos = ve + 1
      elseif vq == '{' or vq == '[' then
        -- 嵌套：跳过到匹配（简化：按引号状态计数）
        local depth = 0; local in_s = false
        local ve = pos
        while ve <= n do
          local c = inner:sub(ve, ve)
          if in_s then
            if c == '\\' then ve = ve + 1
            elseif c == '"' then in_s = false end
          else
            if c == '"' then in_s = true
            elseif c == '{' or c == '[' then depth = depth + 1
            elseif c == '}' or c == ']' then
              depth = depth - 1
              if depth == 0 then break end
            end
          end
          ve = ve + 1
        end
        out[key] = inner:sub(pos, ve)
        pos = ve + 1
      else
        local e2 = inner:find('[,%}]', pos)
        if not e2 then e2 = n + 1 end
        out[key] = inner:sub(pos, e2 - 1):match('^%s*(.-)%s*$')
        pos = e2
      end
    else
      pos = pos + 1
    end
  end
  return out
end

-- ======================================================================
-- 行解析
-- ======================================================================
local LEVELS = { DEBUG=1, INFO=1, WARN=1, WARNING=1, ERROR=1, FATAL=1, CRIT=1, TRACE=1, NOTICE=1 }

-- 去掉 JSON 字符串外层引号（token → 纯文本）
local function unquote(t)
  if type(t) ~= 'string' then return '' end
  if t:match('^"') and t:match('"$') then
    return (t:sub(2, -2):gsub('\\(.)', function(c)
      if c == 'n' then return '\n' elseif c == 't' then return '\t' else return c end
    end))
  end
  return t
end

local function split_line(raw)
  local line = raw:match('^%s*(.-)%s*$')
  -- 1) JSON-lines
  local j = parse_json_line(line)
  if j then
    local ts = unquote(j.time or j.ts or j.timestamp or j['@timestamp'] or j.datetime or '')
    local level = unquote(j.level or j.severity or j.lvl or j.loglevel or ''):upper()
    local msg = unquote(j.msg or j.message or '')
    -- 从 kvs 里移除已用作 ts/level/msg 的字段
    local kv = {}
    local ts_keys = { time=1, ts=1, timestamp=1, ['@timestamp']=1, datetime=1 }
    for k, v in pairs(j) do
      if k ~= 'msg' and k ~= 'message' and k ~= 'level' and k ~= 'severity'
         and k ~= 'lvl' and k ~= 'loglevel' and not ts_keys[k] then kv[k] = v end
    end
    return normalize_ts(ts), level, msg, kvs_to_json(kv)
  end
  -- 2) nginx access: IP - user [time] "METHOD path PROTO" status bytes "ref" "ua"
  local ip, user, tstr, method, path, proto, status, bytes =
    line:match('^(%S+)%s+%-?%s*(%S+)%s+%[(.-)%]%s+"(%S+)%s+(.-)%s+(%S+)"%s+(%d%d%d)%s+(%d+|-)')
  if ip and method then
    -- tstr 形如 "02/Jan/2024:15:04:07 +0800"
    local d, mstr, y, hh, mi, ss = tstr:match('^(%d%d)/(%a%a%a)/(%d%d%d%d):(%d%d):(%d%d):(%d%d)')
    local ts = (d and mstr and y) and iso_from_parts(tonumber(y), MON[mstr], tonumber(d), tonumber(hh), tonumber(mi), tonumber(ss))
             or normalize_ts(tstr)
    local ref, ua = line:match('"([^"]*)"%s+"([^"]*)"%s*$')
    local kv = {}
    if ref and ref ~= '-' then kv.referer = '"' .. ref .. '"' end
    if ua and ua ~= '-' then kv['user_agent'] = '"' .. ua .. '"' end
    kv.method = '"' .. method .. '"'
    kv.path = '"' .. path .. '"'
    kv.status = status
    if bytes ~= '-' then kv.bytes = bytes end
    kv.remote_addr = '"' .. ip .. '"'
    return ts, '', string.format('%s %s', method, path), kvs_to_json(kv)
  end
  -- 3) syslog: Mon DD HH:MM:SS host tag[: msg]
  local mon, day, hh, mi, ss, host, smsg =
    line:match('^(%a%a%a)%s+(%d%d?)[%s](%d%d):(%d%d):(%d%d)%s+(%S+)%s+(.*)$')
  if mon and MON[mon] then
    local ts = iso_from_parts(2000, MON[mon], tonumber(day), tonumber(hh), tonumber(mi), tonumber(ss))
    local msg, level, tag = smsg, '', ''
    local tagcap, restmsg = smsg:match('^([^%s:]+):%s*(.*)$')
    if tagcap then
      tag = tagcap
      local lv, rest = restmsg:match('^([%a%u]+):%s*(.*)$')
      if lv and LEVELS[lv] then level, msg = lv, rest else msg = restmsg end
    end
    local kv = {}
    kv.host = '"' .. host .. '"'
    if tag ~= '' then kv.tag = '"' .. tag .. '"' end
    return ts, level, msg, kvs_to_json(kv)
  end
  -- 4) 通用：时间戳锚定 + [LEVEL] / LEVEL: 前缀
  local ts = ''
  local rest = line
  local iy, im, idd, ihh, imm, iss = line:match('^(%d%d%d%d)[-/%s](%d%d)[-/%s](%d%d)[T ](%d%d):(%d%d):(%d%d)')
  if iy then
    ts = iso_from_parts(tonumber(iy), tonumber(im), tonumber(idd), tonumber(ihh), tonumber(imm), tonumber(iss))
    rest = line:sub(20)  -- YYYY-MM-DDTHH:MM:SS 固定 19 字符
  else
    local ey, after = line:match('^(%d%d%d%d%d%d%d%d%d%d)%s+(.*)$')
    if ey then
      ts = normalize_ts(ey)
      rest = after
    end
  end
  local level = ''
  if rest then
    local lvm, rest2 = rest:match('^%s*%[(%u+)%]%s*(.*)$')  -- [ERROR]
    if lvm and LEVELS[lvm] then level, rest = lvm, rest2
    else
      local lvm2, rest2 = rest:match('^%s*(%u+)%s+(.*)$')  -- ERROR text
      if lvm2 and LEVELS[lvm2] then level, rest = lvm2, rest2 end
    end
  end
  return ts, level, (rest or line), '{}'
end

-- ======================================================================
-- 表函数入口：list = 逗号分隔文件路径，或 '|' 分隔的内联行
-- ======================================================================
return function(list)
  local rows = {}
  local function emit(src_label, line)
    if line == '' then return end
    local ts, level, msg, kvs = split_line(line)
    rows[#rows + 1] = table.concat({
      tostring(#rows + 1),
      escape_pipe(ts),
      escape_pipe(level),
      escape_pipe(msg),
      escape_pipe(kvs),
    }, '|')
  end
  if list and #list > 0 then
    -- 内联：含换行 → 按行；否则按文件
    if list:match('\n') then
      for l in (list .. '\n'):gmatch('([^\n]*)\n') do emit('inline', l) end
    else
      for p in string.gmatch(list, '[^,]+') do
        p = p:match('^%s*(.-)%s*$')
        local f = io.open(p, 'r')
        if f then
          for l in f:lines() do emit(p, l) end
          f:close()
        else
          -- 当作单行
          emit('inline', p)
        end
      end
    end
  end
  return rows
end
