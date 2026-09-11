-- 验证真实用户链路：新会话，install 远程拉取 dbcli（无本地 dofile），查库
-- 模拟 duckdb_universal 用户机器上的体验：装好 sqlite3 + LOAD luajit + install dbcli
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
LOAD httpfs;

-- 清缓存强制走网络（模拟首次安装）
SELECT * FROM luajit_module(mode := 'install', sql_name := 'dbcli');

-- 建测试库 + 查询（install 后直接可用，无任何编译步骤）
SELECT 'A' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/dbcli_e2e.db"],"sql":"CREATE TABLE IF NOT EXISTS t (a INT)","op":"exec"}');
SELECT 'B' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["/mnt/d/wsl2/tmp/dbcli_e2e.db"],"sql":"INSERT INTO t VALUES (1),(2),(3)","op":"exec"}');
SELECT 'C' AS t, val FROM luajit_table('dbcli',
  list := '{"client":"sqlite3","args":["-json","/mnt/d/wsl2/tmp/dbcli_e2e.db"],"sql":"SELECT * FROM t"}');
