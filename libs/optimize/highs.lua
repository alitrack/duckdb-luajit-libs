-- @lib: highs
-- @category: optimize
-- @desc: 线性/混合整数规划求解（HiGHS 内核，LP/QP/MILP）——LuaJIT FFI 直调
--        libhighs（MIT 许可），SQL 里解排产/调度/资源分配/组合优化
-- @source: original（duckdb-luajit 系列）
-- @requires: libhighs.so（HiGHS ≥1.6，MIT）——编译期安装：
--   git clone https://github.com/ERGO-Code/HiGHS
--   cmake -S HiGHS -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
--   cmake --build build -j && sudo cmake --install build
--   （Windows/macOS 同理；找不到库时设 LUAJIT_HIGHS_LIB 指向完整路径）
--
-- Usage (duckdb-luajit):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='highs');
--
--   线性规划（LP，min c'x s.t. l ≤ Ax ≤ u, lb ≤ x ≤ ub）：
--     SELECT luajit_s('highs', {op:'lp', sense:'min',
--       col_cost:[0.18,0.23,0.05], col_lower:[0,0,0], col_upper:[10,10,10],
--       row_lower:[5000,-1e30,2000,-1e30], row_upper:[1e30,50000,1e30,2250],
--       a_start:[0,2,4], a_index:[0,2,1,3,0,1,2,3], a_value:[107,72,500,121,65,107,72,65]});
--     → JSON: {"status":"Optimal","objective":3.15,"solution":[1.9444,10,10],...}
--     （列压缩格式：a_start 长度 = 列数+1，见 HiGHS C API 文档）
--
--   混合整数规划（MILP，integrality: 0=连续 1=整数）：
--     SELECT luajit_s('highs', {op:'mip', sense:'min', ...,
--       integrality:[1,1,1]});
--
--   二次规划（QP，q_start/q_index/q_value = 下三角列压缩 Hessian）：
--     SELECT luajit_s('highs', {op:'qp', ..., q_num_nz:N,
--       q_start:[...], q_index:[...], q_value:[...]});
--
--   结果解析（DuckDB 原生）：
--     SELECT * FROM from_json(
--       luajit_s('highs', {op:'lp', ...}),
--       '{"status":"VARCHAR","objective":"DOUBLE","solution":"DOUBLE[]"}');
--
-- 设计要点：只做「建模 → 求解 → 结果序列化」，矩阵组装（行列式/展开）交给
-- SQL（LIST 聚合构造稀疏矩阵）——Lua 层保持薄胶水，算法全在 HiGHS。

local ffi = require('ffi')

-- ============ 极简 JSON encode（自包含，零依赖） ============
-- 只编码 number/string/boolean/nil/table（数组或对象）——求解结果足够用
local function json_encode(v)
  local t = type(v)
  if t == 'number' then
    if v ~= v then return 'null' end -- NaN
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
    if n > 0 then -- 数组
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

-- ============ FFI: HiGHS C API ============
-- 只声明用到的三个 Call 函数（其余 API 按需扩展）
ffi.cdef[[
  typedef int HighsInt;

  HighsInt Highs_lpCall(const HighsInt num_col, const HighsInt num_row,
                        const HighsInt num_nz, const HighsInt a_format,
                        const HighsInt sense, const double offset,
                        const double* col_cost, const double* col_lower,
                        const double* col_upper, const double* row_lower,
                        const double* row_upper, const HighsInt* a_start,
                        const HighsInt* a_index, const double* a_value,
                        double* col_value, double* col_dual, double* row_value,
                        double* row_dual, HighsInt* col_basis_status,
                        HighsInt* row_basis_status, HighsInt* model_status);

  HighsInt Highs_mipCall(const HighsInt num_col, const HighsInt num_row,
                         const HighsInt num_nz, const HighsInt a_format,
                         const HighsInt sense, const double offset,
                         const double* col_cost, const double* col_lower,
                         const double* col_upper, const double* row_lower,
                         const double* row_upper, const HighsInt* a_start,
                         const HighsInt* a_index, const double* a_value,
                         const HighsInt* integrality, double* col_value,
                         double* row_value, HighsInt* model_status);

  HighsInt Highs_qpCall(const HighsInt num_col, const HighsInt num_row,
                        const HighsInt num_nz, const HighsInt q_num_nz,
                        const HighsInt a_format, const HighsInt q_format,
                        const HighsInt sense, const double offset,
                        const double* col_cost, const double* col_lower,
                        const double* col_upper, const double* row_lower,
                        const double* row_upper, const HighsInt* a_start,
                        const HighsInt* a_index, const double* a_value,
                        const HighsInt* q_start, const HighsInt* q_index,
                        const double* q_value, double* col_value,
                        double* col_dual, double* row_value, double* row_dual,
                        HighsInt* col_basis_status, HighsInt* row_basis_status,
                        HighsInt* model_status);
]]

-- 加载链：LUAJIT_HIGHS_LIB 环境变量 → 系统搜索路径 → 常见用户路径
local lib
local custom = os and os.getenv and os.getenv('LUAJIT_HIGHS_LIB')
if custom then
  local ok, l = pcall(ffi.load, custom)
  if ok and l.Highs_lpCall then lib = l end
end
if not lib then
  for _, name in ipairs({ 'highs', 'libhighs' }) do
    local ok, l = pcall(ffi.load, name)
    if ok and l.Highs_lpCall then lib = l break end
  end
end
if not lib and os and os.getenv then
  -- 无 root 安装场景（~/.local/lib、/usr/local/lib、/opt）
  local home = os.getenv('HOME') or ''
  for _, p in ipairs({
    home .. '/.local/lib/libhighs.so',
    '/usr/local/lib/libhighs.so',
    '/opt/homebrew/lib/libhighs.so',
  }) do
    local ok, l = pcall(ffi.load, p)
    if ok and l.Highs_lpCall then lib = l break end
  end
end
if not lib then
  error('highs: cannot load libhighs — build & install HiGHS first '
    .. '(see @requires; or set LUAJIT_HIGHS_LIB to the full path of libhighs.so)')
end

-- 状态码 → 可读名
local MODEL_STATUS = {
  [0] = 'NotSet', [1] = 'LoadError', [2] = 'ModelError', [3] = 'PresolveError',
  [4] = 'SolveError', [5] = 'PostsolveError', [6] = 'ModelEmpty',
  [7] = 'Optimal', [8] = 'Infeasible', [9] = 'UnboundedOrInfeasible',
  [10] = 'Unbounded', [11] = 'ObjectiveBound', [12] = 'ObjectiveTarget',
  [13] = 'TimeLimit', [14] = 'IterationLimit', [15] = 'Unknown',
  [16] = 'SolutionLimit', [17] = 'Interrupt',
}

-- Lua 数字表 → double* / HighsInt*
local function dbl_arr(t)
  local a = ffi.new('double[?]', #t)
  for i, v in ipairs(t) do a[i - 1] = tonumber(v) or 0 end
  return a
end
local function int_arr(t)
  local a = ffi.new('HighsInt[?]', #t)
  for i, v in ipairs(t) do a[i - 1] = tonumber(v) or 0 end
  return a
end

-- 模型状态枚举（压缩稀疏列格式 A = {start, index, value}）
-- p.sense: 'min'（默认）/'max'；p.offset: 目标常数项
local function solve(p)
  local num_col = #p.col_cost
  local num_row = p.row_lower and #p.row_lower or 0
  local a_start, a_index, a_value = p.a_start, p.a_index, p.a_value
  local num_nz = a_index and #a_index or 0

  if num_col == 0 then return { status = 'Error', message = 'no columns' } end
  if num_row > 0 and not (a_start and a_index and a_value) then
    return { status = 'Error', message = 'rows given but no sparse matrix A' }
  end
  if a_start and #a_start ~= num_col + 1 then
    return { status = 'Error',
             message = 'a_start length must be num_col+1 (' .. tostring(num_col + 1) .. ')' }
  end

  local sense = p.sense == 'max' and ffi.cast('HighsInt', -1)
             or ffi.cast('HighsInt', 1) -- kHighsObjSenseMinimize
  local offset = tonumber(p.offset) or 0
  local col_cost = dbl_arr(p.col_cost)
  local col_lower = dbl_arr(p.col_lower or {})
  local col_upper = dbl_arr(p.col_upper or {})
  -- 缺省界：lower=-inf, upper=+inf
  for i = 1, num_col do
    if col_lower[i - 1] == 0 and not p.col_lower then col_lower[i - 1] = -1e30 end
    if col_upper[i - 1] == 0 and not p.col_upper then col_upper[i - 1] = 1e30 end
  end
  local row_lower = dbl_arr(p.row_lower or {})
  local row_upper = dbl_arr(p.row_upper or {})
  local a_s, a_i, a_v
  if num_row > 0 then
    a_s, a_i, a_v = int_arr(a_start), int_arr(a_index), dbl_arr(a_value)
  else
    a_s, a_i, a_v = ffi.new('HighsInt[1]', { 0 }), ffi.new('HighsInt[1]', { 0 }), ffi.new('double[1]', { 0 })
  end

  local col_value = ffi.new('double[?]', num_col)
  local model_status = ffi.new('HighsInt[1]')

  local rc
  local op = p.op or 'lp'
  if op == 'lp' then
    local col_dual = ffi.new('double[?]', num_col)
    local row_value = ffi.new('double[?]', math.max(num_row, 1))
    local row_dual = ffi.new('double[?]', math.max(num_row, 1))
    local col_bs = ffi.new('HighsInt[?]', num_col)
    local row_bs = ffi.new('HighsInt[?]', math.max(num_row, 1))
    rc = lib.Highs_lpCall(num_col, num_row, num_nz, 1, sense, offset,
      col_cost, col_lower, col_upper, row_lower, row_upper,
      a_s, a_i, a_v, col_value, col_dual, row_value, row_dual,
      col_bs, row_bs, model_status)
  elseif op == 'mip' then
    local integrality = int_arr(p.integrality or {})
    local row_value = ffi.new('double[?]', math.max(num_row, 1))
    rc = lib.Highs_mipCall(num_col, num_row, num_nz, 1, sense, offset,
      col_cost, col_lower, col_upper, row_lower, row_upper,
      a_s, a_i, a_v, integrality, col_value, row_value, model_status)
  elseif op == 'qp' then
    local q_num_nz = #(p.q_index or {})
    local q_start = int_arr(p.q_start or {})
    local q_index = int_arr(p.q_index or {})
    local q_value = dbl_arr(p.q_value or {})
    local row_value = ffi.new('double[?]', math.max(num_row, 1))
    local col_dual = ffi.new('double[?]', num_col)
    local row_dual = ffi.new('double[?]', math.max(num_row, 1))
    local col_bs = ffi.new('HighsInt[?]', num_col)
    local row_bs = ffi.new('HighsInt[?]', math.max(num_row, 1))
    rc = lib.Highs_qpCall(num_col, num_row, num_nz, q_num_nz, 1, 1, sense, offset,
      col_cost, col_lower, col_upper, row_lower, row_upper,
      a_s, a_i, a_v, q_start, q_index, q_value,
      col_value, col_dual, row_value, row_dual, col_bs, row_bs, model_status)
  else
    return { status = 'Error', message = 'unknown op: ' .. tostring(op) }
  end

  if rc ~= 0 then
    return { status = 'Error', message = 'HiGHS call failed rc=' .. tostring(rc) }
  end

  -- 目标值 = offset + Σ cost_i * x_i（LP/MIP；QP 另加二次项 0.5·x'Qx）
  local obj = offset
  local solution = {}
  for i = 1, num_col do
    local x = tonumber(col_value[i - 1])
    solution[i] = x
    obj = obj + (tonumber(p.col_cost[i]) or 0) * x
  end
  if op == 'qp' and p.q_start then
    -- Hessian 下三角列压缩：q_start 列指针，q_index/q_value 行号+值
    local q_start, q_index, q_value = p.q_start, p.q_index, p.q_value
    for j = 1, num_col do -- 列 j（0 基 j-1）
      local s, e = tonumber(q_start[j]), tonumber(q_start[j + 1])
      for k = s, e - 1 do
        local i = tonumber(q_index[k + 1]) + 1 -- 行号转 1 基
        local q = tonumber(q_value[k + 1])
        obj = obj + 0.5 * q * solution[i] * solution[j]
      end
    end
  end

  local ms = tonumber(model_status[0])
  return {
    status = MODEL_STATUS[ms] or tostring(ms),
    model_status = ms,
    objective = obj,
    solution = solution,
  }
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
