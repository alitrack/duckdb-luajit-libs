-- log.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_log.sql
-- luajit_table('log') 输出两列：row_idx | val；val = line_no|ts|level|msg|kvs(JSON)
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'log',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/log.lua'')');

-- 混合格式解析（5 行，自动识别）
CREATE OR REPLACE TEMP TABLE logt AS
SELECT * FROM luajit_table('log', list :=
'2024-01-02T15:04:05 INFO service started
{"time":"2024-01-02T15:04:06","level":"ERROR","msg":"db timeout","trace_id":"t-42","retries":3}
192.168.1.10 - admin [02/Jan/2024:15:04:07 +0800] "GET /api/users HTTP/1.1" 200 512 "https://x.com" "Mozilla/5.0"
Jan  2 11:00:01 host1 mysvc: INFO ready
1704206445 ERROR legacy epoch line
');

-- 1. ISO+level：ts / level / msg
SELECT split_part(val,'|',2) AS ts, split_part(val,'|',3) AS level, split_part(val,'|',4) AS msg
FROM logt WHERE split_part(val,'|',1) = '1';  -- 2024-01-02T15:04:05 | INFO | service started

-- 2. JSON 行：level + kvs 抽取（trace_id / retries）
SELECT split_part(val,'|',3) AS level,
       json_extract(split_part(val,'|',5), '$.trace_id') AS trace_id,
       json_extract(split_part(val,'|',5), '$.retries')  AS retries
FROM logt WHERE split_part(val,'|',1) = '2';  -- ERROR | t-42 | 3

-- 3. nginx：ts + status/path
SELECT split_part(val,'|',2) AS ts,
       json_extract(split_part(val,'|',5), '$.status') AS status,
       json_extract(split_part(val,'|',5), '$.path')   AS path
FROM logt WHERE split_part(val,'|',1) = '3';  -- 2024-01-02T15:04:07 | 200 | /api/users

-- 4. syslog：tag + host
SELECT json_extract(split_part(val,'|',5), '$.tag')  AS tag,
       json_extract(split_part(val,'|',5), '$.host') AS host
FROM logt WHERE split_part(val,'|',1) = '4';  -- mysvc | host1

-- 5. epoch：ts（1704206445 UTC = 2024-01-02T14:40:45）
SELECT split_part(val,'|',2) AS ts, split_part(val,'|',3) AS level
FROM logt WHERE split_part(val,'|',1) = '5';  -- 2024-01-02T14:40:45 | ERROR
