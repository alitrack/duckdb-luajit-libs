-- @lib: basexx
-- @category: udf
-- @desc: base85 (RFC 1924 字符集) + base58 (Bitcoin) 大整型编解码。
--       补齐 DuckDB 用户层 gap：to_base 只支持 2-36，from_base 只支持 base64，base85/58 缺失。
--       op='base85_enc'   ：p.hex → base85 串（字符集 = RFC1924 的 85 字符：0-9 a-z A-Z + 12 符号）
--       op='base85_dec'   ：p.v（base85 串）→ hex
--       op='base58_enc'   ：p.hex → Bitcoin base58 串（字符集无 0 O I l，前导零字节 → '1'，可逆）
--       op='base58_dec'   ：p.v（base58 串）→ hex
--       ⚠️ I/O 是 hex 串（luajit_s 只返回 VARCHAR，二进制走 hex——本系列约定）。
--       算法：标准大整型 base-N（与 Bitcoin base58 库同算法）。
--         * 前导零字节 → N 个标记字符（base58='1' / base85='0'），decode 按标记数还原前导零字节，
--           全零串 roundtrip 精确。
--         * 注意：base85 用的是 RFC1924 的**字符集**，但编解码走大整型（非 RFC1924 的 52 字节分组
--           流格式）——所以与真 RFC1924 流不逐字节兼容，但作为编解码工具 roundtrip 精确、语义清晰。
--           需要真 RFC1924 流格式时另说。
--       64 位安全（硬约束）：本机 LuaJIT 原生整数 32 位 / double 53 位 → 大整型走**字节数组**
--           逐字节进位（每步 cur = byte*base+carry < 255*85+85 < 2^17，double 精确），
--           无需 FFI、无 64 位字面量。
-- @source: original（duckdb-luajit-libs 系列）；base58 对齐 Bitcoin 标准
-- @requires: 无（纯 Lua）
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested（对拍 python3 oracle，roundtrip 全过，见 test_basexx.sql）
--
-- Usage:
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='basexx');
--   SELECT luajit_s('basexx', {hex:'68656c6c6f', op:'base85_enc'});   → '1g4I1>m'
--   SELECT luajit_s('basexx', {v:'1g4I1>m', op:'base85_dec'});         → '68656c6c6f'
--   SELECT luajit_s('basexx', {hex:'deadbeef', op:'base58_enc'});      → '6h8cQN'
--   SELECT luajit_s('basexx', {v:'6h8cQN', op:'base58_dec'});          → 'deadbeef'

-- RFC 1924 base85 alphabet (85 chars: 0-9 a-z A-Z + !#$%&()*+-;<=>?@^_`{|}~)
local A85 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!#$%&()*+-;<=>?@^_`{|}~"
local A85_MAP = {}
for i = 1, #A85 do A85_MAP[A85:sub(i, i)] = i - 1 end

-- Bitcoin base58 alphabet (58 chars, no 0 O I l)
local A58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local A58_MAP = {}
for i = 1, #A58 do A58_MAP[A58:sub(i, i)] = i - 1 end

local function hex_to_bytes(h)
  local n = #h
  if n % 2 ~= 0 then error('hex must have even length') end
  return (h:sub(1, n):gsub('..', function(cc) return string.char(tonumber(cc, 16)) end))
end

local function bytes_to_hex(b)
  return (b:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

-- 数前导零字节数
local function count_leading_zero(data)
  local c = 0
  for i = 1, #data do
    if data:sub(i, i):byte() == 0 then c = c + 1 else break end
  end
  return c
end

-- 大端字节数组除以小 base：返回 (剩余字节数组, 余数)。每步 cur<2^17 精确。
local function div_bytes_be(data, base)
  local rem = 0
  local out = {}
  for i = 1, #data do
    local cur = rem * 256 + data:sub(i, i):byte()
    local q = math.floor(cur / base)
    rem = cur - q * base
    out[i] = q
  end
  -- 去前导零字节
  local j = 1
  while j <= #out and out[j] == 0 do j = j + 1 end
  if j > #out then return '', rem end
  local rest = {}
  for i = j, #out do rest[#rest + 1] = string.char(out[i]) end
  return table.concat(rest), rem
end

-- 大端字节数组乘小 base 再加 v（decode 用）：返回新字节数组。每步 cur<2^17 精确。
local function muladd_bytes_be(data, base, v)
  -- 从低位(右)往高位(左)乘，进位往左传
  local out = {}
  local carry = v
  for i = #data, 1, -1 do
    local cur = data:sub(i, i):byte() * base + carry
    out[i] = cur % 256
    carry = math.floor(cur / 256)
  end
  -- 处理高位溢出
  local head = {}
  while carry > 0 do
    head[#head + 1] = carry % 256
    carry = math.floor(carry / 256)
  end
  -- 组装：head（高位溢出）+ out（原长，右对齐）
  local all = {}
  for i = 1, #head do all[#all + 1] = head[i] end
  for i = 1, #data do
    all[#all + 1] = out[i]
  end
  local bytes = {}
  for i = 1, #all do bytes[#bytes + 1] = string.char(all[i]) end
  local res = table.concat(bytes)
  -- 去前导零字节（最小表示）
  local k = 1
  while k <= #res and res:sub(k, k):byte() == 0 do k = k + 1 end
  if k > #res then return '' end
  return res:sub(k)
end

local function encode_generic(h, alpha, map_unused, base, marker)
  local data = hex_to_bytes(h)
  if #data == 0 then return '' end
  local lead = count_leading_zero(data)
  local rest = data:sub(lead + 1)
  if rest == '' then
    -- 全零串 → lead 个标记
    return string.rep(marker, lead)
  end
  local chars = {}
  local work = rest
  while work ~= '' do
    work, r = div_bytes_be(work, base)
    chars[#chars + 1] = alpha:sub(r + 1, r + 1)
  end
  local rev = {}
  for i = #chars, 1, -1 do rev[#rev + 1] = chars[i] end
  return string.rep(marker, lead) .. table.concat(rev)
end

local function decode_generic(s, alpha_unused, map, base, marker)
  if s == '' then return '' end
  local lead = 0
  for i = 1, #s do
    if s:sub(i, i) == marker then lead = lead + 1 else break end
  end
  local rest = s:sub(lead + 1)
  if rest == '' then
    -- 全是标记 → lead 个零字节
    return string.rep('00', lead)
  end
  local bytes = ''  -- 大端，最小表示
  for i = 1, #rest do
    local v = map[rest:sub(i, i)]
    if v == nil then return 'ERR: invalid char: ' .. rest:sub(i, i) end
    bytes = muladd_bytes_be(bytes, base, v)
  end
  return string.rep('00', lead) .. bytes_to_hex(bytes)
end

local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '' end
  local op = p.op
  if op == 'base85_enc' then
    return encode_generic(p.hex or p.v or '', A85, A85_MAP, 85, '0')
  elseif op == 'base85_dec' then
    return decode_generic(p.v or p.hex or '', A85, A85_MAP, 85, '0')
  elseif op == 'base58_enc' then
    return encode_generic(p.hex or p.v or '', A58, A58_MAP, 58, '1')
  elseif op == 'base58_dec' then
    return decode_generic(p.v or p.hex or '', A58, A58_MAP, 58, '1')
  end
  return 'ERR: unknown op ' .. tostring(op)
end

return function(p)
  local ok, r = pcall(run, p)
  if ok then return r end
  return 'ERR: ' .. tostring(r)
end
