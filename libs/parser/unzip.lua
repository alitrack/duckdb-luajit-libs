-- @lib: unzip
-- @category: parser
-- @desc: ZIP 解压指定文件（deflate 解压，FFI 调 zlib inflate）——DuckDB 无内建 zip 解压，
--        OFD/EPUB/DOCX/xlsx 等 zip 容器格式读取的第一步
-- @source: original（duckdb-luajit 系列）
-- @requires: zlib（Linux/macOS 内置 libz；Windows 常见 zlib1.dll）
-- ⚠️ 需普通模式（非 trusted）：io.open 读文件
--
-- Usage (duckdb-luajit):
--   install:     SELECT * FROM luajit_module(mode:='install', sql_name:='unzip');
--   call:        SELECT luajit_s('unzip', {'file':'/path/a.zip', 'name':'Doc_0/Pages/Page_0/Content.xml'});
--   → 解压内容（文本假定 UTF-8；二进制内容请用 mode='blob' 经 BLOB 桥）
--
-- 设计要点：中央目录条目提供 uncompressed size → 一次性分配输出缓冲，
-- raw inflate（windowBits=-15）解 zip 内的 deflate 流（zip 存的是 raw deflate，无 zlib 头）。

local ffi = require('ffi')

-- ============ FFI: zlib ============
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
  error('unzip: cannot load zlib (Linux/macOS built-in; Windows: zlib1.dll into PATH)')
end

local Z_STREAM_END = 1
local Z_FINISH = 4
local Z_OK = 0
local Z_BUF_ERROR = -5

local u16 = function(b, p) return b:byte(p) + b:byte(p + 1) * 256 end
local u32 = function(b, p)
  return b:byte(p) + b:byte(p + 1) * 256 + b:byte(p + 2) * 65536 + b:byte(p + 3) * 16777216
end

-- Find End Of Central Directory (EOCD): signature PK\x05\x06, scan last 64KB
local function find_eocd(d, fsize)
  local start = fsize - 65536
  if start < 0 then start = 0 end
  local tail = d:sub(start + 1)
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == 'PK\5\6' then return start + i - 1 end
  end
  return nil
end

-- raw deflate 解压（windowBits=-15）
local function inflate_raw(data, expected_size)
  local strm = ffi.new('z_stream[1]')
  local ver = ffi.string(Z.zlibVersion())
  local r = Z.inflateInit2_(strm, -15, ver, ffi.sizeof('z_stream'))
  if r ~= Z_OK then return nil, 'inflateInit2 failed: ' .. r end

  local in_len = #data
  local inbuf = ffi.new('char[?]', in_len > 0 and in_len or 1)
  if in_len > 0 then ffi.copy(inbuf, data, in_len) end

  -- 输出缓冲：中央目录声明的原始大小 + 富余（声明 0 或不可信时给 4 倍兜底）
  local cap = expected_size > 0 and (expected_size + 64) or (in_len * 4 + 1024)
  local outbuf = ffi.new('char[?]', cap)
  local out_cap = cap

  strm[0].next_in = inbuf
  strm[0].avail_in = in_len
  strm[0].next_out = outbuf
  strm[0].avail_out = out_cap

  local loop = 0
  while true do
    r = Z.inflate(strm[0], Z_FINISH)
    loop = loop + 1
    if r == Z_STREAM_END then break end
    if r ~= Z_OK and r ~= Z_BUF_ERROR then
      Z.inflateEnd(strm[0])
      return nil, 'inflate error: ' .. r
    end
    if loop > 4 then break end -- 缓冲不足（理论不该：cap 已按声明分配）
  end
  local total = out_cap - strm[0].avail_out
  Z.inflateEnd(strm[0])
  return ffi.string(outbuf, total)
end

-- 解析中央目录找目标条目 → 本地文件头 → 解压
local function unzip_file(path, wanted)
  local f = io.open(path, 'rb')
  if not f then return nil, 'cannot open ' .. path end
  local d = f:read('*a')
  f:close()
  local fsize = #d
  if fsize < 22 or d:sub(1, 2) ~= 'PK' then return nil, 'not a zip file' end
  local eocd = find_eocd(d, fsize)
  if not eocd then return nil, 'no EOCD' end
  local total = u16(d, eocd + 11)
  local cd_offset = u32(d, eocd + 17)
  if total == 0 or cd_offset == 0 or cd_offset > fsize then return nil, 'empty central dir' end

  local pos = cd_offset + 1
  for _ = 1, total do
    if pos + 46 > fsize or d:sub(pos, pos + 3) ~= 'PK\1\2' then break end
    -- Central dir entry（1-based pos 指 sig 首字节）:
    --  [4B sig][2B ver_made][2B ver_need][2B flags][2B method][2B time][2B date]
    --  [4B crc][4B comp][4B uncomp][2B name_len][2B extra_len][2B comment_len]
    --  [2B disk_start][2B int_attr][4B ext_attr][4B local_offset][name]
    local method = u16(d, pos + 10)
    local comp = u32(d, pos + 20)
    local uncomp = u32(d, pos + 24)
    local nlen = u16(d, pos + 28)
    local elen = u16(d, pos + 30)
    local clen = u16(d, pos + 32)
    local name = d:sub(pos + 46, pos + 45 + nlen)
    if name == wanted then
      local local_offset = u32(d, pos + 42)
      -- 本地文件头: [4B sig][2B ver][2B flags][2B method][2B time][2B date]
      --           [4B crc][4B comp][4B uncomp][2B name_len][2B extra_len]
      if local_offset + 30 > fsize or d:sub(local_offset + 1, local_offset + 4) ~= 'PK\3\4' then
        return nil, 'bad local header for ' .. name
      end
      local lnlen = u16(d, local_offset + 27)
      local lelen = u16(d, local_offset + 29)
      local data_off = local_offset + 30 + lnlen + lelen
      if data_off + comp > fsize then return nil, 'compressed data out of range' end
      local raw = d:sub(data_off + 1, data_off + comp)
      if method == 0 then
        return raw -- stored：直接返回
      elseif method == 8 then
        return inflate_raw(raw, uncomp)
      else
        return nil, 'unsupported zip method: ' .. method .. ' (need deflate=8 or stored=0)'
      end
    end
    pos = pos + 46 + nlen + elen + clen
  end
  return nil, 'entry not found: ' .. tostring(wanted)
end

-- ============ UDF 入口 ============
return function(p)
  if type(p) ~= 'table' then return 'error: unzip expects a struct {file, name}' end
  local content, err = unzip_file(p.file, p.name)
  if not content then return 'error: ' .. tostring(err) end
  return content
end
