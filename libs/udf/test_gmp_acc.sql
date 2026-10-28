-- gmp 有状态累乘 acc* + bits op 测试（2026-10-28）
--
-- 状态作用域（实测）：
--   · acc* 状态存于"执行该查询的 worker 线程"的 Lua state，只在**单条语句**内连续。
--   · 递归 CTE 引擎会**预求值**下一步：读回 acc（acclen/accget）会滞后一步，
--     但 acc 本身收敛正确（accdump 末值与 Python 逐字节一致）。
--   因此：中间步不读 acc（accstep 只回显因子 f），权威结果取 accdump 末值。
-- 可靠形态：(A) 单语句内顺序共享；(B) 一条自包含递归 CTE（推荐）。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'gmp',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/gmp.lua'')');

CREATE OR REPLACE MACRO gmp_accset(f)  AS json_extract_string(luajit_s('gmp', {op: 'accset', f: f}), '$.result');
CREATE OR REPLACE MACRO gmp_accmul(f)  AS json_extract_string(luajit_s('gmp', {op: 'accmul', f: f}), '$.result');
CREATE OR REPLACE MACRO gmp_accstep(f) AS json_extract_string(luajit_s('gmp', {op: 'accstep', f: f}), '$.result');
CREATE OR REPLACE MACRO gmp_accdump(f, file) AS luajit_s('gmp', {op: 'accdump', f: f, file: file});
CREATE OR REPLACE MACRO gmp_mul(a, b)  AS json_extract_string(luajit_s('gmp', {op: 'mul', a: a::VARCHAR, b: b::VARCHAR}), '$.result');
CREATE OR REPLACE MACRO gmp_fac(a)     AS json_extract_string(luajit_s('gmp', {op: 'fac', a: a::VARCHAR}), '$.result');

-- ===== 无状态 op =====
-- T1: bits（2026-10-28 补实现；此前返回 unknown op）。键序不定（Lua pairs），分开匹配
select regexp_matches(luajit_s('gmp', '{"op":"bits","a":"1000000"}'), '"bits":20')
    AND regexp_matches(luajit_s('gmp', '{"op":"bits","a":"1000000"}'), '"decimal_digits":7')
    AND regexp_matches(luajit_s('gmp', '{"op":"bits","a":"128"}'), '"bits":8')
    AND regexp_matches(luajit_s('gmp', '{"op":"bits","a":"128"}'), '"decimal_digits":3') AS t1_pass;

-- T2: 原有算子回归
select gmp_mul('123456789','987654321') = '121932631112635269'  AS t2_mul;          -- 18 位
select length(gmp_fac('10000')) = 35660                          AS t2_fac;          -- product tree

-- ===== 形态 A：单条语句内 accset→accmul 顺序共享（同 worker，无预求值）=====
select (gmp_accset(x) = '6' AND gmp_accmul(y) = '42') AS t3_pass from (values ('6','7')) t(x,y);

-- ===== 形态 B：自包含递归 CTE（推荐）=====
-- T4: accstep 只回显因子（不读 acc，避开预求值滞后）：1..6 末行回显 '6'
with recursive t as (
  select 0 a, '1' b
  union all
  select a+1, case when a=0 then gmp_accset((a+1)::VARCHAR) else gmp_accstep((a+1)::VARCHAR) end
  from t where a < 6)
select case when b = '6' then 'PASS' else 'FAIL: '||b end AS t4_echo from t where a=6;

-- T5: 1..12 累乘 = 479001600（accmul 每步返回大串走列，手工锚点）
with recursive t as (
  select 0 a, '1' b
  union all
  select a+1, case when a=0 then gmp_accset((a+1)::VARCHAR) else gmp_accmul((a+1)::VARCHAR) end
  from t where a < 12)
select case when b = '479001600' then 'PASS' else 'FAIL: '||b end AS t5_12fac from t where a=12;

-- T6: 10000! 位数 = 35660（accmul 走列）
with recursive t as (
  select 0 a, '1' b
  union all
  select a+1, case when a=0 then gmp_accset((a+1)::VARCHAR) else gmp_accmul((a+1)::VARCHAR) end
  from t where a < 10000)
select case when length(b) = 35660 then 'PASS' else 'FAIL: '||length(b) end AS t6_digits from t where a=10000;

-- T7: 快速路径 10000!：中间 accstep（只回显）+ 末步 accdump 落文件；
--     decimal_digits 应 = 35660（accdump 在同一调用内读 acc，是末步、无预求值滞后）
with recursive t as (
  select 0 a, '1' b
  union all
  select a+1, case when a=0        then gmp_accset((a+1)::VARCHAR)
                   when a+1=10000  then gmp_accdump((a+1)::VARCHAR, '/tmp/gmp_f10000.txt')
                   else gmp_accstep((a+1)::VARCHAR) end
  from t where a < 10000)
select case when regexp_matches(b, '"decimal_digits":35660') then 'PASS' else 'FAIL: '||b end AS t7_fastpath
from t where a=10000;

-- ===== 错误路径（不得崩进程）=====
select regexp_matches(luajit_s('gmp','{"op":"accset","f":"abc"}'),   'Error')  AS t8_e1;
select regexp_matches(luajit_s('gmp','{"op":"accmul","f":"12.5"}'),  'Error')  AS t8_e2;
select regexp_matches(luajit_s('gmp','{"op":"accstep","f":"xy"}'),   'Error')  AS t8_e3;
select regexp_matches(luajit_s('gmp','{"op":"accdump"}'),            'p.file') AS t8_e4;
select regexp_matches(luajit_s('gmp','{"op":"accdump","f":"3","file":""}'), 'p.file') AS t8_e5;
select regexp_matches(luajit_s('gmp','{"op":"accdump","f":"3","file":"/nonexistent_dir/x.txt"}'), 'cannot open') AS t8_e6;
select regexp_matches(luajit_s('gmp','{"op":"nope"}'),               'unknown op') AS t8_e7;
select regexp_matches(luajit_s('gmp','{"op":"bits","a":"zz"}'),      'Error')  AS t8_e8;
