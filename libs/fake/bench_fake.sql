LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'fake',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/fake/fake.lua'')');

-- 基准：3 列表函数，10000 行，物化到表（避免 count(*) elision）
.timer on
CREATE TEMP TABLE fake_10k AS
SELECT row_idx, val FROM luajit_table('fake',
  list := '{"cols":{"a":"person.full","b":"int:1,1000","c":"address.country"},"rows":10000,"seed":1}');
SELECT count(*) AS rows, count(val) AS non_null FROM fake_10k;

-- 单列 50000 行（看上限）
CREATE TEMP TABLE fake_50k AS
SELECT row_idx, val FROM luajit_table('fake',
  list := '{"cols":{"a":"uuid"},"rows":50000,"seed":1}');
SELECT count(*) AS rows FROM fake_50k;

-- 标量 gen 向量化：10000 次调用（SQL 批量路径，JSON 串入参）
CREATE TEMP TABLE fake_scalar AS
SELECT luajit_s('fake', '{"op":"gen","kind":"person.full","seed":42}') AS v FROM range(10000);
SELECT count(*) AS calls, count(v) AS non_null FROM fake_scalar;
