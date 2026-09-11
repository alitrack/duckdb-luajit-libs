-- dbcli + usql 集成测试：一个 client 覆盖 45 个驱动目录 / 40+ 种数据库的 DSN 协议
-- usql_most = -tags most 全驱动构建
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'dbcli',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/db/dbcli.lua'')');

-- 准备一个 sqlite 库供 usql 连
SELECT 'P0' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/usql_via_dbcli.db"],"sql":"CREATE TABLE IF NOT EXISTS t(a INT, b TEXT)","op":"exec"}');
SELECT 'P1' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/usql_via_dbcli.db"],"sql":"INSERT INTO t VALUES (1,''x''),(2,''y''),(3,''z'')","op":"exec"}');

-- U1: usql_most 经 dbcli 查 sqlite（DSN 在 args，-J 开关，SQL 走 stdin 自动补分号）
SELECT 'U1' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"/mnt/c/Users/DecisionLinnc/AppData/Local/Temp/usql-recon/bin/usql_most","args":["-q","-J","sqlite3:///mnt/d/wsl2/tmp/usql_via_dbcli.db"],"sql":"SELECT a, b FROM t ORDER BY a"}');

-- U2: usql 聚合（验证自动补尾分号——不补会静默空）
SELECT 'U2' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"/mnt/c/Users/DecisionLinnc/AppData/Local/Temp/usql-recon/bin/usql_most","args":["-q","-J","sqlite3:///mnt/d/wsl2/tmp/usql_via_dbcli.db"],"sql":"SELECT COUNT(*) AS n, MAX(a) AS mx FROM t"}');

-- U3: usql ping
SELECT 'U3' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"/mnt/c/Users/DecisionLinnc/AppData/Local/Temp/usql-recon/bin/usql_most","op":"ping"}');

-- U4: usql -C CSV 输出（kind=raw 透传）
SELECT 'U4' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"/mnt/c/Users/DecisionLinnc/AppData/Local/Temp/usql-recon/bin/usql_most","args":["-q","-C","sqlite3:///mnt/d/wsl2/tmp/usql_via_dbcli.db"],"sql":"SELECT * FROM t","kind":"raw"}');

-- U5: 驱动不可用时的错误可见化（duckdb 驱动在 most 下？查 duckdb 文件库）
SELECT 'U5' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"/mnt/c/Users/DecisionLinnc/AppData/Local/Temp/usql-recon/bin/usql_most","args":["-q","-J","duckdb:///mnt/d/wsl2/tmp/usql_duck.db"],"sql":"SELECT 7 AS q"}');
