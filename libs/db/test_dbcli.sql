-- dbcli PoC 测试：Lua 通过本机 sqlite3 CLI 查数（duckdb_universal 长尾 transport 总线）
-- 管线（skill 验证过）：WSL duckdb v1.5.5 -unsigned -f 本文件
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'dbcli',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/db/dbcli.lua'')');

-- T0: 用 dbcli 自身引导建库（dogfood：先 exec 建表插数）
SELECT 'T0a' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/dbcli_poc.db"],"sql":"CREATE TABLE IF NOT EXISTS users (id INT, name TEXT, score REAL)","op":"exec"}');
SELECT 'T0b' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/dbcli_poc.db"],"sql":"INSERT INTO users VALUES (1, ''alice'', 91.5), (2, ''bob'', 84.0), (3, ''charlie'', 77.25)","op":"exec"}');

-- T1: sqlite3 -json 查询 → 每行一个 JSON 对象
SELECT 'T1' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["-json","/mnt/d/wsl2/tmp/dbcli_poc.db"],"sql":"SELECT id, name, score FROM users ORDER BY score DESC"}');

-- T2: exec 模式（取最后一行输出）
SELECT 'T2' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/dbcli_poc.db"],"sql":"SELECT COUNT(*) FROM users","op":"exec"}');

-- T3: ping（客户端自检）
SELECT 'T3' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","op":"ping"}');

-- T4: 错误可见化——客户端不存在
SELECT 'T4' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"no_such_cli_xyz","sql":"SELECT 1"}');

-- T5: 错误可见化——非法 JSON spec
SELECT 'T5' AS t, val FROM luajit_table('dbcli',
  list := 'not a json at all');

-- T6: SQL 侧继续加工 Lua 拿回来的 JSON 行（extract + 聚合）
SELECT 'T6' AS t,
       count(*) AS n,
       max(CAST(json_extract(val, '$.score') AS DOUBLE)) AS top_score
FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["-json","/mnt/d/wsl2/tmp/dbcli_poc.db"],"sql":"SELECT id, name, score FROM users"}');
