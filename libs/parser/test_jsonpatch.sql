-- jsonpatch.lua 回归（duckdb-luajit）—— RFC 6902 / 6901 + diff
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jp',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/jsonpatch.lua'')');

-- 1. apply：add + test 通过
SELECT json_extract(luajit_s('jp', {op:'apply',
  doc:'{"a":1}',
  patch:'[{"op":"add","path":"/b","value":2},{"op":"test","path":"/a","value":1}]'}), '$.b') AS add_b,
  json_extract(luajit_s('jp', {op:'apply',
  doc:'[1,2,4]',
  patch:'[{"op":"add","path":"/1","value":3}]'}), '$[1]') AS arr_mid
FROM (SELECT 1);
-- 2 | 3

-- 2. apply：replace + remove + move + copy
SELECT json_extract(luajit_s('jp', {op:'apply',
  doc:'{"a":1,"b":2,"c":3}',
  patch:'[{"op":"replace","path":"/a","value":9},{"op":"remove","path":"/b"}]'}), '$.a') AS rep,
  json_extract(luajit_s('jp', {op:'apply',
  doc:'{"a":1,"b":2}',
  patch:'[{"op":"move","from":"/a","to":"/c"}]'}), '$.c') AS mv,
  json_extract(luajit_s('jp', {op:'apply',
  doc:'{"a":1,"b":2}',
  patch:'[{"op":"copy","from":"/a","to":"/d"}]'}), '$.d') AS cp
FROM (SELECT 1);
-- 9 | 1 | 1

-- 3. get（JSON Pointer，含转义 与 数组下标）
SELECT json_extract(luajit_s('jp', {op:'get', doc:'[{"x":7},"y"]', path:'/0/x'}), '$') AS g1,
       json_extract(luajit_s('jp', {op:'get', doc:'{"a/b":{"c~d":5}}', path:'/a~1b/c~0d'}), '$') AS g2
FROM (SELECT 1);
-- 7 | 5

-- 4. test（相等/不等）
SELECT luajit_s('jp', {op:'test', doc:'{"a":[1,2]}', path:'/a', value:'[1,2]'})      AS t1,
       luajit_s('jp', {op:'test', doc:'{"a":[1,2]}', path:'/a', value:'[1,3]'})      AS t2,
       luajit_s('jp', {op:'test', doc:'{"a":null}', path:'/a', value:'null'})        AS t3
FROM (SELECT 1);
-- true | false | true

-- 5. set（父级须存在 → 成功；父级缺失 → error JSON）
SELECT json_extract(luajit_s('jp', {op:'set', doc:'{"a":{"k":0}}', path:'/a/k', value:'"v"'}), '$.a.k') AS setok,
       luajit_s('jp', {op:'set', doc:'{"a":1}', path:'/b/nested', value:'{"k":"v"}'}) LIKE '%error%' AS setbad
FROM (SELECT 1);
-- v | true

-- 6. diff（a→b 的 RFC 6902）：对结果再 apply 回 a 应得到 b（闭环）
WITH d AS (
  SELECT luajit_s('jp', {op:'diff', a:'{"a":1,"b":[1,2],"c":"x"}', b:'{"a":9,"b":[1,3],"d":true}'}) AS patch
),
rt AS (
  SELECT luajit_s('jp', {op:'apply', doc:'{"a":1,"b":[1,2],"c":"x"}', patch:(SELECT patch FROM d)}) AS applied
)
SELECT json_extract(applied,'$.a') AS a9,
       json_extract(applied,'$.b[1]') AS b1,
       json_extract(applied,'$.d') AS d,
       (json_extract(applied,'$.c') IS NULL) AS c_gone
FROM rt;
-- 9 | 3 | true | true

-- 7. apply 失败（test 不通过）→ error JSON
SELECT luajit_s('jp', {op:'apply', doc:'{"a":1}', patch:'[{"op":"test","path":"/a","value":2}]'}) LIKE '%error%' AS failtest
FROM (SELECT 1);
-- true
