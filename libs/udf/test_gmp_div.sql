-- issue #4 回归：div/divmod 用 __gmpz_tdiv_qr（向零截断，C 语义）
-- 此前用 __gmpz_sdiv_qr（历史别名，标准 libgmp 不导出）→ 执行时 undefined symbol。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'gmp',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/gmp.lua'')');

-- issue #4 原句（大数正除）：应为整数商 + 余数
select json_extract_string(luajit_s('gmp', '{"op":"div","a":"123456789012345678901234567890","b":"98765432109876543243210"}'), '$.result') AS q,
       json_extract_string(luajit_s('gmp', '{"op":"div","a":"123456789012345678901234567890","b":"98765432109876543243210"}'), '$.remainder') AS r;

-- 向零截断符号矩阵（余数符号随被除数，同 C 的 / 和 %）
-- 1/-2 → q=0 r=1;  -1/-2 → q=0 r=-1;  7/-2 → q=-3 r=1;  -7/-2 → q=3 r=-1
select (json_extract_string(luajit_s('gmp','{"op":"div","a":"1","b":"-2"}'),'$.result')='0'
   and json_extract_string(luajit_s('gmp','{"op":"div","a":"1","b":"-2"}'),'$.remainder')='1')
   and (json_extract_string(luajit_s('gmp','{"op":"div","a":"-1","b":"-2"}'),'$.result')='0'
   and json_extract_string(luajit_s('gmp','{"op":"div","a":"-1","b":"-2"}'),'$.remainder')='-1')
   and (json_extract_string(luajit_s('gmp','{"op":"div","a":"7","b":"-2"}'),'$.result')='-3'
   and json_extract_string(luajit_s('gmp','{"op":"div","a":"7","b":"-2"}'),'$.remainder')='1')
   and (json_extract_string(luajit_s('gmp','{"op":"div","a":"-7","b":"-2"}'),'$.result')='3'
   and json_extract_string(luajit_s('gmp','{"op":"div","a":"-7","b":"-2"}'),'$.remainder')='-1')
   AS t_sign_matrix;

-- divmod 与 div 同语义；大数精确除（2^128 / 3）
select json_extract_string(luajit_s('gmp','{"op":"divmod","a":"340282366920938463463374607431768211456","b":"3"}'),'$.result') AS q128,
       json_extract_string(luajit_s('gmp','{"op":"divmod","a":"340282366920938463463374607431768211456","b":"3"}'),'$.remainder') AS r128;

-- 错误路径仍正常（除零）
select regexp_matches(luajit_s('gmp','{"op":"div","a":"5","b":"0"}'),'division by zero') AS t_divzero;

-- 原有算子不回归（mul/fac/mod/gcd）
select json_extract_string(luajit_s('gmp','{"op":"mul","a":"123456789","b":"987654321"}'),'$.result')='121932631112635269'
   and json_extract_string(luajit_s('gmp','{"op":"fac","a":"12"}'),'$.result')='479001600'
   and json_extract_string(luajit_s('gmp','{"op":"mod","a":"10","b":"3"}'),'$.result')='1'
   and json_extract_string(luajit_s('gmp','{"op":"gcd","a":"48","b":"36"}'),'$.result')='12'
   AS t_regression;
