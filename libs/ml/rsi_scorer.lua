-- @lib: rsi_scorer
-- @category: ml
-- @desc: 执行特征打分选择器（世界模型低保真版）——候选动作先低成本试跑捕获执行特征，
--        特征加权和（感知机/逻辑回归式打分）选出 argmax 候选；历史 pass/fail 可在线
--        感知机重估权重（Learn→Retain 的低保真等价物）。
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--   设计：RSI-Anything（arXiv 2610.13912）用世界模型（JEPA 潜空间预测）对候选动作
--   打分选择；本库是其低保真等价物——用「执行特征加权和」替代潜空间预测：
--     1) 候选先低成本试跑 → 捕获执行特征（exec_ok/row_count/latency_ms/null_rate/...）
--     2) score = 感知机加权和（exec_ok 权重最高，报错候选大负分）
--     3) select = 一组候选里取 argmax（并列按 candidate_id 字典序，确定性）
--     4) update_weights = 用历史（特征+最终 pass/fail）在线感知机更新权重+bias
--      ——「世界模型适应」的低保真版（打分头学会偏向被验证成功的特征组合）。
--
--   参数形态：所有入参（features/weights/candidates/history）既可以是 SQL 侧
--   结构化表（struct / list(struct)），也可以是 JSON 字符串——本库内置零依赖
--   JSON 解码，因此 update_weights 返回的 JSON 可直接回喂给下一轮的 weights: 参数。
--   特征字段（均可缺省，缺省=无证据→中性分，唯 exec_ok 缺省按 0/失败 处理）：
--     exec_ok        DOUBLE  试跑是否成功 1/0（核心信号）
--     row_count      DOUBLE  产出行数（与 expect_rows 对照做合理性分）
--     expect_rows    DOUBLE  期望行数（调用方给出；缺省则行数分中性）
--     row_tolerance  DOUBLE  行数容差比例（缺省 0.5）
--     latency_ms     DOUBLE  执行延迟（超 latency_budget_ms 线性惩罚，缺省预算 2000ms）
--     null_rate      DOUBLE  结果集空值率 0..1（线性惩罚）
--     error_class    VARCHAR  'ok'/'timeout'/'syntax'/'semantics'/'runtime'/'data'/'other'
--
--   op 分发（luajit_s('rsi_scorer', {op:..., ...})）：
--     features       {f:{...}}                          → 归一化特征 + 逐特征基础分 JSON
--     score          {f:{...}, weights:{...}, bias?}    → {score, contributions} JSON
--     select         {candidates:[{candidate_id, features:{...}},...],
--                     weights:{...}, bias?, }           → {selected_id, score, ranking}
--     update_weights {history:[{features:{...}, pass:1|0|bool},...],
--                     weights:{...}, lr?, epochs?, bias?} → {weights, bias, samples, updates}
--     default_weights {}                                → 出厂权重 JSON
--
-- Usage (duckdb-luajit, scalar mode):
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='rsi_scorer');
--   score:   SELECT luajit_s('rsi_scorer',
--              {op:'score', f:{exec_ok:1, row_count:1000, expect_rows:1000,
--                              latency_ms:120, null_rate:0.01, error_class:'ok'}});
--   select:  SELECT luajit_s('rsi_scorer',
--              {op:'select', candidates:[
--                 {candidate_id:'c1', features:{exec_ok:1, row_count:1000,
--                   expect_rows:1000, latency_ms:120, null_rate:0.01, error_class:'ok'}},
--                 {candidate_id:'c2', features:{exec_ok:0, row_count:0,
--                   latency_ms:90, error_class:'syntax'}}]});
--   → '{"selected_id":"c1","score":2.98,"ranking":[...]}'
--   learn:   SELECT luajit_s('rsi_scorer',
--              {op:'update_weights',
--               history:[{features:{exec_ok:1,row_count:500,expect_rows:500},pass:true},
--                        {features:{exec_ok:0,row_count:0,error_class:'syntax'},pass:false}]});
--
-- 诚实边界：
--   * 权重是手工先验/感知机在线更新，不是潜空间模型；特征-结果强相关时有效，
--     弱相关时退化为 static 档（实验对照组即验此点）。
--   * 打分不做 sigmoid（排序用途，argmax 不变）；输出保留 6 位有效小数。
--   * LuaJIT 数字是 double：2^53 内整数无损。
--   * 选择策略（random/static/full）在 SQL 侧组合：random 用 DuckDB random()，
--     static = 仅 {exec_ok:1} 权重，full = 全特征权重（或 update_weights 产物）。

local rsi = {}

local function json_str(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    local m = { ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['"'] = '\\"', ['\\'] = '\\\\' }
    return m[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function json_num(v)
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then
    return 'null'
  end
  return string.format('%.6g', v)
end

local function json_encode(v)
  local t = type(v)
  if t == 'number' then return json_num(v) end
  if t == 'string' then return json_str(v) end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'nil' then return 'null' end
  if t ~= 'table' then return 'null' end
  local n = #v
  if n > 0 then
    local parts = {}
    for i = 1, n do parts[i] = json_encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local parts = {}
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = json_str(k) .. ':' .. json_encode(v[k])
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

local function r6(x) return math.floor(x * 1e6 + 0.5) / 1e6 end

-- 极简 JSON 解码（自包含，零依赖）：object/array/string/number/true/false/null
-- 支持 \" \\ \/ \n \r \t \b \f 与 \uXXXX（含 UTF-8 编码）
local function json_decode(s)
  if type(s) ~= 'string' then error('json_decode: not a string') end
  local pos = 1
  local function err(m) error('json: ' .. m .. ' at pos ' .. pos, 0) end
  local function ws()
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then pos = pos + 1 else break end
    end
  end
  local function utf8(cp)
    if cp < 128 then return string.char(cp) end
    if cp < 2048 then
      return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
    end
    return string.char(224 + math.floor(cp / 4096),
                       128 + math.floor(cp / 64) % 64, 128 + cp % 64)
  end
  local parse_value
  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == '' then err('unterminated string') end
      if c == '"' then pos = pos + 1 break end
      if c == '\\' then
        local e = s:sub(pos + 1, pos + 1)
        if e == 'u' then
          local hex = s:sub(pos + 2, pos + 5)
          local cp = tonumber(hex, 16)
          if cp == nil then err('bad unicode escape') end
          out[#out + 1] = utf8(cp)
          pos = pos + 6
        elseif e == 'n' then out[#out + 1] = '\n'; pos = pos + 2
        elseif e == 'r' then out[#out + 1] = '\r'; pos = pos + 2
        elseif e == 't' then out[#out + 1] = '\t'; pos = pos + 2
        elseif e == 'b' then out[#out + 1] = '\b'; pos = pos + 2
        elseif e == 'f' then out[#out + 1] = '\f'; pos = pos + 2
        elseif e == '"' or e == '\\' or e == '/' then
          out[#out + 1] = e; pos = pos + 2
        else err('bad escape') end
      else
        out[#out + 1] = c; pos = pos + 1
      end
    end
    return table.concat(out)
  end
  parse_value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      pos = pos + 1
      local obj = {}
      ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return obj end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then err('expected object key') end
        local k = parse_string()
        ws()
        if s:sub(pos, pos) ~= ':' then err('expected :') end
        pos = pos + 1
        obj[k] = parse_value()
        ws()
        local d = s:sub(pos, pos)
        if d == ',' then pos = pos + 1
        elseif d == '}' then pos = pos + 1 break
        else err('expected , or }') end
      end
      return obj
    elseif c == '[' then
      pos = pos + 1
      local arr = {}
      ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = parse_value()
        ws()
        local d = s:sub(pos, pos)
        if d == ',' then pos = pos + 1
        elseif d == ']' then pos = pos + 1 break
        else err('expected , or ]') end
      end
      return arr
    elseif c == '"' then
      return parse_string()
    elseif c == 't' then
      if s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
      else err('bad literal') end
    elseif c == 'f' then
      if s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
      else err('bad literal') end
    elseif c == 'n' then
      if s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
      else err('bad literal') end
    else
      local num = s:match('[-+]?%d*%.?%d+[eE]?[-+]?%d*', pos)
                or s:match('%d+%.?%d*[eE][-+]?%d+', pos)
                or s:match('%d+', pos)
      if not num or num == '' then err('bad value') end
      local v = tonumber(num)
      pos = pos + #num
      return v
    end
  end
  local v = parse_value()
  ws()
  if pos <= #s then err('trailing data') end
  return v
end

-- 参数归一：table 直用；JSON 字符串 → 解码成 table（支持把 update_weights 的
-- 返回 JSON 直接回喂给 weights:/features:/candidates: 参数）
local function as_table(x)
  if type(x) == 'table' then return x end
  if type(x) == 'string' and x ~= '' then
    local ok, t = pcall(json_decode, x)
    if ok and type(t) == 'table' then return t end
  end
  return nil
end


local DEFAULT_WEIGHTS = {
  exec_ok = 2.0,      -- 最高权重：报错候选直接大负分
  row_count = 1.0,    -- 行数合理性
  latency_ms = 0.5,   -- 延迟惩罚
  null_rate = 1.0,    -- 空值率惩罚
  error_class = 0.2,  -- 错误类别区分度
}

-- 权重归一：显式给的权重表只用给定的键（如 static 档 {exec_ok:1} → 真的只看 exec_ok）；
-- 未提供/空表 → 出厂全特征权重（保持 update_weights 前后权重同构）
local function norm_weights(w)
  w = as_table(w)
  if w and next(w) ~= nil then
    local out = {}
    for k, v in pairs(w) do out[k] = tonumber(v) or 0 end
    return out
  end
  local out = {}
  for k, v in pairs(DEFAULT_WEIGHTS) do out[k] = v end
  return out
end

local function norm_features(f)
  f = as_table(f) or {}
  local out = {}
  out.exec_ok = tonumber(f.exec_ok) ~= nil and tonumber(f.exec_ok) or 0
  if out.exec_ok >= 1 then out.exec_ok = 1 elseif out.exec_ok <= 0 then out.exec_ok = 0 end
  out.row_count = tonumber(f.row_count)
  out.expect_rows = tonumber(f.expect_rows)
  out.row_tolerance = tonumber(f.row_tolerance) or 0.5
  out.latency_ms = tonumber(f.latency_ms)
  out.latency_budget_ms = tonumber(f.latency_budget_ms) or 2000
  out.null_rate = tonumber(f.null_rate)
  out.error_class = tostring(f.error_class or 'ok')
  if out.error_class ~= 'ok' and out.exec_ok == 1 then
    out.error_class = 'ok' -- 成功却标错误类别：以 exec_ok 为准
  end
  return out
end

local function error_class_score(cls)
  local t = { ok = 0.0, timeout = -0.6, syntax = -0.9, semantics = -0.7,
              runtime = -0.8, data = -0.5, other = -0.4 }
  return t[cls] or -0.4
end

-- ======================================================================
-- 逐特征基础分（[-1,1]，符号=方向）
-- ======================================================================
local function base_scores(f)
  local s = {}
  -- 1) exec_ok：成功 +1 / 失败 −1（权重最大 → 报错候选大负分）
  s.exec_ok = (f.exec_ok == 1) and 1 or -1
  -- 2) 行数合理性：1 − min(1, |row−expect| / max(expect·tol, 1))；0 行 vs 有期望 → −1
  if f.row_count ~= nil and f.expect_rows ~= nil and f.expect_rows > 0 then
    if f.row_count == 0 then
      s.row_count = -1
    else
      local tol = math.max(f.expect_rows * f.row_tolerance, 1)
      local dev = math.abs(f.row_count - f.expect_rows) / tol
      s.row_count = 1 - math.min(1, dev)
    end
  else
    s.row_count = 0 -- 无期望值可对照 → 中性
  end
  -- 3) 延迟惩罚：预算内 0；超预算线性到 −1（2× 预算封顶）
  if f.latency_ms ~= nil then
    local b = math.max(f.latency_budget_ms, 1)
    if f.latency_ms <= b then s.latency_ms = 0
    else s.latency_ms = -math.min(1, (f.latency_ms - b) / b) end
  else
    s.latency_ms = 0
  end
  -- 4) null 率惩罚：0 → 0；≥0.5 → −1
  if f.null_rate ~= nil then
    local nr = math.max(0, math.min(1, f.null_rate))
    s.null_rate = -nr * 2
  else
    s.null_rate = 0
  end
  -- 5) 错误类别基础分（与 exec_ok=0 叠加，提供并列时的区分度）
  s.error_class = error_class_score(f.error_class)
  return s
end

-- 感知机加权总分（z = bias + Σ w·base；排序用，不做 sigmoid）
local function weighted_score(f, w, bias)
  local s = base_scores(norm_features(f))
  local total = bias or 0
  local detail = {}
  for k in pairs(w) do
    local b = s[k] or 0
    total = total + w[k] * b
    detail[k] = { base = b, weight = w[k], contrib = w[k] * b }
  end
  return total, detail, s
end

-- ======================================================================
-- op 分发
-- ======================================================================
local function op_features(p)
  local f = norm_features(p.f or p.features or {})
  local s = base_scores(f)
  local bs = {}
  for k, v in pairs(s) do bs[k] = r6(v) end
  return json_encode({ normalized = f, base_scores = bs })
end

local function op_score(p)
  local w = norm_weights(p.weights)
  local bias = tonumber(p.bias) or 0
  local total, detail = weighted_score(p.f or p.features, w, bias)
  local d = {}
  for k, v in pairs(detail) do
    d[k] = { base = v.base, weight = v.weight, contrib = r6(v.contrib) }
  end
  return json_encode({ score = r6(total), bias = r6(bias), contributions = d })
end

local function op_select(p)
  local w = norm_weights(p.weights)
  local bias = tonumber(p.bias) or 0
  local cands = as_table(p.candidates) or {}
  local n = #cands
  if n == 0 then return json_encode({ error = 'no candidates' }) end
  local scored = {}
  for i = 1, n do
    local c = cands[i]
    local total = weighted_score(c.features or c.f or {}, w, bias)
    scored[i] = { candidate_id = tostring(c.candidate_id or ('c' .. i)),
                  score = r6(total), rank = 0 }
  end
  local order = {}
  for i = 1, n do order[i] = i end
  table.sort(order, function(a, b)
    if scored[a].score ~= scored[b].score then
      return scored[a].score > scored[b].score
    end
    return scored[a].candidate_id < scored[b].candidate_id -- 并列：字典序（确定性）
  end)
  for r, i in ipairs(order) do scored[i].rank = r end
  local ranking = {}
  for i = 1, n do ranking[i] = scored[i] end
  table.sort(ranking, function(a, b) return a.rank < b.rank end)
  return json_encode({
    selected_id = scored[order[1]].candidate_id,
    score = scored[order[1]].score,
    bias = r6(bias),
    ranking = ranking,
  })
end

-- 在线感知机（Learn→Retain 低保真版）：
-- 逐条历史 (x=特征基础分, y=±1)：若 y·(bias + w·x) ≤ 0 → w += lr·y·x, bias += lr·y
local function op_update_weights(p)
  local w = norm_weights(p.weights)
  local lr = tonumber(p.lr) or 0.1
  local epochs = math.max(1, math.floor(tonumber(p.epochs) or 3))
  local bias = tonumber(p.bias) or 0
  local history = as_table(p.history) or {}
  local n = #history
  local updates = 0
  for _ = 1, epochs do
    for i = 1, n do
      local h = history[i]
      local y = (h.pass == true or h.pass == 1 or h.pass == '1') and 1 or -1
      local s = base_scores(norm_features(h.features or h.f or {}))
      local z = bias
      for k in pairs(w) do z = z + w[k] * (s[k] or 0) end
      if y * z <= 0 then
        for k in pairs(w) do w[k] = w[k] + lr * y * (s[k] or 0) end
        bias = bias + lr * y
        updates = updates + 1
      end
    end
  end
  local out_w = {}
  for k, v in pairs(w) do out_w[k] = r6(v) end
  return json_encode({ weights = out_w, bias = r6(bias),
                       samples = n, updates = updates, lr = lr, epochs = epochs })
end

local function run(p)
  if type(p) ~= 'table' then return json_encode({ error = 'expected table param' }) end
  local op = p.op or 'score'
  if op == 'features' then return op_features(p) end
  if op == 'score' then return op_score(p) end
  if op == 'select' then return op_select(p) end
  if op == 'update_weights' then return op_update_weights(p) end
  if op == 'default_weights' then return json_encode(DEFAULT_WEIGHTS) end
  return json_encode({ error = 'unknown op: ' .. tostring(op) })
end

return function(p)
  return run(p)
end
