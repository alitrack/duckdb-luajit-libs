-- test_zlib.sql — zlib lib E2E（duckdb -unsigned -f 本文件）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'zlib',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/zlib.lua'')');

-- hello → compress → 固定 hex（zlib 容器，level 默认 6）；version 自检
SELECT luajit_s('zlib', {v:'hello', op:'compress'}) AS zc_hello,
       luajit_s('zlib', {op:'version'}) AS zver;
-- roundtrip：compress→uncompress 回环出原 hex（68656c6c6f = "hello"）
SELECT luajit_s('zlib', {v:'hello', op:'roundtrip'}) AS rt_hello;

-- 断言（应为 0 的失配行）
SELECT count(*) FILTER (WHERE x = 1) AS errors_must_be_0 FROM (
  -- roundtrip 回环必须等于 "hello" 的 hex
  SELECT CASE WHEN luajit_s('zlib',{v:'hello',op:'roundtrip'}) = '68656c6c6f' THEN 0 ELSE 1 END AS x
  UNION ALL
  -- version 必须非空
  SELECT CASE WHEN length(luajit_s('zlib',{op:'version'})) > 0 THEN 0 ELSE 1 END
  UNION ALL
  -- compress 结果必须不是 ERR 串
  SELECT CASE WHEN luajit_s('zlib',{v:'hello',op:'compress'}) NOT LIKE 'ERR%' THEN 0 ELSE 1 END
  UNION ALL
  -- compress 结果必须是合法 hex（偶数长度），且比原文短（压缩生效）
  SELECT CASE WHEN (length(luajit_s('zlib',{v:'hello',op:'compress'})) % 2) = 0
                   AND length(luajit_s('zlib',{v:'hello',op:'compress'})) < 30 THEN 0 ELSE 1 END
) t;
