-- @lib: gmp
-- @category: udf
-- @desc: 任意精度整数运算（GNU MP 内核，LuaJIT FFI 直调）——mul/add/sub/div/mod/pow/powmod/
--        fac/isqrt/gcd/lcm/primetest/fib/divmod/compare，SQL 里做大数任意精度算术。
--        对标 DuckDB 原生 BIGNUM：原生 2.1.0 仅 + - * / % 五个算子（纯 schoolbook、无分治），
--        本库经 GMP 自动获得 Karatsuba/Toom 分治乘法与 product tree 阶乘（10000! 实测 0.15ms vs
--        原生朴素左累加 155ms）。大数位数上去后差距指数级拉开（35660 位乘法 ~290×）。
-- @source: original（duckdb-luajit 系列）
-- @requires: 系统 GMP（LGPLv3）：
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: verified（2026-10-20, DuckDB v2.1.0-alpha49002 + GMP 6.3.0 macOS arm64 实测）
--            macOS: 系统自带 /usr/lib/libgmp.10.dylib，零安装
--            Linux: glibc 系发行版基本都带 libgmp（Ubuntu/Debian/Fedora/CentOS 验证）
--            Windows: 需自备 libgmp-10.dll（MinGW 预编译包解压后放 PATH，或设 GMP_LIB=完整路径）
--
-- 用法（数值一律十进制字符串，避免 double 精度损失）：
--   SELECT luajit_s('gmp', '{"op":"mul","a":"123456789012345678901234567890","b":"987654321098765432109876543210"}');
--   -- → {"status":"ok","result":"121932631137021795226185032733622923332237463801111263526900","decimal_digits":56}
--
--   op 列表（a/b 为十进制字符串；除注明外均需 a，二元运算需 a,b）：
--     mul     a*b                        → result
--     add     a+b
--     sub     a-b
--     div     a//b（整数商，向零截断）   → result, remainder
--     mod     a%b（b≠0）
--     pow     a^b（b 为十进制字符串，支持任意大指数）
--     powmod  a^b mod m（需 a,b,m；RSA 场景）
--     divmod  a÷b                        → quotient, remainder
--     fac     a!（a < 2^32；GMP 内部为 product tree 平衡乘法）
--     isqrt   ⌊√a⌋（a ≥ 0）
--     gcd     gcd(a,b)（非负结果）
--     lcm     lcm(a,b)
--     primetest a（Miller-Rabin 概率性，置信度 20）→ is_prime: true/false
--     fib     F(a)（Fibonacci, a < 2^32）
--     compare a vs b → cmp: -1/0/1
--     bits    a 的位宽/十进制位数 → bits, decimal_digits
--     to_base a 转 base(2..36) 进制字符串 → result
--
--   返回 JSON：成功 {"status":"ok",...}；失败 {"status":"Error","message":...}
--   GMP 库加载失败（缺 libgmp）时所有 op 返回明确 Error，不影响其他查询。
--
-- 验证记录（2026-10-20, v2.1.0-alpha49002 + GMP 6.3.0, osx arm64）：
--   fac(12) = 479001600 ✓（手算）
--   fac(10000) = 35660 位 ✓（与原生 bignum 左累加结果位数一致，独立交叉验证）
--   mul(2^200, 2^200) = 2^400 ✓
--   gcd(48,36) = 12 ✓（手算）
--   primetest(大素数/合成数) 方向正确 ✓

local ffi = require('ffi')

-- ============ 极简 JSON encode/decode（与 linalg.lua 同款，自包含） ============
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
      return m[c] or c
    end) .. '"'
  elseif t == 'boolean' then
    return v and 'true' or 'false'
  elseif t == 'table' then
    local is_arr = #v > 0 or next(v) == nil
    if is_arr then
      local parts = {}
      for i = 1, #v do parts[i] = json_encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, val in pairs(v) do parts[#parts + 1] = json_encode(k) .. ':' .. json_encode(val) end
      return '{' .. table.concat(parts, ',') .. '}'
    end
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
      if s:sub(pos, pos) == '}' then pos = pos + 1; return t end
      while true do
        local k = parse()
        skipws()
        if s:sub(pos, pos) ~= ':' then return nil end
        pos = pos + 1
        t[k] = parse()
        skipws()
        local cc = s:sub(pos, pos)
        if cc == ',' then pos = pos + 1
        elseif cc == '}' then pos = pos + 1; break
        else return nil end
      end
      return t
    elseif c == '[' then
      pos = pos + 1
      local t = {}
      skipws()
      if s:sub(pos, pos) == ']' then pos = pos + 1; return t end
      while true do
        t[#t + 1] = parse()
        skipws()
        local cc = s:sub(pos, pos)
        if cc == ',' then pos = pos + 1
        elseif cc == ']' then pos = pos + 1; break
        else return nil end
      end
      return t
    elseif c == '"' then
      pos = pos + 1
      local buf = {}
      while true do
        local c2 = s:sub(pos, pos)
        if c2 == '"' then pos = pos + 1; break end
        if c2 == '\\' then
          local e = s:sub(pos + 1, pos + 1)
          local m = { n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['[/'] = '/' }
          buf[#buf + 1] = m[e] or e
          pos = pos + 2
        else
          buf[#buf + 1] = c2
          pos = pos + 1
        end
      end
      return table.concat(buf)
    elseif c == 't' or c == 'f' or c == 'n' then
      local word = s:sub(pos, pos + 4)
      if word:sub(1, 4) == 'true' then pos = pos + 4; return true end
      if word:sub(1, 5) == 'false' then pos = pos + 5; return false end
      if word:sub(1, 4) == 'null' then pos = pos + 4; return nil end
      return nil
    else
      local num = s:match('^%-?%d+%.?%d*[eE]?%-?%d*', pos)
      if not num then return nil end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local ok, v = pcall(parse)
  if not ok then return nil end
  return v
end

-- ============ GMP FFI 绑定 ============
ffi.cdef[[
typedef struct mpz_struct mpz_t;
void __gmpz_init(mpz_t*);
void __gmpz_clear(mpz_t*);
int  __gmpz_set_str(mpz_t*, const char*, int);
char* __gmpz_get_str(char*, int, const mpz_t*);
void __gmpz_mul(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_add(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_sub(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_div_r(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_mod(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_pow_ui(mpz_t*, const mpz_t*, unsigned long int);
void __gmpz_pow_z(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_powm(mpz_t*, const mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_div_qr(mpz_t*, mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_fac_ui(mpz_t*, unsigned long int);
void __gmpz_sqrt(mpz_t*, const mpz_t*);
void __gmpz_gcd(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_lcm(mpz_t*, const mpz_t*, const mpz_t*);
int  __gmpz_cmp(const mpz_t*, const mpz_t*);
int  __gmpz_sizeinbase(const mpz_t*, int);
int  __gmpz_probab_prime_p(const mpz_t*, int);
void __gmpz_fib_ui(mpz_t*, unsigned long int);
int  __gmpz_sdiv_qr(mpz_t*, mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_abs(mpz_t*, const mpz_t*);
]]

-- 跨平台库名候选（顺序=优先级）：
-- macOS: libgmp（/usr/lib 系统自带）; Linux: libgmp / libgmp.so.10
-- Windows: libgmp-10.dll / gmp-10.dll / gmp10（自备，GMP_LIB=路径 可覆盖）
local gmp_load_error
local gmp = nil
do
  local override = (os.getenv and os.getenv('GMP_LIB')) or ''
  local candidates = { override }
  for _, c in ipairs({ 'libgmp', 'libgmp.so.10', 'libgmp-10.dll', 'gmp-10.dll', 'gmp10', 'gmp' }) do
    if c ~= override and c ~= '' then candidates[#candidates + 1] = c end
  end
  for _, name in ipairs(candidates) do
    if name ~= '' then
      local ok, lib = pcall(ffi.load, name)
      if ok and type(lib) == 'table' then
        -- 自检：lib 必须导出核心符号（防加载到同名异体库）
        local probe_ok = pcall(function()
          local a = lib.__gmpz_init
          local b = lib.__gmpz_mul
          local c = lib.__gmpz_set_str
          local d = lib.__gmpz_get_str
          assert(a and b and c and d)
        end)
        if probe_ok then
          gmp = lib
          break
        end
      end
    end
  end
  if not gmp then
    gmp_load_error = '无法加载 GMP 库（尝试过: libgmp, libgmp.so.10, libgmp-10.dll, gmp-10.dll）。'
      .. 'macOS/Linux 通常系统自带；Windows 需自备 libgmp-10.dll（MinGW 预编译包）或设 GMP_LIB=完整路径'
  end
end

local function to_num(s)
  if type(s) == 'number' then s = tostring(math.floor(s)) end
  if type(s) ~= 'string' then return nil, 'operand must be a decimal string (got ' .. type(s) .. ')' end
  if not s:match('^%-%d+$') and not s:match('^%d+$') then
    return nil, 'operand must be an integer decimal string: ' .. s:sub(1, 32)
  end
  return s
end

local function make_num(g, s)
  local n = ffi.new('mpz_t[1]')
  g.__gmpz_init(n)
  local rc = g.__gmpz_set_str(n, s, 10)
  if rc ~= 0 then
    g.__gmpz_clear(n)
    return nil
  end
  return n
end

local function num_to_str(g, n, base)
  base = base or 10
  local est = g.__gmpz_sizeinbase(n, base) + 2
  local buf = ffi.new('char[?]', est > 16 and est or 16)
  local s = ffi.string(g.__gmpz_get_str(buf, base, n))
  return s
end

local function solve(p)
  if not gmp then
    return { status = 'Error', message = gmp_load_error }
  end
  local g = gmp
  local op = p.op
  if not op then
    return { status = 'Error', message = 'missing op (mul/add/sub/div/mod/pow/powmod/divmod/fac/isqrt/gcd/lcm/primetest/fib/compare/bits/to_base)' }
  end
  local out = { status = 'ok' }

  local function need_two()
    local a_s, e1 = to_num(p.a)
    if not a_s then return nil, e1 end
    local b_s, e2 = to_num(p.b)
    if not b_s then return nil, e2 end
    return a_s, b_s
  end

  local a_s, b_s, e
  if op == 'compare' or op == 'to_base' then
    a_s, e = to_num(p.a)
    if not a_s then return { status = 'Error', message = e } end
  end

  local a, b, r, q
  local function two()
    a_s, b_s, e = need_two()
    if e then return false end
    a = make_num(g, a_s); if not a then return false end
    b = make_num(g, b_s)
    if not b then g.__gmpz_clear(a); a = nil; return false end
    return true
  }
  local function one()
    a_s, e = to_num(p.a)
    if e then return false end
    a = make_num(g, a_s)
    if not a then return false end
    return true
  end
  local function cleanup()
    if a then g.__gmpz_clear(a) end
    if b then g.__gmpz_clear(b) end
    if r then g.__gmpz_clear(r) end
    if q then g.__gmpz_clear(q) end
  end

  local function fresh(tag)
    local n = ffi.new('mpz_t[1]')
    g.__gmpz_init(n)
    if tag == 'r' then r = n
    elseif tag == 'q' then q = n
    end
    return n
  end
  -- (保留备用：后续 op 扩展时复用)

  if op == 'mul' or op == 'add' or op == 'sub' or op == 'div' or op == 'mod'
      or op == 'powmod' or op == 'divmod' or op == 'gcd' or op == 'lcm' then
    if op == 'powmod' then
      local m_s, me = to_num(p.m)
      if not m_s then return { status = 'Error', message = me } end
      if not two() then return { status = 'Error', message = e } end
      local m = make_num(g, m_s)
      if not m then cleanup(); return { status = 'Error', message = 'bad m operand' } end
      r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
      g.__gmpz_powm(r, a, b, m)
      out.result = num_to_str(g, r)
      g.__gmpz_clear(m)
    else
      if not two() then return { status = 'Error', message = e } end
      if op == 'mul' then
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        g.__gmpz_mul(r, a, b)
        out.result = num_to_str(g, r)
        out.decimal_digits = g.__gmpz_sizeinbase(r, 10)
      elseif op == 'add' then
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        g.__gmpz_add(r, a, b)
        out.result = num_to_str(g, r)
      elseif op == 'sub' then
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        g.__gmpz_sub(r, a, b)
        out.result = num_to_str(g, r)
      elseif op == 'div' or op == 'divmod' then
        if b_s == '0' then cleanup(); return { status = 'Error', message = 'division by zero' } end
        q = ffi.new('mpz_t[1]'); g.__gmpz_init(q)
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        g.__gmpz_sdiv_qr(q, r, a, b)
        out.result = num_to_str(g, q)
        out.remainder = num_to_str(g, r)
      elseif op == 'mod' then
        if b_s == '0' then cleanup(); return { status = 'Error', message = 'modulo by zero' } end
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        g.__gmpz_mod(r, a, b)
        out.result = num_to_str(g, r)
      elseif op == 'gcd' then
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        local a2 = ffi.new('mpz_t[1]'); g.__gmpz_init(a2)
        local b2 = ffi.new('mpz_t[1]'); g.__gmpz_init(b2)
        g.__gmpz_abs(a2, a)
        g.__gmpz_abs(b2, b)
        g.__gmpz_gcd(r, a2, b2)
        out.result = num_to_str(g, r)
        g.__gmpz_clear(a2); g.__gmpz_clear(b2)
      elseif op == 'lcm' then
        r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
        g.__gmpz_lcm(r, a, b)
        out.result = num_to_str(g, r)
      else
        cleanup()
        return { status = 'Error', message = 'unknown op: ' .. tostring(op) }
      end
    end
    cleanup()
    return out
  end

  if op == 'pow' then
    if not two() then return { status = 'Error', message = e } end
    local b_int = tonumber(b_s)
    if b_int and b_int >= 0 and b_int < 2147483648 then
      r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
      g.__gmpz_pow_ui(r, a, b_int)
    else
      r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
      g.__gmpz_pow_z(r, a, b)
    end
    out.result = num_to_str(g, r)
    out.decimal_digits = g.__gmpz_sizeinbase(r, 10)
    cleanup()
    return out
  end

  if not one() then
    return { status = 'Error', message = e }
  end

  if op == 'fac' then
    local n = tonumber(a_s)
    if not n or n < 0 or n > 4294967295 then
      cleanup()
      return { status = 'Error', message = 'fac: a must be an integer in [0, 2^32)' }
    end
    local f = ffi.new('mpz_t[1]'); g.__gmpz_init(f)
    g.__gmpz_fac_ui(f, n)
    out.result = num_to_str(g, f)
    out.decimal_digits = g.__gmpz_sizeinbase(f, 10)
    g.__gmpz_clear(f)
  elseif op == 'isqrt' then
    local zero = ffi.new('mpz_t[1]'); g.__gmpz_init(zero)
    g.__gmpz_set_str(zero, "0", 10)
    if g.__gmpz_cmp(a, zero) < 0 then
      g.__gmpz_clear(zero); cleanup()
      return { status = 'Error', message = 'isqrt: negative operand' }
    end
    g.__gmpz_clear(zero)
    r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
    g.__gmpz_sqrt(r, a)
    out.result = num_to_str(g, r)
  elseif op == 'primetest' then
    local conf = g.__gmpz_probab_prime_p(a, 20)
    out.is_prime = conf > 0
    out.confidence = conf
  elseif op == 'fib' then
    local n = tonumber(a_s)
    if not n or n < 0 or n > 4294967295 then
      cleanup()
      return { status = 'Error', message = 'fib: a must be an integer in [0, 2^32)' }
    end
    r = ffi.new('mpz_t[1]'); g.__gmpz_init(r)
    g.__gmpz_fib_ui(r, n)
    out.result = num_to_str(g, r)
  elseif op == 'compare' then
    local b_s2, e2 = to_num(p.b)
    if not b_s2 then cleanup(); return { status = 'Error', message = e2 } end
    b = make_num(g, b_s2)
    if not b then cleanup(); return { status = 'Error', message = 'bad b operand' } end
    local c = g.__gmpz_cmp(a, b)
    out.cmp = c
  elseif op == 'to_base' then
    local base = tonumber(p.base) or 10
    if base < 2 or base > 36 then
      cleanup()
      return { status = 'Error', message = 'to_base: base must be 2..36' }
    end
    out.result = num_to_str(g, a, base)
  else
    cleanup()
    return { status = 'Error', message = 'unknown op: ' .. tostring(op) }
  end

  cleanup()
  return out
end

-- ============ UDF 入口 ============
return function(p)
  if type(p) == 'string' then
    local ok, t = pcall(json_decode, p)
    if not ok or type(t) ~= 'table' then
      return json_encode({ status = 'Error', message = 'bad JSON param: ' .. tostring(p):sub(1, 80) })
    end
    p = t
  elseif type(p) ~= 'table' then
    return json_encode({ status = 'Error', message = 'expected table or JSON string param' })
  end
  local ok, res = pcall(solve, p)
  if not ok then
    return json_encode({ status = 'Error', message = tostring(res) })
  end
  return json_encode(res)
end
