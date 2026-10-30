-- test_soundex.sql — soundex lib E2E（duckdb -unsigned -f 本文件）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'soundex',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/soundex.lua'')');

-- 标准美国 Soundex：Robert/Rabart → R163，difference=4
SELECT luajit_s('soundex', {v:'Robert', op:'soundex'}) AS sx_robert,
       luajit_s('soundex', {v:'Rabart', op:'soundex'}) AS sx_rabart,
       luajit_s('soundex', {a:'Robert', b:'Rabart', op:'difference'}) AS diff_same;
-- H/W/Y 不重置前码：Pfister → P236（f/s/t 中间被 h 隔开仍各计一次）
SELECT luajit_s('soundex', {v:'Pfister', op:'soundex'}) AS sx_pfister;
-- 元音分隔：Tymczak → T522
SELECT luajit_s('soundex', {v:'Tymczak', op:'soundex'}) AS sx_tymczak;
-- difference 不同
SELECT luajit_s('soundex', {a:'Robert', b:'Rupert', op:'difference'}) AS diff_rupert;

-- 断言（应为 0）
SELECT count(*) AS errors_must_be_0 FROM (
  SELECT CASE WHEN luajit_s('soundex',{v:'Robert',op:'soundex'})='R163' THEN 1 ELSE 0 END AS bad
  UNION ALL
  SELECT CASE WHEN luajit_s('soundex',{v:'Rabart',op:'soundex'})='R163' THEN 1 ELSE 0 END
  UNION ALL
  SELECT CASE WHEN luajit_s('soundex',{a:'Robert',b:'Rabart',op:'difference'})='4' THEN 1 ELSE 0 END
  UNION ALL
  SELECT CASE WHEN luajit_s('soundex',{v:'Pfister',op:'soundex'})='P236' THEN 1 ELSE 0 END
) t WHERE bad = 0;
