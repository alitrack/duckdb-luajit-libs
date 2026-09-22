-- @lib: jev_ask
-- @category: udf
-- @desc: 把「类型化决策读出头」接成 SQL 函数——state + 运行时定义的 choice/score/noul 问题，
--        返回每个问题的**概率分布**（不是一句回答）。读模型在 `Answer:` 之后那一个 token 的
--        top-k 分布：一次前向、零 token 输出、答案结构上不可能落在声明的选项集之外。
-- @source: original（duckdb-luajit 系列）
-- @requires: curl CLI（io.popen 调系统 curl）+ 一个跑着的 jev 型决策服务（HTTP 契约 POST /v1/systemone）
-- ⚠️ 需普通模式（非 trusted）：io.popen 用于发起 HTTP 请求（与 llm_extract 同档）
--
-- 与 llm_extract 的分工：那个是**生成式**（LLM 吐 content，要 parse、不确定靠猜）；
-- 这个是**读数式**（读分布，可直接当列用：WHERE 阈值门控 / GROUP BY 分档 / 当特征 / 进台账）。
--
-- ── 用法（duckdb-luajit） ───────────────────────────────────────────────
--   install:  SELECT * FROM luajit_module(mode := 'install', sql_name := 'jev_ask');
--   ⚠️ install 用户注意：展开宏是 **SQL catalog 对象**，装不进 INDEX（INDEX 只收能编译成
--      Lua chunk 的 .lua）。装完按需 `.read libs/udf/jev_ask_macros.sql`，或粘这段最小集：
--        CREATE OR REPLACE MACRO jev_choice(raw, qid) AS json_extract_string(raw, '$.answers.' || qid || '.choice');
--        CREATE OR REPLACE MACRO jev_p(raw, qid, label) AS CAST(json_extract(raw, '$.answers.' || qid || '.probabilities.' || label) AS DOUBLE);
--        CREATE OR REPLACE MACRO jev_conf(raw, qid) AS CAST(json_extract(raw, '$.answers.' || qid || '.confidence') AS DOUBLE);
--        CREATE OR REPLACE MACRO jev_ok(raw) AS (raw IS NOT NULL AND raw NOT LIKE 'error:%');
--   quick_compile:
--     SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jev_ask',
--       source := (SELECT content FROM read_text('/path/to/jev_ask.lua')));
--   探活（批量跑之前先探一次）:
--     SELECT luajit_s('jev_ask', {'op':'health'});            -- {"service":...,"status":"ok"}
--   判定（问题在 SQL 里定义，不在表 schema 里）:
--     SET VARIABLE q = '{"team":{"type":"choice","instructions":"哪个团队该处理？",
--                                "criteria":{"billing":"账单/发票/退款","technical":"故障/报错"}},
--                        "urgent":{"type":"noul","instructions":"表达了紧迫性？"}}';
--     SELECT id, luajit_s('jev_ask', {'state': body, 'questions': getvariable('q')}) AS raw
--     FROM tickets;
--   展开成列 = 交给 DuckDB 原生 json_extract（配套宏见同目录 jev_ask_macros.sql）:
--     SELECT id, jev_choice(raw,'team') AS team, jev_p(raw,'team','billing') AS p_billing,
--            jev_conf(raw,'team') AS conf
--     FROM decisions WHERE jev_ok(raw) AND jev_conf(raw,'team') >= 0.8;
--
-- ── 设计纪律（四条，都是踩过的坑） ──────────────────────────────────────
--   1. **本 lib 只做传输。** 题面渲染、字母槽位分配、槽位校验、概率归一化、confidence 公式
--      全部留在服务端（jev 型服务）。在 SQL 层重写任何一条都是静默陷阱——实测代价：一句
--      「按 sorted() 取首槽」曾让 32/150 条 noul 答到错误的字母位。
--      ⇒ 展开只做「按契约取字段」，不重算、不归一化、不补缺。
--   2. ⚠️ **失败用返回字符串显形，不用 `error()`**（2026-09-21 实测）：duckdb-luajit 扩展把
--      Lua 运行期 `error()` **吞成 NULL**，消息只落到 `luajit_module(mode := 'last_error')`
--      （末次覆盖）。而 NULL 在管道里与「本来就没数据」不可区分 ⇒ 靠 error() 显形是假的。
--      故失败一律返回 **`error: <message>` 字符串**（与 llm_extract 的约定一致，可见、可 grep、
--      可计数），并把 HTTP body 前 400 字符带进消息。调用方用 `jev_ok(raw)` 断言，或
--      `count(*) FILTER (WHERE NOT jev_ok(raw))` 统计失败行数（部分失败容忍口径，同 BigQuery
--      `max_error_ratio` / Snowflake `return_error_details`）。
--   3. **缓存是 opt-in 且不承诺命中率**：`p.cache='true'` 时按 (endpoint,model,state,questions)
--      缓存。temperature=0 的读数场景确定性成立；但 Lua 状态在多线程下按执行单元隔离，
--      实测同一条已缓存查询连跑 6 次耗时 0.809/0.424/0.520/0.001/0.000/0.397 s
--      ⇒ **大批量去重要用 SQL 层 `SELECT DISTINCT state`，不要指望这层缓存**。
--   4. **读出口径别用生成式兜底**：失败就报错，不许退化成「按先验答」或给一个低概率。

local result_cache = {}
local cache_count = 0
local CACHE_MAX = 512

local function json_escape(s)
  return (tostring(s):gsub('[%c\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\r' then return '\\r' end
    if c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end))
end

local function cache_key(p, endpoint)
  return table.concat({ endpoint, p.model or '', p.state or '', p.questions or '' }, '\1')
end

-- 错误即数据：返回可 grep、可计数的 'error: ...'（见纪律 2）
local function err(msg)
  return 'error: ' .. tostring(msg)
end

-- ============ HTTP（curl CLI，跨平台） ============
-- 本机/内网 HTTP 必须 --noproxy '*'：否则会走代理环境变量（WSL 上实测会把 loopback 请求带偏）。
local function http_post(url, body, timeout)
  local tmp = os.tmpname()
  local f = io.open(tmp, 'w')
  if not f then return nil, 'cannot write temp file ' .. tostring(tmp) end
  f:write(body)
  f:close()
  local cmd = string.format(
    "curl -s --noproxy '*' --max-time %s -X POST '%s' "
    .. "-H 'Content-Type: application/json' --data-binary @'%s' -w '\\n%%{http_code}'",
    tostring(timeout or 120), url, tmp)
  local pipe = io.popen(cmd)
  if not pipe then os.remove(tmp) return nil, 'io.popen failed (needs normal mode)' end
  local out = pipe:read('*a')
  pipe:close()
  os.remove(tmp)
  if out == nil then return nil, 'no response from ' .. url end
  local code = out:match('\n(%d+)$')
  local payload = out:match('^(.*)\n%d+$') or ''
  if code ~= '200' then
    return nil, string.format('HTTP %s from %s: %s', tostring(code), url, payload:sub(1, 400))
  end
  return payload
end

local function endpoint_of(p)
  local e = p.endpoint
  if e == nil or e == '' then e = os.getenv('JEV_ENDPOINT') end
  if e == nil or e == '' then e = 'http://127.0.0.1:18090' end
  return (e:gsub('/+$', ''))
end

local function health(p)
  local url = endpoint_of(p) .. '/healthz'
  local pipe = io.popen(string.format("curl -s --noproxy '*' --max-time 10 '%s'", url))
  if not pipe then return err('io.popen failed (needs normal mode)') end
  local out = pipe:read('*a')
  pipe:close()
  if out == nil or out == '' then return err('no response from ' .. url) end
  return out
end

local function ask(p)
  if p.state == nil or p.state == '' then
    return err('empty `state` (nothing to decide on)')
  end
  if p.questions == nil or p.questions == '' then
    return err('empty `questions` (define at least one choice/score/noul question)')
  end

  local endpoint = endpoint_of(p)
  local use_cache = (p.cache == 'true' or p.cache == true)
  local ck = cache_key(p, endpoint)
  if use_cache and result_cache[ck] then return result_cache[ck] end

  local body = '{"state":"' .. json_escape(p.state) .. '"'
    .. ',"model":"' .. json_escape(p.model or 'local-latest') .. '"'
    .. ',"questions":' .. p.questions .. '}'

  local res, e = http_post(endpoint .. '/v1/systemone', body, p.timeout)
  if not res then return err(e) end

  -- 服务端契约违例（422）与读出头失败（502）以 HTTP 码区分，客户端按码分诊而非一律重试
  if use_cache then
    if cache_count >= CACHE_MAX then result_cache = {} cache_count = 0 end
    result_cache[ck] = res
    cache_count = cache_count + 1
  end
  return res
end

return function(p)
  p = p or {}
  local op = p.op or 'ask'
  if op == 'health' then return health(p) end
  if op == 'ask' then return ask(p) end
  return err('unknown op `' .. tostring(op) .. '` (ask | health)')
end
