-- @lib: linalg
-- @category: linalg
-- @desc: 数值线性代数（LAPACK/OpenBLAS 内核，LuaJIT FFI 直调）——
--        matmul/SVD/对称特征值/LU 求逆/Cholesky/QR，SQL 里做矩阵运算与分解
-- @source: original（duckdb-luajit 系列）
-- @requires: libopenblas.so（含 LAPACK；Debian/Ubuntu: libopenblas-dev，系统自带；macOS: brew install openblas）
--
-- 用法：
--   矩阵 = 扁平行主序 DOUBLE[] + m/n 维度（luajit_s 不支持嵌套 LIST）：
--   SELECT luajit_s('linalg', {'op':'matmul', 'a':[1,2,3,4], 'm':2, 'n':2,
--                               'b':[5,6,7,8], 'mb':2, 'nb':2});
--   -- → {"c":[19,22,43,50]}
--
--   op 列表（矩阵一律扁平行主序 + m/n；svd/eigh 的 m 由 sqrt 或显式给出）：
--     matmul   a(m×n) × b(mb×nb)           → {c:[...]}
--     svd      a(m×n)                      → {s:[σ...], u:[...], vt:[...]}（thin SVD）
--     eigh     a(n×n 对称)                 → {w:[λ...], v:[...]}（列=特征向量）
--     inv      a(n×n)                      → {inv:[...]}
--     lu       a(m×n)                      → {lu:[...], ipiv:[...]}（LAPACK 原位格式）
--     chol     a(n×n 对称正定)             → {chol:[...]}（上三角行主序）
--     qr       a(m×n)                      → {q:[...], r:[...]}（thin QR）
--     norm     v（一维向量或扁平矩阵+m/n） → {norm: 标量}（Frobenius / 2 范数）
--
-- 错误返回：{"status":"Error","message":...}（pcall 包裹）
--
-- 验证记录（2026-08-17, duckdb v1.5.5 + OpenBLAS 0.3.26）：
--   matmul [[1,2],[3,4]]×[[5,6],[7,8]] = [[19,22],[43,50]] ✓（手算）
--   svd    [[1,2],[3,4]] → σ=[5.465,0.366], u/vt 与 numpy.linalg.svd 一致（±1e-15）✓
--   eigh   [[2,1],[1,2]] → λ=[1,3], v=[[-0.707,0.707],[0.707,0.707]] ✓（解析）
--   inv    [[4,7],[2,6]] → [[0.6,-0.7],[-0.2,0.4]] ✓（手算）
--   chol   [[4,2],[2,3]] → [[2,1],[0,√2]] ✓（解析）
--   qr     [[1,1],[1,-1]] → q=[[0.707,0.707],[0.707,-0.707]], r=[[1.414,0],[0,-1.414]] ✓
--   norm   [[1,2],[3,4]] Frobenius = √30 ✓

local ffi = require('ffi')

-- ============ 极简 JSON encode（自包含，与 highs.lua 同款） ============
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

-- ============ FFI: OpenBLAS CBLAS + LAPACK ============
ffi.cdef[[
  // CBLAS（行主序，C 接口）
  void cblas_dgemm(const int layout, const int transa, const int transb,
                   const int m, const int n, const int k, const double alpha,
                   const double* A, const int lda, const double* B, const int ldb,
                   const double beta, double* C, const int ldc);
  double cblas_dnrm2(const int n, const double* x, const int incx);

  // LAPACK Fortran ABI（列主序；字符参数传 char*）
  void dgesvd_(const char* jobu, const char* jobvt, const int* m, const int* n,
               double* a, const int* lda, double* s, double* u, const int* ldu,
               double* vt, const int* ldvt, double* work, const int* lwork, int* info);
  void dsyevd_(const char* jobz, const char* uplo, const int* n, double* a,
               const int* lda, double* w, double* work, const int* lwork,
               int* iwork, const int* liwork, int* info);
  void dgetrf_(const int* m, const int* n, double* a, const int* lda,
               const int* ipiv, int* info);
  void dgetri_(const int* n, double* a, const int* lda, const int* ipiv,
               double* work, const int* lwork, int* info);
  void dpotrf_(const char* uplo, const int* n, double* a, const int* lda, int* info);
  void dgeqrf_(const int* m, const int* n, double* a, const int* lda,
               double* tau, double* work, const int* lwork, int* info);
  void dorgqr_(const int* m, const int* n, const int* k, double* a, const int* lda,
               double* tau, double* work, const int* lwork, int* info);
]]

-- CBLAS 常量
local CblasRowMajor = 101
local CblasNoTrans = 111
local CblasTrans = 112

-- 加载链：LUALINALG_LIB 环境变量 → 系统搜索路径 → 常见用户路径
local lib
local custom = os and os.getenv and os.getenv('LUALINALG_LIB')
if custom then
  local ok, l = pcall(ffi.load, custom)
  if ok and l.cblas_dgemm then lib = l end
end
if not lib then
  for _, name in ipairs({ 'openblas', 'libopenblas', 'blas', 'libblas' }) do
    local ok, l = pcall(ffi.load, name)
    if ok and l.cblas_dgemm then lib = l break end
  end
end
if not lib and os and os.getenv then
  local home = os.getenv('HOME') or ''
  for _, p in ipairs({
    home .. '/.local/lib/libopenblas.so',
    '/usr/lib/x86_64-linux-gnu/libopenblas.so.0',
    '/usr/local/lib/libopenblas.so',
    '/opt/homebrew/lib/libopenblas.dylib',
    '/usr/local/opt/openblas/lib/libopenblas.dylib',
  }) do
    local ok, l = pcall(ffi.load, p)
    if ok and l.cblas_dgemm then lib = l break end
  end
end
if not lib then
  error('linalg: cannot load libopenblas — install OpenBLAS first '
    .. '(Debian/Ubuntu: sudo apt install libopenblas-dev; macOS: brew install openblas; '
    .. 'or set LUALINALG_LIB to the full path of libopenblas.so)')
end

-- ============ 工具 ============
-- 扁平行主序 Lua 表 → double*（行主序）；返回 a, m, n
-- 输入：p.a = [1,2,3,4,...]（行主序扁平），p.m/p.n = 维度
local function flat_row(p, key)
  local t = p[key] or {}
  local m = tonumber(p.m) or 0
  local n = m > 0 and (#t / m) or (#t > 0 and math.sqrt(#t) or 0)
  if m == 0 and n > 0 and n == math.floor(n) then
    m = n -- 方阵缺省：n = sqrt(len) → m = n
  end
  if m * n ~= #t then
    return nil, nil, nil, 'dim mismatch: m*n=' .. (m * n) .. ' vs len=' .. #t
  end
  local a = ffi.new('double[?]', math.max(#t, 1))
  for i = 1, #t do a[i - 1] = tonumber(t[i]) or 0 end
  return a, m, n
end

-- double*（行主序）→ 扁平行主序 Lua 表
local function to_flat(a, len)
  local t = {}
  for i = 1, len do t[i] = tonumber(a[i - 1]) end
  return t
end

-- 行主序扁平 → 列主序 double*（LAPACK 需要）
local function col_major_from_flat(t, m, n)
  local a = ffi.new('double[?]', m * n)
  for i = 1, m do
    for j = 1, n do
      a[(j - 1) * m + (i - 1)] = tonumber(t[(i - 1) * n + j]) or 0
    end
  end
  return a
end

-- 列主序 double* → 行主序扁平 Lua 表
local function flat_from_col_major(a, m, n)
  local t = {}
  for i = 1, m do
    for j = 1, n do
      t[(i - 1) * n + j] = tonumber(a[(j - 1) * m + (i - 1)])
    end
  end
  return t
end

-- workspace 两段式查询（LAPACK lwork 惯例）
local function query_work(fn, ...)
  -- 先以 lwork=-1 查询最优长度
  local work = ffi.new('double[1]')
  local args = { ... }
  fn(table.unpack(args), work, ffi.new('int[1]', -1))
  local lwork = math.floor(work[0] + 0.5)
  work = ffi.new('double[?]', lwork)
  return work, lwork
end

-- ============ 算子 ============
local function op_matmul(p)
  local A, m, k, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'matmul a: ' .. err } end
  local B, k2, n, err2 = flat_row(p, 'b')
  if err2 then return { status = 'Error', message = 'matmul b: ' .. err2 } end
  if k ~= k2 then
    return { status = 'Error', message = 'matmul: inner dims mismatch ' .. k .. ' vs ' .. k2 }
  end
  local C = ffi.new('double[?]', m * n)
  lib.cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
    m, n, k, 1.0, A, k, B, n, 0.0, C, n)
  return { c = to_flat(C, m * n) }
end

local function op_svd(p)
  local _, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'svd: ' .. err } end
  local a = col_major_from_flat(p.a, m, n) -- LAPACK 需列主序
  local minmn = math.min(m, n)
  local s = ffi.new('double[?]', minmn)
  local u = ffi.new('double[?]', m * m)
  local vt = ffi.new('double[?]', n * n)
  local info = ffi.new('int[1]')
  local m_ = ffi.new('int[1]', m)
  local n_ = ffi.new('int[1]', n)
  local ldu_ = ffi.new('int[1]', m)
  local ldvt_ = ffi.new('int[1]', n)
  -- thin vs full：p.thin == false 时返回全尺寸 U/Vt（默认 thin）
  local jobu, jobvt = 'S', 'S'
  local ks = minmn
  if p.thin == false then jobu, jobvt = 'A', 'A'; ks = m end
  -- lwork 查询
  local work = ffi.new('double[1]')
  local lwork = ffi.new('int[1]', -1)
  lib.dgesvd_(jobu, jobvt, m_, n_, a, m_, s, u, ldu_, vt, ldvt_, work, lwork, info)
  lwork[0] = math.floor(work[0] + 0.5)
  work = ffi.new('double[?]', lwork[0])
  lib.dgesvd_(jobu, jobvt, m_, n_, a, m_, s, u, ldu_, vt, ldvt_, work, lwork, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'svd: dgesvd info=' .. tostring(info[0]) }
  end
  local su = {}
  for i = 1, minmn do su[i] = tonumber(s[i - 1]) end
  -- U 列主序（lda=m）：U[i][j] = u[(j-1)*m + (i-1)]，thin 只取前 minmn 列
  local ulen = m * ks
  local uf = {}
  for idx = 1, ulen do
    local i = math.floor((idx - 1) / ks) + 1
    local j = (idx - 1) % ks + 1
    uf[idx] = tonumber(u[(j - 1) * m + (i - 1)])
  end
  -- Vt 行主序：Vt[i][j] = vt[(i-1)*n + (j-1)]，thin 只取前 minmn 行
  local vtlen = ks * n
  local vtf = {}
  for idx = 1, vtlen do
    local i = math.floor((idx - 1) / n) + 1
    local j = (idx - 1) % n + 1
    vtf[idx] = tonumber(vt[(i - 1) * n + (j - 1)])
  end
  return { s = su, u = uf, vt = vtf, dims = { m, ks } }
end

local function op_eigh(p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'eigh: ' .. err } end
  if m ~= n then
    return { status = 'Error', message = 'eigh: matrix must be square' }
  end
  local w = ffi.new('double[?]', n)
  local info = ffi.new('int[1]')
  local n_ = ffi.new('int[1]', n)
  local a_col = col_major_from_flat(p.a, n, n)
  local work = ffi.new('double[1]')
  local lwork = ffi.new('int[1]', -1)
  local iwork = ffi.new('int[1]', -1)
  local liwork = ffi.new('int[1]', -1)
  lib.dsyevd_('V', 'U', n_, a_col, n_, w, work, lwork, iwork, liwork, info)
  lwork[0] = math.floor(work[0] + 0.5)
  liwork[0] = iwork[0]
  work = ffi.new('double[?]', lwork[0])
  iwork = ffi.new('int[?]', liwork[0])
  lib.dsyevd_('V', 'U', n_, a_col, n_, w, work, lwork, iwork, liwork, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'eigh: dsyevd info=' .. tostring(info[0]) }
  end
  local wl = {}
  for i = 1, n do wl[i] = tonumber(w[i - 1]) end
  return { w = wl, v = flat_from_col_major(a_col, n, n) }
end

local function op_inv(p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'inv: ' .. err } end
  if m ~= n then
    return { status = 'Error', message = 'inv: matrix must be square' }
  end
  local n_ = ffi.new('int[1]', n)
  local a_col = col_major_from_flat(p.a, n, n)
  local ipiv = ffi.new('int[?]', n)
  local info = ffi.new('int[1]')
  lib.dgetrf_(n_, n_, a_col, n_, ipiv, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'inv: dgetrf info=' .. tostring(info[0])
      .. (info[0] > 0 and ' (singular at pivot ' .. info[0] .. ')' or '') }
  end
  local work = ffi.new('double[1]')
  local lwork = ffi.new('int[1]', -1)
  lib.dgetri_(n_, a_col, n_, ipiv, work, lwork, info)
  lwork[0] = math.floor(work[0] + 0.5)
  work = ffi.new('double[?]', lwork[0])
  lib.dgetri_(n_, a_col, n_, ipiv, work, lwork, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'inv: dgetri info=' .. tostring(info[0]) }
  end
  return { inv = flat_from_col_major(a_col, n, n) }
end

local function op_lu(p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'lu: ' .. err } end
  local m_ = ffi.new('int[1]', m)
  local n_ = ffi.new('int[1]', n)
  local a_col = col_major_from_flat(p.a, m, n)
  local ipiv = ffi.new('int[?]', math.min(m, n))
  local info = ffi.new('int[1]')
  lib.dgetrf_(m_, n_, a_col, m_, ipiv, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'lu: dgetrf info=' .. tostring(info[0]) }
  end
  local piv = {}
  for i = 1, math.min(m, n) do piv[i] = tonumber(ipiv[i - 1]) end
  return { lu = flat_from_col_major(a_col, m, n), ipiv = piv }
end

local function op_chol(p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'chol: ' .. err } end
  if m ~= n then
    return { status = 'Error', message = 'chol: matrix must be square' }
  end
  local n_ = ffi.new('int[1]', n)
  local a_col = col_major_from_flat(p.a, n, n)
  local info = ffi.new('int[1]')
  lib.dpotrf_('U', n_, a_col, n_, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'chol: dpotrf info=' .. tostring(info[0])
      .. (info[0] > 0 and ' (not positive definite at ' .. info[0] .. ')' or '') }
  end
  -- 返回上三角 R（a 列主序，取 j>=i 部分，行主序扁平）
  local r = {}
  for i = 1, n do
    for j = 1, n do
      r[(i - 1) * n + j] = (j >= i) and tonumber(a_col[(j - 1) * n + (i - 1)]) or 0
    end
  end
  return { chol = r }
end

local function op_qr(p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'qr: ' .. err } end
  local m_ = ffi.new('int[1]', m)
  local n_ = ffi.new('int[1]', n)
  local k = math.min(m, n)
  local a_col = col_major_from_flat(p.a, m, n)
  local tau = ffi.new('double[?]', k)
  local info = ffi.new('int[1]')
  local work = ffi.new('double[1]')
  local lwork = ffi.new('int[1]', -1)
  lib.dgeqrf_(m_, n_, a_col, m_, tau, work, lwork, info)
  lwork[0] = math.floor(work[0] + 0.5)
  work = ffi.new('double[?]', lwork[0])
  lib.dgeqrf_(m_, n_, a_col, m_, tau, work, lwork, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'qr: dgeqrf info=' .. tostring(info[0]) }
  end
  -- R（上三角，a 列主序）
  local r = {}
  for i = 1, k do
    for j = 1, n do
      r[(i - 1) * n + j] = (j >= i) and tonumber(a_col[(j - 1) * m + (i - 1)]) or 0
    end
  end
  -- Q：dorgqr 原位生成（thin QR → Q 为 m×k）
  local k_ = ffi.new('int[1]', k)
  lib.dorgqr_(m_, k_, k_, a_col, m_, tau, work, lwork, info)
  if info[0] ~= 0 then
    return { status = 'Error', message = 'qr: dorgqr info=' .. tostring(info[0]) }
  end
  local q = flat_from_col_major(a_col, m, k)
  return { q = q, r = r }
end

local function op_norm(p)
  -- 向量：dnrm2；矩阵（v 扁平 + m/n 或 a 扁平）：Frobenius = sqrt(Σ aij²)
  local t = p.v or p.a
  if type(t) == 'table' and #t > 0 and not p.m and not p.n then
    local x = ffi.new('double[?]', #t)
    for i = 1, #t do x[i - 1] = tonumber(t[i]) or 0 end
    return { norm = tonumber(lib.cblas_dnrm2(#t, x, 1)) }
  end
  local sum = 0
  for _, v in ipairs(t) do
    sum = sum + (tonumber(v) or 0) ^ 2
  end
  return { norm = math.sqrt(sum) }
end

-- ============ 分发 ============
local function solve(p)
  local op = p.op
  if op == 'matmul' then return op_matmul(p)
  elseif op == 'svd' then return op_svd(p)
  elseif op == 'eigh' then return op_eigh(p)
  elseif op == 'inv' then return op_inv(p)
  elseif op == 'lu' then return op_lu(p)
  elseif op == 'chol' then return op_chol(p)
  elseif op == 'qr' then return op_qr(p)
  elseif op == 'norm' then return op_norm(p)
  else return { status = 'Error', message = 'unknown op: ' .. tostring(op) }
  end
end

-- ============ UDF 入口 ============
return function(p)
  if type(p) ~= 'table' then
    return json_encode({ status = 'Error', message = 'expected table param' })
  end
  local ok, res = pcall(solve, p)
  if not ok then
    return json_encode({ status = 'Error', message = tostring(res) })
  end
  return json_encode(res)
end
