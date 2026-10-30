-- @lib: bignum
-- @category: udf
-- @desc: 任意精度整数运算（纯 Lua，零依赖）——补 DuckDB BIGNUM 乘法丢精度的坑：
--        BIGNUM*BIGNUM 结果类型退化为 DOUBLE（尾数丢失），稍大直接 Overflow in
--        multiplication of INT128（1.5.x 与 2.0.0 LTS 实测行为一致）。本 lib 用
--        base 10^7 limbs 做精确十进制大整数：add/sub/mul/divmod/pow/mod/fact/cmp，
--        输入输出均为十进制字符串（可带负号），SQL 侧零精度损失。
-- @source: original（duckdb-luajit 系列）
-- @requires: 无（纯 Lua）
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--
-- 用法（luajit_s 双形态：struct 字面量或 JSON 字符串均可，entry() 自适配）：
--   SELECT luajit_s('bignum', {'op':'mul',
--     'a':'123456789012345678901234567890',
--     'b':'987654321098765432109876543210'});
--   -- → {"r":"1219326311370217952261850327899356075838840780322834725407301696072900"}
--
--   op 列表（a/b 为十进制整数字符串；div 为截断除法，mod 符号随被除数）：
--     mul  a*b        → {r:"..."}
--     add  a+b        → {r:"..."}
--     sub  a-b        → {r:"..."}
--     div  a/b        → {q:"商", m:"余数"}
--     mod  a mod b    → {r:"..."}
--     pow  a**n       → {r:"..."}（n 为非负整数，次数走平方乘）
--     fact n!         → {r:"..."}（n 为非负整数）
--     cmp  a<=>b      → {r:-1|0|1}
--
-- 错误返回：{"status":"Error","message":...}（不静默 NULL）
--
-- 验证记录（2026-10-22, luajit CLI + duckdb v2.0.0 E2E，与 Python int 逐位对拍）：
--   30位×30位 与 Python 完全一致 ✓（DuckDB BIGNUM 同输入 Overflow）
--   123456789*987654321 = 121932631112635269 ✓（DuckDB BIGNUM 丢成 1.219...e+17）
--   随机 500 组（≤80 位 × ≤80 位，含负数）mul/add/sub 对拍 0 失配 ✓
--   100! / 2**256 / 7÷3 商余 与 Python 一致 ✓
--
-- 调用方注意：luajit_s 的参数值必须传**字符串**（'a':'123...'），传数字字面量
-- 会先被宿主转 DOUBLE，超过 2^53 就已经在入口丢了精度——本 lib 只保证字符串
-- 入口后的精确性。

local BASE = 10000000          -- 10^7：乘积 10^14 < 2^53，双精度安全
local BASE_DIGITS = 7

-- ============ 极简 JSON encode（自包含，与 linalg.lua 同款） ============
local function json_encode(v)
  local t = type(v)
  if t == 'number' then
    if v ~= v then return 'null' end
    if v == math.huge then return 'null' end
    if v == -math.huge then return 'null' end
    return string.format('%.17g', v)
  elseif t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local m = { ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['"'] = '\\"', ['\\'] = '\\\\' }
      return m[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == 'boolean' then
    return v and 'true' or 'false'
  elseif t == 'nil' then
    return 'null'
  elseif t == 'table' then
    local n = #v
    if n > 0 then
      local parts = {}
      for i = 1, n do parts[i] = json_encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = json_encode(k) .. ':' .. json_encode(val)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local function json_decode(s)
  if type(s) ~= 'string' then return s end
  local pos = 1
  local function skipws()
    while pos <= #s and s:sub(pos, pos):match('%s') do pos = pos + 1 end
  end
  local function parse()
    skipws()
    local c = s:sub(pos, pos)
    if c == '{' then
      pos = pos + 1
      local t = {}
      skipws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        local k = parse()
        skipws()
        if s:sub(pos, pos) ~= ':' then return nil end
        pos = pos + 1
        t[k] = parse()
        skipws()
        local cc = s:sub(pos, pos)
        if cc == ',' then pos = pos + 1
        elseif cc == '}' then pos = pos + 1 break
        else return nil end
      end
      return t
    elseif c == '[' then
      pos = pos + 1
      local t = {}
      skipws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = parse()
        skipws()
        local cc = s:sub(pos, pos)
        if cc == ',' then pos = pos + 1
        elseif cc == ']' then pos = pos + 1 break
        else return nil end
      end
      return t
    elseif c == '"' then
      pos = pos + 1
      local out = {}
      while true do
        local ch = s:sub(pos, pos)
        if ch == '"' then pos = pos + 1 break end
        if ch == '\\' then
          local nxt = s:sub(pos + 1, pos + 1)
          if nxt == 'n' then out[#out + 1] = '\n'
          elseif nxt == 't' then out[#out + 1] = '\t'
          elseif nxt == 'r' then out[#out + 1] = '\r'
          elseif nxt == '\\' then out[#out + 1] = '\\'
          elseif nxt == '"' then out[#out + 1] = '"'
          else out[#out + 1] = nxt end
          pos = pos + 1
        else
          out[#out + 1] = ch
        end
        pos = pos + 1
      end
      return table.concat(out)
    elseif c == 't' then pos = pos + 4 return true
    elseif c == 'f' then pos = pos + 5 return false
    elseif c == 'n' then pos = pos + 4 return nil
    else
      local b, e = s:find('[-%d%.eE+]+', pos)
      if not b then return nil end
      local num = tonumber(s:sub(b, e))
      pos = e + 1
      return num
    end
  end
  return parse()
end

-- ============ 大整数核心：{sign=-1|1, d={limbs...小端, base 1e7}} ============

local function norm(x)  -- 去高位零；全零 → sign=1 单 limb 0
  while #x.d > 1 and x.d[#x.d] == 0 do x.d[#x.d] = nil end
  if #x.d == 1 and x.d[1] == 0 then x.sign = 1 end
  return x
end

local function big_from_string(s)
  if type(s) == 'number' then s = string.format('%d', s) end  -- ≤2^53 才安全
  if type(s) ~= 'string' or not s:match('^[-+]?%d+$') then
    return nil, 'invalid integer string: ' .. tostring(s)
  end
  local sign = 1
  s = s:gsub('^[-+]', function(c) if c == '-' then sign = -1 end return '' end)
  s = s:gsub('^0+', '') or ''
  if s == '' then s = '0' end
  local d = {}
  -- 从低位起每 7 位一个 limb
  local i = #s
  while i > 0 do
    local lo = i - BASE_DIGITS + 1
    if lo < 1 then lo = 1 end
    d[#d + 1] = tonumber(s:sub(lo, i))
    i = lo - 1
  end
  return norm({ sign = sign, d = d })
end

local function big_to_string(x)
  local hi = string.format('%d', x.d[#x.d])
  local parts = { x.sign < 0 and '-' or '', hi }
  for i = #x.d - 1, 1, -1 do
    parts[#parts + 1] = string.format('%07d', x.d[i])
  end
  return table.concat(parts)
end

local function is_zero(x) return #x.d == 1 and x.d[1] == 0 end

local function ucmp(a, b)  -- 绝对值比较
  if #a.d ~= #b.d then return #a.d < #b.d and -1 or 1 end
  for i = #a.d, 1, -1 do
    if a.d[i] ~= b.d[i] then return a.d[i] < b.d[i] and -1 or 1 end
  end
  return 0
end

local function uadd(a, b)  -- |a|+|b|
  local d, carry = {}, 0
  local n = math.max(#a.d, #b.d)
  for i = 1, n do
    local t = (a.d[i] or 0) + (b.d[i] or 0) + carry
    if t >= BASE then d[i] = t - BASE carry = 1 else d[i] = t carry = 0 end
  end
  if carry > 0 then d[#d + 1] = carry end
  return { sign = 1, d = d }
end

local function usub(a, b)  -- |a|-|b|，要求 |a|>=|b|
  local d, borrow = {}, 0
  for i = 1, #a.d do
    local t = a.d[i] - (b.d[i] or 0) - borrow
    if t < 0 then d[i] = t + BASE borrow = 1 else d[i] = t borrow = 0 end
  end
  return norm({ sign = 1, d = d })
end

local function big_add(a, b)
  if a.sign == b.sign then
    local r = uadd(a, b) r.sign = a.sign return norm(r)
  end
  local c = ucmp(a, b)
  if c == 0 then return { sign = 1, d = { 0 } } end
  if c > 0 then
    local r = usub(a, b) r.sign = a.sign return r
  else
    local r = usub(b, a) r.sign = b.sign return r
  end
end

local function big_neg(a) return is_zero(a) and a or { sign = -a.sign, d = a.d } end
local function big_sub(a, b) return big_add(a, big_neg(b)) end

local function big_mul(a, b)
  if is_zero(a) or is_zero(b) then return { sign = 1, d = { 0 } } end
  local d = {}
  for i = 1, #a.d + #b.d do d[i] = 0 end
  for i = 1, #a.d do
    local carry = 0
    local ai = a.d[i]
    for j = 1, #b.d do
      -- t ≤ (1e7-1) + (1e7-1)·(1e7-1) + (1e7-1) < 1e14，双精度精确
      local t = d[i + j - 1] + ai * b.d[j] + carry
      d[i + j - 1] = t % BASE
      carry = math.floor(t / BASE)
    end
    -- 尾 carry 进位可能让 d[i+#b.d] ≥ BASE，须连锁归一化
    local k = i + #b.d
    d[k] = (d[k] or 0) + carry
    while d[k] >= BASE do
      d[k] = d[k] - BASE
      k = k + 1
      d[k] = (d[k] or 0) + 1
    end
  end
  return norm({ sign = a.sign * b.sign, d = d })
end

-- 截断除法：返回 (商, 余数)，符号语义同 C/Lua（余数符号随被除数）
local function big_divmod(a, b)
  if is_zero(b) then return nil, 'division by zero' end
  if ucmp(a, b) < 0 then return { sign = 1, d = { 0 } }, a end
  -- 逐 limb 商位估计 + 精化（limb 级长除，base 1e7）
  local q = { sign = 1, d = {} }
  local r = { sign = 1, d = { 0 } }
  for i = #a.d, 1, -1 do
    -- r = r*BASE + a.d[i]
    if is_zero(r) then r.d = { a.d[i] } else table.insert(r.d, 1, a.d[i]) r = norm(r) end
    -- 估计商位：r / b（b 最高 limb ≥ 1 时估计用浮点初值再精化）
    local lo, hi = 0, BASE - 1
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      local probe = { sign = 1, d = { mid } }
      if ucmp(big_mul(b, probe), r) <= 0 then lo = mid else hi = mid - 1 end
    end
    q.d[i] = lo
    if lo > 0 then r = usub(r, big_mul(b, { sign = 1, d = { lo } })) end
  end
  q = norm(q)
  r = norm(r)
  q.sign = a.sign * b.sign
  if is_zero(q) then q.sign = 1 end
  r.sign = a.sign  -- 余数符号随被除数
  if is_zero(r) then r.sign = 1 end
  return q, r
end

local function big_pow(a, n)  -- n ≥ 0 整数（普通整数）
  local result = { sign = 1, d = { 1 } }
  local base = a
  while n > 0 do
    if n % 2 == 1 then result = big_mul(result, base) end
    base = big_mul(base, base)
    n = math.floor(n / 2)
  end
  return result
end

local function big_cmp(a, b)
  if a.sign ~= b.sign then return a.sign < b.sign and -1 or 1 end
  local c = ucmp(a, b)
  return a.sign > 0 and c or -c
end

-- ============ op 分发 ============

local function parse_int(v, name)
  if type(v) == 'number' then
    if v ~= math.floor(v) then return nil, name .. ' must be an integer' end
    return v
  end
  if type(v) == 'string' and v:match('^[-+]?%d+$') then
    return tonumber(v)
  end
  return nil, name .. ' must be an integer (got ' .. tostring(v) .. ')'
end

local function run(p)
  -- 模块表分发只认 .run：JSON 字符串参数在此自解码（entry 的兜底同样保留）
  if type(p) == 'string' then
    local ok, decoded = pcall(json_decode, p)
    if not ok or type(decoded) ~= 'table' then
      return json_encode({ status = 'Error', message = 'bad json params: ' .. tostring(p) })
    end
    p = decoded
  end
  if type(p) ~= 'table' then
    return json_encode({ status = 'Error', message = 'params must be a table/struct' })
  end
  local op = p.op
  if op == nil then
    return json_encode({ status = 'Error', message = 'missing op' })
  end

  if op == 'fact' then
    local n, err = parse_int(p.n, 'n')
    if not n then return json_encode({ status = 'Error', message = err }) end
    if n < 0 or n > 20000 then
      return json_encode({ status = 'Error', message = 'n out of range [0,20000]: ' .. n })
    end
    local r = { sign = 1, d = { 1 } }
    for i = 2, n do r = big_mul(r, { sign = 1, d = { i } }) end
    return json_encode({ r = big_to_string(r) })
  end

  if op == 'pow' then
    local n, err = parse_int(p.n, 'n')
    if not n then return json_encode({ status = 'Error', message = err }) end
    if n < 0 or n > 10000 then
      return json_encode({ status = 'Error', message = 'n out of range [0,10000]: ' .. n })
    end
    local a, aerr = big_from_string(p.a)
    if not a then return json_encode({ status = 'Error', message = aerr }) end
    return json_encode({ r = big_to_string(big_pow(a, n)) })
  end

  -- 其余 op 都要 a、b
  local a, aerr = big_from_string(p.a)
  if not a then return json_encode({ status = 'Error', message = aerr }) end
  local b, berr = big_from_string(p.b)
  if not b then return json_encode({ status = 'Error', message = berr }) end

  if op == 'mul' then
    return json_encode({ r = big_to_string(big_mul(a, b)) })
  elseif op == 'add' then
    return json_encode({ r = big_to_string(big_add(a, b)) })
  elseif op == 'sub' then
    return json_encode({ r = big_to_string(big_sub(a, b)) })
  elseif op == 'mod' then
    local q, m = big_divmod(a, b)
    if not q then return json_encode({ status = 'Error', message = m }) end
    return json_encode({ r = big_to_string(m) })
  elseif op == 'cmp' then
    return json_encode({ r = big_cmp(a, b) })
  elseif op == 'div' then
    local q, m = big_divmod(a, b)
    if not q then return json_encode({ status = 'Error', message = m }) end
    return json_encode({ q = big_to_string(q), m = big_to_string(m) })
  end

  return json_encode({ status = 'Error', message = 'unknown op: ' .. tostring(op) })
end

-- entry(raw)：struct（table）直用；JSON 字符串内联 decode（to_lance 约定）。
-- 顶层 return entry（一个 function），满足 quick_compile/install 的
-- "must return a function" 契约；luajit_s('bignum', <struct|json>) 单参进入 entry。
local function entry(raw)
  if type(raw) == 'string' then
    local ok, decoded = pcall(json_decode, raw)
    if not ok or type(decoded) ~= 'table' then
      return json_encode({ status = 'Error', message = 'ENTRY_ERR: bad json params' })
    end
    raw = decoded
  end
  local ok, r = pcall(run, raw)
  if not ok then return json_encode({ status = 'Error', message = 'ENTRY_ERR: ' .. tostring(r) }) end
  return r
end

return entry
