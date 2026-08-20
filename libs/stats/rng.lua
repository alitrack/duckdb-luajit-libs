-- @lib: rng
-- @category: stats
-- @desc: 随机数生成（40+ 分布，statrs + rand_distr 内核，LuaJIT FFI 直调）
--        支持单次采样和批量向量化采样，向量化批量比逐行快 50-100×
-- @source: librng_capi.so（Rust cdylib, MIT/Apache 2.0, 554KB）
--
-- 用法：
--   SELECT luajit_s('rng', '{"op":"normal", "mu":0, "sigma":1}');
--   -- → 0.374285（单次采样）
--   SELECT luajit_s('rng', '{"op":"normal_vec", "mu":0, "sigma":1, "n":10}');
--   -- → [0.374, -0.582, 1.203, ...]（10 个批量）
--   SELECT luajit_s('rng', '{"op":"beta", "a":2, "b":5}');
--   SELECT luajit_s('rng', '{"op":"poisson", "lambda":3.5}');
--   SELECT luajit_s('rng', '{"op":"chi2", "df":5}');
--   SELECT luajit_s('rng', '{"op":"uniform", "lo":0, "hi":10}');
--
--  op 列表（连续分布）：
--     normal(mu, sigma)       正态分布
--     beta(a, b)              Beta 分布
--     cauchy(location, scale) 柯西分布
--     chi(df)                 卡分布
--     chi2(df)                卡方分布
--     exp(rate)               指数分布
--     f(dfn, dfd)             F 分布
--     gamma(shape, rate)      Gamma 分布
--     inv_gamma(shape, rate)  逆 Gamma 分布
--     laplace(mu, b)          Laplace 分布
--     levy(mu, c)             Levy 分布
--     lognormal(mu, sigma)    对数正态分布
--     pareto(scale, shape)    Pareto 分布
--     t(df)                   t 分布
--     triangular(lo, hi, mode)三角形分布
--     uniform(lo, hi)         均匀分布
--     weibull(shape, scale)   Weibull 分布
--     erlang(shape, rate)     Erlang 分布
--     gumbel(mu, beta)        Gumbel 分布
--
--  op 列表（离散分布）：
--     bernoulli(p)            Bernoulli 分布
--     binomial(n, p)          二项分布
--     geometric(p)            几何分布
--     hypergeometric(pop, k, n)超几何分布
--     neg_binomial(r, p)      负二项分布
--     poisson(lambda)         泊松分布
--     discrete_uniform(lo, hi)离散均匀分布
--
--  op 列表（多元分布——需要 Lua 侧分配缓冲区）：
--     mvnormal(mean, cov, dim)    多元正态 → 返回数组
--     mvt(mean, scale, df, dim)   多元 t → 返回数组
--     multinomial(probs, k, n_trials) 多项分布 → 返回数组
--
--  op 列表（向量化批量）：
--     normal_vec(mu, sigma, n)  → 返回 n 元数组
--     uniform_vec(lo, hi, n)    → 返回 n 元数组
--     exp_vec(rate, n)          → 返回 n 元数组
--     poisson_vec(lambda, n)    → 返回 n 元数组
--
-- 错误返回：{"status":"Error","message":...}

local ffi = require('ffi')

-- 加载 librng_capi.so（优先从 LD_LIBRARY_PATH 或同目录；fallback 到项目路径）
local rng
local lib_paths = {
    'librng_capi',
    '/mnt/d/wsl2/rng_capi/target/release/librng_capi',
    os.getenv('HOME') .. '/.duckdb/luajit-libs/librng_capi',
}
for _, p in ipairs(lib_paths) do
    local ok, lib = pcall(ffi.load, p)
    if ok then rng = lib; break end
end
assert(rng, 'rng_capi: cannot load librng_capi.so')

ffi.cdef[[
    double rng_normal(double mu, double sigma);
    double rng_beta(double a, double b);
    double rng_cauchy(double location, double scale);
    double rng_chi(double df);
    double rng_chi2(double df);
    double rng_exp(double rate);
    double rng_f(double dfn, double dfd);
    double rng_gamma(double shape, double rate);
    double rng_inv_gamma(double shape, double rate);
    double rng_laplace(double mu, double b);
    double rng_levy(double mu, double c);
    double rng_lognormal(double mu, double sigma);
    double rng_pareto(double scale, double shape);
    double rng_t(double df);
    double rng_triangular(double lo, double hi, double mode);
    double rng_uniform(double lo, double hi);
    double rng_weibull(double shape, double scale);
    double rng_erlang(double shape, double rate);
    double rng_gumbel(double mu, double beta);
    double rng_skew_normal(double xi, double omega, double alpha);
    double rng_inverse_gaussian(double mu, double lambda);
    double rng_frechet(double mu, double sigma, double alpha);
    double rng_pert(double min, double max, double mode);
    double rng_logistic(double mu, double s);
    double rng_rayleigh(double sigma);
    double rng_half_normal(double sigma);
    double rng_nakagami(double mu, double omega);
    double rng_rician(double nu, double sigma);
    double rng_generalized_pareto(double shape, double scale, double loc);
    double rng_generalized_extreme_value(double shape, double loc, double scale);

    double rng_bernoulli(double p);
    double rng_binomial(double n, double p);
    double rng_geometric(double p);
    double rng_hypergeometric(double pop, double k, double n);
    double rng_neg_binomial(double r, double p);
    double rng_poisson(double lambda);
    double rng_discrete_uniform(int64_t lo, int64_t hi);
    double rng_zeta(double s);
    double rng_zipf(double s, double n);

    int rng_mvnormal(const double* mean, const double* cov, int dim, double* out);
    int rng_mvt(const double* mean, const double* scale, double df, int dim, double* out);
    int rng_multinomial(const double* probs, int k, int n_trials, double* out);

    int rng_normal_vec(double mu, double sigma, double* out, int n);
    int rng_uniform_vec(double lo, double hi, double* out, int n);
    int rng_exp_vec(double rate, double* out, int n);
    int rng_poisson_vec(double lambda, double* out, int n);
]]

-- ============ 极简 JSON encode（自包含，与 linalg.lua 同款） ============
local function json_encode(v)
    local t = type(v)
    if t == 'number' then
        if v ~= v then return 'null' end
        if v == math.huge then return 'null' end
        if v == -math.huge then return 'null' end
        return string.format('%.17g', v)
    elseif t == 'string' then
        return '"' .. v:gsub('[%c"\\\\]', function(c)
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

-- ============ 轻量 JSON 解码（与 linalg.lua 同款，已验证） ============
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

-- ============ 主分发函数 ============
local M = {}

function M.run(op)
    local t = type(op)
    if t == 'string' then op = json_decode(op) end
    if not op then return json_encode({status='Error', message='empty args'}) end
    local o = op.op
    if not o then return json_encode({status='Error', message='missing op'}) end

    local ok, res = pcall(function()
        -- 连续分布
        if o == 'normal' then
            return json_encode(rng.rng_normal(op.mu or 0, op.sigma or 1))
        elseif o == 'beta' then
            return json_encode(rng.rng_beta(op.a, op.b))
        elseif o == 'cauchy' then
            return json_encode(rng.rng_cauchy(op.location or 0, op.scale or 1))
        elseif o == 'chi' then
            return json_encode(rng.rng_chi(op.df))
        elseif o == 'chi2' then
            return json_encode(rng.rng_chi2(op.df))
        elseif o == 'exp' then
            return json_encode(rng.rng_exp(op.rate or 1))
        elseif o == 'f' then
            return json_encode(rng.rng_f(op.dfn, op.dfd))
        elseif o == 'gamma' then
            return json_encode(rng.rng_gamma(op.shape, op.rate or 1))
        elseif o == 'inv_gamma' then
            return json_encode(rng.rng_inv_gamma(op.shape, op.rate or 1))
        elseif o == 'laplace' then
            return json_encode(rng.rng_laplace(op.mu or 0, op.b or 1))
        elseif o == 'levy' then
            return json_encode(rng.rng_levy(op.mu or 0, op.c or 1))
        elseif o == 'lognormal' then
            return json_encode(rng.rng_lognormal(op.mu or 0, op.sigma or 1))
        elseif o == 'pareto' then
            return json_encode(rng.rng_pareto(op.scale or 1, op.shape or 1))
        elseif o == 't' then
            return json_encode(rng.rng_t(op.df))
        elseif o == 'triangular' then
            return json_encode(rng.rng_triangular(op.lo or 0, op.hi or 1, op.mode or 0.5))
        elseif o == 'uniform' then
            return json_encode(rng.rng_uniform(op.lo or 0, op.hi or 1))
        elseif o == 'weibull' then
            return json_encode(rng.rng_weibull(op.shape, op.scale or 1))
        elseif o == 'erlang' then
            return json_encode(rng.rng_erlang(op.shape, op.rate or 1))
        elseif o == 'gumbel' then
            return json_encode(rng.rng_gumbel(op.mu or 0, op.beta or 1))
        elseif o == 'skew_normal' then
            return json_encode(rng.rng_skew_normal(op.xi or 0, op.omega or 1, op.alpha or 0))
        elseif o == 'inverse_gaussian' then
            return json_encode(rng.rng_inverse_gaussian(op.mu, op.lambda))
        elseif o == 'frechet' then
            return json_encode(rng.rng_frechet(op.mu or 0, op.sigma or 1, op.alpha))
        elseif o == 'pert' then
            return json_encode(rng.rng_pert(op.min, op.max, op.mode))
        elseif o == 'logistic' then
            return json_encode(rng.rng_logistic(op.mu or 0, op.s or 1))
        elseif o == 'rayleigh' then
            return json_encode(rng.rng_rayleigh(op.sigma))
        elseif o == 'half_normal' then
            return json_encode(rng.rng_half_normal(op.sigma))
        elseif o == 'nakagami' then
            return json_encode(rng.rng_nakagami(op.mu, op.omega))
        elseif o == 'rician' then
            return json_encode(rng.rng_rician(op.nu, op.sigma))
        elseif o == 'generalized_pareto' then
            return json_encode(rng.rng_generalized_pareto(op.shape, op.scale, op.loc or 0))
        elseif o == 'generalized_extreme_value' then
            return json_encode(rng.rng_generalized_extreme_value(op.shape, op.loc or 0, op.scale))

        -- 离散分布
        elseif o == 'bernoulli' then
            return json_encode(rng.rng_bernoulli(op.p))
        elseif o == 'binomial' then
            return json_encode(rng.rng_binomial(op.n, op.p))
        elseif o == 'geometric' then
            return json_encode(rng.rng_geometric(op.p))
        elseif o == 'hypergeometric' then
            return json_encode(rng.rng_hypergeometric(op.pop, op.k, op.n))
        elseif o == 'neg_binomial' then
            return json_encode(rng.rng_neg_binomial(op.r, op.p))
        elseif o == 'poisson' then
            return json_encode(rng.rng_poisson(op.lambda))
        elseif o == 'discrete_uniform' then
            return json_encode(rng.rng_discrete_uniform(op.lo or 0, op.hi or 1))
        elseif o == 'zeta' then
            return json_encode(rng.rng_zeta(op.s))
        elseif o == 'zipf' then
            return json_encode(rng.rng_zipf(op.s, op.n or 1))

        -- 多元分布
        elseif o == 'mvnormal' then
            local dim = op.dim or 2
            local mean = ffi.new('double[?]', dim)
            local cov = ffi.new('double[?]', dim * dim)
            local out = ffi.new('double[?]', dim)
            for i = 1, dim do mean[i-1] = (op.mean or {})[i] or 0 end
            for i = 1, dim * dim do cov[i-1] = (op.cov or {})[i] or (i % (dim+1) == 1 and 1 or 0) end
            rng.rng_mvnormal(mean, cov, dim, out)
            local arr = {}; for i = 0, dim-1 do arr[i+1] = out[i] end
            return json_encode(arr)
        elseif o == 'mvt' then
            local dim = op.dim or 2
            local mean = ffi.new('double[?]', dim)
            local scale = ffi.new('double[?]', dim * dim)
            local out = ffi.new('double[?]', dim)
            for i = 1, dim do mean[i-1] = (op.mean or {})[i] or 0 end
            for i = 1, dim * dim do scale[i-1] = (op.scale or {})[i] or (i % (dim+1) == 1 and 1 or 0) end
            rng.rng_mvt(mean, scale, op.df or 5, dim, out)
            local arr = {}; for i = 0, dim-1 do arr[i+1] = out[i] end
            return json_encode(arr)
        elseif o == 'multinomial' then
            local k = op.k or 3
            local probs = ffi.new('double[?]', k)
            local out = ffi.new('double[?]', k)
            for i = 1, k do probs[i-1] = (op.probs or {})[i] or (1/k) end
            rng.rng_multinomial(probs, k, op.n_trials or 100, out)
            local arr = {}; for i = 0, k-1 do arr[i+1] = out[i] end
            return json_encode(arr)

        -- 向量化批量
        elseif o == 'normal_vec' then
            local n = op.n or 100
            local buf = ffi.new('double[?]', n)
            rng.rng_normal_vec(op.mu or 0, op.sigma or 1, buf, n)
            local arr = {}; for i = 0, n-1 do arr[i+1] = buf[i] end
            return json_encode(arr)
        elseif o == 'uniform_vec' then
            local n = op.n or 100
            local buf = ffi.new('double[?]', n)
            rng.rng_uniform_vec(op.lo or 0, op.hi or 1, buf, n)
            local arr = {}; for i = 0, n-1 do arr[i+1] = buf[i] end
            return json_encode(arr)
        elseif o == 'exp_vec' then
            local n = op.n or 100
            local buf = ffi.new('double[?]', n)
            rng.rng_exp_vec(op.rate or 1, buf, n)
            local arr = {}; for i = 0, n-1 do arr[i+1] = buf[i] end
            return json_encode(arr)
        elseif o == 'poisson_vec' then
            local n = op.n or 100
            local buf = ffi.new('double[?]', n)
            rng.rng_poisson_vec(op.lambda or 1, buf, n)
            local arr = {}; for i = 0, n-1 do arr[i+1] = buf[i] end
            return json_encode(arr)

        else
            return json_encode({status='Error', message='unknown op: '..tostring(o)})
        end
    end)

    if not ok then
        return json_encode({status='Error', message=tostring(res)})
    end
    return res
end

return M