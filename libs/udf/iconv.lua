-- @lib: iconv
-- @category: udf
-- @desc: 字符编码全家桶——enc_detect(编码检测) / convert(iconv 转码, //IGNORE 剔非法字节) /
--        file(文件转码→UTF-8 临时文件，供 read_csv/COPY 直接消费) / lang(语言检测 ISO 639-1)
-- @source: original（duckdb-luajit 系列）
-- @requires: none（FFI 调 libc 的 iconv：Linux glibc/macOS 自带；Windows 需 libiconv.dll）
-- ⚠️ 需普通模式（非 trusted）：file 场景用 io.open 读文件
--
-- Usage (duckdb-luajit):
--   install:     SELECT * FROM luajit_module(mode:='install', sql_name:='iconv');
--   quick_compile:
--     SELECT * FROM luajit_module(mode:='quick_compile', sql_name:='iconv',
--       source:=(SELECT content FROM read_text('/path/to/iconv.lua')));
--   编码检测（p.file 存在时读文件头 8KB，否则用 p.s）：
--     SELECT luajit_s('iconv', {op:'detect', s:'...字节串...'});      -- 'UTF-8'/'GBK'/'GB18030'/...
--     SELECT luajit_s('iconv', {op:'detect', file:'/data/orders.csv'});  -- 读文件检测
--   转码（from 缺省或 'auto' 时自动检测；to 默认 'UTF-8'；mode 默认 'ignore' 剔非法字节）：
--     SELECT luajit_s('iconv', {op:'convert', s: blob_or_varchar, from:'GBK', to:'UTF-8', mode:'ignore'});
--   文件转码→UTF-8 临时文件（GBK CSV 直接喂 read_csv）：
--     SELECT * FROM read_csv(luajit_s('iconv', {op:'file', file:'/data/orders.csv'}), header := true);
--   语言检测（输入需为 UTF-8 文本；字符区间判定 ~15 语言 + 拉丁停用词细分）：
--     SELECT luajit_s('iconv', {op:'lang', s:'Bonjour le monde'});    -- 'fr'
--
-- 设计要点：只做「检测 + 转码」，CSV/JSON 解析永远交给 DuckDB 原生 read_csv/read_json——
-- read_csv 的 encoding 参数仅支持 utf-8/utf-16/latin-1（COPY 语句不支持 encoding），GBK 等中文编码是真空位。

local ffi = require('ffi')

-- ============ FFI: iconv ============
ffi.cdef[[
  typedef void *iconv_t;
  iconv_t iconv_open(const char *tocode, const char *fromcode);
  size_t iconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
               char **outbuf, size_t *outbytesleft);
  int iconv_close(iconv_t cd);
]]

-- glibc 的 iconv 在 libc 里；macOS/其他平台可能叫 iconv
local C
for _, lib in ipairs({ 'c', 'iconv' }) do
  local ok, l = pcall(ffi.load, lib)
  if ok and l.iconv_open then C = l; break end
end
if not C then
  error('iconv: cannot load libc iconv (Linux/macOS built-in; Windows needs libiconv.dll)')
end

local NEG1 = ffi.cast('size_t', -1)

-- 前向声明：convert 定义在 detect 之前，须先绑定 local 名（否则被解析为全局）
local detect

-- ============ sanitize：剔除源编码非法字节（//IGNORE 语义，跨平台一致） ============
-- glibc 的 iconv //IGNORE 会跳过非法字节但最终仍返回 -1 错误码（实测），且对
-- "目标无法表示"（如 emoji→GBK）不生效——所以剔除逻辑在 Lua 侧自己做，iconv 走严格模式。

-- GBK/GB2312/GB18030 双字节序列：首 0x81-0xFE，尾 0x40-0xFE（除 0x7F）；GB18030 另有 4 字节序列
local function sanitize_gbk(s, gb18030)
  local out, n, i = {}, #s, 1
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    elseif b >= 0x81 and b <= 0xFE then
      local b2 = s:byte(i + 1)
      if gb18030 and b2 and b2 >= 0x30 and b2 <= 0x39 then
        local b3, b4 = s:byte(i + 2), s:byte(i + 3)
        if b3 and b3 >= 0x81 and b3 <= 0xFE and b4 and b4 >= 0x30 and b4 <= 0x39 then
          out[#out + 1] = s:sub(i, i + 3)
          i = i + 4
        else
          i = i + 1 -- 剔除孤立首字节（半个字）
        end
      elseif b2 and b2 >= 0x40 and b2 <= 0xFE and b2 ~= 0x7F then
        out[#out + 1] = s:sub(i, i + 1)
        i = i + 2
      else
        i = i + 1 -- 剔除孤立首字节（半个字）
      end
    else
      i = i + 1 -- 剔除 0x80/0xFF 等非法字节
    end
  end
  return table.concat(out)
end

-- UTF-8 严格校验式剔除（E0/ED/F0/F4 边界，与 utf8_valid 同规则）
local function sanitize_utf8(s)
  local out, n, i = {}, #s, 1
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      local b2 = s:byte(i + 1)
      if b2 and b2 >= 0x80 and b2 <= 0xBF then
        out[#out + 1] = s:sub(i, i + 1)
        i = i + 2
      else
        i = i + 1
      end
    elseif b >= 0xE0 and b <= 0xEF then
      local b2, b3 = s:byte(i + 1), s:byte(i + 2)
      local ok = b2 and b3
      if ok and b == 0xE0 then ok = b2 >= 0xA0 and b2 <= 0xBF end
      if ok and b == 0xED then ok = b2 >= 0x80 and b2 <= 0x9F end
      if ok then ok = b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF end
      if ok then
        out[#out + 1] = s:sub(i, i + 2)
        i = i + 3
      else
        i = i + 1
      end
    elseif b >= 0xF0 and b <= 0xF4 then
      local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
      local ok = b2 and b3 and b4
      if ok and b == 0xF0 then ok = b2 >= 0x90 and b2 <= 0xBF end
      if ok and b == 0xF4 then ok = b2 >= 0x80 and b2 <= 0x8F end
      if ok then ok = b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF end
      if ok then
        out[#out + 1] = s:sub(i, i + 3)
        i = i + 4
      else
        i = i + 1
      end
    else
      i = i + 1 -- 剔除孤立 continuation / 非法首字节
    end
  end
  return table.concat(out)
end

local function sanitize(s, from)
  local u = from:upper()
  if u:find('GBK') or u:find('GB2312') then return sanitize_gbk(s, false) end
  if u:find('GB18030') then return sanitize_gbk(s, true) end
  if u:find('UTF%-8') or u:find('UTF8') then return sanitize_utf8(s) end
  return s -- 其他编码不预处理，依赖 iconv 行为
end

-- ============ 核心转码 ============
-- mode: 'ignore'（默认，剔除非法字节）/ 'strict'（非法字节报错）
-- 返回 utf8 字符串；失败返回 nil, errmsg
local function convert(s, from, to, mode)
  if from == nil or from == '' or from == 'auto' then
    from = detect(s)
  end
  local ignore = mode ~= 'strict'
  if ignore then
    s = sanitize(s, from) -- 剔除源编码非法字节（半个字/孤立字节）
  end
  local tocode = to
  if ignore and to:find('IGNORE', 1, true) == nil then
    tocode = to .. '//IGNORE' -- 目标无法表示字符（emoji→GBK）兜底
  end
  local cd = C.iconv_open(tocode, from)
  if cd == ffi.cast('iconv_t', -1) then
    return nil, 'iconv_open failed: ' .. tostring(from) .. ' -> ' .. tostring(tocode)
  end
  local in_len = #s
  local inbuf = ffi.new('char[?]', in_len > 0 and in_len or 1)
  if in_len > 0 then ffi.copy(inbuf, s, in_len) end
  local inptr = ffi.new('char*[1]', inbuf)
  local inleft = ffi.new('size_t[1]', in_len)
  -- 输出缓冲：UTF-8 为变长（GBK 2B → UTF-8 3B ≈ 1.5x；UTF-16 → UTF-8 ≤ 2x），4x 富余
  local out_cap = in_len * 4 + 64
  local outbuf = ffi.new('char[?]', out_cap)
  local outptr = ffi.new('char*[1]', outbuf)
  local outleft = ffi.new('size_t[1]', out_cap)
  local r = C.iconv(cd, inptr, inleft, outptr, outleft)
  C.iconv_close(cd)
  local written = out_cap - outleft[0]
  if r == NEG1 then
    local e = ffi.errno()
    if e == 7 then -- E2BIG：缓冲不足，绝不静默截断
      return nil, 'iconv E2BIG: output buffer too small at ' .. tostring(from) .. ' -> ' .. tostring(to)
    end
    if ignore then
      -- EILSEQ/EINVAL：返回已转码部分（sanitize 后残留多为目标无法表示字符）
      return ffi.string(outbuf, written)
    end
    return nil, 'iconv error (errno ' .. tostring(e) .. ') at ' .. tostring(from) .. ' -> ' .. tostring(to)
      .. ' (use mode "ignore" to skip invalid bytes)'
  end
  return ffi.string(outbuf, written)
end

-- ============ 编码检测 ============
-- 严格 UTF-8 校验（含 E0/ED/F0/F4 边界，防误判 GBK 为 UTF-8）
local function utf8_valid(s)
  local n = #s
  local i = 1
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      local b2 = s:byte(i + 1)
      if not b2 or b2 < 0x80 or b2 > 0xBF then return false end
      i = i + 2
    elseif b >= 0xE0 and b <= 0xEF then
      local b2, b3 = s:byte(i + 1), s:byte(i + 2)
      if not b2 or not b3 then return false end
      if b == 0xE0 and (b2 < 0xA0 or b2 > 0xBF) then return false end
      if b == 0xED and (b2 < 0x80 or b2 > 0x9F) then return false end
      if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
      i = i + 3
    elseif b >= 0xF0 and b <= 0xF4 then
      local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
      if not b2 or not b3 or not b4 then return false end
      if b == 0xF0 and (b2 < 0x90 or b2 > 0xBF) then return false end
      if b == 0xF4 and (b2 < 0x80 or b2 > 0x8F) then return false end
      if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
      i = i + 4
    else
      return false -- 孤立 continuation / 非法首字节
    end
  end
  return true
end

-- GBK 双字节序列占比：首字节 0x81-0xFE，尾字节 0x40-0xFE（除 0x7F）
local function gbk_score(s)
  local n = #s
  local pairs, total = 0, 0
  local i = 1
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      i = i + 1
    elseif b >= 0x81 and b <= 0xFE then
      local b2 = s:byte(i + 1)
      if b2 and b2 >= 0x40 and b2 <= 0xFE and b2 ~= 0x7F then
        pairs = pairs + 1
      end
      total = total + 1
      i = i + 2
    else
      total = total + 1
      i = i + 1
    end
  end
  if total == 0 then return 0 end
  return pairs / total
end

-- GB18030 4 字节序列：0x81-0xFE 0x30-0x39 0x81-0xFE 0x30-0x39
local function gb18030_detect(s)
  local n = #s
  local hits = 0
  local i = 1
  while i <= n - 3 do
    local b1, b2, b3, b4 = s:byte(i), s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
    if b1 >= 0x81 and b1 <= 0xFE and b2 >= 0x30 and b2 <= 0x39
      and b3 >= 0x81 and b3 <= 0xFE and b4 >= 0x30 and b4 <= 0x39 then
      hits = hits + 1
      i = i + 4
    else
      i = i + 1
    end
  end
  return hits > 0
end

-- 检测字节串编码：BOM → UTF-8 严格校验 → GB18030/GBK 特征 → latin-1 兜底
detect = function(data)
  local n = #data
  if n >= 3 and data:sub(1, 3) == '\239\187\191' then return 'UTF-8' end  -- EF BB BF
  if n >= 2 and data:sub(1, 2) == '\255\254' then return 'UTF-16LE' end   -- FF FE
  if n >= 2 and data:sub(1, 2) == '\254\255' then return 'UTF-16BE' end   -- FE FF
  -- 取前 4KB 做 UTF-8 校验（大文件避免全扫）
  local sample = n > 4096 and data:sub(1, 4096) or data
  if utf8_valid(sample) then return 'UTF-8' end
  if gb18030_detect(sample) then return 'GB18030' end
  if gbk_score(sample) > 0.5 then return 'GBK' end
  return 'latin-1' -- 兜底：单字节（或无法识别）
end

-- ============ 语言检测（UTF-8 输入，ISO 639-1） ============
-- 3 字节 UTF-8 字符的码点分类
local function cp3(b1, b2, b3)
  return (b1 % 16) * 4096 + (b2 % 64) * 64 + (b3 % 64)
end

local LATIN_STOPWORDS = {
  en = { the = 1, ['and'] = 1, ['of'] = 1, ['to'] = 1, ['in'] = 1, is = 1, ['for'] = 1, with = 1 },
  fr = { le = 1, la = 1, de = 1, les = 1, et = 1, des = 1, un = 1, une = 1 },
  de = { der = 1, die = 1, und = 1, ['in'] = 1, von = 1, den = 1, das = 1, mit = 1 },
  es = { el = 1, la = 1, de = 1, los = 1, las = 1, que = 1, y = 1, ['en'] = 1 },
  it = { il = 1, la = 1, di = 1, del = 1, che = 1, e = 1, un = 1, per = 1 },
  pt = { o = 1, a = 1, os = 1, as = 1, de = 1, que = 1, e = 1, em = 1 },
}

local function lang_detect(s)
  local han, hira, kata, hangul, cyr, arab, greek, thai, deva = 0, 0, 0, 0, 0, 0, 0, 0, 0
  local n = #s
  local i = 1
  while i <= n do
    local b = s:byte(i)
    if b >= 0xC0 and b <= 0xDF then
      -- 2 字节区：西里尔 U+0400-04FF / 希腊 U+0370-03FF / 阿拉伯 U+0600-06FF
      local cp = (b % 32) * 64 + ((s:byte(i + 1) or 0) % 64)
      if cp >= 0x0400 and cp <= 0x04FF then cyr = cyr + 1
      elseif cp >= 0x0600 and cp <= 0x06FF then arab = arab + 1
      elseif cp >= 0x0370 and cp <= 0x03FF then greek = greek + 1
      end
      i = i + 2
    elseif b >= 0xE0 and b <= 0xEF then
      local cp = cp3(b, s:byte(i + 1) or 0, s:byte(i + 2) or 0)
      if cp >= 0x4E00 and cp <= 0x9FFF then han = han + 1
      elseif cp >= 0x3040 and cp <= 0x309F then hira = hira + 1
      elseif cp >= 0x30A0 and cp <= 0x30FF then kata = kata + 1
      elseif cp >= 0xAC00 and cp <= 0xD7A3 then hangul = hangul + 1
      elseif cp >= 0x0400 and cp <= 0x04FF then cyr = cyr + 1
      elseif cp >= 0x0600 and cp <= 0x06FF then arab = arab + 1
      elseif cp >= 0x0370 and cp <= 0x03FF then greek = greek + 1
      elseif cp >= 0x0E00 and cp <= 0x0E7F then thai = thai + 1
      elseif cp >= 0x0900 and cp <= 0x097F then deva = deva + 1
      end
      i = i + 3
    else
      i = i + 1
    end
  end
  -- 表意文字系：汉字 + 假名/谚文判定
  if han > 0 or hira > 0 or kata > 0 or hangul > 0 then
    if hira + kata > 0 then return 'ja' end
    if hangul > 0 then return 'ko' end
    if han > 0 then return 'zh' end
  end
  if cyr > 0 then return 'ru' end
  if arab > 0 then return 'ar' end
  if greek > 0 then return 'el' end
  if thai > 0 then return 'th' end
  if deva > 0 then return 'hi' end
  -- 拉丁系：停用词细分（英法德西意葡），无命中默认 en
  local scores = { en = 0, fr = 0, de = 0, es = 0, it = 0, pt = 0 }
  for word in s:lower():gmatch('[a-z]+') do
    for lang, tbl in pairs(LATIN_STOPWORDS) do
      if tbl[word] then scores[lang] = scores[lang] + 1 end
    end
  end
  local best, best_n = 'en', 0
  for lang, cnt in pairs(scores) do
    if cnt > best_n then best, best_n = lang, cnt end
  end
  return best
end

-- ============ 文件转码 → UTF-8 临时文件 ============
-- p.file 输入路径；p.from 缺省自动检测；p.to 默认 UTF-8；p.mode 默认 ignore；p.out 可选输出路径
-- 返回转码后文件路径（供 read_csv / COPY 直接消费）
local function iconv_file(p)
  local f, err = io.open(p.file, 'rb')
  if not f then return nil, 'iconv.file: ' .. tostring(err) end
  local data = f:read('*a')
  f:close()
  local from = p.from or detect(data)
  local to = p.to or 'UTF-8'
  local out, cerr = convert(data, from, to, p.mode)
  if not out then return nil, cerr end
  local out_path = p.out
  if not out_path then
    local base = p.file:match('([^/\\]+)$') or 'input'
    base = base:gsub('[^%w%.%-_]', '_')
    out_path = '/tmp/luajit_iconv/' .. base .. '.' .. from .. '.to' .. to
  end
  local dir = out_path:match('^(.*)[/\\][^/\\]+$')
  if dir and dir ~= '' then
    local d = io.open(dir, 'rb')
    if not d then os.execute('mkdir -p ' .. dir) end
    if d then d:close() end
  end
  local f2, werr = io.open(out_path, 'wb')
  if not f2 then return nil, 'iconv.file: ' .. tostring(werr) end
  f2:write(out)
  f2:close()
  return out_path
end

-- ============ UDF 入口 ============
return function(p)
  if type(p) == 'string' then
    p = { op = 'convert', s = p }
  end
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'convert'
  if op == 'detect' then
    if p.file then
      local f = io.open(p.file, 'rb')
      if not f then return 'error: cannot open ' .. tostring(p.file) end
      local head = f:read(8192)
      f:close()
      if not head or #head == 0 then return 'unknown' end
      return detect(head)
    end
    return detect(p.s or '')
  elseif op == 'lang' then
    return lang_detect(p.s or '')
  elseif op == 'file' then
    local path, err = iconv_file(p)
    if not path then return 'error: ' .. tostring(err) end
    return path
  else -- op == 'convert'
    local out, err = convert(p.s or '', p.from, p.to or 'UTF-8', p.mode)
    if not out then return 'error: ' .. tostring(err) end
    return out
  end
end
