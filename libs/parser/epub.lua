-- @lib: epub
-- @category: parser
-- @desc: EPUB 电子书解析（纯 Lua + zlib inflate，自包含）——EPUB 是 zip 容器，
--       DuckDB 无内建 EPUB/zip 读取。本库内嵌 zip 中央目录 + raw inflate
--       （逐字移植自本系列已验证的 unzip.lua），并做命名空间容忍的 XML 抽取
--       （OPF / NCX / container），返回 JSON（配 json_extract）。
--       op 选项：
--         'metadata' → {title, creators[], language, identifier, publisher, date, version, cover_href}
--         'toc'      → [{play_order, label, href}]（EPUB2 NCX navPoint；EPUB3 找 nav type=toc）
--         'text'     → 需 href：该章节去标签纯文本
--         'info'     → {opf_path, version, doc_count}
--       流程：container.xml 定位 OPF → 解析 metadata/manifest/spine → 目录/正文按 OPF 目录拼接相对路径。
--       诚实边界：deflate(8)/stored(0) 两种 zip 方法；不处理加密 EPUB；单 OPF 包；
--       XML 抽取是针对性解析（非完整 XML 引擎），异常嵌套/CDATA 复杂结构可能漏。
-- @source: 自包含（zip/inflate 逐字移植自 libs/parser/unzip.lua；XML 抽取参考 xml.lua 思路）
-- @requires: zlib（Linux/macOS 内置；Windows zlib1.dll 入 PATH）。需普通模式（读文件）。
--
-- Usage (duckdb-luajit):
--   元数据:  SELECT luajit_s('epub', {file: '/x/book.epub', op: 'metadata'});
--   目录:    SELECT luajit_s('epub', {file: '/x/book.epub', op: 'toc'});
--   正文:    SELECT luajit_s('epub', {file: '/x/book.epub', op: 'text', href: 'text/ch1.xhtml'});
--   抽取:    SELECT json_extract(luajit_s('epub',{file:=f,op:='metadata'}), '$.title');

local ffi = require('ffi')

-- ======================================================================
-- FFI: zlib raw deflate（windowBits=-15）—— 逐字同 unzip.lua
-- ======================================================================
ffi.cdef[[
  typedef unsigned char Bytef;
  typedef unsigned int  uInt;
  typedef unsigned long uLong;
  typedef struct z_stream_s {
    Bytef *next_in; uInt avail_in; uLong total_in;
    Bytef *next_out; uInt avail_out; uLong total_out;
    char *msg; struct internal_state *state;
    void *zalloc; void *zfree; void *opaque;
    int data_type; uLong adler; uLong reserved;
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
if not Z then error('epub: cannot load zlib (Windows: zlib1.dll into PATH)') end
local Z_STREAM_END, Z_FINISH, Z_OK, Z_BUF_ERROR = 1, 4, 0, -5

local u16 = function(b, p) return b:byte(p) + b:byte(p + 1) * 256 end
local u32 = function(b, p)
  return b:byte(p) + b:byte(p + 1) * 256 + b:byte(p + 2) * 65536 + b:byte(p + 3) * 16777216
end

-- raw deflate 解压（windowBits=-15）—— 逐字同 unzip.lua
local function inflate_raw(data, expected_size)
  local strm = ffi.new('z_stream[1]')
  local ver = ffi.string(Z.zlibVersion())
  local r = Z.inflateInit2_(strm, -15, ver, ffi.sizeof('z_stream'))
  if r ~= Z_OK then return nil, 'inflateInit2 failed: ' .. r end
  local in_len = #data
  local inbuf = ffi.new('char[?]', in_len > 0 and in_len or 1)
  if in_len > 0 then ffi.copy(inbuf, data, in_len) end
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
    if loop > 4 then break end
  end
  local total = out_cap - strm[0].avail_out
  Z.inflateEnd(strm[0])
  return ffi.string(outbuf, total)
end

-- 读 zip 内指定条目 → 解压内容。成功返回单值 content；失败返回 nil, err。
-- 逻辑逐字同 unzip.lua unzip_file（注意：成功路径只有 1 个返回值）。
local function zip_entry(d, fsize, wanted)
  if fsize < 22 or d:sub(1, 2) ~= 'PK' then return nil, 'not a zip/epub' end
  local start = fsize - 65536
  if start < 0 then start = 0 end
  local tail = d:sub(start + 1)
  local eocd
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == 'PK\5\6' then eocd = start + i - 1 break end
  end
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
      if method == 0 then
        return raw
      elseif method == 8 then
        return inflate_raw(raw, uncomp)
      else
        return nil, 'unsupported zip method: ' .. method
      end
    end
    pos = pos + 46 + nlen + elen + clen
  end
  return nil, 'entry not found: ' .. tostring(wanted)
end

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
local function jencode(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v % 1 == 0 and math.abs(v) < 1e15 then return string.format('%d', v) end
    return tostring(v)
  end
  if t == 'string' then return '"' .. json_escape(v) .. '"' end
  if t == 'table' then
    local isarr = true
    for k in pairs(v) do if type(k) ~= 'number' then isarr = false break end end
    if isarr and #v == 0 then return '[]' end
    if isarr then
      local p = {} for i = 1, #v do p[#p + 1] = jencode(v[i]) end
      return '[' .. table.concat(p, ',') .. ']'
    end
    local p = {}
    for k, val in pairs(v) do p[#p + 1] = '"' .. json_escape(tostring(k)) .. '":' .. jencode(val) end
    return '{' .. table.concat(p, ',') .. '}'
  end
  return 'null'
end

-- ======================================================================
-- 命名空间容忍的 XML 工具（针对 OPF/NCX/container 的已知结构）
-- ======================================================================
-- 取某本地标签 <...name>text</...name> 的后代文本列表（跨命名空间：dc:title / title 都匹配）
-- 关键点：开、闭标签都可能带命名空间前缀（<dc:title>...</dc:title>），闭标签不能假设无前缀。
local function tag_all(xml, name)
  local out = {}
  local function collect(pat)
    for body in xml:gmatch(pat) do
      local t = body:gsub('<[^>]+>', ''):match('^%s*(.-)%s*$')
      if t and t ~= '' then out[#out + 1] = t end
    end
  end
  -- 命名空间形式：<dc:title>x</dc:title>（开闭都带前缀）
  collect('<[%a.]*:' .. name .. '[^>]*>-.-</[%a.]*:' .. name .. '[^>]*>')
  -- 无前缀形式：<title>x</title>（<title 不会误匹配 <dc:title，因其前是 ':' 非 '<'）
  collect('<' .. name .. '[^>]*>-.-</' .. name .. '[^>]*>')
  return out
end
local function tag_one(xml, name)
  local all = tag_all(xml, name)
  return all[1] or ''
end

-- 定位 OPF（container.xml → full-path）
local function find_opf(zbuf, fsize)
  local cont = zip_entry(zbuf, fsize, 'META-INF/container.xml')
  if not cont then
    for _, cand in ipairs({ 'OEBPS/content.opf', 'content.opf', 'OPS/content.opf' }) do
      if zip_entry(zbuf, fsize, cand) then return cand end
    end
    return nil, 'cannot locate container.xml / OPF'
  end
  local path = cont:match('full%-path%s*=%s*"([^"]*)"')
    or cont:match("full%-path%s*=%s*'([^']*)'")
  if not path then return nil, 'no full-path in container.xml' end
  return path
end

-- OPF 所在目录（不带尾斜杠）：OEBPS/content.opf → OEBPS
local function opf_dir(opf_path)
  local d = opf_path:match('^(.*)/[^/]+$')
  return (d or '')
end
-- 拼接 OPF 目录 + 相对 href（补斜杠，去重）
local function join_path(dir, href)
  if href:match('^/') then return href end          -- 已是绝对
  if dir == '' then return href end
  if dir:sub(-1) == '/' then return dir .. href end
  return dir .. '/' .. href
end

local function read_all(p)
  local f = io.open(p.file, 'rb')
  if not f then return nil, 'cannot open ' .. p.file end
  local d = f:read('*a'); f:close()
  return d
end

-- 载入 OPF 上下文（zbuf/fsize/opf_path/opf/dir）
local function ensure_opf(p)
  local zbuf = read_all(p)
  if not zbuf then return nil, 'cannot open ' .. p.file end
  local opf_path, err = find_opf(zbuf, #zbuf)
  if not opf_path then return nil, err end
  local opf = zip_entry(zbuf, #zbuf, opf_path)
  if not opf then return nil, 'cannot read OPF ' .. opf_path end
  return { zbuf = zbuf, fsize = #zbuf, opf_path = opf_path, opf = opf, dir = opf_dir(opf_path) }
end

-- ======================================================================
-- 各 op
-- ======================================================================
local function op_metadata(ctx)
  local opf = ctx.opf
  local meta = {}
  meta.title = tag_one(opf, 'title')
  meta.creators = tag_all(opf, 'creator')
  if #meta.creators == 0 then meta.creators = { tag_one(opf, 'author') } end
  meta.language = tag_one(opf, 'language')
  meta.identifier = tag_one(opf, 'identifier')
  meta.publisher = tag_one(opf, 'publisher')
  meta.date = tag_one(opf, 'date')
  meta.version = opf:match('<package[^>]*version%s*=%s*"([%d%.]+)"') or ''
  -- cover：OPF2 <meta name="cover-id" content="ID"/>；OPF3 <meta name="cover" content="href"/>
  local cover_href
  for m in opf:gmatch('<meta[^>]*>') do
    local nm = m:match('name%s*=%s*"([^"]*)"')
    local ct = m:match('content%s*=%s*"([^"]*)"')
    if nm == 'cover' and not cover_href then cover_href = ct end
    if nm == 'cover-id' and ct then
      for blk in opf:gmatch('<item[^>]*>') do
        local id = blk:match('id%s*=%s*"([^"]*)"')
        if id == ct then cover_href = blk:match('href%s*=%s*"([^"]*)"') break end
      end
    end
  end
  meta.cover_href = cover_href
  return jencode(meta)
end

local function op_toc(ctx)
  local out = {}
  -- 优先 EPUB2 NCX：manifest 里 media-type 含 dtbncx
  local ncx_href
  for href, mt in ctx.opf:gmatch('<item[^>]*href%s*=%s*"([^"]*)"[^>]*media%-type%s*=%s*"([^"]*)"') do
    if mt:find('dtbncx') then ncx_href = href end
  end
  if ncx_href then
    local ncx = zip_entry(ctx.zbuf, ctx.fsize, join_path(ctx.dir, ncx_href))
    if ncx then
      local i = 0
      ncx:gsub('<navPoint[^>]*>.-</navPoint>', function(block)
        i = i + 1
        local po = block:match('playOrder%s*=%s*"([0-9]+)"')
        local txt = block:match('<text[^>]*>.-</text>')
        local src = block:match('<content[^>]*src%s*=%s*"([^"]*)"')
        if txt then txt = txt:gsub('<[^>]+>', ''):match('^%s*(.-)%s*$') end
        if src then
          out[#out + 1] = { play_order = po and tonumber(po) or i, label = txt or '', href = src }
        end
      end)
    end
  end
  if #out == 0 then
    -- EPUB3：找 nav type=toc 的 XHTML
    for id, href, mt in ctx.opf:gmatch('<item[^>]*id%s*=%s*"([^"]*)"[^>]*href%s*=%s*"([^"]*)"[^>]*media%-type%s*=%s*"([^"]*)"') do
      local nav = zip_entry(ctx.zbuf, ctx.fsize, join_path(ctx.dir, href))
      if nav and nav:find('epub:type%s*=%s*"toc"') then
        local i = 0
        nav:gsub('<a[^>]*>.-</a>', function(a)
          local src = a:match('href%s*=%s*"([^"]*)"')
          local label = a:gsub('<[^>]+>', ''):match('^%s*(.-)%s*$')
          if src then
            i = i + 1
            out[#out + 1] = { play_order = i, label = label or '', href = src }
          end
        end)
        break
      end
    end
  end
  return jencode(out)
end

local function op_text(ctx, p)
  local href = p.href
  if not href then return '{"error":"text op needs href"}' end
  local candidates = { join_path(ctx.dir, href), href }
  for _, path in ipairs(candidates) do
    local xhtml = zip_entry(ctx.zbuf, ctx.fsize, path)
    if xhtml then
      local t = xhtml
      t = t:gsub('<head[^>]*>.-</head>', '')          -- 去 head（含 <title>，避免重复）
      t = t:gsub('<(script|style)[^>]*>.-</%1>', '')
      t = t:gsub('<br[^>]*>', '\n')
      t = t:gsub('</(p|h[1-6]|li|div|blockquote)>', '\n')
      t = t:gsub('<[^>]+>', '')
      t = t:gsub('&nbsp;', ' '):gsub('&amp;', '&'):gsub('&lt;', '<')
             :gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', "'")
      t = t:gsub('%s+', ' '):match('^%s*(.-)%s*$')
      return t
    end
  end
  return '{"error":"cannot read ' .. json_escape(href) .. '"}'
end

local function op_info(ctx)
  local doc_count = 0
  for _ in ctx.opf:gmatch('<itemref[^>]*>') do doc_count = doc_count + 1 end
  return jencode({
    opf_path = ctx.opf_path,
    version = ctx.opf:match('<package[^>]*version%s*=%s*"([%d%.]+)"') or '',
    doc_count = doc_count,
  })
end

local function run(p)
  if type(p) == 'string' then p = { file = p } end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local op = p.op or 'metadata'
  local ctx, err = ensure_opf(p)
  if not ctx then return '{"error":"' .. json_escape(tostring(err)) .. '"}' end
  if op == 'metadata' then return op_metadata(ctx)
  elseif op == 'toc' then return op_toc(ctx)
  elseif op == 'text' then return op_text(ctx, p)
  elseif op == 'info' then return op_info(ctx) end
  return '{}'
end

return function(p)
  return run(p)
end
