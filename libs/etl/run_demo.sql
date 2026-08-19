LOAD luajit;

-- 安装 etl 模块
SELECT * FROM luajit_module(mode := 'install', sql_name := 'etl');

-- 读取 demo 脚本到变量
SET VARIABLE demo_src = (SELECT content FROM read_text('/mnt/d/wsl2/duckdb-luajit-libs/libs/etl/demo_e2e.lua'));

-- 编译 demo
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'etl_demo_e2e',
  source := getvariable('demo_src'));

-- 执行
SELECT luajit_s('etl_demo_e2e', 'go');