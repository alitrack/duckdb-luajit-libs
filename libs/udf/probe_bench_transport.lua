-- probe: FFI vs curl-CLI 每行传输开销对拍（PoC 用，不进 INDEX）
-- @license: MIT (duckdb-luajit-libs project)
-- 同一 URL（jev-clone /healthz，几 ms 级响应 → fork 开销占比最大、对比最清晰）
-- 计时用 FFI clock_gettime(CLOCK_MONOTONIC)：wall-clock、μs 级；os.clock 是 CPU 时间
-- 不适合含 I/O 的场景，jit.time 在嵌入式 LuaJIT 里被禁用。
local ffi = require('ffi')
ffi.cdef[[
  struct tspec { long tv_sec; long tv_nsec; };
  int clock_gettime(int clockid, struct tspec *tp);
]]
local CLOCK_MONOTONIC = 1
local ts = ffi.new('struct tspec[1]')
local function wall_us()
  ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
  local t = ts[0]
  return tonumber(t.tv_sec) * 1000000 + tonumber(t.tv_nsec) / 1000
end

local ffi_fn = dofile('/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/curl_ffi.lua')
local jev_fn = dofile('/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/jev_ask.lua')

local function wall_ms(n, f)
  local t0 = wall_us()
  for _ = 1, n do f() end
  return (wall_us() - t0) / n / 1000
end

return function(p)
  local n = tonumber(p and p.n) or 50
  local url = 'http://127.0.0.1:18090/healthz'
  -- 预热（FFI 首调含 dlopen 后首次 easy_init；CLI 首调含 page-in）
  for _ = 1, 10 do ffi_fn({url = url}) end
  for _ = 1, 10 do jev_fn({op = 'health'}) end
  local ffi_ms = wall_ms(n, function() ffi_fn({url = url}) end)
  local cli_ms = wall_ms(n, function() jev_fn({op = 'health'}) end)
  return string.format(
    'n=%d  ffi=%.3f ms/call  cli=%.3f ms/call  speedup=%.1fx',
    n, ffi_ms, cli_ms, cli_ms / ffi_ms)
end
