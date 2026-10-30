-- @lib: zlib
-- @category: udf
-- @desc: zlib 压缩/解压（FFI dlopen 系统 libz，SQLite compress()/uncompress() 的等价物）。
--       补齐 DuckDB 用户层空白：核心 compress* 是内部列存编码函数，用户不可见/不可用于任意数据。
--       语义 = 标准 zlib 容器格式（带 zlib 头 0x78…，与 SQLite compress() / python zlib.compress /
--             gzip CLI 的 deflate 流兼容，**不是**裸 deflate 也不是 gzip 文件）。
--       op='compress'   ：p.hex（输入字节 hex）或 p.v（UTF-8 文本）→ 压缩后 hex（level 默认 6，可 p.level 0-9）
--       op='uncompress' ：p.hex（压缩字节 hex）→ 解压后 hex
--       op='roundtrip'  ：p.hex/p.v → compress→uncompress 后 hex（自检用）
--       op='version'    ：→ 系统 libz 版本串（自检用）
--       ⚠️ 输出恒为 hex 串（luajit_s 只返回 VARCHAR）。输入双通道：p.hex（裸字节）或 p.v（文本→UTF-8 字节）。
-- @source: original（duckdb-luajit-libs 系列）；算法由系统 libz 提供（zlib 许可证）
-- @requires: LuaJIT FFI + 系统 libz（WSL libz.so.1 / macOS libz.dylib / Windows zlib1.dll）
--            ⚠️ 非 trusted 沙箱（ffi.load 被 trusted 禁用，与 curl_ffi/pgcrypto 同档）。
-- @license: MIT (duckdb-luajit-libs project)；zlib 由系统提供
-- @maturity: tested（逐字节对拍 python3 zlib oracle，见 test_zlib.lua / test_zlib.sql）
--
-- 实现要点（2026-10-13 实测）：用 zlib 一次性 API compress2/uncompress（非流式 z_stream），
--   避免手写 z_stream 结构体的 ABI/sizeof 风险。uncompress 输出大小未知 → Z_BUF_ERROR 翻倍重试。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:   SELECT * FROM luajit_module(mode:='install', sql_name:='zlib');
--   compress:  SELECT luajit_s('zlib', {v:'hello', op:'compress'});                 -- 文本直传
--             → '789ccb48cdc9c90700062c0215'
--   uncompress:SELECT luajit_s('zlib', {hex:'789ccb48cdc9c90700062c0215', op:'uncompress'});

local ffi

local function load_z()
  if ffi == nil then
    local ok, m = pcall(require, 'ffi')
    if not ok then return nil, 'FFI unavailable in this sandbox' end
    ffi = m
  end
  local ok, lib = pcall(function()
    local names
    if ffi.os == 'Windows' then
      names = { 'zlib1.dll', 'zlibwapi.dll' }
    elseif ffi.os == 'OSX' then
      names = { 'libz.dylib', '/usr/lib/libz.dylib' }
    else
      names = { 'libz.so.1', 'libz.so' }
    end
    local errs = {}
    for _, n in ipairs(names) do
      local l, e = ffi.load(n)
      if l then return l end
      errs[#errs + 1] = e or n
    end
    error('libz not found: ' .. table.concat(errs, '; '))
  end)
  if ok then return lib, nil end
  return nil, tostring(lib)
end

local lib, cdef_done

local function ensure()
  if lib then return end
  lib = load_z()
  if not lib then error(lib) end
  if not cdef_done then
    local ok, e = pcall(function()
      ffi.cdef[[
        int compress2(unsigned char *dest, unsigned long *destLen,
                      const unsigned char *source, unsigned long sourceLen, int level);
        int uncompress(unsigned char *dest, unsigned long *destLen,
                       const unsigned char *source, unsigned long sourceLen);
        const char *zlibVersion(void);
      ]]
    end)
    if not ok and tostring(e):find('redefine') == nil then
      error('cdef failed: ' .. tostring(e))
    end
    cdef_done = true
  end
end

local function hex_to_bytes(h)
  local n = #h
  if n % 2 ~= 0 then error('hex must have even length') end
  return (h:sub(1, n):gsub('..', function(cc) return string.char(tonumber(cc, 16)) end))
end

local function bytes_to_hex(b)
  return (b:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function compress_hex(h, level)
  ensure()
  local data = hex_to_bytes(h)
  level = level or 6
  local src_len = ffi.cast('unsigned long', #data)
  local destLen = ffi.new('unsigned long[1]')
  local cbufsize = #data + math.floor(#data / 1000) + 16
  local outbuf = ffi.new('unsigned char[?]', cbufsize)
  destLen[0] = ffi.cast('unsigned long', cbufsize)
  local rc = lib.compress2(outbuf, destLen, data, src_len, level)
  if rc ~= 0 then return 'ERR: compress2 failed rc=' .. rc end
  return bytes_to_hex(ffi.string(outbuf, destLen[0]))
end

local function uncompress_hex(h)
  ensure()
  local data = hex_to_bytes(h)
  local src_len = ffi.cast('unsigned long', #data)
  -- 解压大小未知：从 64KB 起，Z_BUF_ERROR(-5) 时翻倍重试
  local bufsize = 65536
  while true do
    local outbuf = ffi.new('unsigned char[?]', bufsize)
    local destLen = ffi.new('unsigned long[1]')
    destLen[0] = ffi.cast('unsigned long', bufsize)
    local rc = lib.uncompress(outbuf, destLen, data, src_len)
    if rc == 0 then             -- Z_OK
      return bytes_to_hex(ffi.string(outbuf, destLen[0]))
    elseif rc == -5 then        -- Z_BUF_ERROR：输出缓冲不足，扩容
      bufsize = bufsize * 2
      if bufsize > 256 * 1024 * 1024 then return 'ERR: uncompress too large' end
    else
      return 'ERR: uncompress failed rc=' .. rc
    end
  end
end

local function run(p)
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'compress'
  -- 双通道：p.hex（裸字节 hex）优先；否则 p.v（UTF-8 文本 → 字节 hex）。
  -- 两个都缺 → 空输入（与之前行为一致，空串 roundtrip 仍可用）。
  local h
  if type(p.hex) == 'string' and p.hex ~= '' then
    h = p.hex
  elseif type(p.v) == 'string' then
    h = bytes_to_hex(p.v)
  else
    h = ''
  end
  if op == 'compress' then
    return compress_hex(h, p.level)
  elseif op == 'uncompress' then
    return uncompress_hex(h)
  elseif op == 'roundtrip' then
    local c = compress_hex(h, p.level)
    if c:sub(1, 4) == 'ERR:' then return c end
    return uncompress_hex(c)
  elseif op == 'version' then
    ensure()
    return ffi.string(lib.zlibVersion())
  end
  return 'ERR: unknown op ' .. tostring(op)
end

return function(p)
  local ok, r = pcall(run, p)
  if ok then return r end
  return 'ERR: ' .. tostring(r)
end
