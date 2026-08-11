-- @lib: vbamod
-- @category: udf
-- @desc: VBA 运行时库（Microsoft VBA 语义对齐）— 让存量 VBA 函数逐行移植成 Lua UDF 后直接可用
-- @source: 原创（语义参照 MS VBA 语言参考）；配套 vbamod_test.lua 断言
-- @requires: none（纯 Lua 5.1/LuaJIT 兼容，无外部依赖）
--
-- 用法（duckdb-luajit）:
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='vbamod');
--   移植:    local vba = dofile('libs/udf/vbamod.lua')  -- 或 install 后全局 vbamod
--   UDF:     SELECT luajit_s('my_udf', 1.5);  -- my_udf 内部调 vbamod.Round 等
--
-- 语义对齐要点：
--   * 字符串 1-based；InStr 找不到返 0；Mid(start≤0) 返 ""
--   * Round/CInt/CLng = 银行家舍入（四舍六入五成双）；Int 向下、Fix 截断
--   * Date = Double 序列号（1899-12-30 = 0，与 Excel/VBA 一致）
--   * Array(...) 真 0-based（VBA 默认 LBound=0）
--   * Val 解析前导数字（跳过空格/逗号，&H 十六进制）
--   * 宿主函数（MsgBox/InputBox/DoEvents）在 UDF 环境不可用，返回 nil/报错

local M = {}

-- ============ 内部 helpers ============
local floor, abs, huge = math.floor, math.abs, math.huge
local tostr = tostring
local function ton(x) return tonumber(x) end
local function isint(x) return type(x) == "number" and x == floor(x) end

-- 银行家舍入（VBA Round/CInt/CLng 语义：四舍六入五成双）
local function round_banker(x)
  if x < 0 then return -round_banker(-x) end
  local f = floor(x)
  local d = x - f
  if d < 0.5 then return f
  elseif d > 0.5 then return f + 1
  else
    -- 恰好 .5：取偶数
    if f % 2 == 0 then return f else return f + 1 end
  end
end

-- VBA 数字转字符串（整数无小数点）
local function num2str(x)
  if isint(x) and abs(x) < 1e15 then return string.format("%.0f", x) end
  return tostr(x)
end

-- 转字符串（数字用 VBA 风格）
local function vstr(x)
  if type(x) == "number" then return num2str(x) end
  if x == nil then return "" end
  return tostr(x)
end

-- ============ Strings（字符串函数） ============
function M.Len(s) return #vstr(s) end
function M.LenB(s) return #vstr(s) end -- 单字节假设

function M.Left(s, n)
  s = vstr(s); n = ton(n) or 0
  if n <= 0 then return "" end
  return s:sub(1, n)
end
M.LeftB = M.Left

function M.Right(s, n)
  s = vstr(s); n = ton(n) or 0
  if n <= 0 then return "" end
  return s:sub(-n)
end
M.RightB = M.Right

function M.Mid(s, start, len)
  s = vstr(s); start = ton(start) or 0
  if start <= 0 then return "" end
  if len == nil then return s:sub(start) end
  len = ton(len)
  if len <= 0 then return "" end
  return s:sub(start, start + len - 1)
end
M.MidB = M.Mid

-- VBA InStr([start,] s1, s2)：1-based；找不到 0；s2 空串返 start
function M.InStr(...)
  local n = select('#', ...)
  local start, s1, s2
  if n == 2 then start, s1, s2 = 1, ...
  else start, s1, s2 = ... end
  start = ton(start) or 1
  s1, s2 = vstr(s1), vstr(s2)
  if s2 == "" then return start end
  if start < 1 then start = 1 end
  local i = s1:find(s2, start, true)
  return i or 0
end
M.InStrB = M.InStr

-- VBA InStrRev([start,] s1, s2)：从尾部找；找不到 0
function M.InStrRev(s1, s2, start)
  s1, s2 = vstr(s1), vstr(s2)
  if s2 == "" then
    return start and math.min(start, #s1 + 1) or #s1 + 1
  end
  start = start or #s1 + 1
  if start > #s1 then start = #s1 + 1 end
  local from = math.min(start, #s1)
  local i = s1:find(s2, 1, true)
  local last
  while i and i <= from do
    last = i
    i = s1:find(s2, i + 1, true)
  end
  return last or 0
end

-- VBA Replace(s, find, repl[, start[, count]])：start 之前字符保留，count 限替换次数
function M.Replace(s, f, r, start, count)
  s, f, r = vstr(s), vstr(f), vstr(r)
  start = ton(start) or 1
  if start < 1 then start = 1 end
  if f == "" then return s end
  local prefix = s:sub(1, start - 1)
  local body = s:sub(start)
  local n = 0
  local res = {}
  local pos = 1
  local from = 1
  while true do
    local i = body:find(f, from, true)
    if not i then break end
    if count and n >= count then break end
    res[#res + 1] = body:sub(from, i - 1)
    res[#res + 1] = r
    from = i + #f
    n = n + 1
  end
  res[#res + 1] = body:sub(from)
  return prefix .. table.concat(res)
end

function M.Trim(s) return (vstr(s):gsub("^%s+", ""):gsub("%s+$", "")) end
function M.LTrim(s) return (vstr(s):gsub("^%s+", "")) end
function M.RTrim(s) return (vstr(s):gsub("%s+$", "")) end

function M.UCase(s) return vstr(s):upper() end
function M.LCase(s) return vstr(s):lower() end

function M.Asc(s) s = vstr(s); if #s == 0 then return 0 end return s:byte(1) end
M.AscB = M.Asc
function M.AscW(s) s = vstr(s); if #s == 0 then return 0 end return s:byte(1) end

function M.Chr(c) c = ton(c) or 0; if c < 0 or c > 255 then return "" end return string.char(c) end
M.ChrB = M.Chr
function M.ChrW(c) c = ton(c) or 0; if c < 0 or c > 255 then return "" end return string.char(c) end

function M.Space(n) n = ton(n) or 0; if n <= 0 then return "" end return string.rep(" ", n) end

function M.String(n, c)
  n = ton(n) or 0
  local ch = type(c) == "number" and string.char(c % 256) or vstr(c)
  if #ch == 0 then ch = " " end
  ch = ch:sub(1, 1)
  if n <= 0 then return "" end
  return string.rep(ch, n)
end

function M.StrReverse(s) return vstr(s):reverse() end

function M.Split(s, delim, limit)
  s = vstr(s)
  delim = delim == nil and " " or vstr(delim)
  if delim == "" then return { s } end
  local out = {}
  if limit and limit > 0 then
    local pos = 1
    for _ = 1, limit - 1 do
      local i = s:find(delim, pos, true)
      if not i then break end
      out[#out + 1] = s:sub(pos, i - 1)
      pos = i + #delim
    end
    out[#out + 1] = s:sub(pos)
  else
    local pos = 1
    while true do
      local i = s:find(delim, pos, true)
      if not i then out[#out + 1] = s:sub(pos); break end
      out[#out + 1] = s:sub(pos, i - 1)
      pos = i + #delim
    end
  end
  return out
end

function M.Join(arr, delim)
  if type(arr) ~= "table" then return "" end
  local t = {}
  for _, v in ipairs(arr) do t[#t + 1] = vstr(v) end
  return table.concat(t, delim == nil and " " or vstr(delim))
end

-- VBA Filter(arr, match[, include[, compare]])：字符串数组过滤
function M.Filter(arr, match, include, compare)
  if type(arr) ~= "table" then return {} end
  include = include ~= false
  local out = {}
  local m = vstr(match)
  for _, v in ipairs(arr) do
    local vs = vstr(v)
    local hit = (vs:find(m, 1, true) ~= nil)
    if hit == include then out[#out + 1] = vs end
  end
  return out
end

-- VBA StrComp(s1, s2[, compare])：0=二进制(默认) 1=文本
function M.StrComp(s1, s2, compare)
  s1, s2 = vstr(s1), vstr(s2)
  if compare == 1 then s1, s2 = s1:lower(), s2:lower() end
  if s1 == s2 then return 0 end
  return s1 < s2 and -1 or 1
end

-- Val：解析前导数字（跳过空格/逗号/换行；&H 十六进制；&O 八进制）
function M.Val(s)
  s = vstr(s):gsub("[,%s]", "")
  local hex = s:match("^[&]H([0-9A-Fa-f]+)")
  if hex then return tonumber(hex, 16) or 0 end
  local oct = s:match("^[&]O([0-7]+)")
  if oct then return tonumber(oct, 8) or 0 end
  local num = s:match("^[-+]?%d*%.?%d*[EeDd]?[-+]?%d*")
  if not num or num == "" then return 0 end
  num = num:gsub("[Dd]", "e")
  if num == "" or num == "-" or num == "+" then return 0 end
  return tonumber(num) or 0
end

function M.Str(x) return vstr(x) end

-- ============ Conversion（转换函数） ============
function M.CBool(x)
  if type(x) == "string" then
    local l = x:lower()
    if l == "true" then return true end
    if l == "false" then return false end
  end
  return ton(x) ~= 0
end

function M.CByte(x) x = round_banker(ton(x) or 0); if x < 0 then x = 0 end; if x > 255 then x = 255 end; return x end
function M.CInt(x) return round_banker(ton(x) or 0) end
function M.CLng(x) return round_banker(ton(x) or 0) end
M.CLngLng = M.CLng
M.CLngPtr = M.CLng
function M.CSng(x) return ton(x) or 0 end
function M.CDbl(x) return ton(x) or 0 end
function M.CCur(x) return round_banker((ton(x) or 0) * 100) / 100 end
function M.CStr(x) return vstr(x) end
function M.CVar(x) return x end
function M.CDate(x)
  if type(x) == "number" then return x end
  local y, mo, d = vstr(x):match("(%d+)[-/](%d+)[-/](%d+)")
  if y then return M.DateSerial(ton(y), ton(mo), ton(d)) end
  return 0
end

function M.Fix(x) x = ton(x) or 0; if x < 0 then return math.ceil(x) end return floor(x) end
function M.Int(x) return floor(ton(x) or 0) end
function M.Hex(x)
  x = ton(x) or 0
  if x < 0 then x = x + 2 ^ 32 end
  return string.format("%X", x)
end
function M.Oct(x)
  x = ton(x) or 0
  if x < 0 then x = x + 2 ^ 32 end
  return string.format("%o", x)
end

-- VarType 常量（vbEmpty=0 vbNull=1 vbInteger=2 vbLong=3 vbSingle=4 vbDouble=5
--   vbCurrency=6 vbDate=7 vbString=8 vbObject=9 vbError=10 vbBoolean=11 vbVariant=12
--   vbArray=8192 vbLongLong=20 vbUserDefinedType=36）
function M.VarType(x)
  local t = type(x)
  if t == "nil" then return 0 end
  if t == "number" then
    if isint(x) then
      if abs(x) < 2 ^ 31 then return 2 end
      return 20
    end
    return 5
  end
  if t == "string" then return 8 end
  if t == "boolean" then return 11 end
  if t == "table" then return 8192 end
  return 9
end

-- VBA TypeName 风格："Empty","Integer","Long","Double","String","Boolean","Variant()","Object"
function M.TypeName(x)
  local t = type(x)
  if t == "nil" then return "Empty" end
  if t == "number" then
    if isint(x) then
      if abs(x) < 2 ^ 31 then return "Integer" end
      return "Long"
    end
    return "Double"
  end
  if t == "string" then return "String" end
  if t == "boolean" then return "Boolean" end
  if t == "table" then return "Variant()" end
  return "Object"
end

-- ============ Math（数学函数） ============
function M.Abs(x) return abs(ton(x) or 0) end
function M.Sgn(x)
  x = ton(x) or 0
  if x > 0 then return 1 end
  if x < 0 then return -1 end
  return 0
end
function M.Sqr(x) return math.sqrt(ton(x) or 0) end
function M.Sin(x) return math.sin(ton(x) or 0) end
function M.Cos(x) return math.cos(ton(x) or 0) end
function M.Tan(x) return math.tan(ton(x) or 0) end
function M.Atn(x) return math.atan(ton(x) or 0) end
function M.Exp(x) return math.exp(ton(x) or 0) end
function M.Log(x) return math.log(ton(x) or 0) end

-- VBA Round(x[, n]) 银行家舍入
function M.Round(x, n)
  x = ton(x) or 0
  n = ton(n) or 0
  local m = 10 ^ n
  return round_banker(x * m) / m
end

-- VBA Rnd：LCG 伪随机 [0,1)，种子 327680（VBA 默认）
local rnd_state = 327680
function M.Randomize(seed)
  rnd_state = ton(seed) or os.time()
  if rnd_state == 0 then rnd_state = 327680 end
end
function M.Rnd(seed)
  if seed and seed < 0 then rnd_state = ton(seed) or 327680 end
  rnd_state = (rnd_state * 1140671485 + 12820163) % (2 ^ 24)
  return rnd_state / (2 ^ 24)
end

-- ============ Date/Time（序列号 = 1899-12-30 起天数，纯算术无 os.time 历史时区坑） ============
-- 日期 → 序列号（Fliegel-Van Flandern 儒略日算法；1899-12-30 的 JD=2415019）
local function date_to_serial(y, m, d)
  local yy = y
  if m <= 2 then yy = y - 1; m = m + 12 end
  local a = math.floor(yy / 100)
  local b = 2 - a + math.floor(a / 4)
  local jd = math.floor(365.25 * (yy + 4716)) + math.floor(30.6001 * (m + 1)) + d + b - 1524
  return jd - 2415019
end

-- 序列号 → 年/月/日
local function serial_to_ymd(serial)
  local jd = serial + 2415019
  local l = jd + 68569
  local n = math.floor(4 * l / 146097)
  l = l - math.floor((146097 * n + 3) / 4)
  local i = math.floor(4000 * (l + 1) / 1461001)
  l = l - math.floor(1461 * i / 4) + 31
  local j = math.floor(80 * l / 2447)
  local d = l - math.floor(2447 * j / 80)
  l = math.floor(j / 11)
  local m = j + 2 - 12 * l
  local y = 100 * (n - 49) + i + l
  return y, m, d
end

-- 该月天数
local function days_in_month(y, m)
  return date_to_serial(y, m + 1, 1) - date_to_serial(y, m, 1)
end

-- 序列号 → {year,month,day,hour,min,sec}（本地时区无关，纯算术）
local function serial2table(serial)
  local y, m, d = serial_to_ymd(floor(serial))
  local frac = serial - floor(serial)
  local total = frac * 86400 + 0.0000001 -- 浮点修正
  local h = floor(total / 3600)
  local mi = floor((total - h * 3600) / 60)
  local s = floor(total - h * 3600 - mi * 60)
  return { year = y, month = m, day = d, hour = h, min = mi, sec = s }
end

-- 表 → 序列号（VBA 语义：day 超月尾截断，month/year 归一化）
local function table2serial(t)
  local y, m = t.year, t.month
  local base_y, base_m = serial_to_ymd(date_to_serial(y, m, 1))
  local day = math.min(t.day or 1, days_in_month(base_y, base_m))
  local serial = date_to_serial(base_y, base_m, day)
  return serial + ((t.hour or 0) * 3600 + (t.min or 0) * 60 + (t.sec or 0)) / 86400
end

function M.DateSerial(y, m, d)
  return table2serial({ year = ton(y) or 0, month = ton(m) or 1, day = ton(d) or 1 })
end

function M.DateValue(s)
  local y, mo, d = vstr(s):match("(%d+)[-/](%d+)[-/](%d+)")
  if y then return M.DateSerial(ton(y), ton(mo), ton(d)) end
  return 0
end

function M.TimeSerial(h, mi, s)
  return (ton(h) * 3600 + ton(mi) * 60 + ton(s)) / 86400
end

function M.TimeValue(s)
  local h, mi, sec = vstr(s):match("(%d+):(%d+):?(%d*)")
  if h then return M.TimeSerial(ton(h), ton(mi), ton(sec ~= "" and sec or 0)) end
  return 0
end

function M.Now() local t = os.date("*t"); return date_to_serial(t.year, t.month, t.day) + (t.hour * 3600 + t.min * 60 + t.sec) / 86400 end
function M.Date() return floor(M.Now()) end
function M.Time() return M.Now() % 1 end
function M.Timer() local t = os.date("*t"); return t.hour * 3600 + t.min * 60 + t.sec end -- 午夜后秒（VBA 语义）

function M.Day(d) return serial2table(ton(d)).day end
function M.Month(d) return serial2table(ton(d)).month end
function M.Year(d) return serial2table(ton(d)).year end
function M.Hour(d) return serial2table(ton(d)).hour end
function M.Minute(d) return serial2table(ton(d)).min end
function M.Second(d) return serial2table(ton(d)).sec end

-- Weekday(d[, firstdayofweek])：默认周日=1（vbSunday）；serial=1(1899-12-31) 是周日
function M.Weekday(d, firstday)
  local serial = ton(d) or 0
  local wd = ((floor(serial) - 1) % 7) + 1 -- 周日=1
  firstday = ton(firstday) or 1
  local r = wd - firstday + 1
  if r < 1 then r = r + 7 end
  return r
end

local MONTH_NAMES = { "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December" }
local WEEKDAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
function M.MonthName(m, abbreviate)
  m = ton(m) or 1
  local name = MONTH_NAMES[m] or ""
  if abbreviate and #name > 0 then name = name:sub(1, 3) end
  return name
end
function M.WeekdayName(wd, abbreviate)
  wd = ton(wd) or 1
  local name = WEEKDAY_NAMES[wd] or ""
  if abbreviate and #name > 0 then name = name:sub(1, 3) end
  return name
end

-- DateAdd(interval, n, date)：y/m/d/h/n/s/q/ww/w/yyyy
function M.DateAdd(iv, n, d)
  iv = vstr(iv):lower()
  n = ton(n) or 0
  d = ton(d) or 0
  if iv == "d" or iv == "y" or iv == "w" then return d + n end
  if iv == "h" then return d + n / 24 end
  if iv == "n" then return d + n / 1440 end
  if iv == "s" then return d + n / 86400 end
  if iv == "ww" then return d + n * 7 end
  local y, m, day = serial_to_ymd(floor(d))
  if iv == "yyyy" then y = y + n
  elseif iv == "q" then m = m + n * 3
  elseif iv == "m" then m = m + n
  end
  local base_y, base_m = serial_to_ymd(date_to_serial(y, m, 1)) -- 归一化
  local base_day = math.min(day, days_in_month(base_y, base_m)) -- VBA 截断语义
  return date_to_serial(base_y, base_m, base_day) + (d - floor(d))
end

-- DateDiff(interval, d1, d2)：d2-d1 的间隔数
function M.DateDiff(iv, d1, d2)
  iv = vstr(iv):lower()
  d1, d2 = ton(d1) or 0, ton(d2) or 0
  local secs = (d2 - d1) * 86400
  if iv == "s" then return floor(secs) end
  if iv == "n" then return floor(secs / 60) end
  if iv == "h" then return floor(secs / 3600) end
  if iv == "d" or iv == "y" or iv == "w" then return floor(d2 - d1) end
  if iv == "ww" then return floor((d2 - d1) / 7) end
  local y1, m1 = serial_to_ymd(floor(d1))
  local y2, m2 = serial_to_ymd(floor(d2))
  if iv == "m" then return (y2 - y1) * 12 + (m2 - m1) end
  if iv == "q" then return floor(((y2 - y1) * 12 + (m2 - m1)) / 3) end
  if iv == "yyyy" then return y2 - y1 end
  return 0
end

-- DatePart(interval, d[, firstdayofweek])：取部分
function M.DatePart(iv, d)
  iv = vstr(iv):lower()
  local serial = ton(d) or 0
  local y, m, day = serial_to_ymd(floor(serial))
  if iv == "yyyy" then return y end
  if iv == "m" then return m end
  if iv == "d" then return day end
  if iv == "y" then return floor(serial) - date_to_serial(y, 1, 1) + 1 end
  if iv == "ww" then return floor((floor(serial) - date_to_serial(y, 1, 1)) / 7) + 1 end
  if iv == "q" then return floor((m - 1) / 3) + 1 end
  local t = serial2table(serial)
  if iv == "h" then return t.hour end
  if iv == "n" then return t.min end
  if iv == "s" then return t.sec end
  if iv == "w" then return ((floor(serial) - 1) % 7) + 1 end
  return 0
end

-- ============ Format（格式化） ============
-- Format(x, fmt)：支持 0.00 / #,##0.00 / 0% / yyyy-mm-dd / yyyy/m/d 等常用模式
function M.Format(x, fmt)
  fmt = fmt or ""
  if type(x) == "number" then
    if fmt:find("%%") then
      local digits = fmt:match("%.(0+)%%") and #(fmt:match("%.(0+)%%")) or 0
      return string.format("%." .. digits .. "f%%", x * 100)
    end
    local digits = fmt:match("%.0+") and #(fmt:match("%.0+")) - 1 or 0
    local thousands = fmt:find("#,##", 1, true) ~= nil
    local neg = x < 0
    local y = abs(x)
    local s = string.format("%." .. digits .. "f", y)
    if thousands then
      local ip, fp = s:match("^(%d+)%.?(%d*)$")
      local out = {}
      local k = 1
      for i = #ip, 1, -1 do
        out[#out + 1] = ip:sub(i, i)
        if k % 3 == 0 and i > 1 then out[#out + 1] = "," end
        k = k + 1
      end
      s = table.concat(out):reverse()
      if fp ~= "" then s = s .. "." .. fp end
    end
    return (neg and "-" or "") .. s
  end
  if type(x) == "string" then
    local y, mo, d = x:match("(%d+)[-/](%d+)[-/](%d+)")
    if y then
      local t = { year = ton(y), month = ton(mo), day = ton(d) }
      local function p2(v) return string.format("%02d", v) end
      if fmt == "yyyy-mm-dd" then return string.format("%04d-%02d-%02d", t.year, t.month, t.day) end
      if fmt == "yyyy/m/d" then return string.format("%04d/%d/%d", t.year, t.month, t.day) end
      if fmt == "mm-dd-yyyy" then return string.format("%02d-%02d-%04d", t.month, t.day, t.year) end
      return p2(t.month) .. "/" .. p2(t.day) .. "/" .. t.year
    end
  end
  return vstr(x)
end

function M.FormatNumber(x, n)
  n = ton(n) or -1
  local s = M.Round(ton(x) or 0, n < 0 and 0 or n)
  return vstr(s)
end

function M.FormatPercent(x, n)
  return M.Format(ton(x) or 0, "%." .. (ton(n) or 2) .. "f%%")
end

function M.FormatCurrency(x, n)
  return string.format("%." .. (ton(n) or 2) .. "f", ton(x) or 0)
end

function M.FormatDateTime(d, fmt)
  fmt = fmt or 0
  local t = serial2table(ton(d) or 0)
  if fmt == 1 then return string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec) end
  if fmt == 2 then return string.format("%04d-%02d-%02d", t.year, t.month, t.day) end
  if fmt == 3 then return string.format("%02d:%02d:%02d", t.hour, t.min, t.sec) end
  return string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- ============ Information / Array（信息与数组） ============
function M.IsArray(x) return type(x) == "table" end
function M.IsDate(x)
  if type(x) == "number" then return true end
  if type(x) == "string" then return x:match("^%d+[-/]%d+[-/]%d+") ~= nil end
  return false
end
function M.IsEmpty(x) return x == nil or (type(x) == "table" and next(x) == nil) end
function M.IsNull(x) return x == nil end
function M.IsMissing(x) return x == nil end
function M.IsNumeric(x)
  if type(x) == "number" then return true end
  if type(x) ~= "string" then return false end
  local s = x:gsub("[,%s]", "")
  local core = s:match("^([-+]?%d*%.?%d*)") or ""
  local rest = s:sub(#core + 1)
  if rest ~= "" and not rest:match("^[eE][-+]?%d+$") then return false end
  return core:find("%d") ~= nil -- 至少一个数字（"1e"、"-.e5" 等非法）
end
function M.IsError(x) return false end
function M.IsObject(x) return type(x) == "table" and not M.IsArray(x) end

function M.Array(...)
  -- VBA Array() 默认 0-based：返回真 0-based 键表（t[0], t[1], ...）
  local t = {}
  for i = 1, select('#', ...) do t[i - 1] = select(i, ...) end
  return t
end

function M.UBound(arr, dim)
  if type(arr) ~= "table" then return -1 end
  local maxk = -1
  for k in pairs(arr) do
    if type(k) == "number" and k > maxk then maxk = k end
  end
  return maxk -- 0-based 表的最大键
end

function M.LBound(arr, dim) return 0 end

-- IIf(cond, t, f)：立即求值（与 VBA 一致，非惰性）
function M.IIf(cond, t, f)
  if cond then return t end
  return f
end

function M.Choose(idx, ...)
  idx = ton(idx) or 0
  if idx < 1 then return nil end
  return select(idx, ...)
end

function M.Switch(...)
  local n = select('#', ...)
  for i = 1, n - 1, 2 do
    if select(i, ...) then return select(i + 1, ...) end
  end
  return nil
end

function M.RGB(r, g, b) return (ton(r) or 0) + (ton(g) or 0) * 256 + (ton(b) or 0) * 65536 end

local QB_COLORS = { 0, 8388608, 32768, 8421376, 128, 8388736, 32896, 8421504, 8421504, 16711680, 65280, 16776960, 255, 16711935, 65535, 16777215 }
function M.QBColor(c)
  c = ton(c) or 0
  if c < 0 then c = 0 end
  if c > 15 then c = c % 16 end
  return QB_COLORS[c + 1]
end

function M.Environ(s) return os.getenv(vstr(s)) end
function M.DoEvents() return 0 end -- UDF 环境无事件循环

-- 宿主函数：UDF 环境不可用，显式报错
function M.MsgBox(...) error("MsgBox is a host function, not available in UDF context") end
function M.InputBox(...) error("InputBox is a host function, not available in UDF context") end

return M
