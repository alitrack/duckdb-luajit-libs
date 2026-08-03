-- DICOM tag parser for duckdb-luajit (LuaJIT 5.1, no string.unpack)
-- Explicit VR Little Endian. Returns one flat "|"-joined row per file.
-- Usage (luajit_table, table mode): source returns function(list_str) → rows[]
local function u16(d, p) return d:byte(p) + d:byte(p + 1) * 256 end
local function u32(d, p) return d:byte(p) + d:byte(p + 1) * 256 + d:byte(p + 2) * 65536 + d:byte(p + 3) * 16777216 end

-- 19 tags mirrored from dicom-ducklink (group,elem)
local WANT = {
  ['00080020'] = 1, ['00080060'] = 1, ['00080080'] = 1, ['00081030'] = 1,
  ['00080018'] = 1, ['00100010'] = 1, ['00100020'] = 1, ['00100030'] = 1,
  ['00100040'] = 1, ['00180050'] = 1, ['0020000D'] = 1, ['0020000E'] = 1,
  ['00200013'] = 1, ['00280002'] = 1, ['00280010'] = 1, ['00280011'] = 1,
  ['00280100'] = 1, ['00280101'] = 1, ['7FE00010'] = 1,
}

local function parse(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  if #d < 132 or d:sub(129, 132) ~= 'DICM' then return nil end
  local pos, out = 133, {}
  local n = #d
  while pos + 8 <= n do
    local g, e = u16(d, pos), u16(d, pos + 2)
    pos = pos + 4
    local vr = d:sub(pos, pos + 1)
    pos = pos + 2
    local len
    if vr == 'OB' or vr == 'OW' or vr == 'OF' or vr == 'SQ' or vr == 'UT' or vr == 'UN' then
      pos = pos + 2
      len = u32(d, pos)
      pos = pos + 4
    else
      len = u16(d, pos)
      pos = pos + 2
    end
    if pos + len - 1 > n then break end
    local key = string.format('%04X%04X', g, e)
    if WANT[key] then
      local v = d:sub(pos, pos + len - 1)
      if vr == 'US' then
        v = tostring(u16(v, 1))            -- numeric decode (Rows/Columns/Bits...)
      elseif key == '7FE00010' then
        v = 'blob:' .. #v                  -- PixelData: length marker (text row)
      elseif vr == 'IS' then
        v = (v:gsub('%z+$', ''):gsub('%s+$', ''))
      else
        v = (v:gsub('%z+$', ''):gsub('%s+$', ''))
      end
      out[key] = v
    end
    pos = pos + len
    if len % 2 == 1 then pos = pos + 1 end
  end
  local parts = {
    out['00080020'] or '', out['00080060'] or '', out['00080080'] or '',
    out['00081030'] or '', out['00080018'] or '', out['00100010'] or '',
    out['00100020'] or '', out['00100030'] or '', out['00100040'] or '',
    out['00180050'] or '', out['0020000D'] or '', out['0020000E'] or '',
    out['00200013'] or '', out['00280002'] or '', out['00280010'] or '',
    out['00280011'] or '', out['00280100'] or '', out['00280101'] or '',
    out['7FE00010'] or '',
  }
  return table.concat(parts, '|')
end

return function(list)
  local rows = {}
  local files = {}
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
  else
    local h = io.popen('ls /tmp/dicom-files/*.dcm')
    for line in h:lines() do files[#files + 1] = line end
    h:close()
  end
  for i = 1, #files do
    local row = parse(files[i])
    if row then rows[#rows + 1] = row end
  end
  return rows
end
