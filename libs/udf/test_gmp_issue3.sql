-- issue #3 复现/修复验证（2026-10-29）
-- issue 原文宏 gmp_accstep 用 json_extract(...)::INT → Binder Error
-- （CASE 分支 INTEGER vs VARCHAR）。修复后的宏（json_extract_string）应全过。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'gmp',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/gmp.lua'')');

CREATE OR REPLACE MACRO gmp_accset(f) AS json_extract_string(luajit_s('gmp',{op:'accset',f:f}),'$.result');
CREATE OR REPLACE MACRO gmp_accmul(f) AS json_extract_string(luajit_s('gmp',{op:'accmul',f:f}),'$.result');
CREATE OR REPLACE MACRO gmp_accstep(f) AS json_extract_string(luajit_s('gmp',{op:'accstep',f:f}),'$.result');
CREATE OR REPLACE MACRO gmp_accdump(f,file) AS luajit_s('gmp',{op:'accdump',f:f,file:file});

-- 小尺度回显语义：1..6 末行 b 回显 '6'（accstep 只回显因子、不读 acc）
with recursive t as (
  select 0 a, '1' b
  union all
  select a+1, case when a=0 then gmp_accset((a+1)::VARCHAR) else gmp_accstep((a+1)::VARCHAR) end
  from t where a < 6)
select case when b = '6' then 'ECHO_PASS' else 'FAIL: '||b end AS i3_echo from t where a=6;

-- issue #3 原文递归（10000 步，accdump 落盘 /tmp/f.txt）；末行 b = accdump 的 JSON，
-- 其中 decimal_digits=35660 即 PASS 信号（accstep 回显语义见 i3_echo）
with recursive t as (
  select 0 a, '1' b
  union all
  select a + 1 , case when a = 0 then gmp_accset((a + 1):: VARCHAR )
                       when a + 1 = 10000 then gmp_accdump((a + 1):: VARCHAR , '/tmp/f.txt')
                       else gmp_accstep((a + 1):: VARCHAR ) end
  from t where a < 10000 )
select case when regexp_matches(b, '"decimal_digits":35660') then 'ISSUE3_RECURSION_PASS'
            else 'FAIL: ' || b end AS i3_recurse from t where a = 10000;

-- 落盘文件 = 10000!：35660 位（sha256 与 Python math.factorial(10000) 逐字节一致）
select case when length(content) = 35660 then 'FILE_DIGITS_PASS' else 'FAIL: '||length(content) end AS i3_file
from read_text('/tmp/f.txt');
