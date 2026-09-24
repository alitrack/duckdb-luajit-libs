-- @lib: classifier
-- @category: ml
-- @desc: jimothy 模式文本分类器（Rust cdylib 内核 + LuaJIT FFI 直调）——
--        TF-IDF(中英混合 bigram) + 线性 softmax 头(full-batch Adam) +
--        temperature 校准 + Clopper-Pearson 精确二项下界阈值推荐。
--        "把 LLM 用量蒸馏成本地分类器"：标签可以来自 jev_ask / llm_extract，
--        训练好的 model 是自包含 JSON 资产，predict 零网络、毫秒级。
-- @source: libclassifier_capi.so（Rust cdylib, MIT/Apache 2.0, ~770KB，源码
-- @license: MIT OR Apache-2.0 (Rust cdylib, sources in repo)
-- @maturity: audited
--          /mnt/d/wsl2/classifier_capi/，编译 cargo build --offline --release）
--
-- 用法（duckdb-luajit，非 trusted 模式）：
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='classifier');
--   训练:     SELECT luajit_s('classifier', {op:'train', out:'/tmp/model.json',
--             sql:'SELECT text, label FROM tickets'});
--   预测:     SELECT luajit_s('classifier', {op:'predict', model:'/tmp/model.json',
--             texts:['我被扣了两次款']});
--   评估:     SELECT luajit_s('classifier', {op:'evaluate', model:'/tmp/model.json',
--             sql:'SELECT text, label FROM test_set'});
--
--  op：
--    train    {sql | texts+labels, texts_cal+labels_cal?, out?, l2?, epochs?,
--              lr?, seed?, min_df?, ngram?, target?}
--             → {status, model_path?, model?, report}
--               report: n_train/n_cal/n_classes/n_features/labels/best_l2/
--               temperature/train_accuracy/l2_grid/threshold(+grid)
--    predict  {model | model_path, texts, threshold?}
--             → {status, predictions:[{label,probability,accepted?,probs}]}
--    evaluate {model | model_path, sql | texts+labels}
--             → {status, n, accuracy, per_class, confusion}
--
--  模型持久化：model 字段是 JSON 字符串（内部已转义），out 写文件后可用
--  model_path 引用——推荐落文件，SQL 里传路径比传大字符串稳。
--
-- 错误返回：{"status":"Error","message":...}（同 llm_extract 约定）

local ffi = require('ffi')

-- ============ 加载 libclassifier_capi.so ============
local lib
local lib_paths = {
    'libclassifier_capi',
    os.getenv('HOME') .. '/.duckdb/luajit-libs/libclassifier_capi',
    os.getenv('LUAJIT_CLASSIFIER_LIB') or '/nonexistent',
}
for _, p in ipairs(lib_paths) do
    local ok, l = pcall(ffi.load, p)
    if ok then lib = l; break end
end

local RUN = { train = true, predict = true, evaluate = true }

local function run(p)
    if lib then
        local req = p.request or (p.texts and true) or nil
    end
    if not lib then
        return { status = 'Error',
                 message = 'libclassifier_capi.so not found (LD_LIBRARY_PATH or ~/.duckdb/luajit-libs/)' }
    end
    local op = p.op
    if not op then return { status = 'Error', message = 'missing op' } end
    if not RUN[op] then
        return { status = 'Error', message = 'unknown op: ' .. tostring(op) }
    end
    -- persistent handle mode: {handle:'...'} reuses a model loaded earlier
    if p.handle then
        return { status = 'Error', message = 'handle mode not supported in v1' }
    end
    return nil -- fall through to slow path below
end

ffi.cdef[[
    void* classifier_train(const char* req);
    void* classifier_predict(const char* req);
    void* classifier_evaluate(const char* req);
    void  classifier_free(void* p);
]]

-- model cache: path → model JSON string (avoids re-reading file per row)
local model_cache = {}
local CACHE_MAX = 32

-- ============ 极简 JSON encode（自包含，逐字复制自 linalg.lua 契约） ============
local function json_encode(v)
    local t = type(v)
    if t == 'string' then
        return '"' .. v:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                          ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format('\\u%04x', c:byte())
        end) .. '"'
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if math.floor(v) == v and math.abs(v) < 1e15 then return string.format('%d', v) end
        return string.format('%.14g', v)
    elseif t == 'boolean' then
        return tostring(v)
    elseif t == 'nil' then
        return 'null'
    elseif t == 'table' then
        local n = #v
        if n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = json_encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = json_encode(k) .. ':' .. json_encode(val)
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

-- ============ JSON decode（逐字复制自 linalg.lua，勿简化） ============
local function json_decode(s)
    local pos = 1
    local parse_value, skipws

    skipws = function()
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then pos = pos + 1 else break end
        end
    end

    local function parse_string()
        pos = pos + 1 -- skip opening quote
        local buf = {}
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1; break end
            if c == '\\' then
                local e = s:sub(pos + 1, pos + 1)
                if e == 'u' then
                    local hex = s:sub(pos + 2, pos + 5)
                    buf[#buf + 1] = utf8_char(tonumber(hex, 16) or 0)
                    pos = pos + 6
                else
                    local map = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }
                    buf[#buf + 1] = map[e] or e
                    pos = pos + 2
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parse_number()
        local b, e = s:find('^[-+]?[0-9]+%.?[0-9]*([eE][-+]?[0-9]+)?', pos)
        if not b then
            b, e = s:find('^[-%d%.eE+]+', pos)
        end
        if not b then error('bad number at ' .. pos) end
        pos = e + 1
        return tonumber(s:sub(b, e))
    end

    parse_value = function()
        skipws()
        local c = s:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            skipws()
            if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
            while true do
                skipws()
                local k = parse_string()
                skipws()
                pos = pos + 1 -- colon
                obj[k] = parse_value()
                skipws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == '}' then break end
            end
            return obj
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skipws()
            if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parse_value()
                skipws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == ']' then break end
            end
            return arr
        elseif c == '"' then
            return parse_string()
        elseif s:sub(pos, pos + 3) == 'true' then
            pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == 'false' then
            pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == 'null' then
            pos = pos + 4; return nil
        else
            return parse_number()
        end
    end

    utf8_char = function(cp)
        if cp < 0x80 then return string.char(cp) end
        if cp < 0x800 then
            return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
        end
        if cp < 0x10000 then
            return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
        end
        return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                           0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    end

    return parse_value()
end

-- ============ DuckDB SQL 查询辅助（非 trusted 模式，同 jev_ask/etl 模式） ============
local function q(sql)
    if _duckdb_query then
        local ok, rows = pcall(_duckdb_query, sql)
        if ok and type(rows) == 'table' then return rows end
        return nil, tostring(rows)
    end
    return nil, '_duckdb_query unavailable (trusted sandbox?)'
end

-- pull two columns (text, label) from a SQL result
-- ⛔ pairs() 键序不稳定（E2E 实测 text/label 拿反）——一律显式按列名取；
--    查询必须 SELECT ... AS text, ... AS label
local function fetch_pairs(sql)
    local rows, err = q(sql)
    if not rows then return nil, err end
    local texts, labels = {}, {}
    for i = 1, #rows do
        local r = rows[i]
        local t, l = r['text'], r['label']
        if t == nil or l == nil then
            return nil, 'query must return columns named text and label (use AS text, AS label)'
        end
        texts[#texts + 1] = tostring(t)
        labels[#labels + 1] = tostring(l)
    end
    if #texts == 0 then return nil, 'query returned 0 rows' end
    return texts, labels
end

-- ============ model 存取 ============
local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'cannot open ' .. path end
    local c = f:read('*a')
    f:close()
    return c
end

local function write_file(path, content)
    local f = io.open(path, 'w')
    if not f then return nil, 'cannot write ' .. path end
    f:write(content)
    f:close()
    return true
end

local function get_model(p)
    if p.model_path then
        if model_cache[p.model_path] then return model_cache[p.model_path] end
        local c, err = read_file(p.model_path)
        if not c then return nil, err end
        local n = 0
        for _ in pairs(model_cache) do n = n + 1 end
        if n >= CACHE_MAX then model_cache = {} end
        model_cache[p.model_path] = c
        return c
    end
    if p.model then
        -- model passed as string: may be raw JSON or a Lua-decoded table re-encoded
        if type(p.model) == 'string' then
            -- detect already-escaped (from train output round-trip) vs raw
            return p.model
        end
        return json_encode(p.model)
    end
    return nil, 'missing model or model_path'
end

-- ============ FFI 调用包装（返回 Lua table） ============
local function call_c(fn_name, req_table)
    local req = json_encode(req_table)
    local fn = lib['classifier_' .. fn_name]
    local p = fn(req)
    if p == nil then return { status = 'Error', message = fn_name .. ' returned null' } end
    local s = ffi.string(p)
    lib.classifier_free(p)
    local ok, decoded = pcall(json_decode, s)
    if not ok then
        return { status = 'Error', message = 'bad json from rust: ' .. tostring(decoded) }
    end
    return decoded
end

-- ============ op 分派 ============
local function op_train(p)
    local req = {}
    if p.sql then
        local texts, labels = fetch_pairs(p.sql)
        if not texts then return { status = 'Error', message = labels } end
        req.texts, req.labels = texts, labels
    elseif p.texts and p.labels then
        req.texts, req.labels = p.texts, p.labels
    else
        return { status = 'Error', message = 'train needs sql or texts+labels' }
    end
    for _, k in ipairs({ 'texts_cal', 'labels_cal', 'l2', 'epochs', 'lr', 'seed', 'min_df', 'ngram', 'target' }) do
        if p[k] ~= nil then req[k] = p[k] end
    end
    local r = call_c('train', req)
    if r.status ~= 'ok' then return r end
    -- persist model if out given
    if p.out then
        local m = r.model
        -- r.model came back as JSON string field; write raw
        local ok, err = write_file(p.out, m)
        if not ok then
            r.status = 'Error'
            r.message = 'trained but cannot write model: ' .. tostring(err)
            return r
        end
        r.model_path = p.out
        r.model = nil -- drop the big string from the return value
        return r
    end
    return r
end

local function op_predict(p)
    local model, err = get_model(p)
    if not model then return { status = 'Error', message = err } end
    local req = { model = model, texts = p.texts }
    if p.threshold then req.threshold = p.threshold end
    return call_c('predict', req)
end

local function op_evaluate(p)
    local model, err = get_model(p)
    if not model then return { status = 'Error', message = err } end
    local req = { model = model }
    if p.sql then
        local texts, labels = fetch_pairs(p.sql)
        if not texts then return { status = 'Error', message = labels } end
        req.texts, req.labels = texts, labels
    elseif p.texts and p.labels then
        req.texts, req.labels = p.texts, p.labels
    else
        return { status = 'Error', message = 'evaluate needs sql or texts+labels' }
    end
    return call_c('evaluate', req)
end

local OPS = { train = op_train, predict = op_predict, evaluate = op_evaluate }

return function(p)
    if type(p) == 'string' then
        local ok, d = pcall(json_decode, p)
        if ok then p = d else
            return json_encode({ status = 'Error', message = 'bad json args' })
        end
    end
    if type(p) ~= 'table' then
        return json_encode({ status = 'Error', message = 'args must be table or json string' })
    end
    local fn = OPS[p.op]
    if not fn then
        return json_encode({ status = 'Error', message = 'unknown op: ' .. tostring(p.op) })
    end
    local ok, r = pcall(fn, p)
    if not ok then
        return json_encode({ status = 'Error', message = 'op failed: ' .. tostring(r) })
    end
    return json_encode(r)
end
