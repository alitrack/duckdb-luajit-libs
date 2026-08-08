-- @lib: id3
-- @category: parser
-- @desc: MP3 ID3v2 标签解析（TIT2/TPE1/TALB/TYER/TRCK/TCON，ISO-8859-1/UTF-16/UTF-8），单文件→扁平行，目录→多行
-- @source: original（duckdb-luajit 系列）
-- @requires: none
-- Usage (luajit_table, table mode): source returns function(list_str) → rows[]
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='id3');
--   call:    SELECT * FROM luajit_table('id3', list := '/path/a.mp3,/path/b.mp3');
-- Row format: title|artist|album|year|track|genre

local function u32(b, p) return b:byte(p) + b:byte(p+1)*256 + b:byte(p+2)*65536 + b:byte(p+3)*16777216 end

-- ID3v2 syncsafe int: 4 bytes × 7 bits
local function syncsafe(b, p)
  return (b:byte(p)%128)*2097152 + (b:byte(p+1)%128)*16384 + (b:byte(p+2)%128)*128 + (b:byte(p+3)%128)
end

-- Strip encoding prefix byte + BOM + trailing NULs from a text frame payload
local function clean_text(d)
  if #d == 0 then return '' end
  local enc = d:byte(1)
  local t = d:sub(2)
  if enc == 1 or enc == 2 then -- UTF-16 (with/without BOM)
    if t:sub(1, 2) == '\255\254' or t:sub(1, 2) == '\254\255' then t = t:sub(3) end
    t = (t:gsub('\0\0+$', ''):gsub('\0', ''))  -- strip NUL bytes (ASCII subset)
  else -- ISO-8859-1 (0) or UTF-8 (3)
    t = (t:gsub('%z+$', ''))
  end
  return t
end

local function parse(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read(1048576)  -- ID3v2 header lives at file start, tags < 1MB typical
  f:close()
  if not d or d:sub(1, 3) ~= 'ID3' then return nil end
  local tagsize = syncsafe(d, 7)
  local pos = 11  -- header is 10 bytes; 2.4 extended header not handled
  local out = {}
  while pos + 10 <= #d and pos - 10 < tagsize do
    local fid = d:sub(pos, pos + 3)
    local fsize = syncsafe(d, pos + 4)
    if fsize == 0 or pos + 10 + fsize > #d then break end
    local data = d:sub(pos + 10, pos + 10 + fsize - 1)
    -- text frames start with encoding byte; only keep T*** text frames
    if fid:match('^T') and #data >= 1 then
      out[fid] = clean_text(data)
    end
    pos = pos + 10 + fsize
  end
  return table.concat({
    out['TIT2'] or '', out['TPE1'] or '', out['TALB'] or '',
    out['TYER'] or out['TDRC'] or '', out['TRCK'] or '', out['TCON'] or '',
  }, '|')
end

return function(list)
  local rows = {}
  local files = {}
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
  else
    local h = io.popen('ls /tmp/mp3-files/*.mp3 2>/dev/null')
    for line in h:lines() do files[#files + 1] = line end
    h:close()
  end
  for i = 1, #files do
    local row = parse(files[i])
    if row then rows[#rows + 1] = row end
  end
  return rows
end
