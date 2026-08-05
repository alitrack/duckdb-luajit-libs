-- @lib: crc32
-- @category: udf
-- @desc: CRC-32 校验和（IEEE 802.3，LuaJIT bit 查表法，返回 8 位十六进制大写）
-- @source: original（duckdb-luajit 系列；标准 CRC-32 算法，查表法）
-- @requires: LuaJIT bit 库（duckdb-luajit 环境必有）
-- Usage (duckdb-luajit):
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='crc32');
--   call:    SELECT luajit_s('crc32', 'hello');   -- → 3610A686
local bit = require('bit')
local bxor, band, rshift = bit.bxor, bit.band, bit.rshift

-- build CRC-32 table (polynomial 0xEDB88320)
local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if band(c, 1) == 1 then
      c = bxor(rshift(c, 1), 0xEDB88320)
    else
      c = rshift(c, 1)
    end
  end
  crc_table[i] = c
end

return function(s)
  if type(s) ~= 'string' then return '' end
  local crc = 0xFFFFFFFF
  for i = 1, #s do
    crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, s:byte(i)), 0xFF)])
  end
  crc = bxor(crc, 0xFFFFFFFF)
  -- format as 8-digit uppercase hex (LuaJIT %08X handles int32)
  return string.format('%08X', crc)
end
