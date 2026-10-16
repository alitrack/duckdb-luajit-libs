-- to_lance PoC/E2E 测试（DuckDB v1.5.6 + luajit v0.32.5 + lance_conversion v0.1.5，2026-10-16）
-- 跑法（cwd 任意，产物落 /tmp/to_lance_test/，幂等）：
--   duckdb -c ".read libs/etl/test_to_lance.sql"
-- 断言：run1 write=create loaded=1000；run2 write=append loaded=200；run3 loaded=0 write=noop；
--       水位表 1 行；读回（另会话）1200 行。
-- 注意：lance 与 lance_conversion 不能同会话 LOAD（LANCE CopyFunction 重名冲突），
--       读回校验须另起会话 LOAD lance（见文件尾注释）。
-- 调用约定：luajit_s 传 JSON 字符串；to_lance.entry 内置极简 JSON 解码（与 struct 直传二选一，
--       struct 形态走 luajit_module compile wrapper 闭包，见 PoC 记录）。

LOAD luajit;
LOAD lance_conversion;

CREATE OR REPLACE TABLE tl_src AS
  SELECT i AS id, (TIMESTAMP '2026-10-16 00:00:00' + INTERVAL (i) MINUTE) AS ts, 'ord-' || i AS label
  FROM range(1, 1001) t(i);

-- 库源内联注册（install 需要 INDEX 登记，CI/本地两种姿势都可用：本地直读库文件）
-- SET VARIABLE 方式取文件内容
SET VARIABLE tls = (SELECT content FROM read_text('libs/etl/to_lance.lua'));
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'tl_mod', source := 'local src = [==[' || getvariable('tls') || ']==]; local c = load(src, ''to_lance''); if not c then error(''load failed'', 0) end; _G[''to_lance''] = c(); return function() return ''registered'' end');
SELECT luajit_s('tl_mod', 'x') AS mod_registered;

SELECT * FROM luajit_module(mode := 'compile', sql_name := 'tl_run',
  source := 'return function(raw) return to_lance.entry(raw) end');

-- 幂等：清水位（to_lance.reset 也行，但这里直接建/清表最直观）
DROP TABLE IF EXISTS etl_watermark;

.print '--- run1: initial load (expect write=create loaded=1000)'
SELECT luajit_s('tl_run', '{"op":"run","source":"tl_src","dest":"/tmp/to_lance_test/orders.lance","ts_col":"ts","mode":"ts"}') AS run1;

INSERT INTO tl_src SELECT i + 1000 AS id, (TIMESTAMP '2026-10-16 00:00:00' + INTERVAL (i + 1000) MINUTE) AS ts, 'ord-' || (i + 1000) AS label FROM range(1, 201) t(i);

.print '--- run2: incremental (expect write=append loaded=200)'
SELECT luajit_s('tl_run', '{"op":"run","source":"tl_src","dest":"/tmp/to_lance_test/orders.lance","ts_col":"ts","mode":"ts"}') AS run2;

.print '--- run3: noop (expect loaded=0 write=noop)'
SELECT luajit_s('tl_run', '{"op":"run","source":"tl_src","dest":"/tmp/to_lance_test/orders.lance","ts_col":"ts","mode":"ts"}') AS run3;

.print '--- watermark table (expect 1 row, name=dest path)'
TABLE etl_watermark;

.print '--- read-back (SEPARATE session, official lance extension): expect 1200 rows, max_id=1200'
.print 'duckdb -c "LOAD lance; SELECT count(*), max(id), max(ts) FROM ''/tmp/to_lance_test/orders.lance'';"'
