-- jsonpath.lua 回归（duckdb-luajit）
-- 注：DuckDB 单引号串不处理 \" 转义 → JSON 内的双引号直接写 "（不加反斜杠）。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jp',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/jsonpath.lua'')');

-- 1. 成员 + 数组索引（0-based / 负下标）
SELECT jp({v:'{"a":{"b":[10,20,30]}}', e:'$.a.b[1]'})   AS c1,  -- [20]
       jp({v:'{"a":{"b":[10,20,30]}}', e:'$.a.b[-1]'})  AS c2,  -- [30]
       jp({v:'{"a":{"b":[10,20,30]}}', e:'$.a.b'})      AS c3;  -- [[10,20,30]]

-- 2. 通配 *
SELECT jp({v:'{"a":{"b":[10,20,30]}}', e:'$.a.b[*]'})   AS c4,  -- [10,20,30]
       jp({v:'{"x":1,"y":2}', e:'$.*'})                  AS c5;  -- [1,2]

-- 3. 递归下降 $..name（文档顺序）
SELECT jp({v:'{"a":{"b":{"name":"n1"}},"name":"top"}', e:'$..name'}) AS c6,  -- ["n1","top"]
       jp({v:'{"a":{"b":{"cat":"ref"}},"cat":"novel"}', e:'$..cat'})  AS c7;  -- ["ref","novel"]

-- 4. 过滤谓词 [?(@.price>10)] / [?(@.price<10)]
SELECT jp({v:'{"book":[{"title":"A","price":8.95},{"title":"B","price":12.99}]}', e:'$.book[?(@.price>10)]'}) AS c8,  -- [{"title":"B","price":12.99}]
       jp({v:'{"book":[{"title":"A","price":8.95},{"title":"B","price":12.99}]}', e:'$.book[?(@.price<10)]'}) AS c9;  -- [{"title":"A","price":8.95}]

-- 5. 过滤 = / != / and
SELECT jp({v:'{"p":[{"cat":"ref","n":1},{"cat":"novel","n":2},{"cat":"ref","n":3}]}', e:'$.p[?(@.cat="ref")]'})        AS c10,  -- 2 个
       jp({v:'{"p":[{"cat":"ref","n":1},{"cat":"novel","n":2},{"cat":"ref","n":3}]}', e:'$.p[?(@.cat="ref" and @.n>2)]'}) AS c11, -- 1 个（n=3）
       jp({v:'{"p":[{"cat":"ref","n":1},{"cat":"novel","n":2}]}', e:'$.p[?(@.cat!="ref")]'})  AS c12;  -- 1 个（novel）

-- 6. 过滤 存在性 / 根 $
SELECT jp({v:'{"p":[{"a":1,"b":2},{"b":3}]}', e:'$.p[?(@.a)]'})   AS c13,  -- 1 个（有 a）
       jp({v:'{"x":42}', e:'$'})                                  AS c14;  -- [{"x":42}]

-- 7. op 变体：count / exists / first
SELECT jp({v:'{"p":[{"n":1},{"n":2},{"n":3}]}', e:'$.p[*]', op:'count'})   AS c15,  -- 3
       jp({v:'{"a":{"b":1}}', e:'$.a.c', op:'exists'})                  AS c16,  -- false
       jp({v:'{"book":[{"price":1},{"price":2}]}', e:'$.book[?(@.price>1)]', op:'first'}) AS c17;  -- {"price":2}

-- 8. 错误处理（非 $ 开头 / 坏 json / 空）
SELECT jp({v:'{"x":1}', e:'a.b'})                    AS e1,  -- error: must start with $
       jp({v:'{bad json', e:'$'})                     AS e2,  -- error: invalid json doc
       jp({v:'', e:'$'})                              AS e3;  -- error: missing v
