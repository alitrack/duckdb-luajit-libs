-- curl_ffi.lua 回归测试套件（duckdb-luajit）
-- 运行：wsl bash -lc 'cd /mnt/d/wsl2 && duckdb -unsigned -f /mnt/d/wsl2/duckdb-luajit-libs/libs/udf/test_curl_ffi.sql'
--
-- ⚠️ 前置（与 test_jev_ask.sql 同款依赖）：jev 型决策服务在 http://127.0.0.1:18090
--   （/healthz + /v1/systemone）。服务没起时本套件会报错——这是设计，不是测试坏了。
--
-- 对拍矩阵：
--   T1  libcurl 版本可见
--   T2  GET /healthz：FFI vs curl CLI（jev_ask health）逐字节一致
--   T3  POST /v1/systemone：同一请求 body 两种 transport → 决策 JSON 一致
--   T4  404 路径 → 'error: HTTP 404 ...'
--   T5  不可达端口 → 'error: CURL 7 ...'（不是 NULL）
--   T6  负数路径：空 url / 未知 op
--   T7  per-call 开销对拍（n=50，wall-clock）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'curl_ffi',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/curl_ffi.lua'')');
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jev_ask',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/jev_ask.lua'')');

-- T1. libcurl 版本
SELECT luajit_s('curl_ffi', {'op':'version'}) AS libcurl_version;

-- T2. GET /healthz：两种 transport 逐字节一致
SELECT luajit_s('curl_ffi', {url: 'http://127.0.0.1:18090/healthz'}) AS ffi_health,
       luajit_s('jev_ask', {'op':'health'}) AS cli_health;

-- T3. POST /v1/systemone：同一 body 两种 transport
SET VARIABLE q = '{"team":{"type":"choice","instructions":"哪个团队该处理？","criteria":{"billing":"账单、发票、退款、价格","technical":"故障、报错、接口、崩溃","logistics":"发货、物流、到货时间"}}}';
-- 与 jev_ask 内部构造的 body 逐字节相同（state 无需转义、model 默认 local-latest、questions 同变量）
SET VARIABLE body = '{"state":"发票金额和合同不一致，我已经催了三次了","model":"local-latest","questions":' || getvariable('q') || '}';
CREATE OR REPLACE TABLE cmp AS
SELECT luajit_s('curl_ffi', {url: 'http://127.0.0.1:18090/v1/systemone',
                             body: getvariable('body'),
                             headers: {'Content-Type': 'application/json'}}) AS ffi_raw,
       luajit_s('jev_ask', {'op':'ask',
                            'state':'发票金额和合同不一致，我已经催了三次了',
                            'questions': getvariable('q')}) AS cli_raw;
SELECT ffi_raw = cli_raw AS transport_identical,
       json_extract(ffi_raw, '$.answers.team.choice') AS ffi_team,
       json_extract(cli_raw, '$.answers.team.choice') AS cli_team,
       round(CAST(json_extract(ffi_raw, '$.answers.team.probabilities.billing') AS DOUBLE), 4) AS ffi_p_billing,
       round(CAST(json_extract(cli_raw, '$.answers.team.probabilities.billing') AS DOUBLE), 4) AS cli_p_billing
FROM cmp;

-- T4. 404 路径 → 错误串带 HTTP 码与 body 前缀（不是 NULL、不是静默）
SELECT luajit_s('curl_ffi', {url: 'http://127.0.0.1:18090/definitely-not-a-route'}) AS not_found;

-- T5. 不可达端口 → CURL 7（Could not connect）
SELECT luajit_s('curl_ffi', {url: 'http://127.0.0.1:1/v1/systemone'}) AS unreachable;

-- T6. 负数路径
SELECT luajit_s('curl_ffi', {url: ''}) AS empty_url,
       luajit_s('curl_ffi', {op: 'nope'}) AS unknown_op;

-- T7. per-call 开销对拍（healthz：几 ms 级响应，fork 开销占比最大）
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'bench_transport',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/probe_bench_transport.lua'')');
SELECT luajit_s('bench_transport', {n: 50}) AS bench;
