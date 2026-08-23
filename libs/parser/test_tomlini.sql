-- tomlini.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_tomlini.sql
-- 注意：配置文本用**真实换行**（DuckDB 单引号不处理 \n 转义）；
--       struct 字面量用 `key: value`（非 :=），且字符串首字符不能是换行。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'tomlini',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/tomlini.lua'')');

-- 1. TOML 基础（分组 + 标量类型 + 注释）
SELECT luajit_s('tomlini', {v: '# comment
title = "x"  # trailing
[db]
host = "localhost"
port = 5432
debug = true', op: 'toml'}) AS t1;
-- {"title":"x","db":{"host":"localhost","port":5432,"debug":true}}

-- 2. TOML 嵌套分组 [a.b] + 行内表 + 行内数组
SELECT luajit_s('tomlini', {v: '[a.b]
x = 1
opt = { k = 2, s = "v" }
list = [1, 2, 3]', op: 'toml'}) AS t2;
-- {"a":{"b":{"x":1,"opt":{"k":2,"s":"v"},"list":[1,2,3]}}}

-- 3. TOML 数值/布尔/单引号字符串/多行
SELECT luajit_s('tomlini', {v: 'pi = 3.14
flag = false
name = ''lit''
text = """abc"""', op: 'toml'}) AS t3;
-- {"pi":3.14,"flag":false,"name":"lit","text":"abc"}

-- 4. INI（分组 + 类型嗅探 + ; 注释）
SELECT luajit_s('tomlini', {v: '; ini file
[sec]
k = 3
s = hello
flag = yes', op: 'ini'}) AS t4;
-- {"sec":{"k":3,"s":"hello","flag":true}}

-- 5. INI 无分组（归根）+ 空文件
SELECT luajit_s('tomlini', {v: 'root = 1', op: 'ini'}) AS t5;   -- {"root":1}
SELECT luajit_s('tomlini', {v: '', op: 'ini'}) AS t6;           -- {}

-- 6. 配 json_extract 抽取
SELECT json_extract(luajit_s('tomlini', {v: '[db]
host = "h"
port = 5432', op: 'toml'}), '$.db.port') AS drill;  -- 5432
