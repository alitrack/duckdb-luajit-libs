-- test_inv_ofd_install.sql — verify the REMOTE install path (宣传要吹"一条 SQL 安装"，必须真通).
-- Loads community/本地扩展，然后从 GitHub 网络拉 INDEX + inv_ofd.lua，注册后立即调用。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
-- 清本地缓存，强制走网络（验证远程链路而非缓存命中）
-- (rm 由 runner 在 WSL 侧执行)
SELECT * FROM luajit_module(mode := 'list_remote');
SELECT * FROM luajit_module(mode := 'install', sql_name := 'inv_ofd');
-- 调用（用 fixture 路径）：meta 标量
SELECT luajit_s('inv_ofd', {'op':'meta', 'file':'/tmp/inv_ofd_probe.ofd'}) AS meta;
-- 版面行（表函数）
SELECT * FROM luajit_table('inv_ofd', list := '/tmp/inv_ofd_probe.ofd');
