-- tail_file.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_tail_file.sql
-- 用内联内容（多行 SQL 字符串，真实换行）演示增量 tail：
--   C1 = "line1\nline2\nline3\nline4\nline5"      （末尾无 \n，line5 是未完结行）
--   C2 = "line1\n...\nline6\n"                     （C1 基础上追加 line5 完结 + line6）
-- 注意：offset 是 DuckDB 关键字，struct 内必须写成 'offset': ；行值路径是 $.lines[n]。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'tail_file',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/tail_file.lua'')');

-- 1. 首次全读（offset=0）：line5 无 \n → 暂不吐；吐 line1..line4，offset=24
SELECT json_extract(r, '$.offset') AS off,
       json_extract(r, '$.count')  AS cnt,
       json_extract(r, '$.lines[3]') AS last
FROM (SELECT luajit_s('tail_file', {v: 'line1
line2
line3
line4
line5', 'offset': 0, max: 100}) AS r);
-- 24 | 4 | line4

-- 2. 增量：内容增长到 C2（line5 完结 + line6），从 offset=24 续读 → line5,line6，offset=36
SELECT json_extract(r, '$.offset') AS off,
       json_extract(r, '$.count')  AS cnt,
       json_extract(r, '$.lines[0]') AS first,
       json_extract(r, '$.lines[1]') AS second
FROM (SELECT luajit_s('tail_file', {v: 'line1
line2
line3
line4
line5
line6
', 'offset': 24, max: 100}) AS r);
-- 36 | 2 | line5 | line6

-- 3. max 限制：offset=0 max=2 → 只吐 line1,line2，offset=12
SELECT json_extract(r, '$.offset') AS off,
       json_extract(r, '$.count')  AS cnt,
       json_extract(r, '$.lines[1]') AS last
FROM (SELECT luajit_s('tail_file', {v: 'line1
line2
line3
line4
line5', 'offset': 0, max: 2}) AS r);
-- 12 | 2 | line2

-- 4. 截断/重建：offset=100 超出长度 → 重置 0 重读 → line1..line4，offset=24
SELECT json_extract(r, '$.offset') AS off,
       json_extract(r, '$.count')  AS cnt
FROM (SELECT luajit_s('tail_file', {v: 'line1
line2
line3
line4
line5', 'offset': 100, max: 100}) AS r);
-- 24 | 4

-- 5. 无新增（offset 已到末尾且无新完整行）→ count=0，offset 不变
SELECT json_extract(r, '$.count')  AS cnt,
       json_extract(r, '$.offset') AS off
FROM (SELECT luajit_s('tail_file', {v: 'line1
line2
line3
line4
line5', 'offset': 24, max: 100}) AS r);
-- 0 | 24
