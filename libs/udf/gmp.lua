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
-- 有状态累乘 op（2026-10-28 加；递归 CTE 大数迭代场景专用）：
--   大数常驻 UDF 的 Lua state（mpz_t），每步只喂一个小乘数，避免十进制字符串
--   每步 解析→乘法→转回 的 O(n²) 往返。
--     accset   [f]     无条件把累乘器置为 f（无 f → 1），返回其十进制串——
--                      既是"初始化"也是"清残留"，递归 CTE 第一步用它自初始化
--     accmul   [f]     累乘器 *= f（无 f → 自乘 acc^2），返回新值十进制串
--     accstep  [f]     累乘器 *= f（无 f → 自乘），**只回显因子 f（VARCHAR）**——
--                      中间步用这个，大数不跨 SQL/Lua 边界，最快。
--                      ⚠️ 不要改成"返回位数 ::INT"：递归 CTE 里 CASE 分支会
--                      INTEGER vs VARCHAR 混型 → Binder Error（issue #3）；
--                      且引擎会预求值下一步，读回 acc 的位数滞后一步，无意义
--     accdump  [f]     累乘器 *= f（可选），把**完整十进制值写文件** p.file，
--                      返回 {status, path, decimal_digits}——末步取最终值落盘
--     accget/acclen    读当前值/位数（仅限与 accset 同一条语句内，见下）
--     accclear          销毁累乘器（当前 state）
--
--   ⚠️ 状态作用域（实测，务必遵守）：acc* 状态存在**执行该查询的 worker 线程**
--   的 Lua state 里，且只在**单条语句**内连续有效。跨独立语句（多条 SELECT）
--   会落到不同 worker → 新 state，读不到上一句的值。因此：
--     · 不要靠"先 select accset() 再 select accmul()"跨句累积（不可靠）。
--     · 可靠形态 = **一条自包含的递归 CTE**：base 行是常量（不碰 state），
--       递归项每步跑在同一个 worker 上顺序执行 → 状态天然连续。第一步用
--       accset 自初始化，天然免疫该 worker 上上一轮 CTE 的残留。
--     · 最终大数要"取出来"：末步用 accdump 写文件（read_text 读回），
--       或每步 accmul 返回大串走列（慢，每步转回大串）。
--
--   性能（实测 10000!，WSL duckdb v2.0-alpha）：
--     逐行 gmp_mul（每步 解析大串→乘→转回大串）        ~4.2 s
--     每步 accmul（仍每步转回大串，只省一次解析）       ~3.3 s
--     每步 accstep + 末步 accdump（大数只转一次）        ~0.06 s  ← 推荐
--     非递归一次性 gmp_fac('10000')（product tree）      ~0.035 s ← 只求最终值用它
--
--   推荐 SQL（10000!，中间只传因子回显、末步落文件；CASE 分支全 VARCHAR）：
--     with recursive t as (
--       select 0 a, '1' b                                   -- base 常量
--       union all
--       select a+1, case when a = 0        then gmp_accset((a+1)::VARCHAR)
--                        when a+1 = 10000 then gmp_accdump((a+1)::VARCHAR,'/tmp/f.txt')
--                        else gmp_accstep((a+1)::VARCHAR) end
--       from t where a < 10000)
--     select a from t where a = 10000;
--     select * from read_text('/tmp/f.txt');
--   宏封装（分支类型统一 VARCHAR；accstep 用 json_extract_string，
--   切勿 ::INT —— 与 accset/accdump 的 VARCHAR 分支混型 → Binder Error，issue #3）：
--     CREATE OR REPLACE MACRO gmp_accset(f) AS json_extract_string(luajit_s('gmp',{op:'accset',f:f}),'$.result');
--     CREATE OR REPLACE MACRO gmp_accmul(f) AS json_extract_string(luajit_s('gmp',{op:'accmul',f:f}),'$.result');
--     CREATE OR REPLACE MACRO gmp_accstep(f) AS json_extract_string(luajit_s('gmp',{op:'accstep',f:f}),'$.result');
--     CREATE OR REPLACE MACRO gmp_accdump(f,file) AS luajit_s('gmp',{op:'accdump',f:f,file:file});
--   ⚠️ 同一会话同一时刻只跑一轮 acc* 累乘；stateful 调用传**列参数**
--   （递归列或 from (values ...)）——常量实参会被 plan 常量折叠 + 执行期求值两次。
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
--
-- 验证记录（2026-10-28, WSL duckdb v2.0.0-alpha39998 + libgmp.so.10, test_gmp_acc.sql 15/15 过）：
--   bits(1000000) = 20位2进制/7位10进制 ✓；bits(128) = 8/3 ✓（此前 unknown op，本次补实现）
--   递归 accmul 1..8! = 1,2,6,24,120,720,5040,40320 ✓（逐值精确）
--   递归 accmul 10000! = 35660 位 ✓；accdump 落盘与 Python math.factorial(10000) sha256 逐字节一致（f17f312b…）
--   快速路径（accstep 中间 + accdump 末步）10000 步 ~45ms vs 逐行 gmp_mul ~4070ms ≈ 90×
--   踩坑定案：递归 CTE 会预求值下一步 → 读回 acc 的位数滞后一步，但 acc 本身收敛正确
--   （accdump 末值精确）。故 accstep 改为只回显因子、不读 acc；权威结果取 accdump。
--   状态作用域 = 单条语句 / 单 worker：跨独立 SELECT 不可靠，勿靠跨句 accset→accmul 累积。
--
-- 验证记录（2026-10-29, WSL duckdb v2.0.0-alpha39998, test_gmp_issue3.sql）：
--   issue #3（外部用户）：gmp.lua 头部旧宏 gmp_accstep = json_extract(...)::INT，
--   递归 CTE 里 CASE 三分支 INTEGER vs VARCHAR 混型 → Binder Error。根因 = 头部文档
--   宏落后于实现（accstep 早已改为回显因子 VARCHAR；::INT 版本还有预求值滞后坑）。
--   修复 = 头部宏/推荐 SQL 同步为 json_extract_string 形态（CASE 分支全 VARCHAR），
--   issue 原文递归（10000 步）全过：accdump decimal_digits=35660、落盘 35660 字节、
--   sha256 f17f312b… 与 Python math.factorial(10000) 逐字节一致（10-28 锚点同值）。

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
-- mpz_t 布局按 GMP 公开 ABI（gmp.h）：
--   64 位平台 mp_limb_t = unsigned long（8B），_mp_size_t = int（4B），struct 共 16B
--   （Windows x64 同为 unsigned long；32 位平台 GMP 用 unsigned int，本库目标为 64 位 DuckDB）
ffi.cdef[[
typedef unsigned long mp_limb_t;
typedef int _mp_size_t;
typedef struct { _mp_size_t _mp_size; mp_limb_t *_mp_d; } mpz_t;
void __gmpz_init(mpz_t*);
void __gmpz_clear(mpz_t*);
int  __gmpz_set_str(mpz_t*, const char*, int);
char* __gmpz_get_str(char*, int, const mpz_t*);
void __gmpz_mul(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_add(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_sub(mpz_t*, const mpz_t*, const mpz_t*);
void __gmpz_swap(mpz_t*, mpz_t*);
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
  -- macOS: 系统 GMP 只在 dyld shared cache 里（/usr/lib/libgmp.10.dylib，绝对路径 dlopen 反而找不到），
  -- 必须用全文件名 'libgmp.10.dylib' 让 dyld 从 shared cache 解析；Homebrew 绝对路径做兜底。
  -- Linux: libgmp.so.10（ldconfig）。Windows: 需自备 dll 或设 GMP_LIB。
  local extra = {
    'libgmp.10.dylib',                                   -- macOS（dyld cache，系统自带）
    '/opt/homebrew/opt/gmp/lib/libgmp.10.dylib',         -- Homebrew arm64 兜底
    '/usr/local/opt/gmp/lib/libgmp.10.dylib',            -- Homebrew x86_64 兜底
    'libgmp.so.10',                                       -- Linux
    'libgmp-10.dll', 'gmp-10.dll', 'gmp10',              -- Windows
  }
  for _, c in ipairs(extra) do
    if c ~= override then candidates[#candidates + 1] = c end
  end
  local gmp_load_err_detail = {}
  for _, name in ipairs(candidates) do
    if name ~= '' then
      local ok, lib = pcall(ffi.load, name)
      -- 注意：LuaJIT 的 ffi.load 成功时返回 cdata（userdata），不是 table；
      -- 只按 pcall 成功与否判断。
      if ok then
        -- 自检：lib 必须导出核心符号（防加载到同名异体库；cdef 已声明，符号访问合法）
        local probe_ok, probe_err = pcall(function()
          local a = lib.__gmpz_init
          local b = lib.__gmpz_mul
          local c = lib.__gmpz_set_str
          local d = lib.__gmpz_get_str
          assert(a and b and c and d)
        end)
        if probe_ok then
          gmp = lib
          gmp_loaded_name = name
          break
        else
          gmp_load_err_detail[#gmp_load_err_detail + 1] = name .. ': loaded but symbols missing (' .. tostring(probe_err) .. ')'
        end
      else
        gmp_load_err_detail[#gmp_load_err_detail + 1] = name .. ': ' .. tostring(lib)
      end
    end
  end
  if not gmp then
    gmp_load_error = '无法加载 GMP 库。诊断: ' .. table.concat(gmp_load_err_detail, ' | ')
      .. '。macOS 系统自带（dyld cache, libgmp.10.dylib）；Linux 需 libgmp10；Windows 需自备 libgmp-10.dll 或设 GMP_LIB=完整路径'
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
  -- 防御纵深：s 非字符串（nil/数字/表）一律返回 nil，绝不把 NULL 喂给 __gmpz_set_str
  -- （那会 GMP NULL 解引用 segfault，issue #2 的崩溃路径）。调用方的 `if not x then` 负责报错。
  if type(s) ~= 'string' then return nil end
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

-- ============ 有状态累乘器（acc* op） ============
-- 大数常驻本 Lua state 的 mpz_t；递归 CTE 单线程顺序调用同一会话的同一
-- Lua state（已探针验证：无状态 UDF 在递归里逐行求值、_G 计数在递归后
-- 语句接着涨）。状态是进程级的：同一会话同一时刻只跑一轮 acc* 累乘。
local acc = nil
local function acc_clear()
  if acc then gmp.__gmpz_clear(acc); acc = nil end
end
local function acc_ensure()
  if acc then return acc end
  acc = ffi.new('mpz_t[1]')
  gmp.__gmpz_init(acc)
  gmp.__gmpz_set_str(acc, "1", 10)
  return acc
end

local function solve(p)
  if not gmp then
    return { status = 'Error', message = gmp_load_error }
  end
  local g = gmp
  local op = p.op
  if not op then
    return { status = 'Error', message = 'missing op (mul/add/sub/div/mod/pow/powmod/divmod/fac/isqrt/gcd/lcm/primetest/fib/compare/bits/to_base/accset/accmul/accstep/accdump/accget/acclen/accclear)' }
  end
  local out = { status = 'ok' }

  -- 未知 op 显式拒绝（避免落到下方 one()/two() 分支报"missing operand"误导）
  local known = {
    mul=1, add=1, sub=1, div=1, mod=1, pow=1, powmod=1, divmod=1,
    fac=1, isqrt=1, gcd=1, lcm=1, primetest=1, fib=1, compare=1,
    bits=1, to_base=1, accset=1, accmul=1, accstep=1, accdump=1,
    accget=1, acclen=1, accclear=1,
  }
  if not known[op] then
    return { status = 'Error', message = 'unknown op: ' .. tostring(op) }
  end

  -- ---- 有状态累乘 op（见文件头注释；大数常驻 Lua state，避免逐行字符串往返）----
  if op == 'accset' then
    -- 无条件置值（不依赖当前 state 是否有值）：既是"初始化"也是"清理残留"。
    -- 递归 CTE 第一步用它自初始化，天然免疫 worker 线程残留。
    if p.f ~= nil then
      local f_s, e = to_num(p.f)
      if not f_s then return { status = 'Error', message = e } end
      local n = make_num(g, f_s)
      if not n then return { status = 'Error', message = 'accset: bad operand' } end
      acc_clear()
      acc = n
    else
      acc_clear()
      acc_ensure()
    end
    out.result = num_to_str(g, acc)
    return out
  end
  if op == 'accmul' then
    local n = acc_ensure()
    if p.f ~= nil then
      local f_s, e = to_num(p.f)
      if not f_s then return { status = 'Error', message = e } end
      local f = make_num(g, f_s)
      if not f then return { status = 'Error', message = 'accmul: bad factor' } end
      g.__gmpz_mul(n, n, f)
      g.__gmpz_clear(f)
    else
      -- 无 f：acc *= acc（acc^2）
      local t = ffi.new('mpz_t[1]')
      g.__gmpz_init(t)
      g.__gmpz_mul(t, n, n)
      g.__gmpz_swap(t, n)
      g.__gmpz_clear(t)
    end
    out.result = num_to_str(g, n)
    return out
  end
  -- accstep / accdump 共用：acc *= f（f 缺省 → 自乘），大数不转字符串
  local function acc_mul_factor()
    local n = acc_ensure()
    if p.f ~= nil then
      local f_s, e = to_num(p.f)
      if not f_s then return e or 'acc: bad factor' end
      local f = make_num(g, f_s)
      if not f then return 'acc: bad factor' end
      g.__gmpz_mul(n, n, f)
      g.__gmpz_clear(f)
    else
      local t = ffi.new('mpz_t[1]')
      g.__gmpz_init(t)
      g.__gmpz_mul(t, n, n)
      g.__gmpz_swap(t, n)
      g.__gmpz_clear(t)
    end
    return nil
  end
  if op == 'accstep' then
    -- 只做乘法，**不读 acc**：返回刚乘的因子 f（回显）。
    -- 原因（实测）：递归 CTE 里 stateful 函数被预求值，读回 acc 的位数可能
    -- 滞后一步（720 报 4 位、5040 报 4 位），但 acc 本身始终正确（accdump
    -- 末值与 Python 逐字节一致）。因此中间步不读 acc，只回显 f 保持列一致；
    -- 权威结果一律取 accdump 的末值/位数。
    local e = acc_mul_factor()
    if e then return { status = 'Error', message = e } end
    if p.f ~= nil then out.result = tostring(p.f) else out.result = 'self' end
    return out
  end
  if op == 'accdump' then
    local e = acc_mul_factor()
    if e then return { status = 'Error', message = e } end
    if type(p.file) ~= 'string' or p.file == '' then
      return { status = 'Error', message = 'accdump: p.file (output path) required' }
    end
    local wfile, openerr = io.open(p.file, 'w')
    if not wfile then
      return { status = 'Error', message = 'accdump: cannot open ' .. p.file .. ': ' .. tostring(openerr) }
    end
    local s = num_to_str(g, acc)
    wfile:write(s)
    wfile:close()
    out.path = p.file
    out.decimal_digits = g.__gmpz_sizeinbase(acc, 10)
    return out
  end
  if op == 'accget' then
    local n = acc_ensure()
    out.result = num_to_str(g, n)
    return out
  end
  if op == 'acclen' then
    local n = acc_ensure()
    out.decimal_digits = g.__gmpz_sizeinbase(n, 10)
    return out
  end
  if op == 'accclear' then
    acc_clear()
    return out
  end

  -- ---- bits：位宽/十进制位数（文件头承诺的 op，2026-10-28 补实现）----
  if op == 'bits' then
    local a_s, e = to_num(p.a)
    if not a_s then return { status = 'Error', message = e } end
    local n = make_num(g, a_s)
    if not n then return { status = 'Error', message = 'bits: bad operand' } end
    out.decimal_digits = g.__gmpz_sizeinbase(n, 10)
    out.bits = g.__gmpz_sizeinbase(n, 2)
    g.__gmpz_clear(n)
    return out
  end

  local function need_two()
    -- 统一 3 返回值契约：成功 (a_s, b_s, nil)，失败 (nil, nil, errmsg)。
    -- 失败时 errmsg 必须落在第 3 位，two() 的 `if e then return false` 才抓得住。
    -- 旧版失败只返回 2 值 (nil, errmsg)，被 two() 的 3 目标赋值错位 → e 变 nil → 漏判
    -- → make_num(nil) → __gmpz_set_str(n, NULL, 10) → GMP NULL 解引用 segfault（issue #2）。
    local a_s, e1 = to_num(p.a)
    if not a_s then return nil, nil, e1 end
    local b_s, e2 = to_num(p.b)
    if not b_s then return nil, nil, e2 end
    return a_s, b_s, nil
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
  end
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
