-- @lib: inv_ofd
-- @category: datasource
-- @desc: 数电发票（全电发票）OFD 版式解析——元数据（发票号码/金额/税号/开票日期）+ 版面文本行。
--        OFD = zip 容器：OFD.xml 的 CustomDatas 直接带发票元数据（诺诺/百望等生成器写入），
--        Doc_0/Pages/Page_0/Content.xml 是版面文本（TextObject + Boundary 坐标）。
-- @source: original（duckdb-luajit 系列）
-- @requires: zlib（Linux/macOS 内置 libz；Windows 需 zlib1.dll）——zip 解压逻辑内嵌，零库依赖
-- ⚠️ 需普通模式（非 trusted）：io.open 读文件
--
-- Usage (duckdb-luajit):
--   install:     SELECT * FROM luajit_module(mode:='install', sql_name:='inv_ofd');
--   元数据（标量，返回 JSON 字符串，交给 json_extract 展开）：
--     SELECT luajit_s('inv_ofd', {'op':'meta', 'file':'/tmp/invoice.ofd'});
--     → {"发票号码":"...","合计税额":"5.17","合计金额":"172.37","开票日期":"2026年06月11日",...}
--   版面文本行（表函数：按 y 坐标聚类还原发票行，行内按 x 排序）：
--     SELECT * FROM luajit_table('inv_ofd', list := '/tmp/invoice.ofd');
--     → 列: y(double) | text(varchar)
--
-- 设计要点：OFD 是版式格式，结构化字段在配套 XML 发票文件里；本库解决「只有 OFD 也能读」——
-- 元数据直接可用，明细行文本可按「购买方/销售方/价税合计」标签文本二次匹配提取。

local ffi = require('ffi')

-- ============ FFI: zlib（raw deflate 解压） ============
ffi.cdef[[
  typedef unsigned char Bytef;
  typedef unsigned int  uInt;
  typedef unsigned long uLong;

  typedef struct z_stream_s {
    Bytef *next_in;
    uInt avail_in;
    uLong total_in;

    Bytef *next_out;
    uInt avail_out;
    uLong total_out;

    char *msg;
    struct internal_state *state;

    void *zalloc;
    void *zfree;
    void *opaque;

    int data_type;
    uLong adler;
    uLong reserved;
  } z_stream;

  const char *zlibVersion(void);
  int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
  int inflate(z_stream *strm, int flush);
  int inflateEnd(z_stream *strm);
]]

local Z
for _, lib in ipairs({ 'z', 'zlib1' }) do
  local ok, l = pcall(ffi.load, lib)
  if ok and l.inflate then Z = l break end
end
if not Z then
  error('inv_ofd: cannot load zlib (Linux/macOS built-in; Windows: zlib1.dll into PATH)')
end

local Z_OK, Z_STREAM_END, Z_FINISH = 0, 1, 4

local u16 = function(b, p) return b:byte(p) + b:byte(p + 1) * 256 end
local u32 = function(b, p)
  return b:byte(p) + b:byte(p + 1) * 256 + b:byte(p + 2) * 65536 + b:byte(p + 3) * 16777216
end

-- ============ zip 读取：找条目 → 解压（内嵌，零库依赖） ============
local function find_eocd(d, fsize)
  local start = fsize - 65536
  if start < 0 then start = 0 end
  local tail = d:sub(start + 1)
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == 'PK\5\6' then return start + i - 1 end
  end
  return nil
end

local function inflate_raw(data, expected_size)
  local strm = ffi.new('z_stream[1]')
  local r = Z.inflateInit2_(strm, -15, ffi.string(Z.zlibVersion()), ffi.sizeof('z_stream'))
  if r ~= Z_OK then return nil, 'inflateInit2 failed: ' .. r end
  local in_len = #data
  local inbuf = ffi.new('char[?]', in_len > 0 and in_len or 1)
  if in_len > 0 then ffi.copy(inbuf, data, in_len) end
  local cap = expected_size > 0 and (expected_size + 64) or (in_len * 4 + 1024)
  local outbuf = ffi.new('char[?]', cap)
  strm[0].next_in = inbuf
  strm[0].avail_in = in_len
  strm[0].next_out = outbuf
  strm[0].avail_out = cap
  local loop = 0
  while true do
    r = Z.inflate(strm[0], Z_FINISH)
    loop = loop + 1
    if r == Z_STREAM_END then break end
    if r ~= Z_OK and r ~= -5 then
      Z.inflateEnd(strm[0])
      return nil, 'inflate error: ' .. r
    end
    if loop > 4 then break end
  end
  local total = cap - strm[0].avail_out
  Z.inflateEnd(strm[0])
  return ffi.string(outbuf, total)
end

-- 在 zip 里找 name 条目并解压；返回内容或 nil, errmsg
local function zip_read(d, fsize, wanted)
  if fsize < 22 or d:sub(1, 2) ~= 'PK' then return nil, 'not a zip file' end
  local eocd = find_eocd(d, fsize)
  if not eocd then return nil, 'no EOCD' end
  local total = u16(d, eocd + 11)
  local cd_offset = u32(d, eocd + 17)
  if total == 0 or cd_offset == 0 or cd_offset > fsize then return nil, 'empty central dir' end
  local pos = cd_offset + 1
  for _ = 1, total do
    if pos + 46 > fsize or d:sub(pos, pos + 3) ~= 'PK\1\2' then break end
    local method = u16(d, pos + 10)
    local comp = u32(d, pos + 20)
    local uncomp = u32(d, pos + 24)
    local nlen = u16(d, pos + 28)
    local elen = u16(d, pos + 30)
    local clen = u16(d, pos + 32)
    local name = d:sub(pos + 46, pos + 45 + nlen)
    if name == wanted then
      local local_offset = u32(d, pos + 42)
      if local_offset + 30 > fsize or d:sub(local_offset + 1, local_offset + 4) ~= 'PK\3\4' then
        return nil, 'bad local header for ' .. name
      end
      local lnlen = u16(d, local_offset + 27)
      local lelen = u16(d, local_offset + 29)
      local data_off = local_offset + 30 + lnlen + lelen
      if data_off + comp > fsize then return nil, 'compressed data out of range' end
      local raw = d:sub(data_off + 1, data_off + comp)
      if method == 0 then return raw end
      if method == 8 then return inflate_raw(raw, uncomp) end
      return nil, 'unsupported zip method: ' .. method
    end
    pos = pos + 46 + nlen + elen + clen
  end
  return nil, 'entry not found: ' .. tostring(wanted)
end

-- ============ OFD.xml 元数据（CustomDatas） ============
local function json_escape(s)
  return (s:gsub('[%c\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\r' then return '\\r' end
    if c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end))
end

-- 提取 <ofd:CustomData Name="...">value</ofd:CustomData> → JSON 对象
local function meta_json(ofd_xml)
  local fields = {}
  for name, value in ofd_xml:gmatch('CustomData Name="([^"]*)"%s*>%s*([^<]*)%s*<') do
    fields[#fields + 1] = '"' .. json_escape(name) .. '":"' .. json_escape(value) .. '"'
  end
  return '{' .. table.concat(fields, ',') .. '}'
end

-- ============ Content.xml 版面文本行 ============
-- 提取所有 TextObject：Boundary="x y w h" + 内部 TextCode 的 CDATA 文本（find 定位，跨行安全）
local function extract_text_rows(content_xml)
  local objs = {}
  local pos = 1
  while true do
    local ts = content_xml:find('<ofd:TextObject', pos)
    if not ts then break end
    local te = content_xml:find('</ofd:TextObject>', ts)
    if not te then break end
    local block = content_xml:sub(ts, te + 17)
    local boundary = block:match('Boundary="([^"]+)"')
    local x, y
    if boundary then
      local x1 = boundary:match('(%S+)')
      local y1 = boundary:match('%S+%s+(%S+)')
      x, y = tonumber(x1), tonumber(y1)
    end
    -- CDATA 内容（find 定位，不受 Lua pattern 跨行限制）
    local texts = {}
    local p = 1
    while true do
      local a = block:find('<!%[CDATA%[', p)
      if not a then break end
      local b = block:find('%]%]>', a)
      if not b then break end
      texts[#texts + 1] = block:sub(a + 9, b - 1)
      p = b + 3
    end
    local text = table.concat(texts, '')
    if x and y and text ~= '' then
      objs[#objs + 1] = { x = x, y = y, text = text }
    end
    pos = te + 17
  end

  -- 按 y 聚类成行（同页 y 坐标相近归一行），行内按 x 排序拼接
  table.sort(objs, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  local rows = {}
  local cur_y, cur_text, cur_x
  for _, o in ipairs(objs) do
    if cur_y ~= nil and math.abs(o.y - cur_y) < 1.5 then
      if o.x < cur_x then
        cur_text = o.text .. cur_text
      else
        cur_text = cur_text .. o.text
      end
      cur_x = math.min(o.x, cur_x)
    else
      if cur_y ~= nil then rows[#rows + 1] = { cur_y, cur_text } end
      cur_y, cur_text, cur_x = o.y, o.text, o.x
    end
  end
  if cur_y ~= nil then rows[#rows + 1] = { cur_y, cur_text } end
  return rows
end

-- ============ 入口 ============
-- 标量（luajit_s）：{op:'meta', file} → JSON（发票元数据）
-- 表函数（luajit_table，list 逗号分隔多文件）：每文件 → 'y|text' 竖线行（DuckDB 拆两列）
local function load(path)
  local f = io.open(path, 'rb')
  if not f then return nil, 'cannot open ' .. path end
  local d = f:read('*a')
  f:close()
  return d, #d
end

local fn = function(p)
  if type(p) ~= 'table' then return 'error: inv_ofd expects a struct' end
  local d, err = load(p.file)
  if not d then return 'error: ' .. tostring(err) end
  if p.op == 'meta' then
    local ofd_xml, e = zip_read(d, #d, 'OFD.xml')
    if not ofd_xml then return 'error: ' .. tostring(e) end
    return meta_json(ofd_xml)
  end
  return 'error: unknown op ' .. tostring(p.op or '')
end

return function(list)
  -- 表函数形态：list = 逗号分隔 ofd 路径（DuckDB luajit_table 传字符串）；
  -- 标量形态：quick_compile 注册后 luajit_s 传 struct（table）→ fn 处理。
  if type(list) == 'table' then
    return fn(list)
  end
  local rows = {}
  local files = {}
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
  else
    -- 与 dicom/zip_list 同约定：无参时扫描默认目录（供 quick_compile 探测样例行）
    local h = io.popen('ls /tmp/ofd-files/*.ofd 2>/dev/null')
    for line in h:lines() do files[#files + 1] = line end
    h:close()
  end
  for _, path in ipairs(files) do
    local d, err = load(path)
    if d then
      local content_xml, e2 = zip_read(d, #d, 'Doc_0/Pages/Page_0/Content.xml')
      if content_xml then
        local r = extract_text_rows(content_xml)
        for _, row in ipairs(r) do
          rows[#rows + 1] = string.format('%g|%s', row[1], row[2])
        end
      end
    end
  end
  return rows
end
