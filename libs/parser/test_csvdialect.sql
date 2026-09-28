-- csvdialect.lua 回归（duckdb-luajit）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'cd',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/csvdialect.lua'')');

-- 1. 逗号 + 表头（detect）
SELECT json_extract(cd({v:'name,age,city
Alice,30,Berlin
Bob,25,Paris', op:'detect'}), '$.delimiter')  AS d1,   -- ","
       json_extract(cd({v:'name,age,city
Alice,30,Berlin
Bob,25,Paris', op:'detect'}), '$.has_header') AS h1,   -- true
       json_extract(cd({v:'name,age,city
Alice,30,Berlin
Bob,25,Paris', op:'detect'}), '$.ncols')       AS n1;   -- 3

-- 2. 分号（欧洲格式）
SELECT json_extract(cd({v:'name;age;city
Alice;30;Berlin
Bob;25;Paris', op:'detect'}), '$.delimiter')  AS d2,   -- ";"
       json_extract(cd({v:'name;age;city
Alice;30;Berlin
Bob;25;Paris', op:'detect'}), '$.ncols')      AS n2;   -- 3

-- 3. 制表符（chr(9)/chr(10) 造真实 tab/换行，因 DuckDB 单引号串不处理 \t）
SELECT json_extract(cd({v: 'a' || chr(9) || 'b' || chr(9) || 'c' || chr(10)
     || '1' || chr(9) || '2' || chr(9) || '3' || chr(10)
     || '4' || chr(9) || '5' || chr(9) || '6', op:'detect'}), '$.delimiter') AS d3;   -- "\t"

-- 4. 引号内含逗号（解析后字段矩阵）
SELECT cd({v:'a,b
"1,2",3
"say ""hi""",x', op:'parse'}) AS p4;   -- [["a","b"],["1,2","3"],["say hi","x"]]

-- 5. parse 普通表
SELECT cd({v:'x,y
1,2
3,4', op:'parse'}) AS p5;   -- [["x","y"],["1","2"],["3","4"]]

-- 6. rows / ncols op
SELECT cd({v:'a,b,c
1,2,3
4,5,6', op:'rows'})  AS r6,   -- 3
       cd({v:'a,b,c
1,2,3
4,5,6', op:'ncols'}) AS c6;   -- "rect"

-- 7. 无表头（首行也含数字）
SELECT json_extract(cd({v:'1,2,3
4,5,6', op:'detect'}), '$.has_header') AS h7;   -- false

-- 8. 空 / 错误
SELECT cd({v:'', op:'detect'})  AS e1,   -- error: missing v or file
       cd({op:'detect'})          AS e2;   -- error: missing v or file

-- 9. whitespace-delimited（duckdb/duckdb#18413：NOAA Keeling 曲线式，定长分隔符全 miss → 自动回退）
SELECT json_extract(cd({v:
'Year  Month  Decimal   Average
1958  1.0  0.042   315.71
1958  2.0  0.083   317.02
1958  3.0  0.125   317.88', op:'detect'}), '$.delimiter')  AS d9,  -- "whitespace"
       json_extract(cd({v:
'Year  Month  Decimal   Average
1958  1.0  0.042   315.71
1958  2.0  0.083   317.02
1958  3.0  0.125   317.88', op:'detect'}), '$.ncols')      AS n9,  -- 4
       json_extract(cd({v:
'Year  Month  Decimal   Average
1958  1.0  0.042   315.71
1958  2.0  0.083   317.02
1958  3.0  0.125   317.88', op:'detect'}), '$.has_header') AS h9;  -- true

-- 10. whitespace parse（含 tab 混合空白 + 显式 delimit='whitespace'）
SELECT cd({v: 'Year  Month  Average
1958  1.0  315.71
1958  2.0  317.02', op:'parse'}) AS p10;   -- [["Year","Month","Average"],["1958","1.0","315.71"],["1958","2.0","317.02"]]
SELECT cd({v: 'a b
1 2', delimit:'whitespace', op:'parse'}) AS p11;   -- [["a","b"],["1","2"]]

-- 11. whitespace rows / ncols
SELECT cd({v: 'a  b  c
1  2  3
4  5  6', op:'rows'})  AS r11,   -- 3
       cd({v: 'a  b  c
1  2  3
4  5  6', op:'ncols'}) AS c11;   -- "rect"

-- 12. 非空白表格不受影响（单列文本不触发 whitespace）
SELECT json_extract(cd({v: 'hello world
foo bar baz', op:'detect'}), '$.delimiter') AS d12;   -- "unknown"（列数不一致）

-- 13. # 注释头 + whitespace 数据（NOAA 原始文件式：注释行破坏列一致性 → 自动剥 # 后回退 whitespace）
SELECT json_extract(cd({v:
'# ---- NOAA GML DATA
# Monthly CO2, Mauna Loa
Year  Month  Average
1958  1.0  315.71
1958  2.0  317.02', op:'detect'}), '$.delimiter')  AS d13,  -- "whitespace"
       json_extract(cd({v:
'# ---- NOAA GML DATA
# Monthly CO2, Mauna Loa
Year  Month  Average
1958  1.0  315.71
1958  2.0  317.02', op:'detect'}), '$.comment')    AS c13,  -- "#"
       cd({v:
'# ---- NOAA GML DATA
# Monthly CO2, Mauna Loa
Year  Month  Average
1958  1.0  315.71
1958  2.0  317.02', op:'rows'})                    AS r13;  -- 3（注释行不计）

-- 14. # 注释头 + 逗号 CSV（自动剥 #）
SELECT cd({v:
'# comment line
name,age
Alice,30
Bob,25', op:'parse'}) AS p14;   -- [["name","age"],["Alice","30"],["Bob","25"]]

-- 15. 显式 comment 参数（// 注释，逗号 CSV）
SELECT cd({v:
'// comment
x,y
1,2', comment:'//', op:'parse'}) AS p15;   -- [["x","y"],["1","2"]]

-- 16. 数据里含 # 行但定长探测已成立 → 不自动剥（# 视为数据）
SELECT json_extract(cd({v: 'a,b
#1,2
3,4', op:'detect'}), '$.comment') AS c16;   -- null（无 comment 字段）

-- 17. 表函数形态：luajit_table（row_idx|val，val=管道拼接行；表函数源=path/URL，inline 文本走标量形态）
SELECT * FROM luajit_table('cd', list := '/mnt/d/wsl2/tmp/csvd_ws_fixture.txt') LIMIT 2;   -- 1|a|b|c  2|1|2|3
-- 18. 表函数 + 本地文件（NOAA 式注释自动剥）
SELECT COUNT(*) AS n18 FROM luajit_table('cd', list := '/mnt/d/wsl2/tmp/co2_mm_mlo.txt');   -- 822
-- 19. 表函数 + JSON spec（skip_header=true 去掉首行）
SELECT COUNT(*) AS n19 FROM luajit_table('cd', list := '{"file": "/mnt/d/wsl2/tmp/co2_mm_mlo.txt", "skip_header": true}');   -- 821（NOAA 文件无表头行，822-1）
-- 20. 表函数错误可见（ERR 行而非静默 0 行）
SELECT val FROM luajit_table('cd', list := '{"file": "/nonexistent/path"}');   -- ERR: ...

-- 21. read_csv_dialect 式一行封装（table macro，真名可用；v2.0 无内置 read_csv_dialect，
--     v1.x 有内置同名函数，本宏会遮蔽它——按需在别名上创建）
-- SET table_function_identifier_conversion = 'ENABLE_IMPLICIT_STRING';  -- 老版传参行为，免 deprecation 警告
CREATE OR REPLACE MACRO read_csv_dialect(src) AS TABLE
  SELECT * FROM luajit_table('cd', list := src);
SELECT * FROM read_csv_dialect('/mnt/d/wsl2/tmp/csvd_ws_fixture.txt') LIMIT 2;   -- 1|a|b|c  2|1|2|3
