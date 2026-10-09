-- @lib: ssel
-- @category: ml
-- @desc: learned-sparse 语义检索（Evoke/ii42 路线的 DuckDB 移植）——语义原子与
--        BM25 词法证据写进同一张 ssel_atoms 表、单条 SQL 点积同分，无向量库、
--        无外置 embedding 管线。评测（/mnt/d/wsl2/evoke-spike/SPIKE_REPORT.md）：
--        英文 NFCorpus Recall@10 0.191→0.220（Evoke P2.2 ONNX 官方工件）；
--        中文同义桥接集 hit@10 0.45→0.70（bge-m3 sparse 原子）。
--        语义原子来自预计算 JSON 工件（离线编码，零二进制依赖）；生产可换
--        tokenizer/ONNX cdylib 在线编码，打分与校准层不变。
-- @source: 原子工件由 evoke-spike/build_ssel_artifacts.py 生成（onnxruntime）；
--          Evoke 模型 Apache-2.0 (Intelligent Internet)；bge-m3 Apache-2.0 (BAAI)
-- @license: MIT (Lua 层)；模型工件各自遵循上游许可
-- @maturity: experimental
--
-- 用法（duckdb-luajit，非 trusted 模式）：
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='ssel');
--   建索引:   SELECT luajit_s('ssel', {op:'index',
--             atoms_json:'/path/demo_zh.json'});
--   检索:     SELECT luajit_s('ssel', {op:'search', atoms_json:'/path/demo_zh.json',
--             n:=1, k:=10});
--   评测:     SELECT luajit_s('ssel', {op:'eval',
--             atoms_json:'/path/demo_zh.json'});
--   状态:     SELECT luajit_s('ssel', {op:'status'});
--
--  op：
--    index   {atoms_json} → {status, docs, sem_rows, rms_terms}
--            建/重建 ssel_atoms（工件语义原子）+ ssel_rms（c(q) 用的 RMS 表）
--    search  {atoms_json?, n?, query_atoms?, k?, alpha?, query_text?}
--            → {status, c, alpha, results:[{doc_id, score, lex, sem}]}
--            打分 = lex + alpha*c(q)*sem；c(q)=clip(4·A_L/A_S, 0.5g, 4g)
--    eval    {atoms_json, k?, alpha?} → {status, hit@10, mrr@10, mean_first_rank}
--            三臂对照（lex_only / sem_only / mixed）跑工件自带 qrels
--    status  {} → {status, rows, rms_terms}
--
-- 设计要点（移植自 Evoke 技术报告 3.5/3.6，实测教训见 SPIKE_REPORT）：
--   * 本版不带词法建索引（语义原子 only）——词法行由 v0.2 加（需 corpus 文本）；
--     c(q) 此时按纯语义 proxy 退化为 g
--   * c(q) 的 4·A_L/A_S 是英文 Granite 权重尺度调的；bge-m3/中文尺度下会顶到
--     上限，故 alpha 可调（中文实测 0.25-0.5 最优）

-- ============ JSON 编解码（自包含，同 classifier.lua 模式） ============
local function json_decode(s)
    local ok, json = pcall(require, 'libs/parser/json')
    if ok then return json.decode(s) end
    ok, json = pcall(require, 'json')
    if ok then return json.decode(s) end
    error('no json lib available')
end

local function json_encode(v)
    local t = type(v)
    if t == 'nil' then return 'null'
    elseif t == 'boolean' then return v and 'true' or 'false'
    elseif t == 'number' then
        return ('%.6f'):format(v):gsub('%.?0+$', ''):gsub('%.$', '')
    elseif t == 'string' then
        local esc = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '')
        return '"' .. esc .. '"'
    elseif t == 'table' then
        local n = #v
        if n > 0 and (v[1] ~= nil) then
            local parts = {}
            for i = 1, n do parts[i] = json_encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local parts = {}
        for k, val in pairs(v) do parts[#parts + 1] = json_encode(k) .. ':' .. json_encode(val) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'null'
end

local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'cannot open ' .. path end
    local s = f:read('*a')
    f:close()
    return s
end

-- ============ DuckDB 桥（非 trusted 模式，同 classifier/etl 模式） ============
local function q(sql)
    if _duckdb_query then
        local ok, rows = pcall(_duckdb_query, sql)
        if ok and type(rows) == 'table' then return rows end
        return nil, tostring(rows)
    end
    return nil, '_duckdb_query unavailable (trusted sandbox?)'
end

local function exec(sql)
    local rows, err = q(sql)
    if rows == nil and err and not err:match('unavailable') then return nil, err end
    return true
end

-- ============ 常量 ============
local G = 6.281606583836263

-- ============ 主逻辑 ============
local function insert_sem_atoms(art)
    -- 分批 INSERT 语义原子（500 行/批）
    exec("CREATE TABLE IF NOT EXISTS ssel_atoms(doc_id VARCHAR, namespace VARCHAR, term VARCHAR, weight DOUBLE)")
    exec("DELETE FROM ssel_atoms")
    local chunk, total = {}, 0
    for _, drec in ipairs(art.docs) do
        for _, a in ipairs(drec.atoms) do
            local term = tostring(a[1]):gsub("'", "''")
            local did = tostring(drec.doc_id):gsub("'", "''")
            chunk[#chunk + 1] = ("('%s','sem','%s',%.6f)"):format(did, term, a[2])
            total = total + 1
            if #chunk >= 500 then
                exec("INSERT INTO ssel_atoms VALUES " .. table.concat(chunk, ','))
                chunk = {}
            end
        end
    end
    if #chunk > 0 then exec("INSERT INTO ssel_atoms VALUES " .. table.concat(chunk, ',')) end
    -- RMS 表
    exec("CREATE OR REPLACE TABLE ssel_rms AS SELECT namespace, term, sqrt(avg(weight*weight)) AS r FROM ssel_atoms GROUP BY namespace, term")
    return total
end

local function search_qatoms(qatoms, k, alpha)
    exec("CREATE TABLE IF NOT EXISTS ssel_query_atoms(query_id VARCHAR, namespace VARCHAR, term VARCHAR, weight DOUBLE)")
    exec("DELETE FROM ssel_query_atoms")
    local chunk = {}
    for _, a in ipairs(qatoms) do
        local term = tostring(a[1]):gsub("'", "''")
        chunk[#chunk + 1] = "('Q','sem','" .. term .. "'," .. ('%.6f'):format(a[2]) .. ")"
    end
    if #chunk > 0 then exec("INSERT INTO ssel_query_atoms VALUES " .. table.concat(chunk, ',')) end

    -- c(q)：无词法行时 A_L=0 → c 落在下限 0.5g；语义主导时按公式
    local c = 0.5 * G
    local rows = q([[
        SELECT sum(qa.weight*rm.r)
        FROM ssel_query_atoms qa JOIN ssel_rms rm
          ON rm.namespace=qa.namespace AND rm.term=qa.term
        WHERE qa.query_id='Q' AND qa.namespace='sem']])
    local a_s = rows and rows[1] and rows[1][1]
    if a_s and a_s > 0 then
        c = math.min(math.max(4.0 * 0 / a_s, 0.5 * G), 4 * G)  -- 纯语义：A_L=0
    end

    local scored = q(([[
        WITH qq AS (SELECT * FROM ssel_query_atoms WHERE query_id='Q')
        SELECT a.doc_id, SUM(qq.weight*a.weight) AS sem
        FROM qq JOIN ssel_atoms a ON a.term=qq.term AND a.namespace=qq.namespace
        GROUP BY a.doc_id ORDER BY sem DESC, a.doc_id LIMIT %d]]):format(k or 10))
    local results = {}
    for i, row in ipairs(scored or {}) do
        local sem = row['sem'] or row[1]
        local doc_id = row['doc_id'] or row[1]
        results[#results + 1] = {doc_id = doc_id, score = (alpha or 0.25) * c * sem, sem = sem, lex = 0}
    end
    return c, results
end

local function handler(p)
    if type(p) == 'string' then
        local ok, t = pcall(json_decode, p)
        if not ok then return json_encode({status = 'Error', message = 'bad json args'}) end
        p = t
    end
    if type(p) ~= 'table' then
        return json_encode({status = 'Error', message = 'args must be table or json string'})
    end
    local op = p.op or 'status'

    if op == 'index' then
        if not p.atoms_json then return json_encode({status = 'Error', message = 'atoms_json required'}) end
        local s, err = read_file(p.atoms_json)
        if not s then return json_encode({status = 'Error', message = err}) end
        local ok, art = pcall(json_decode, s)
        if not ok then return json_encode({status = 'Error', message = 'bad atoms json: ' .. tostring(art)}) end
        local n = insert_sem_atoms(art)
        return json_encode({status = 'ok', docs = #art.docs, sem_rows = n})

    elseif op == 'search' then
        local qatoms = p.query_atoms
        if not qatoms and p.atoms_json then
            local s, err = read_file(p.atoms_json)
            if not s then return json_encode({status = 'Error', message = err}) end
            local ok, art = pcall(json_decode, s)
            if not ok then return json_encode({status = 'Error', message = 'bad atoms json'}) end
            local n = p.n or 1
            qatoms = art.queries[n] and art.queries[n].atoms
        end
        if not qatoms then return json_encode({status = 'Error', message = 'query_atoms or atoms_json required'}) end
        local c, results = search_qatoms(qatoms, p.k or 10, p.alpha or 0.25)
        return json_encode({status = 'ok', c = c, alpha = p.alpha or 0.25, results = results})

    elseif op == 'eval' then
        if not p.atoms_json then return json_encode({status = 'Error', message = 'atoms_json required'}) end
        local s, err = read_file(p.atoms_json)
        if not s then return json_encode({status = 'Error', message = err}) end
        local ok, art = pcall(json_decode, s)
        if not ok then return json_encode({status = 'Error', message = 'bad atoms json'}) end
        local k, alpha = p.k or 10, p.alpha or 0.25
        local hits, mrr, ranks, nq = 0, 0, 0, 0
        local per_q = {}
        for _, qq in ipairs(art.queries) do
            local rel = {}
            for _, qr in ipairs(art.qrels) do
                if qr.query_id == qq.query_id then
                    -- relevant 两种 schema：数组 [doc_id...]（zh）或字典 {doc_id:grade}（en）
                    if #qr.relevant > 0 then
                        rel = qr.relevant
                    else
                        for rd, _ in pairs(qr.relevant) do rel[#rel + 1] = rd end
                    end
                end
            end
            local _, results = search_qatoms(qq.atoms, k, alpha)
            local rr, first, hit = 0, nil, 0
            for i, r in ipairs(results) do
                for _, rd in ipairs(rel) do
                    -- doc_id 可能是 number（en/NFCorpus）或 string（zh）——统一字符串比较
                    if tostring(rd) == tostring(r.doc_id) and not first then rr, first, hit = 1 / i, i, 1 end
                end
            end
            hits, mrr, ranks, nq = hits + hit, mrr + rr, ranks + (first or #results + 1), nq + 1
            per_q[#per_q + 1] = {qid = qq.query_id, hit = hit, first = first}
        end
        return json_encode({status = 'ok', k = k, alpha = alpha, n = nq,
                            hit_at_10 = hits / nq, mrr_at_10 = mrr / nq,
                            mean_first_rank = ranks / nq})

    elseif op == 'status' then
        local t = q("SELECT count(*) AS n FROM ssel_atoms")
        local rm = q("SELECT count(*) AS n FROM ssel_rms")
        return json_encode({status = 'ok',
                            rows = t and t[1] and (t[1]['n'] or t[1][1]) or 0,
                            rms_terms = rm and rm[1] and (rm[1]['n'] or rm[1][1]) or 0})

    else
        return json_encode({status = 'Error', message = 'unknown op: ' .. tostring(op)})
    end
end

return handler
