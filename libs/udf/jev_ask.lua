-- @lib: jev_ask
-- @category: udf
-- @desc: 把「类型化决策读出头」接成 SQL 函数——state + 运行时定义的 choice/score/noul 问题，
--        返回每个问题的**概率分布**（不是一句回答）。读模型在 `Answer:` 之后那一个 token 的
--        top-k 分布：一次前向、零 token 输出、答案结构上不可能落在声明的选项集之外。
-- @source: original（duckdb-luajit 系列）
-- @requires: 一个跑着的 jev 型决策服务（HTTP 契约 POST /v1/systemone）。
-- @license: MIT (duckdb-luajit-libs project)
--            传输层**自动选择**：同会话已装 curl_ffi（FFI dlopen libcurl，零 fork）→ 优先用它；
--            未装则回退 curl CLI（io.popen）。大批量 per-row 调用建议装 curl_ffi（≈10x，见 curl_ffi.lua）。
-- ⚠️ 需普通模式（非 trusted）：io.popen / ffi.load 发起 HTTP 请求（与 llm_extract 同档）
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
-- ── 批量管道（2026-09-22 实测，AG News N=1000，见 D:\wsl2\ag_news_data\AG_NEWS_BENCH.md）──
--   单条 SQL 大查询 + per-row 门面宏（jev_ask_macros.sql 尾部 jev_questions/jev）:
--     SET threads = 1;   -- ⚠️ 必须：per-row FFI UDF 在并行扫描里跨线程竞争，实测 threads=4
--                        --    比串行慢 18%（8.19 vs 10.02 rows/s），0 失败但纯损耗
--     SET VARIABLE q = (SELECT questions FROM jev_questions(<instructions>, <choice list>));
--     SELECT id, jev_choice(r,'q') AS topic, jev_conf(r,'q') AS conf
--     FROM (SELECT id, jev(body, getvariable('q')) AS r FROM t);
--   实测：threads=1 门面 10.02 rows/s > Python loop（每行 fetchone）9.37 rows/s（快 ~7%，
--        省 Python↔DuckDB 往返），0 失败、预测逐行一致。并行扫描 threads=4 = 8.19 rows/s
--        （比串行慢 18%）。⇒ **批量走纯 SQL 门面，勿用 Python loop、勿开并行**；
--        吞吐上限是推理后端，不是传输层。
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

-- 平台探测：Windows 的 io.popen 走 cmd.exe，**单引号是字面量**（不是 shell 引用）→
-- URL/路径里混入 ' → curl rc=3 (malformed URL) / rc=26 (file read error)。
-- 2026-09-22 Windows 实测：同一命令 WSL 正常、cmd.exe 全灭；双引号版（cmd 剥外层双引号）
-- 则全过。解法：平台感知引用——Windows 用双引号、`*` 裸写；其余平台用单引号。
local IS_WINDOWS = (os.getenv('PROCESSOR_ARCHITECTURE') ~= nil or os.getenv('COMPUTERNAME') ~= nil)

-- shell 引用（cmd.exe 认双引号、POSIX 认单引号）
local function sq(s)
  if IS_WINDOWS then return '"' .. s .. '"' end
  return "'" .. s .. "'"
end
-- --noproxy 的通配 *：POSIX 要引号防 glob，cmd.exe 裸写即可
local NOPROXY_STAR = IS_WINDOWS and '*' or "'*'"

-- ============ HTTP（curl CLI，跨平台） ============
-- 本机/内网 HTTP 必须 --noproxy '*'：否则会走代理环境变量（WSL 上实测会把 loopback 请求带偏）。
local function http_post(url, body, timeout)
  local tmp = os.tmpname()
  local f = io.open(tmp, 'w')
  if not f then return nil, 'cannot write temp file ' .. tostring(tmp) end
  f:write(body)
  f:close()
  local cmd = string.format(
    "curl -s --noproxy %s --max-time %s -X POST %s "
    .. "-H %s --data-binary %s -w %s",
    NOPROXY_STAR, tostring(timeout or 120), sq(url),
    sq('Content-Type: application/json'), sq('@' .. tmp),
    sq('\\n%{http_code}'))   -- 已是 %s 参数，% 无需再 %% 转义（那是 format 串才需要的）
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

-- ── 传输层选择（2026-09-22 升级）────────────────────────────────────────
-- 优先走 curl_ffi（FFI dlopen libcurl，零 fork、零临时文件）：当同会话已加载
-- curl_ffi（init.lua batch-register 会设 _G._curl_ffi_post）时启用。
-- 不存在则回退 curl CLI（io.popen）——保证 curl_ffi 未安装时 jev_ask 独立可用。
-- PoC 实测（WSL, jev-clone /healthz 微基准）：FFI 0.33ms/call vs CLI 3.34ms/call ≈ 10x，
-- 且同一 POST body 两种 transport 响应逐字节一致（见 libs/udf/PoC-curl_ffi-output.txt）。
local function post(url, body, timeout)
  local ffi_post = _G._curl_ffi_post
  if ffi_post then
    local res, e = ffi_post({ url = url, body = body,
                               headers = { ['Content-Type'] = 'application/json' },
                               timeout = timeout })
    if res then return res end
    -- curl_ffi 返回 'error: <msg>'，剥掉前缀回传裸消息，由调用方 err() 统一加前缀
    -- （与 CLI 路径 http_post 返回裸错误串的约定一致）
    return nil, tostring(e or 'curl_ffi transport failed'):sub(8)
  end
  -- 回退：curl CLI
  return http_post(url, body, timeout)
end

local function health(p)
  local url = endpoint_of(p) .. '/healthz'
  local pipe = io.popen(string.format("curl -s --noproxy %s --max-time 10 %s", NOPROXY_STAR, sq(url)))
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

  local res, e = post(endpoint .. '/v1/systemone', body, p.timeout)
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
