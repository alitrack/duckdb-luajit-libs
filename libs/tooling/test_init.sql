-- init.lua 回归（duckdb-luajit）—— 仓库批量注册入口
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'init',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/tooling/init.lua'')');

-- 1. list：列出全部库名 + 总数（INDEX 当前 40 库）
SELECT json_extract(init({root:'/mnt/d/wsl2/duckdb-luajit-libs'}), '$.total') AS total,
       json_extract(init({root:'/mnt/d/wsl2/duckdb-luajit-libs'}), '$.names[0]') AS first,
       json_contains(init({root:'/mnt/d/wsl2/duckdb-luajit-libs'}), '"jsonpath"') AS has_jp;
-- 40 | "dicom" | true

-- 2. names：子集过滤 + 未知库 → missing
SELECT init({root:'/mnt/d/wsl2/duckdb-luajit-libs', op:'names', names:['jsonpath','cidr','nope_lib']}) AS n2;
-- {"names":["jsonpath","cidr"],"missing":{"nope_lib":"not in INDEX"}}

-- 3. all：全量注册（38 库，纯 Lua 全通；FFI 缺依赖的会进 skipped，不算失败）
SELECT init({root:'/mnt/d/wsl2/duckdb-luajit-libs', op:'all'}) AS a3;

-- 4. 注册生效：jsonpath / cidr / base64 直接 luajit_s 调用
SELECT luajit_s('jsonpath', {v:'{"a":{"b":[{"name":"x"},{"name":"y"}]}}', e:'$.a.b[*].name'}) AS j4,
       json_extract(luajit_s('cidr', {v:'192.168.1.5', op:'in_cidr', cidr:'192.168.1.0/24'}), '$.in') AS c4,
       luajit_s('base64', {v:'hello', op:'encode'}) AS b4;
-- ["x","y"] | true | aGVsbG8=

-- 5. some：只注册子集（fresh 场景下新装）
SELECT json_array_length(json_extract(init({root:'/mnt/d/wsl2/duckdb-luajit-libs', op:'some', names:['fuzzy','qr']}), '$.registered')) AS s5;
-- 2

-- 6. 错误处理
SELECT init({v:'x'})        AS e6a,   -- error: need root (表里无 root 字段)
       init({root:'/tmp'})  AS e6b,   -- error: cannot open .../INDEX
