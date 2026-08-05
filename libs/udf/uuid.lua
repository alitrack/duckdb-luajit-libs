-- @lib: uuid
-- @category: udf
-- @desc: UUID v4 生成（纯 Lua，基于 math.random 的 122 位随机；非加密级）
-- @source: original（duckdb-luajit 系列）
-- @requires: LuaJIT bit 库
-- Usage (duckdb-luajit):
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='uuid');
--   call:    SELECT luajit_s('uuid', '');   -- → 550e8400-e29b-41d4-a716-446655440000
local bit = require('bit')
local band, bor = bit.band, bit.bor
local rand = math.random

return function()
  -- 16 random bytes; set version (0100) and variant (10xx) bits
  local hex = {}
  for i = 1, 16 do
    local x = rand(0, 255)
    if i == 7 then x = bor(band(x, 0x0F), 0x40) end   -- version 4
    if i == 9 then x = bor(band(x, 0x3F), 0x80) end   -- variant 10xx
    hex[i] = string.format('%02x', x)
  end
  return table.concat(hex, '', 1, 4) .. '-' .. table.concat(hex, '', 5, 6)
      .. '-' .. table.concat(hex, '', 7, 8) .. '-' .. table.concat(hex, '', 9, 10)
      .. '-' .. table.concat(hex, '', 11, 16)
end
