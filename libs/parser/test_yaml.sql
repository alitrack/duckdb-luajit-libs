-- yaml.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_yaml.sql
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'yaml',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/yaml.lua'')');

-- 1. 嵌套映射 → JSON
SELECT luajit_s('yaml', {v: 'a: 1
b:
  c: 2', op: 'load'}) AS t1;  -- 期望 {"a":1,"b":{"c":2}}

-- 2. json_extract 穿透
SELECT json_extract(luajit_s('yaml', {v: 'server:
  host: 10.0.0.1
  port: 5432
  db:
    name: app
    replica: 3', op: 'load'}), '$.server.db.replica') AS t2;  -- 3

-- 3. 序列
SELECT luajit_s('yaml', {v: 'items:
  - 1
  - 2
  - 3', op: 'load'}) AS t3;  -- {"items":[1,2,3]}

-- 4. 行内流式集合
SELECT luajit_s('yaml', {v: 'nums: [1, 2, 3]
tags: {a: 1, b: 2}', op: 'load'}) AS t4;  -- {"nums":[1,2,3],"tags":{"a":1,"b":2}}

-- 5. 标量类型
SELECT luajit_s('yaml', {v: 'i: 42
f: 3.14
h: 0xff
b1: true
b2: false
z: null', op: 'load'}) AS t5;  -- {"i":42,"f":3.14,"h":255,"b1":true,"b2":false,"z":null}

-- 6. 引号标量 + 注释
SELECT luajit_s('yaml', {v: 'name: "hello world"  # 注释
squote: ''a b''', op: 'load'}) AS t6;  -- {"name":"hello world","squote":"a b"}

-- 7. 块标量 |
SELECT luajit_s('yaml', {v: 'script: |
  line1
  line2', op: 'load'}) AS t7;  -- {"script":"line1\nline2"}

-- 8. encode: JSON → YAML
SELECT luajit_s('yaml', {v: '{"a":1,"b":[1,2],"c":{"d":true}}', op: 'encode'}) AS t8;

-- 9. encode 再 load 往返
SELECT json_extract(luajit_s('yaml', {v: luajit_s('yaml', {v: '{"x":[1,2],"y":"hi"}', op: 'encode'}), op: 'load'}), '$.y') AS t9;  -- hi

-- 10. 空 / 标量
SELECT luajit_s('yaml', {v: '~', op: 'load'}) AS t10;  -- null
SELECT luajit_s('yaml', {v: '', op: 'load'}) AS t11;   -- null
