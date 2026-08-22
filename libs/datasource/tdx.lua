-- @lib: tdx
-- @category: datasource
-- @desc: 通达信（TDX）股票行情数据解析——.lc1（1分钟线）、.lc5（5分钟线）、.day（日线），32字节/记录，小端序
-- @source: original（duckdb-luajit 系列）
-- @requires: ffi（float32 reinterpret）
-- Usage (luajit_table, table mode): source returns function(list_str) → rows[]
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='tdx');
--   call:    SELECT * FROM luajit_table('tdx', list := '/path/sh000001.day');
-- Row format: datetime|open|high|low|close|volume|amount
--   datetime: 'YYYY-MM-DD HH:MM:SS'（分钟线）或 'YYYY-MM-DD'（日线）
--   open/high/low/close: FLOAT
--   volume: BIGINT（股数）
--   amount: DOUBLE（成交额，元）
-- SQL 展开：
--   SELECT split_part(val,'|',1) AS datetime,
--          split_part(val,'|',2)::FLOAT AS open,
--          split_part(val,'|',3)::FLOAT AS high,
--          split_part(val,'|',4)::FLOAT AS low,
--          split_part(val,'|',5)::FLOAT AS close,
--          split_part(val,'|',6)::BIGINT AS volume,
--          split_part(val,'|',7)::DOUBLE AS amount
--   FROM luajit_table('tdx', list := '/path/sh000001.day');

local ffi = require("ffi")

-- Little-endian uint16
local function u16(b, p)
  return b:byte(p) + b:byte(p + 1) * 256
end

-- Little-endian uint32
local function u32(b, p)
  return b:byte(p) + b:byte(p + 1) * 256 + b:byte(p + 2) * 65536 + b:byte(p + 3) * 16777216
end

-- Reinterpret 4 bytes as float32 (little-endian)
local f32_union = ffi.new("union { uint8_t b[4]; float f; }")
local function f32(b, p)
  f32_union.b[0] = b:byte(p)
  f32_union.b[1] = b:byte(p + 1)
  f32_union.b[2] = b:byte(p + 2)
  f32_union.b[3] = b:byte(p + 3)
  return f32_union.f
end

-- Detect file type by extension (case-insensitive)
local function detect_type(path)
  local ext = path:lower():sub(-4)
  if ext == '.lc1' then return 'LC1' end
  if ext == '.lc5' then return 'LC5' end
  if ext == '.day' then return 'DAY' end
  return nil
end

-- Decode .lc1/.lc5 timestamp: date = (year-2004)*2048 + month*100 + day, time = minutes from midnight
-- Returns 'YYYY-MM-DD HH:MM:SS'
local function decode_lc_ts(date_raw, time_raw)
  local year = math.floor(date_raw / 2048) + 2004
  local rem = date_raw % 2048
  local month = math.floor(rem / 100)
  local day = rem % 100
  local hour = math.floor(time_raw / 60)
  local min = time_raw % 60
  return string.format('%04d-%02d-%02d %02d:%02d:%02d', year, month, day, hour, min, 0)
end

-- Decode .day timestamp: date = YYYYMMDD
-- Returns 'YYYY-MM-DD'
local function decode_day_ts(date_raw)
  local year = math.floor(date_raw / 10000)
  local month = math.floor((date_raw % 10000) / 100)
  local day = date_raw % 100
  return string.format('%04d-%02d-%02d', year, month, day)
end

-- Parse a single file; returns array of pipe-delimited rows
local function parse(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()

  local fsize = #d
  if fsize < 32 or fsize % 32 ~= 0 then return nil end

  local ftype = detect_type(path)
  if not ftype then return nil end

  local n = math.floor(fsize / 32)
  local rows = {}
  local fmt = string.format

  if ftype == 'DAY' then
    for i = 0, n - 1 do
      local p = i * 32 + 1
      local date_raw = u32(d, p)
      local open_raw = u32(d, p + 4)
      local high_raw = u32(d, p + 8)
      local low_raw  = u32(d, p + 12)
      local close_ra = u32(d, p + 16)
      local amount   = f32(d, p + 20)
      local volume   = u32(d, p + 24)
      -- offset 28: unused
      rows[#rows + 1] = fmt('%s|%.4f|%.4f|%.4f|%.4f|%d|%.2f',
        decode_day_ts(date_raw),
        open_raw / 100.0, high_raw / 100.0, low_raw / 100.0, close_ra / 100.0,
        volume, amount)
    end
  else
    for i = 0, n - 1 do
      local p = i * 32 + 1
      local date_raw = u16(d, p)
      local time_raw = u16(d, p + 2)
      local open   = f32(d, p + 4)
      local high   = f32(d, p + 8)
      local low    = f32(d, p + 12)
      local close  = f32(d, p + 16)
      local amount = f32(d, p + 20)
      local volume = u32(d, p + 24)
      -- offset 28: unused
      rows[#rows + 1] = fmt('%s|%.4f|%.4f|%.4f|%.4f|%d|%.2f',
        decode_lc_ts(date_raw, time_raw),
        open, high, low, close, volume, amount)
    end
  end

  return rows
end

-- Entry point: list = comma-separated file paths
return function(list)
  local rows = {}
  local files = {}
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
  end
  for i = 1, #files do
    local r = parse(files[i])
    if r then
      for j = 1, #r do rows[#rows + 1] = r[j] end
    end
  end
  return rows
end