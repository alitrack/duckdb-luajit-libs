-- @lib: zip_list
-- @category: parser
-- @desc: ZIP 中央目录文件清单（文件名|压缩方法|压缩大小|原始大小|CRC32），无需解压
-- @source: original（duckdb-luajit 系列）
-- @requires: none
-- Usage (luajit_table, table mode): source returns function(list_str) → rows[]
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='zip_list');
--   call:    SELECT * FROM luajit_table('zip_list', list := '/path/a.zip');
-- Row format: name|method|comp_size|uncomp_size|crc32_hex

local u16 = function(b, p) return b:byte(p) + b:byte(p + 1) * 256 end
local u32 = function(b, p)
  return b:byte(p) + b:byte(p + 1) * 256 + b:byte(p + 2) * 65536 + b:byte(p + 3) * 16777216
end

local METHODS = {
  [0] = 'stored', [1] = 'shrink', [6] = 'implode', [8] = 'deflate',
  [9] = 'deflate64', [12] = 'bzip2', [14] = 'lzma', [93] = 'zstd',
  [95] = 'xz', [98] = 'ppmd',
}

-- Find End Of Central Directory (EOCD): signature PK\x05\x06, scan last 64KB
local function find_eocd(d, fsize)
  local start = fsize - 65536
  if start < 0 then start = 0 end
  local tail = d:sub(start + 1)
  -- search from the end (comment can contain the signature)
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == 'PK\5\6' then return start + i - 1 end
  end
  return nil
end

local function parse(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  local fsize = #d
  if fsize < 22 or d:sub(1, 2) ~= 'PK' then return nil end
  local eocd = find_eocd(d, fsize)
  if not eocd then return nil end
  -- EOCD: [4B sig][2B disk][2B cd_disk][2B entries_disk][2B total_entries]
  --       [4B cd_size][4B cd_offset][2B comment_len]
  local total = u16(d, eocd + 11)
  local cd_offset = u32(d, eocd + 17)
  if total == 0 or cd_offset == 0 or cd_offset > fsize then return {} end
  local rows = {}
  local pos = cd_offset + 1
  for _ = 1, total do
    if pos + 46 > fsize or d:sub(pos, pos + 3) ~= 'PK\1\2' then break end
    -- Central dir entry: [4B sig][2B ver_made][2B ver_need][2B flags]
    --  [2B method][2B time][2B date][4B crc][4B comp][4B uncomp]
    --  [2B name_len][2B extra_len][2B comment_len][2B disk_start]
    --  [2B int_attr][4B ext_attr][4B local_offset][name]
    local method = u16(d, pos + 11)
    local crc = u32(d, pos + 17)
    local comp = u32(d, pos + 21)
    local uncomp = u32(d, pos + 25)
    local nlen = u16(d, pos + 29)
    local elen = u16(d, pos + 31)
    local clen = u16(d, pos + 33)
    local name = d:sub(pos + 47, pos + 46 + nlen)
    rows[#rows + 1] = table.concat({
      name, METHODS[method] or tostring(method),
      tostring(comp), tostring(uncomp), string.format('%08X', crc),
    }, '|')
    pos = pos + 46 + nlen + elen + clen
  end
  return rows
end

return function(list)
  local rows = {}
  local files = {}
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
  else
    local h = io.popen('ls /tmp/zip-files/*.zip 2>/dev/null')
    for line in h:lines() do files[#files + 1] = line end
    h:close()
  end
  for i = 1, #files do
    local r = parse(files[i])
    if r then for j = 1, #r do rows[#rows + 1] = r[j] end end
  end
  return rows
end
