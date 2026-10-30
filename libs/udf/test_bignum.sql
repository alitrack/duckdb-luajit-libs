-- test_bignum.sql — bignum lib E2E（duckdb -unsigned < 本文件）
-- 验证记录 2026-10-22：duckdb v2.0.0-alpha39998 CLI + luajit 扩展 v1.5.5 ABI
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

-- ① quick_compile 注册（本地 dofile；install 链路单独由 test_*_install.sql 覆盖）
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'bignum',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/bignum.lua'')');

-- ② 核心对照：官方 BIGNUM vs bignum lib（同一输入）
--    官方：DOUBLE 丢尾数 1.2193263111263526e+17；lib：精确字符串
SELECT '官方BIGNUM' AS who, CAST(123456789 AS BIGNUM) * CAST(987654321 AS BIGNUM) AS result
UNION ALL
SELECT 'bignum lib', json_extract(luajit_s('bignum', {'op':'mul','a':'123456789','b':'987654321'}), '$.r');

-- ③ 30 位 × 30 位（官方直接 Overflow 的用例）
SELECT luajit_s('bignum', {'op':'mul',
  'a':'123456789012345678901234567890',
  'b':'987654321098765432109876543210'}) AS mul_30x30;

-- ④ 其余 op 冒烟
SELECT luajit_s('bignum', {'op':'pow','a':'2','n':'256'}) AS pow_2_256;
SELECT luajit_s('bignum', {'op':'fact','n':'100'}) AS fact_100;
SELECT luajit_s('bignum', {'op':'div','a':'7','b':'3'}) AS div_7_3;
SELECT luajit_s('bignum', '{"op":"add","a":"-99999999999999999999","b":"1"}') AS add_neg_json;

-- ⑤ 断言（应为 0 的错误行）
SELECT count(*) FILTER (WHERE r IS NULL OR json_extract(r,'$.status') = 'Error') AS errors_must_be_0
FROM (
  SELECT luajit_s('bignum', {'op':'mul','a':'99999999999999999999','b':'99999999999999999999'}) AS r
  UNION ALL SELECT luajit_s('bignum', {'op':'sub','a':'-5','b':'-10'})
  UNION ALL SELECT luajit_s('bignum', {'op':'cmp','a':'-3','b':'2'})
) t;

-- ⑥ 批量场景：表列里的订单号/卡号级大整数连乘也可用
SELECT upper(substr(json_extract(r,'$.r'),2,20)) AS batch_mul_prefix, length(json_extract(r,'$.r')) AS digits
FROM (SELECT luajit_s('bignum', {'op':'mul','a':'170141183460469231731687303715884105727','b':'340282366920938463463374607431768211455'}) AS r);

-- ⑦ 错误路径：除零 / 非法输入（应返回 Error JSON，不静默 NULL）
SELECT luajit_s('bignum', {'op':'div','a':'1','b':'0'}) AS div_by_zero;
SELECT luajit_s('bignum', {'op':'mul','a':'12.5','b':'3'}) AS bad_input;
