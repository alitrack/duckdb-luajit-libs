-- 端到端：同会话装 curl_ffi + jev_ask，验证 jev_ask 自动走 FFI 传输层
-- 判据：装 curl_ffi 后 jev_ask 的 ask() 结果与 curl CLI 直调 curl_ffi 的 POST 逐字节一致，
--       且 jev_ok/jev_choice 展开正常。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
.read /mnt/d/wsl2/duckdb-luajit-libs/libs/udf/jev_ask_macros.sql
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'curl_ffi',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/curl_ffi.lua'')');
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jev_ask',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/jev_ask.lua'')');

SET VARIABLE q = '{"team":{"type":"choice","instructions":"哪个团队该处理？","criteria":{"billing":"账单、发票、退款、价格","technical":"故障、报错、接口、崩溃","logistics":"发货、物流、到货时间"}}}';
SET VARIABLE body = '{"state":"发票金额和合同不一致，我已经催了三次了","model":"local-latest","questions":' || getvariable('q') || '}';

-- jev_ask（同会话已装 curl_ffi → 应自动走 FFI）
CREATE OR REPLACE TABLE via_jev AS
SELECT luajit_s('jev_ask', {'op':'ask', 'state':'发票金额和合同不一致，我已经催了三次了', 'questions': getvariable('q')}) AS raw;

-- curl_ffi 直调（同一 body，参照系）
CREATE OR REPLACE TABLE via_ffi AS
SELECT luajit_s('curl_ffi', {url:'http://127.0.0.1:18090/v1/systemone', body: getvariable('body'),
                             headers:{'Content-Type':'application/json'}}) AS raw;

-- 判据 1：两条传输路径结果一致（FFI 走通了）
SELECT (SELECT raw FROM via_jev) = (SELECT raw FROM via_ffi) AS ffi_path_identical;
-- 判据 2：jev_ask 经 FFI 也能正常展开 choice / confidence
SELECT jev_ok((SELECT raw FROM via_jev)) AS ok,
       jev_choice((SELECT raw FROM via_jev),'team') AS team,
       round(CAST(jev_p((SELECT raw FROM via_jev),'team','billing') AS DOUBLE),4) AS p_billing
FROM (SELECT 1 AS x) t;
