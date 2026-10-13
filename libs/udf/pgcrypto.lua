-- @lib: pgcrypto
-- @category: udf
-- @desc: 哈希/HMAC（移植 PostgreSQL pgcrypto 的 digest()/hmac()，FFI 调系统 OpenSSL，逐位对拍 openssl CLI）。
--       补齐 DuckDB 核心缺失的：sha512、sha3_256/384/512、hmac（核心已有 md5/sha1/sha256，此处统一入口也覆盖）。
--       op='digest' ：p.algo + p.v → 十六进制小写（PG `digest(data, type)`）
--                      algo ∈ sha224 sha256 sha384 sha512 sha3_224 sha3_256 sha3_384 sha3_512 md5 ripemd160
--       op='hmac'   ：p.algo + p.key + p.v → 十六进制小写（PG `hmac(data, key, type)`）
--                      algo ∈ 同上（HMAC 支持 sha256/sha384/sha512/sha224/sha3_*/md5 等）
--       op='algo'   ：p.v → 校验并返回该算法名是否在 OpenSSL 可用（'true'/'false'），便于 SQL 侧探测
--       依赖 FFI + 系统 libcrypto（OpenSSL 1.1/3.x 或 LibreSSL）。库缺失时返回清晰 ERR 串（不崩）。
-- @source: 移植 PostgreSQL pgcrypto（digest/hmac 语义），实现用 OpenSSL EVP_Digest / HMAC 一次性 API
-- @requires: LuaJIT FFI + 系统 OpenSSL（libcrypto.so.3 / libcrypto.dylib / libcrypto-3-x64.dll 等）
-- @license: MIT (duckdb-luajit-libs project)；算法由 OpenSSL 提供（Apache-2.0）
-- @maturity: tested（对拍 openssl dgst 独立 C oracle，见 test_pgcrypto.lua）
-- 诚实边界：① 一次性 digest/hmac（非流式，长文件请分块——但 UDF 单次传整串即可）。
--   ② pgcrypto 的对称加密（pgp_sym_encrypt / pgp_pub_* / crypt/gen_salt）未实现——那需要
--     libpgp 或 OpenPGP，远超哈希范围，需要时另立库。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='pgcrypto');
--   digest:   SELECT luajit_s('pgcrypto', {v:'abc', algo:'sha512', op:'digest'});
--             → 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f'
--   hmac:     SELECT luajit_s('pgcrypto', {v:'abc', key:'abc', algo:'sha256', op:'hmac'});
--             → '2f02e24ae2e1fe880399f27600afa88364e6062bf9bbe114b32fa8f23d03608a'

local ffi

local function load_crypto()
  if ffi == nil then
    local ok, m = pcall(require, 'ffi')
    if not ok then return nil, 'FFI unavailable in this sandbox' end
    ffi = m
  end
  local ok, lib = pcall(function()
    local names
    if ffi.os == 'Windows' then
      names = { 'libcrypto-3-x64.dll', 'libcrypto-3.dll', 'libcrypto.dll', 'libcrypto-1_1-x64.dll', 'vcruntime140.dll' }
    elseif ffi.os == 'OSX' then
      names = { 'libcrypto.3.dylib', 'libcrypto.dylib', '/usr/lib/libcrypto.dylib', '@rpath/libcrypto.3.dylib' }
    else
      names = { 'libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so', 'libcrypto.so.1.0.0' }
    end
    local errs = {}
    for _, n in ipairs(names) do
      local l, e = ffi.load(n)
      if l then return l end
      errs[#errs + 1] = e or n
    end
    error('libcrypto not found: ' .. table.concat(errs, '; '))
  end)
  if ok then return lib, nil end
  return nil, tostring(lib)
end

local lib, cdef_done

local function ensure()
  if lib then return end
  lib = load_crypto()
  if not lib then error(lib) end
  if not cdef_done then
    local ok, e = pcall(function()
      ffi.cdef[[
        typedef struct evp_md_st EVP_MD;
        const EVP_MD *EVP_sha224(void);
        const EVP_MD *EVP_sha256(void);
        const EVP_MD *EVP_sha384(void);
        const EVP_MD *EVP_sha512(void);
        const EVP_MD *EVP_md5(void);
        const EVP_MD *EVP_ripemd160(void);
        const EVP_MD *EVP_sha3_224(void);
        const EVP_MD *EVP_sha3_256(void);
        const EVP_MD *EVP_sha3_384(void);
        const EVP_MD *EVP_sha3_512(void);
        int EVP_Digest(const void *data, size_t data_len, unsigned char *md,
                       unsigned int *md_len, const EVP_MD *type, void *impl);
        unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
                            const unsigned char *d, size_t n,
                            unsigned char *md, unsigned int *md_len);
      ]]
    end)
    -- 重复 cdef（同会话二次加载）会抛 attempt to redefine —— 视为已声明，忽略
    if not ok and tostring(e):find('redefine') == nil then
      error('cdef failed: ' .. tostring(e))
    end
    cdef_done = true
  end
end

local algo_map = {
  sha224 = 'EVP_sha224', sha256 = 'EVP_sha256', sha384 = 'EVP_sha384', sha512 = 'EVP_sha512',
  md5 = 'EVP_md5', ripemd160 = 'EVP_ripemd160',
  sha3_224 = 'EVP_sha3_224', sha3_256 = 'EVP_sha3_256', sha3_384 = 'EVP_sha3_384', sha3_512 = 'EVP_sha3_512',
}

local function to_hex(bytes, n)
  local out = {}
  for i = 0, n - 1 do
    out[i + 1] = string.format('%02x', bytes[i])
  end
  return table.concat(out)
end

local function digest(algo, v)
  ensure()
  local fnname = algo_map[algo]
  if not fnname then return 'ERR: unknown algorithm: ' .. tostring(algo) end
  local evp = lib[fnname]()
  if evp == nil or not evp then return 'ERR: algorithm not in OpenSSL: ' .. algo end
  local md = ffi.new('unsigned char[64]')
  local md_len = ffi.new('unsigned int[1]')
  local data = v
  local rc = lib.EVP_Digest(data, #data, md, md_len, evp, nil)
  if rc ~= 1 then return 'ERR: EVP_Digest failed for ' .. algo end
  return to_hex(md, md_len[0])
end

local function hmac(algo, key, v)
  ensure()
  local fnname = algo_map[algo]
  if not fnname then return 'ERR: unknown algorithm: ' .. tostring(algo) end
  local evp = lib[fnname]()
  if evp == nil or not evp then return 'ERR: algorithm not in OpenSSL: ' .. algo end
  local md = ffi.new('unsigned char[64]')
  local md_len = ffi.new('unsigned int[1]')
  local r = lib.HMAC(evp, key, #key, v, #v, md, md_len)
  if r == nil then return 'ERR: HMAC failed for ' .. algo end
  return to_hex(md, md_len[0])
end

local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'digest'
  local algo = p.algo or 'sha512'
  local v = tostring(p.v or '')
  if op == 'digest' then
    return digest(algo, v)
  elseif op == 'hmac' then
    return hmac(algo, tostring(p.key or ''), v)
  elseif op == 'algo' then
    local ok, e = pcall(function()
      ensure()
      local fnname = algo_map[algo]
      if not fnname then error('unknown') end
      local evp = lib[fnname]()
      if not evp or evp == nil then error('absent') end
    end)
    return tostring(ok)
  end
  return ''
end

return function(p)
  local ok, r = pcall(run, p)
  if ok then return r end
  return 'ERR: ' .. tostring(r)
end
