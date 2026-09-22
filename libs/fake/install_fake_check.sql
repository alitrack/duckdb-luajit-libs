LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
LOAD httpfs;
-- 强制清缓存走网络（模拟新机器首次安装）
SELECT '== install fake（远程拉取 main 分支）==' AS step;
SELECT * FROM luajit_module(mode := 'install', sql_name := 'fake');
SELECT '== install 后直接调用 ==' AS step;
SELECT luajit_s('fake', {op: 'gen', kind: 'person.full', seed: 1}) AS full,
       luajit_s('fake', {op: 'template', template: '{person.full} <{contact.email}>', seed: 1}) AS tpl,
       luajit_s('fake', {op: 'kinds'})::VARCHAR LIKE '%"count":30%' AS has_30_kinds
FROM (SELECT 1);
SELECT '== 表函数 ==' AS step;
SELECT row_idx, val FROM luajit_table('fake',
  list := '{"cols":{"name":"person.full","age":"int:18,65"},"rows":3,"seed":7}')
  ORDER BY row_idx;
