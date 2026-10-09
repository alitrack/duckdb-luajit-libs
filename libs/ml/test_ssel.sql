-- test_ssel.sql — ssel E2E（duckdb -unsigned < test_ssel.sql）
-- 覆盖：compile 注册 / index（zh+en 双集）/ eval / search / status
-- 前置：工件由 evoke-spike/build_ssel_artifacts.py 生成；扩展路径按本机调整

LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SET VARIABLE src = (SELECT content FROM read_text('/mnt/d/wsl2/duckdb-luajit-libs/libs/ml/ssel.lua'));
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'ssel', source := getvariable('src'));

-- 中文同义桥接集（bge-m3 sparse 原子；spike 基线 hit@10=0.70 纯语义）
SELECT luajit_s('ssel', {op:'index', atoms_json:'/mnt/d/wsl2/evoke-spike/ssel_artifacts/demo_zh.json'}) AS idx_zh;
SELECT luajit_s('ssel', {op:'eval',  atoms_json:'/mnt/d/wsl2/evoke-spike/ssel_artifacts/demo_zh.json'}) AS ev_zh;  -- 期望 hit@10≈0.70
SELECT luajit_s('ssel', {op:'search', atoms_json:'/mnt/d/wsl2/evoke-spike/ssel_artifacts/demo_zh.json', n: 1, k: 3}) AS s_zh;

-- 英文 NFCorpus（Evoke P2.2 ONNX 原子；spike 纯语义基线 MRR≈0.70）
SELECT luajit_s('ssel', {op:'index', atoms_json:'/mnt/d/wsl2/evoke-spike/ssel_artifacts/demo_en.json'}) AS idx_en;
SELECT luajit_s('ssel', {op:'eval',  atoms_json:'/mnt/d/wsl2/evoke-spike/ssel_artifacts/demo_en.json'}) AS ev_en;  -- 期望 hit@10≈0.76

SELECT luajit_s('ssel', {op:'status'}) AS st;
