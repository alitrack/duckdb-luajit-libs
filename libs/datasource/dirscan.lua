-- @lib: dirscan
-- @category: datasource
-- @desc: 目录扫描——文件类型 magic + EXIF（Make/Model/DateTime）+ PDF /Info
-- @source: original（duckdb-luajit 系列）
-- @requires: none（io.popen 列目录，普通模式）
-- Directory metadata scanner for duckdb-luajit (LuaJIT 5.1, no string.unpack)
-- One flat "|"-joined row per file: path|type|size|exif_cam|exif_dt|pdf_title|pdf_author
-- File type via magic bytes; EXIF via JPEG APP1/TIFF IFD0; PDF via %PDF + tail /Info scan.
local function u16(d, p) return d:byte(p) + d:byte(p + 1) * 256 end
local function u32(d, p)
  return d:byte(p) + d:byte(p + 1) * 256 + d:byte(p + 2) * 65536 + d:byte(p + 3) * 16777216
end
local function clean(s)
  if not s then return '' end
  return (s:gsub('%z+$', ''):gsub('[|%z]+', ' '))
end

local function filetype(h)
  if not h or #h < 4 then return '' end
  local b1, b2, b3, b4 = h:byte(1), h:byte(2), h:byte(3), h:byte(4)
  if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E then return 'PNG' end
  if b1 == 0xFF and b2 == 0xD8 then return 'JPEG' end
  if b1 == 0x25 and b2 == 0x50 and b3 == 0x44 and b4 == 0x46 then return 'PDF' end
  if b1 == 0x50 and b2 == 0x4B and b3 == 0x03 and b4 == 0x04 then return 'ZIP' end
  if b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then return 'GIF' end
  if b1 == 0x7F and b2 == 0x45 and b3 == 0x4C and b4 == 0x46 then return 'ELF' end
  if b1 == 0x49 and b2 == 0x44 and b3 == 0x33 then return 'MP3' end
  if b1 == 0x42 and b2 == 0x4D then return 'BMP' end
  return '?'
end

-- EXIF: JPEG SOI(FFD8) → APP1(FFE1) → 'Exif\0\0' → TIFF (II/MM) → IFD0
local function exif(path)
  local f = io.open(path, 'rb')
  if not f then return '', '', '' end
  local d = f:read(131072)  -- header only (APP1 sits near the start)
  f:close()
  if not d then return '', '', '' end
  local pos = d:find('\xFF\xE1', 1, true)
  if not pos then return '', '', '' end
  local t = d:sub(pos + 4)
  if t:sub(1, 6) ~= 'Exif\0\0' then return '', '', '' end
  t = t:sub(7)
  local le = t:sub(1, 2) == 'II'
  local function U16(p) return le and u16(t, p) or (t:byte(p) * 256 + t:byte(p + 1)) end
  local function U32(p)
    if le then return u32(t, p) end
    return t:byte(p) * 16777216 + t:byte(p + 1) * 65536 + t:byte(p + 2) * 256 + t:byte(p + 3)
  end
  if U16(3) ~= 0x2A then return '', '', '' end
  local ifd0 = U32(5) + 1
  if ifd0 + 2 > #t then return '', '', '' end
  local n = U16(ifd0)
  local mk, cam, dt = '', '', ''
  for i = 1, n do
    local e = ifd0 + 2 + (i - 1) * 12
    if e + 12 > #t then break end
    local tag, typ = U16(e), U16(e + 2)
    local cnt, val = U32(e + 4), U32(e + 8)
    if tag == 0x010F and typ == 2 and cnt <= 64 then
      local s = t:sub(val + 1, val + cnt)
      if #s == cnt then mk = clean(s) end
    elseif tag == 0x0110 and typ == 2 and cnt <= 64 then
      local s = t:sub(val + 1, val + cnt)
      if #s == cnt then cam = clean(s) end
    elseif tag == 0x0132 and typ == 2 and cnt <= 32 then
      local s = t:sub(val + 1, val + cnt)
      if #s == cnt then dt = clean(s) end
    end
  end
  return mk, cam, dt
end

-- PDF: %PDF-x.y header + tail /Info scan (Title/Author/CreationDate)
local function pdfinfo(path)
  local f = io.open(path, 'rb')
  if not f then return '', '' end
  local head = f:read(1024) or ''
  f:seek('end', -4096)
  local tail = f:read(4096) or ''
  f:close()
  if not head:match('^%%PDF%-') then return '', '' end
  local function grab(patt)
    local v = tail:match(patt) or head:match(patt)
    if not v then return '' end
    v = v:gsub('%s+$', '')
    return v:gsub('[|%z]+', ' ')
  end
  local title = grab('/Title%s*%(([^%)]*)%)')
  local author = grab('/Author%s*%(([^%)]*)%)')
  return title, author
end

return function(list)
  local rows = {}
  local files = {}
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
  else
    local h = io.popen('ls /tmp/meta-files/*')
    for line in h:lines() do files[#files + 1] = line end
    h:close()
  end
  for i = 1, #files do
    local p = files[i]
    local f = io.open(p, 'rb')
    if f then
      local sz = f:seek('end')
      f:seek('set')
      local h = f:read(16)
      f:close()
      local t = filetype(h)
      if t == 'JPEG' then
        local mk, cam, dt = exif(p)
        rows[#rows + 1] = table.concat({ p, t, tostring(sz), mk, cam, dt, '', '' }, '|')
      elseif t == 'PDF' then
        local ttl, aut = pdfinfo(p)
        rows[#rows + 1] = table.concat({ p, t, tostring(sz), '', '', '', ttl, aut }, '|')
      else
        rows[#rows + 1] = table.concat({ p, t, tostring(sz), '', '', '', '', '' }, '|')
      end
    end
  end
  return rows
end
