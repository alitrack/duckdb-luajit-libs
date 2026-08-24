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
-- 错误可见化：任何文件解析失败（路径错/文件缺失/扩展名非 .lc1/.lc5/.day/大小非 32 倍数）
--   会产出一行 "ERR: <原因> @ <path>|0|0|0|0|0|0"（字段2-7 为 0，::FLOAT 仍可转），
--   且全部失败时首行是 "ERR: 0/N files parsed" 汇总。所以聚合得 NULL 时 select *
--   即可看到原因，而非静默 0 行。注意 WSL 里路径须用 /mnt/d/…（正斜杠），D:\… 打不开。

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

-- Parse a single file; returns {ok=bool, rows=...|err=..., raw=size}
local function parse(path)
  local f = io.open(path, 'rb')
  if not f then
    return {ok = false, err = 'cannot open (path bad or file missing)'}
  end
  local d = f:read('*a')
  f:close()

  local fsize = #d
  local ftype = detect_type(path)
  if not ftype then
    return {ok = false, err = 'unsupported extension (expect .lc1/.lc5/.day)'}
  end
  if fsize < 32 or fsize % 32 ~= 0 then
    return {ok = false, err = string.format(
      'bad size %d bytes (must be a positive multiple of 32, 32B/record)', fsize)}
  end

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

  return {ok = true, rows = rows, raw = fsize}
end

-- Entry point: list = comma-separated file paths.
-- Each failing file (bad path / missing / bad extension / bad size) yields ONE
-- visible error row — "ERR: <reason>|0|0|0|0|0|0" — so a NULL from an aggregate
-- is never mistaken for "no data": select * and you see why. (The C table fn
-- swallows a Lua error() from here — it only surfaces source-*compile* errors
-- — so an error row is the reliable in-band signal. fields 2-7 are numeric so
-- the common `split_part(val,'|',k)::FLOAT` stays cast-safe.)
return function(list)
  local rows = {}
  local files = {}
  local npath = 0
  if list and #list > 0 then
    for p in string.gmatch(list, '[^,]+') do files[#files + 1] = p end
    npath = #files
  end
  if npath == 0 then
    rows[#rows + 1] = 'ERR: no file path (list empty)|0|0|0|0|0|0'
    return rows
  end
  local nfound = 0
  for i = 1, #files do
    local r = parse(files[i])
    if r and r.ok then
      nfound = nfound + 1
      for j = 1, #r.rows do rows[#rows + 1] = r.rows[j] end
    else
      local err = r and r.err or 'parse failed'
      rows[#rows + 1] = 'ERR: ' .. err .. ' @ ' .. files[i] .. '|0|0|0|0|0|0'
    end
  end
  if nfound == 0 then
    -- every file failed: lead with a summary so the cause is unmissable
    table.insert(rows, 1, 'ERR: 0/' .. npath .. ' files parsed (see ERR rows below)|0|0|0|0|0|0')
  end
  return rows
end