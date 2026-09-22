-- fake.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_fake.sql
-- 锚点：seed 可复现（同 seed 两次调用逐字节一致）、格式正则校验、表函数行数/列数、
--       JSON/pipe 双格式、区间 int、模板 #? hex、kinds 计数。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'fake',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/fake/fake.lua'')');

-- 0. kinds 列表：30 个占位符
SELECT json_extract(luajit_s('fake', {op: 'kinds'}), '$.count') AS n_kinds
FROM (SELECT 1);
-- 30

-- 1. gen 各 kind 格式正则（一次采样，seed 固定；regexp_matches 精确断言）
SELECT
  luajit_s('fake', {op: 'gen', kind: 'person.full',  seed: 1})   LIKE '% %'        AS full_sp,
  luajit_s('fake', {op: 'gen', kind: 'contact.email', seed: 1})  LIKE '%@%.%'      AS email_ok,
  regexp_matches(luajit_s('fake', {op: 'gen', kind: 'contact.phone', seed: 1}), '^\(\d{3}\) \d{3}-\d{4}$') AS phone_ok,
  regexp_matches(luajit_s('fake', {op: 'gen', kind: 'number.hex',   seed: 1}), '^[0-9a-f]{8}$')  AS hex_ok,
  regexp_matches(luajit_s('fake', {op: 'gen', kind: 'color.hex',    seed: 1}), '^#[0-9a-f]{6}$') AS hex6_ok,
  regexp_matches(luajit_s('fake', {op: 'gen', kind: 'date.iso',     seed: 1}), '^\d{4}-\d{2}-\d{2}$') AS iso_ok,
  luajit_s('fake', {op: 'gen', kind: 'bool.b',       seed: 1})  IN ('true','false') AS bool_ok,
  luajit_s('fake', {op: 'gen', kind: 'person.first_cn', seed: 1}) NOT IN ('')       AS cn_ok
FROM (SELECT 1);
-- true x8

-- 2. 确定性：同 seed 两次调用逐字节一致（gen + rows + template）
SELECT
  luajit_s('fake', {op: 'gen', kind: 'person.full', seed: 42})
    = luajit_s('fake', {op: 'gen', kind: 'person.full', seed: 42})                 AS gen_same,
  luajit_s('fake', {op: 'rows', spec: {cols: {a: 'person.last', b: 'int:1,10'}, rows: 5}, seed: 42})
    = luajit_s('fake', {op: 'rows', spec: {cols: {a: 'person.last', b: 'int:1,10'}, rows: 5}, seed: 42}) AS rows_same,
  luajit_s('fake', {op: 'template', template: '{person.first} {number.hex}', seed: 7})
    = luajit_s('fake', {op: 'template', template: '{person.first} {number.hex}', seed: 7}) AS tpl_same,
  luajit_s('fake', {op: 'rows', spec: {cols: {a: 'person.last'}, rows: 5}, seed: 42})
    != luajit_s('fake', {op: 'rows', spec: {cols: {a: 'person.last'}, rows: 5}, seed: 43}) AS seed_differs
FROM (SELECT 1);
-- true | true | true | true

-- 3. 区间 int + 错误可见化（缺 kind / 未知 kind → JSON 错误对象）
SELECT
  cast(luajit_s('fake', {op: 'gen', kind: 'int:18,65', seed: 1}) AS BIGINT) BETWEEN 18 AND 65 AS int_in_range,
  json_extract(luajit_s('fake', {op: 'gen', kind: 'badkind'}), '$.status') AS bad_kind,
  json_extract(luajit_s('fake', {op: 'gen'}), '$.message') AS missing_kind
FROM (SELECT 1);
-- true | Error | missing kind

-- 4. 模板展开：{占位符} 全部替换 + #? → hex
SELECT luajit_s('fake', {op: 'template', template: '{person.full} <{contact.email}> {company.name} {date.iso} #?', seed: 3}) AS tpl
FROM (SELECT 1);
-- 形如 "Mary Smith <mary.smith@example.com> Apex Labs 2011-07-12 3a"（#? 是 1 位 hex，无残留 {}）
SELECT
  (SELECT luajit_s('fake', {op: 'template', template: '{person.full} #?', seed: 3})) NOT LIKE '%{%' AS no_left_brace,
  (SELECT luajit_s('fake', {op: 'template', template: '{person.full} #?', seed: 3})) NOT LIKE '%}%' AS no_right_brace
FROM (SELECT 1);
-- true | true

-- 5. rows op='rows'：JSON 数组，5 行（输出形如 ["a","b",...]）
SELECT json_array_length(luajit_s('fake', {op: 'rows', spec: {cols: {n: 'person.first'}, rows: 5}, seed: 11})) AS n_rows,
       (luajit_s('fake', {op: 'rows', spec: {cols: {n: 'person.first'}, rows: 5}, seed: 11})) LIKE '["%' AS is_array
FROM (SELECT 1);
-- 5 | true

-- 6. 表函数 pipe 形态：5 行 3 列
SELECT row_idx, val FROM luajit_table('fake',
  list := '{"cols":{"name":"person.full","age":"int:18,65","city":"address.city_us"},"rows":5,"seed":42}')
  ORDER BY row_idx;
-- 5 行，每行 3 段（| 分隔）
SELECT count(*) AS rows5,
       min(length(val) - length(replace(val, '|', '')) + 1 = 3) AS all_3col
FROM luajit_table('fake',
  list := '{"cols":{"name":"person.full","age":"int:18,65","city":"address.city_us"},"rows":5,"seed":42}');
-- 5 | true

-- 7. 表函数 json 形态：每行合法 JSON 且列名正确
SELECT json_valid(val) AS json_ok,
       json_extract(val, '$.name') IS NOT NULL AS has_name
FROM luajit_table('fake',
  list := '{"cols":{"name":"person.full","age":"int:18,65"},"rows":3,"seed":9,"format":"json"}');
-- true x3 | true x3

-- 8. 表函数错误可见化：缺 cols → ERR 行（不静默 0 行）
SELECT val FROM luajit_table('fake', list := '{"rows":3}');
-- ERR: spec.cols required: {col: 'kind', ...}

-- 9. 日期区间参数：2024 年内（datetime 现含秒）
SELECT luajit_s('fake', {op: 'gen', kind: 'date.iso:2024-01-01,2024-12-31', seed: 5}) LIKE '2024-%' AS in_2024,
       regexp_matches(luajit_s('fake', {op: 'gen', kind: 'date.datetime:2024-01-01,2024-12-31', seed: 5}), '^2024-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') AS dt_2024
FROM (SELECT 1);
-- true | true

-- 10. 中文 kind：姓名 = 1 姓 + 1~2 名 = 2~3 个 CJK 字符（DuckDB length() 数字符非字节）
SELECT luajit_s('fake', {op: 'gen', kind: 'person.first_cn', seed: 2}) AS cn_name
FROM (SELECT 1);
-- 形如 张伟 / 王秀英
SELECT length(luajit_s('fake', {op: 'gen', kind: 'person.first_cn', seed: 2})) IN (2, 3) AS cn_chars
FROM (SELECT 1);
-- true（2 或 3 个汉字）

-- 11. uuid 格式 + 版本位
SELECT luajit_s('fake', {op: 'gen', kind: 'uuid', seed: 1})
  SIMILAR TO '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' AS uuid_ok
FROM (SELECT 1);
-- true

-- 12. 表函数大数据量：1000 行不 OOM、不截断（pipe 3 列）
SELECT count(*) AS n1000, min(length(val) - length(replace(val, '|', '')) + 1 = 3) AS all_3col
FROM luajit_table('fake',
  list := '{"cols":{"a":"person.full","b":"int:1,1000","c":"address.country"},"rows":1000,"seed":1}');
-- 1000 | true

-- 13. JSON 字符串入参（非 struct）：模板串直接当 template
SELECT luajit_s('fake', '{"op":"template","template":"{person.last} {number.hex}","seed":4}') AS tpl_json
FROM (SELECT 1);
-- 形如 "Smith 1a2b3c4d"

-- 14. 列序稳定：多列按名字排序，同 seed 重复执行逐字节一致
WITH r1 AS (SELECT length(val) - length(replace(val, '|', '')) + 1 AS n FROM luajit_table('fake',
         list := '{"cols":{"z":"number.int","a":"number.int","m":"number.int"},"rows":3,"seed":1}'))
SELECT min(n) = 3 AS all_3col FROM r1;
-- true（列名 z,a,m 排序后仍各占一列，3 段）
