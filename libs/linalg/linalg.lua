-- @lib: linalg
-- @category: linalg
-- @desc: 数值线性代数（LAPACK/OpenBLAS 内核，LuaJIT FFI 直调）——
--        matmul/SVD/对称特征值/LU 求逆/Cholesky/QR，SQL 里做矩阵运算与分解
--        GPU 加速（可选）：LUA_LINALG_GPU=1 且可加载 cuBLAS/cuSOLVER 时，
--        matmul/svd/eigh/inv/lu/chol/qr 自动走 GPU（结果带 backend:'gpu' 标记）；
--        per-call 覆盖：参数里带 backend='gpu'/'cpu'/'auto' 可强制/禁用/自动
--        实测 TPC-H lineitem SVD 加速 18.6×。⚠️ SVD 的 u/vt 列符号可能与 LAPACK
--        相反（固有符号自由度，UΣVT=A 重建不受影响）；cuSOLVER 必须用 64 位 Xgesvd
--        （32 位 dgesvd 在 Ada N≥768 失败）。无 GPU 时静默走 CPU，行为不变。
-- @source: original（duckdb-luajit 系列）
-- @requires: libopenblas.so（含 LAPACK；Debian/Ubuntu: libopenblas-dev，系统自带；macOS: brew install openblas）
--            GPU 模式额外需要 CUDA toolkit（libcublas.so.13/libcusolver.so.12/libcudart）
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

-- 轻量 JSON 解码（UDF 字符串参数 → 表；duckdb-luajit luajit_s 传字符串）
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
local cpu_backend_error = nil
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
  cpu_backend_error = 'linalg: cannot load libopenblas — CPU 算子不可用 '
    .. '(Debian/Ubuntu: sudo apt install libopenblas-dev; macOS: brew install openblas; '
    .. 'or set LUALINALG_LIB to the full path of libopenblas.so; 或用 LUA_LINALG_GPU=1 走 GPU 后端)'
end

-- ============ GPU 后端（可选：LUA_LINALG_GPU=1 且 cuBLAS/cuSOLVER 可加载） ============
-- 仅加速 matmul/svd（实测证明 SVD 是主加速源 18.6×）；其余算子走 CPU。
-- 注意：cuSOLVER 的 SVD 必须用 64 位通用 API cusolverDnXgesvd ——
-- 32 位 cusolverDnDgesvd 在 Ada (sm_89) N≥768 失败（EXECUTION_FAILED，见调研报告 §3.5）。
ffi.cdef[[
  int cublasCreate_v2(void **handle);
  int cublasDestroy_v2(void *handle);
  int cublasDgemm_v2(void *handle, int transa, int transb, int m, int n, int k,
      const double *alpha, const double *A, int lda, const double *B, int ldb,
      const double *beta, double *C, int ldc);
  int cusolverDnCreate(void **handle);
  int cusolverDnCreateParams(void **params);
  int cusolverDnXgesvd_bufferSize(void *handle, void *params, signed char jobu, signed char jobvt,
      int64_t m, int64_t n, int dataTypeA, const void *A, int64_t lda,
      int dataTypeS, const void *S, int dataTypeU, const void *U, int64_t ldu,
      int dataTypeVT, const void *VT, int64_t ldvt, int computeType,
      unsigned long long *wsDev, unsigned long long *wsHost);
  int cusolverDnXgesvd(void *handle, void *params, signed char jobu, signed char jobvt,
      int64_t m, int64_t n, int dataTypeA, void *A, int64_t lda,
      int dataTypeS, void *S, int dataTypeU, void *U, int64_t ldu,
      int dataTypeVT, void *VT, int64_t ldvt, int computeType,
      void *bufDev, unsigned long long wsDev, void *bufHost, unsigned long long wsHost, int *info);
  int cudaMalloc(void **devPtr, unsigned long long size);
  int cudaMemcpy(void *dst, const void *src, unsigned long long count, int kind);
  int cudaFree(void *devPtr);
  int cudaDeviceSynchronize(void);
  // —— 64 位 X 系列：eigh / lu / inv / chol / qr ——
  int cusolverDnXsyevd_bufferSize(void *handle, void *params, int jobz, int uplo,
      int64_t n, int dataTypeA, const void *A, int64_t lda,
      int dataTypeW, const void *W, int dataTypeCompute,
      unsigned long long *wsDev, unsigned long long *wsHost);
  int cusolverDnXsyevd(void *handle, void *params, int jobz, int uplo,
      int64_t n, int dataTypeA, void *A, int64_t lda,
      int dataTypeW, void *W, int dataTypeCompute,
      void *bufDev, unsigned long long wsDev, void *bufHost, unsigned long long wsHost, int *info);
  int cusolverDnXgetrf_bufferSize(void *handle, void *params,
      int64_t m, int64_t n, int dataTypeA, const void *A, int64_t lda,
      int dataTypeCompute, unsigned long long *wsDev, unsigned long long *wsHost);
  int cusolverDnXgetrf(void *handle, void *params,
      int64_t m, int64_t n, int dataTypeA, void *A, int64_t lda,
      int64_t *ipiv, int dataTypeCompute,
      void *bufDev, unsigned long long wsDev, void *bufHost, unsigned long long wsHost, int *info);
  int cusolverDnXgetrs(void *handle, void *params, int trans,
      int64_t n, int64_t nrhs, int dataTypeA, const void *A, int64_t lda,
      const int64_t *ipiv, int dataTypeB, void *B, int64_t ldb, int *info);
  int cusolverDnXpotrf_bufferSize(void *handle, void *params, int uplo,
      int64_t n, int dataTypeA, const void *A, int64_t lda,
      int dataTypeCompute, unsigned long long *wsDev, unsigned long long *wsHost);
  int cusolverDnXpotrf(void *handle, void *params, int uplo,
      int64_t n, int dataTypeA, void *A, int64_t lda, int dataTypeCompute,
      void *bufDev, unsigned long long wsDev, void *bufHost, unsigned long long wsHost, int *info);
  int cusolverDnXgeqrf_bufferSize(void *handle, void *params,
      int64_t m, int64_t n, int dataTypeA, const void *A, int64_t lda,
      int dataTypeTau, const void *tau, int dataTypeCompute,
      unsigned long long *wsDev, unsigned long long *wsHost);
  int cusolverDnXgeqrf(void *handle, void *params,
      int64_t m, int64_t n, int dataTypeA, void *A, int64_t lda,
      int dataTypeTau, void *tau, int dataTypeCompute,
      void *bufDev, unsigned long long wsDev, void *bufHost, unsigned long long wsHost, int *info);
  // 32 位经典 API：QR 的 Q 生成（X 系列无 Xorgqr）
  int cusolverDnDorgqr_bufferSize(void *handle, int m, int n, int k,
      const double *A, int lda, const double *tau, int *lwork);
  int cusolverDnDorgqr(void *handle, int m, int n, int k,
      double *A, int lda, const double *tau, double *work, int lwork, int *info);
]]

local gpu = nil
if (os and os.getenv and os.getenv('LUA_LINALG_GPU') or '') == '1' then
  local function gpu_init()
    local ok_cublas, cublas = pcall(ffi.load, 'cublas')
    local ok_solver, cusolver = pcall(ffi.load, 'cusolver')
    local ok_cudart, cudart = pcall(ffi.load, 'cudart')
    if not (ok_cublas and ok_solver and ok_cudart) then return nil end
    local bh, sh, par = ffi.new('void*[1]'), ffi.new('void*[1]'), ffi.new('void*[1]')
    if cublas.cublasCreate_v2(bh) ~= 0 then return nil end
    if cusolver.cusolverDnCreate(sh) ~= 0 then return nil end
    if cusolver.cusolverDnCreateParams(par) ~= 0 then return nil end
    return { cublas = cublas, cusolver = cusolver, cudart = cudart,
             blas = bh[0], solver = sh[0], par = par[0],
             H2D = 1, D2H = 2, R64F = 1, OP_N = 0, OP_T = 1,
             UPPER = 1, LOWER = 0, EVEC = 1,
             JOB_S = 0x53, JOB_A = 0x41 }
  end
  gpu = gpu_init()  -- 模块级缓存：handle 跨 SQL 调用复用，避免 ~30ms 冷启动
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

-- ============ GPU 算子 ============
local function gpu_chk(g, st, what)
  if st ~= 0 then error(what .. ' cudaStatus=' .. st) end
end

-- matmul：零输入转置。行主序 A(m×k) 的 flat 直接是列主序 Aᵀ(k×m) 的 flat。
--   Cᵀ(n×m) = Bᵀ·Aᵀ → cublasDgemm(OP_N, OP_N, n, m, k, B, n, A, k, C', n)
--   输出 C' 列主序 n×m：C'[i + j*n] = C(j,i)，转置循环填回行主序 C。
local function gpu_matmul(g, p)
  local A, m, k, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'matmul a: ' .. err } end
  local B, k2, n, err2 = flat_row(p, 'b')
  if err2 then return { status = 'Error', message = 'matmul b: ' .. err2 } end
  if k ~= k2 then
    return { status = 'Error', message = 'matmul: inner dims mismatch ' .. k .. ' vs ' .. k2 }
  end
  local szA, szB, szC = m * k * 8, k * n * 8, m * n * 8
  local dA = ffi.new('void*[1]')
  local dB = ffi.new('void*[1]')
  local dC = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dA, szA), 'cudaMalloc A')
  gpu_chk(g, g.cudart.cudaMalloc(dB, szB), 'cudaMalloc B')
  gpu_chk(g, g.cudart.cudaMalloc(dC, szC), 'cudaMalloc C')
  gpu_chk(g, g.cudart.cudaMemcpy(dA[0], A, szA, g.H2D), 'H2D A')
  gpu_chk(g, g.cudart.cudaMemcpy(dB[0], B, szB, g.H2D), 'H2D B')
  local alpha = ffi.new('double[1]', 1.0)
  local beta = ffi.new('double[1]', 0.0)
  -- A' = B flat（n×k 列主序，lda=n）= Bᵀ；B' = A flat（k×m 列主序，ldb=k）= Aᵀ
  gpu_chk(g, g.cublas.cublasDgemm_v2(g.blas, g.OP_N, g.OP_N, n, m, k,
      alpha, dB[0], n, dA[0], k, beta, dC[0], n), 'cublasDgemm')
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  local Ccol = ffi.new('double[?]', m * n)
  gpu_chk(g, g.cudart.cudaMemcpy(Ccol, dC[0], szC, g.D2H), 'D2H C')
  g.cudart.cudaFree(dA[0]); g.cudart.cudaFree(dB[0]); g.cudart.cudaFree(dC[0])
  -- C' 列主序 n×m → 行主序 C(m×n)：C_flat[(j-1)*n + i] = C'[(i-1) + (j-1)*n]
  local c = {}
  for j = 1, m do
    for i = 1, n do
      c[(j - 1) * n + i] = tonumber(Ccol[(i - 1) + (j - 1) * n])
    end
  end
  return { c = c }
end

-- svd：Xgesvd（64 位通用 API）。输出格式与 CPU 版一致（s 表 + 行主序 u/vt）。
local function gpu_svd(g, p)
  local _, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'svd: ' .. err } end
  local a = col_major_from_flat(p.a, m, n) -- cuSOLVER 需列主序
  local minmn = math.min(m, n)
  local jobu, jobvt = g.JOB_S, g.JOB_S
  local ks = minmn
  if p.thin == false then jobu, jobvt = g.JOB_A, g.JOB_A; ks = m end
  local szA = m * n * 8
  local vt_n = (jobvt == g.JOB_A) and n or ks -- 'A' 时 VT 是 n×n
  local dA = ffi.new('void*[1]')
  local dS = ffi.new('void*[1]')
  local dU = ffi.new('void*[1]')
  local dVT = ffi.new('void*[1]')
  local dI = ffi.new('void*[1]')
  local dW = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dA, szA), 'cudaMalloc A')
  gpu_chk(g, g.cudart.cudaMalloc(dS, minmn * 8), 'cudaMalloc S')
  gpu_chk(g, g.cudart.cudaMalloc(dU, m * ks * 8), 'cudaMalloc U')
  gpu_chk(g, g.cudart.cudaMalloc(dVT, vt_n * n * 8), 'cudaMalloc VT')
  gpu_chk(g, g.cudart.cudaMalloc(dI, 4), 'cudaMalloc info')
  gpu_chk(g, g.cudart.cudaMemcpy(dA[0], a, szA, g.H2D), 'H2D A')
  local wsD = ffi.new('unsigned long long[1]')
  local wsH = ffi.new('unsigned long long[1]')
  local st = g.cusolver.cusolverDnXgesvd_bufferSize(g.solver, g.par, jobu, jobvt, m, n,
      g.R64F, dA[0], m, g.R64F, dA[0], g.R64F, dA[0], m, g.R64F, dA[0], n, g.R64F, wsD, wsH)
  if st ~= 0 then return { status = 'Error', message = 'svd: Xgesvd_bufferSize status=' .. st } end
  gpu_chk(g, g.cudart.cudaMalloc(dW, wsD[0]), 'cudaMalloc work')
  local bufH = ffi.new('uint8_t[?]', math.max(tonumber(wsH[0]) or 0, 1))
  local st2 = g.cusolver.cusolverDnXgesvd(g.solver, g.par, jobu, jobvt, m, n,
      g.R64F, dA[0], m, g.R64F, dS[0], g.R64F, dU[0], m, g.R64F, dVT[0], vt_n, g.R64F,
      dW[0], wsD[0], bufH, wsH[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st2 ~= 0 then return { status = 'Error', message = 'svd: Xgesvd status=' .. st2 } end
  local hI = ffi.new('int[1]')
  g.cudart.cudaMemcpy(hI, dI[0], 4, g.D2H)
  if hI[0] ~= 0 then return { status = 'Error', message = 'svd: Xgesvd info=' .. hI[0] } end
  local s = ffi.new('double[?]', minmn)
  local u = ffi.new('double[?]', m * ks)
  local vt = ffi.new('double[?]', vt_n * n)
  g.cudart.cudaMemcpy(s, dS[0], minmn * 8, g.D2H)
  g.cudart.cudaMemcpy(u, dU[0], m * ks * 8, g.D2H)
  g.cudart.cudaMemcpy(vt, dVT[0], vt_n * n * 8, g.D2H)
  g.cudart.cudaFree(dA[0]); g.cudart.cudaFree(dS[0]); g.cudart.cudaFree(dU[0])
  g.cudart.cudaFree(dVT[0]); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW[0])
  -- 输出（与 CPU 版一致）：s 表；u 行主序 m×ks；vt 行主序 ks×n
  local su = {}
  for i = 1, minmn do su[i] = tonumber(s[i - 1]) end
  local uf = {}
  for i = 1, m do
    for j = 1, ks do uf[(i - 1) * ks + j] = tonumber(u[(j - 1) * m + (i - 1)]) end
  end
  local vtf = {}
  for i = 1, ks do
    for j = 1, n do vtf[(i - 1) * n + j] = tonumber(vt[(j - 1) * vt_n + (i - 1)]) end
  end
  return { s = su, u = uf, vt = vtf, dims = { m, ks } }
end

-- ===== GPU 通用小工具 =====
-- 分配设备内存并 H2D 拷贝
local function gpu_dev(g, hptr, bytes)
  local dp = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dp, bytes), 'cudaMalloc')
  gpu_chk(g, g.cudart.cudaMemcpy(dp[0], hptr, bytes, g.H2D), 'H2D')
  return dp[0]
end

-- 分配 X 系列 workspace（已查询 wsD/wsH 后）→ 设备 buffer + 主机 buffer
-- ⚠️ 不用 vararg 包装 bufferSize 调用：LuaJIT 对 FFI cdata 函数调用
-- `f(..., x, y)` 有参数错位 bug（实测 vararg 后追加参数时第 3 参变 uint64_t[1]），
-- 且 FFI 调用不允许 nil 填充（wrong number of arguments）。
-- 每个算子必须内联精确参数的 bufferSize 查询，再调此分配。
local function gpu_ws_alloc(g, wsD, wsH, what)
  local dWp = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dWp, wsD[0] or 1), 'cudaMalloc work ' .. what)
  local bufH = ffi.new('uint8_t[?]', math.max(tonumber(wsH[0]) or 0, 1))
  return dWp[0], bufH
end

-- X 系列 info 检查（D2H 后非 0 → Error 表）
local function gpu_xinfo(g, dI, what)
  local hI = ffi.new('int[1]')
  g.cudart.cudaMemcpy(hI, dI, 4, g.D2H)
  if hI[0] ~= 0 then
    return { status = 'Error', message = what .. ' info=' .. hI[0]
      .. (hI[0] > 0 and ' (singular/not-PD at ' .. hI[0] .. ')' or '') }
  end
  return nil
end

-- eigh：Xsyevd。a 列主序 n×n（对称），jobz=VECTOR, uplo=UPPER
-- 输出与 CPU 版一致：{ w:[λ升序], v:[行主序，列=特征向量] }
local function gpu_eigh(g, p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'eigh: ' .. err } end
  if m ~= n then return { status = 'Error', message = 'eigh: matrix must be square' } end
  local ac = col_major_from_flat(p.a, n, n)
  local dA = gpu_dev(g, ac, n * n * 8)
  local dWp = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dWp, n * 8), 'cudaMalloc W')
  local dI = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dI, 4), 'cudaMalloc info')
  local wsD = ffi.new('unsigned long long[1]')
  local wsH = ffi.new('unsigned long long[1]')
  local stq = g.cusolver.cusolverDnXsyevd_bufferSize(g.solver, g.par, g.EVEC, g.UPPER, n,
    g.R64F, dA, n, g.R64F, dWp[0], g.R64F, wsD, wsH)
  if stq ~= 0 then return { status = 'Error', message = 'eigh: Xsyevd_bufferSize status=' .. stq } end
  local dW, bufH = gpu_ws_alloc(g, wsD, wsH, 'eigh')
  local st = g.cusolver.cusolverDnXsyevd(g.solver, g.par, g.EVEC, g.UPPER, n, g.R64F,
    dA, n, g.R64F, dWp[0], g.R64F, dW, wsD[0], bufH, wsH[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st ~= 0 then return { status = 'Error', message = 'eigh: Xsyevd status=' .. st } end
  local errT = gpu_xinfo(g, dI[0], 'eigh: Xsyevd')
  if errT then g.cudart.cudaFree(dA); g.cudart.cudaFree(dWp[0]); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT end
  local w = ffi.new('double[?]', n)
  local vc = ffi.new('double[?]', n * n)
  g.cudart.cudaMemcpy(w, dWp[0], n * 8, g.D2H)
  g.cudart.cudaMemcpy(vc, dA, n * n * 8, g.D2H)
  g.cudart.cudaFree(dA); g.cudart.cudaFree(dWp[0]); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW)
  local wl = {}
  for i = 1, n do wl[i] = tonumber(w[i - 1]) end
  return { w = wl, v = flat_from_col_major(vc, n, n) }
end

-- lu：Xgetrf。输出与 CPU 版一致：{ lu:[行主序原位], ipiv:[1-based] }
local function gpu_lu(g, p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'lu: ' .. err } end
  local ac = col_major_from_flat(p.a, m, n)
  local k = math.min(m, n)
  local dA = gpu_dev(g, ac, m * n * 8)
  local ipiv = ffi.new('int64_t[?]', k)
  local dI = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dI, 4), 'cudaMalloc info')
  local wsD = ffi.new('unsigned long long[1]')
  local wsH = ffi.new('unsigned long long[1]')
  local stq = g.cusolver.cusolverDnXgetrf_bufferSize(g.solver, g.par, m, n, g.R64F, dA, m, g.R64F, wsD, wsH)
  if stq ~= 0 then return { status = 'Error', message = 'lu: Xgetrf_bufferSize status=' .. stq } end
  local dW, bufH = gpu_ws_alloc(g, wsD, wsH, 'lu')
  local st = g.cusolver.cusolverDnXgetrf(g.solver, g.par, m, n, g.R64F,
    dA, m, ipiv, g.R64F, dW, wsD[0], bufH, wsH[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st ~= 0 then return { status = 'Error', message = 'lu: Xgetrf status=' .. st } end
  local errT = gpu_xinfo(g, dI[0], 'lu: Xgetrf')
  if errT then g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT end
  local lu = ffi.new('double[?]', m * n)
  g.cudart.cudaMemcpy(lu, dA, m * n * 8, g.D2H)
  g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW)
  local piv = {}
  for i = 1, k do piv[i] = tonumber(ipiv[i - 1]) end
  return { lu = flat_from_col_major(lu, m, n), ipiv = piv }
end

-- inv：Xgetrf + Xgetrs(A·X=I)。输出与 CPU 版一致：{ inv:[行主序] }
local function gpu_inv(g, p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'inv: ' .. err } end
  if m ~= n then return { status = 'Error', message = 'inv: matrix must be square' } end
  local ac = col_major_from_flat(p.a, n, n)
  local dA = gpu_dev(g, ac, n * n * 8)
  local ipiv = ffi.new('int64_t[?]', n)
  local dI = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dI, 4), 'cudaMalloc info')
  local wsD = ffi.new('unsigned long long[1]')
  local wsH = ffi.new('unsigned long long[1]')
  local stq = g.cusolver.cusolverDnXgetrf_bufferSize(g.solver, g.par, n, n, g.R64F, dA, n, g.R64F, wsD, wsH)
  if stq ~= 0 then return { status = 'Error', message = 'inv: Xgetrf_bufferSize status=' .. stq } end
  local dW, bufH = gpu_ws_alloc(g, wsD, wsH, 'inv')
  local st = g.cusolver.cusolverDnXgetrf(g.solver, g.par, n, n, g.R64F,
    dA, n, ipiv, g.R64F, dW, wsD[0], bufH, wsH[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st ~= 0 then return { status = 'Error', message = 'inv: Xgetrf status=' .. st } end
  local errT = gpu_xinfo(g, dI[0], 'inv: Xgetrf')
  if errT then g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT end
  -- B = I（列主序单位阵 = 行主序单位阵）
  local b = ffi.new('double[?]', n * n)
  for i = 1, n do b[(i - 1) * n + (i - 1)] = 1.0 end
  local dB = gpu_dev(g, b, n * n * 8)
  local st2 = g.cusolver.cusolverDnXgetrs(g.solver, g.par, g.OP_N, n, n, g.R64F,
    dA, n, ipiv, g.R64F, dB, n, dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st2 ~= 0 then return { status = 'Error', message = 'inv: Xgetrs status=' .. st2 } end
  local errT2 = gpu_xinfo(g, dI[0], 'inv: Xgetrs')
  if errT2 then g.cudart.cudaFree(dA); g.cudart.cudaFree(dB); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT2 end
  -- ⚠️ D2H 必须在 free 之前（use-after-free 会 segfault，实测踩坑）
  local inv = ffi.new('double[?]', n * n)
  g.cudart.cudaMemcpy(inv, dB, n * n * 8, g.D2H)
  g.cudart.cudaFree(dA); g.cudart.cudaFree(dB); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW)
  return { inv = flat_from_col_major(inv, n, n) }
end

-- chol：Xpotrf（uplo=UPPER）。输出与 CPU 版一致：{ chol:[行主序上三角] }
local function gpu_chol(g, p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'chol: ' .. err } end
  if m ~= n then return { status = 'Error', message = 'chol: matrix must be square' } end
  local ac = col_major_from_flat(p.a, n, n)
  local dA = gpu_dev(g, ac, n * n * 8)
  local dI = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dI, 4), 'cudaMalloc info')
  local wsD = ffi.new('unsigned long long[1]')
  local wsH = ffi.new('unsigned long long[1]')
  local stq = g.cusolver.cusolverDnXpotrf_bufferSize(g.solver, g.par, g.UPPER, n, g.R64F, dA, n, g.R64F, wsD, wsH)
  if stq ~= 0 then return { status = 'Error', message = 'chol: Xpotrf_bufferSize status=' .. stq } end
  local dW, bufH = gpu_ws_alloc(g, wsD, wsH, 'chol')
  local st = g.cusolver.cusolverDnXpotrf(g.solver, g.par, g.UPPER, n, g.R64F,
    dA, n, g.R64F, dW, wsD[0], bufH, wsH[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st ~= 0 then return { status = 'Error', message = 'chol: Xpotrf status=' .. st } end
  local errT = gpu_xinfo(g, dI[0], 'chol: Xpotrf')
  if errT then g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT end
  local ac2 = ffi.new('double[?]', n * n)
  g.cudart.cudaMemcpy(ac2, dA, n * n * 8, g.D2H)
  g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW)
  -- 上三角 R（列主序 → 行主序，j>=i 有值）
  local r = {}
  for i = 1, n do
    for j = 1, n do
      r[(i - 1) * n + j] = (j >= i) and tonumber(ac2[(j - 1) * n + (i - 1)]) or 0
    end
  end
  return { chol = r }
end

-- qr：Xgeqrf（R+tau）+ Dorgqr（Q，32 位经典 API，无 Ada bug）
-- 输出与 CPU 版一致：{ q:[行主序 m×k thin], r:[行主序 k×n 上三角] }
local function gpu_qr(g, p)
  local a, m, n, err = flat_row(p, 'a')
  if err then return { status = 'Error', message = 'qr: ' .. err } end
  local k = math.min(m, n)
  local ac = col_major_from_flat(p.a, m, n)
  local dA = gpu_dev(g, ac, m * n * 8)
  local tau = ffi.new('double[?]', k)
  local dI = ffi.new('void*[1]')
  gpu_chk(g, g.cudart.cudaMalloc(dI, 4), 'cudaMalloc info')
  local wsD = ffi.new('unsigned long long[1]')
  local wsH = ffi.new('unsigned long long[1]')
  local stq = g.cusolver.cusolverDnXgeqrf_bufferSize(g.solver, g.par, m, n, g.R64F, dA, m,
    g.R64F, tau, g.R64F, wsD, wsH)
  if stq ~= 0 then return { status = 'Error', message = 'qr: Xgeqrf_bufferSize status=' .. stq } end
  local dW, bufH = gpu_ws_alloc(g, wsD, wsH, 'qr')
  local st = g.cusolver.cusolverDnXgeqrf(g.solver, g.par, m, n, g.R64F,
    dA, m, g.R64F, tau, g.R64F, dW, wsD[0], bufH, wsH[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st ~= 0 then return { status = 'Error', message = 'qr: Xgeqrf status=' .. st } end
  local errT = gpu_xinfo(g, dI[0], 'qr: Xgeqrf')
  if errT then g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT end
  -- ⚠️ 必须先拷 R（Dorgqr 会原位覆盖 A 的前 k 列为 Q）
  local aq = ffi.new('double[?]', m * n)
  g.cudart.cudaMemcpy(aq, dA, m * n * 8, g.D2H)
  -- R（上三角，前 k 行，列主序 → 行主序）
  local r = {}
  for i = 1, k do
    for j = 1, n do
      r[(i - 1) * n + j] = (j >= i) and tonumber(aq[(j - 1) * m + (i - 1)]) or 0
    end
  end
  -- Dorgqr 生成 Q（m×k thin；宿主侧 work 查询 + 执行）
  local tauH = ffi.new('double[?]', k)
  g.cudart.cudaMemcpy(tauH, tau, k * 8, g.D2H)
  local lwork = ffi.new('int[1]')
  local st2 = g.cusolver.cusolverDnDorgqr_bufferSize(g.solver, m, k, k, dA, m, tauH, lwork)
  if st2 ~= 0 then return { status = 'Error', message = 'qr: Dorgqr_bufferSize status=' .. st2 } end
  local work = ffi.new('double[?]', lwork[0])
  local st3 = g.cusolver.cusolverDnDorgqr(g.solver, m, k, k, dA, m, tauH, work, lwork[0], dI[0])
  gpu_chk(g, g.cudart.cudaDeviceSynchronize(), 'sync')
  if st3 ~= 0 then return { status = 'Error', message = 'qr: Dorgqr status=' .. st3 } end
  local errT2 = gpu_xinfo(g, dI[0], 'qr: Dorgqr')
  if errT2 then g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW); return errT2 end
  -- Dorgqr 后 A 前 k 列已是 Q → 拷回（R 已在上面的 aq 保存）
  local aqQ = ffi.new('double[?]', m * n)
  g.cudart.cudaMemcpy(aqQ, dA, m * n * 8, g.D2H)
  g.cudart.cudaFree(dA); g.cudart.cudaFree(dI[0]); g.cudart.cudaFree(dW)
  -- Q（前 k 列，列主序 m×k → 行主序）
  local q = flat_from_col_major(aqQ, m, k)
  return { q = q, r = r }
end

-- ============ 分发 ============
-- backend 覆盖：p.backend = 'auto'（默认，env 门控）/ 'gpu'（强制）/ 'cpu'（强制）
local gpu_ops = {
  matmul = gpu_matmul, svd = gpu_svd, eigh = gpu_eigh,
  lu = gpu_lu, inv = gpu_inv, chol = gpu_chol, qr = gpu_qr,
}
local function solve(p)
  local op = p.op
  local backend = p.backend or 'auto'
  if backend ~= 'cpu' then
    if gpu and gpu_ops[op] then
      local ok, res = pcall(function() return gpu_ops[op](gpu, p) end)
      if ok and type(res) == 'table' then
        res.backend = 'gpu'
        return res
      end
      return { status = 'Error', message = 'linalg gpu ' .. op .. ': ' .. tostring(res) }
    end
    if backend == 'gpu' then
      return { status = 'Error', message = 'linalg: backend=gpu requested but GPU unavailable for op=' .. tostring(op)
        .. ' (set LUA_LINALG_GPU=1 and ensure cuBLAS/cuSOLVER/cudart loadable)' }
    end
  end
  if not lib then
    return { status = 'Error', message = cpu_backend_error or 'no CPU backend available' }
  end
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
-- 参数兼容：table（FFI 直调）或 JSON 字符串（duckdb-luajit luajit_s 传字符串）
return function(p)
  if type(p) == 'string' then
    local ok, t = pcall(json_decode, p)
    if not ok or type(t) ~= 'table' then
      return json_encode({ status = 'Error', message = 'bad JSON param: ' .. tostring(p) })
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
