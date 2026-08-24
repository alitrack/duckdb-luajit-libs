-- tdx.lua 回归（duckdb-luajit）：日线/分钟线解析 + 错误可见化（ERR 行）
-- 先跑 make_tdx_fixture.py 生成 fixture_*.{day,lc5,bin}
-- ⚠️ 必须 set threads=1：duckdb-luajit 扩展的并行表函数在默认多线程下会因
--    共享 init_data 竞态返回 0 行（预存 bug，threads=1 稳定）。
set threads=1;
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'tdx',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/tdx.lua'')');

-- 1. 日线 .day：3 行，MAX close = 12.5（stored 1000/1250/1100 → /100）
SELECT 'day' AS case, COUNT(*) AS n,
       MAX(split_part(val,'|',5)::FLOAT) AS max_close,
       MIN(split_part(val,'|',1)) AS d0
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_sh000001.day');
-- day | 3 | 12.5 | 2026-08-19

-- 2. 5分钟线 .lc5：3 行，MAX close = 11.0（close f32 直存 10.5/11.0/10.8）
SELECT 'lc5' AS case, COUNT(*) AS n,
       MAX(split_part(val,'|',5)::FLOAT) AS max_close
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_sz000002.lc5');
-- lc5 | 3 | 11.0

-- 3. 多文件（.day + .lc5）：6 行
SELECT 'multi' AS case, COUNT(*) AS n
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_sh000001.day,/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_sz000002.lc5');
-- multi | 6

-- 4. 文件缺失（用户场景：路径打不开）→ 1 行 ERR，MAX=0.0 而非静默 NULL
SELECT 'missing' AS case, COUNT(*) AS n,
       MAX(split_part(val,'|',5)::FLOAT) AS max_close,
       ANY_VALUE(split_part(val,'|',1)) AS reason
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/does_not_exist.day');
-- missing | 1 | 0.0 | ERR: cannot open (path bad or file missing) @ ...

-- 5. 坏大小（16 字节非 32 倍数）→ ERR 行
SELECT 'badsz' AS case, COUNT(*) AS n, ANY_VALUE(split_part(val,'|',1)) AS reason
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_bad16.day');
-- badsz | 1 | ERR: bad size 16 bytes ... @ ...

-- 6. 错误扩展名（合法字节存成 .bin）→ ERR 行
SELECT 'ext' AS case, COUNT(*) AS n, ANY_VALUE(split_part(val,'|',1)) AS reason
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_sh000001.bin');
-- ext | 1 | ERR: unsupported extension ... @ ...

-- 7. 全部失败 → 首行汇总 "0/1 files parsed"
SELECT 'allfail' AS case, row_idx, split_part(val,'|',1) AS reason
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/does_not_exist.day')
ORDER BY row_idx;
-- row_idx=0 → ERR: 0/1 files parsed (see ERR rows below)|...
-- row_idx=1 → ERR: cannot open ... @ ...

-- 8. 过滤 ERR 行的推荐写法（避免 0 污染 MIN/AVG）
SELECT 'filtered' AS case, COUNT(*) AS n,
       MAX(split_part(val,'|',5)::FLOAT) AS max_close
FROM luajit_table('tdx', list := '/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/fixture_sh000001.day')
WHERE split_part(val,'|',1) NOT LIKE 'ERR%';
-- filtered | 3 | 12.5
