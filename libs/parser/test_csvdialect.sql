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
