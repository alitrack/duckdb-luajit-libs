-- test_basexx.sql — basexx lib E2E（duckdb -unsigned -f 本文件）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'basexx',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/basexx.lua'')');

-- base85：hello → 1g4I1>m → 回环 68656c6c6f
SELECT luajit_s('basexx', {hex:'68656c6c6f', op:'base85_enc'}) AS b85_enc,
       luajit_s('basexx', {v:'1g4I1>m', op:'base85_dec'}) AS b85_dec;
-- base58：deadbeef → 6h8cQN → 回环 deadbeef
SELECT luajit_s('basexx', {hex:'deadbeef', op:'base58_enc'}) AS b58_enc,
       luajit_s('basexx', {v:'6h8cQN', op:'base58_dec'}) AS b58_dec;
-- 前导零字节 → 标记字符（base58 的 '1'），全零串 roundtrip
SELECT luajit_s('basexx', {hex:'0000', op:'base58_enc'}) AS b58_leadzero,
       luajit_s('basexx', {v:'11', op:'base58_dec'}) AS b58_leadzero_dec;

-- 断言（应为 0 的失配行）
SELECT count(*) FILTER (WHERE x = 1) AS errors_must_be_0 FROM (
  SELECT CASE WHEN luajit_s('basexx',{v:'1g4I1>m',op:'base85_dec'}) = '68656c6c6f' THEN 0 ELSE 1 END AS x
  UNION ALL SELECT CASE WHEN luajit_s('basexx',{hex:'68656c6c6f',op:'base85_enc'}) = '1g4I1>m' THEN 0 ELSE 1 END
  UNION ALL SELECT CASE WHEN luajit_s('basexx',{v:'6h8cQN',op:'base58_dec'}) = 'deadbeef' THEN 0 ELSE 1 END
  UNION ALL SELECT CASE WHEN luajit_s('basexx',{hex:'deadbeef',op:'base58_enc'}) = '6h8cQN' THEN 0 ELSE 1 END
  UNION ALL SELECT CASE WHEN luajit_s('basexx',{hex:'0000',op:'base58_enc'}) = '11' THEN 0 ELSE 1 END
  UNION ALL SELECT CASE WHEN luajit_s('basexx',{v:'11',op:'base58_dec'}) = '0000' THEN 0 ELSE 1 END
) t;
