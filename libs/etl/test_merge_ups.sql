-- merge_ups.lua 回归测试套件（duckdb-luajit）——自判分
-- 运行：duckdb -unsigned -noheader -list < test_merge_ups.sql   （每检查一行：<check>\t<true/false>）
-- merge_ups_run 会改 target，故每个场景：重置 target/src → 单独执行一次取结果 → 从结果表断言。
-- 数据真值：
--   场景A（retract=false，upsert）：tgt{1:a,10  2:b,20  3:c,30}，src{1:a,10(未变) 2:b2,20(变name) 4:d,40(新增)}
--     → in=3 new=1 changed=1 unchanged=1 overwrite=1 retract=0；tgt 终态 4 行，id2→b2，id3 保留，id4 新增
--   场景B（retract=true，全量MERGE）：同初始 tgt/src，但删 source 缺的 id3 → retract=1，tgt 终态 3 行无 id3
--   场景C（幂等）：对已对齐 tgt 再 merge 同一 src → 全 unchanged，零写入
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
-- 模块库（return 表，非函数）走 compile 注入 _G（同 to_lance/incremental 的本地直读姿势）
SET VARIABLE mup = (SELECT content FROM read_text('libs/etl/merge_ups.lua'));
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'mup_mod',
  source := 'local src = [==[' || getvariable('mup') || ']==]; local c = load(src, ''merge_ups''); if not c then error(''load failed'', 0) end; _G[''merge_ups''] = c(); return function() return ''registered'' end');
SELECT luajit_s('mup_mod', 'x') AS mod_registered;
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'merge_ups_run',
  source := 'return function(o) return merge_ups.run(o) end');

-- ============ A. 首次 upsert（retract 默认 false）============
CREATE OR REPLACE TABLE tgt(id INTEGER, name VARCHAR, amt DOUBLE);
INSERT INTO tgt VALUES (1,'a',10.0),(2,'b',20.0),(3,'c',30.0);
CREATE OR REPLACE TABLE src(id INTEGER, name VARCHAR, amt DOUBLE);
INSERT INTO src VALUES (1,'a',10.0),(2,'b2',20.0),(4,'d',40.0);

CREATE OR REPLACE TEMP TABLE rA AS SELECT luajit_s('merge_ups_run', {target:'tgt', source:'src', key_cols:['id']}) AS j;
SELECT 'A1_in3', (json_extract_string(j,'$.in')='3') FROM rA;
SELECT 'A2_new1', (json_extract_string(j,'$.new')='1') FROM rA;
SELECT 'A3_changed1', (json_extract_string(j,'$.changed')='1') FROM rA;
SELECT 'A4_unchanged1', (json_extract_string(j,'$.unchanged')='1') FROM rA;
SELECT 'A5_overwrite1', (json_extract_string(j,'$.overwrite')='1') FROM rA;
SELECT 'A6_retract0', (json_extract_string(j,'$.retract')='0') FROM rA;
SELECT 'A7_tgt_4rows', count(*)=4 FROM tgt;
SELECT 'A8_id2_updated', exists(SELECT 1 FROM tgt WHERE id=2 AND name='b2') FROM rA;
SELECT 'A9_id3_retained', exists(SELECT 1 FROM tgt WHERE id=3 AND name='c') FROM rA;
SELECT 'A10_id4_inserted', exists(SELECT 1 FROM tgt WHERE id=4 AND name='d' AND amt=40.0) FROM rA;
SELECT 'A11_id1_intact', exists(SELECT 1 FROM tgt WHERE id=1 AND name='a' AND amt=10.0) FROM rA;

-- ============ B. retract=true（全量 MERGE：删 source 缺的 id3）============
CREATE OR REPLACE TABLE tgt(id INTEGER, name VARCHAR, amt DOUBLE);
INSERT INTO tgt VALUES (1,'a',10.0),(2,'b',20.0),(3,'c',30.0);
CREATE OR REPLACE TABLE src(id INTEGER, name VARCHAR, amt DOUBLE);
INSERT INTO src VALUES (1,'a',10.0),(2,'b2',20.0),(4,'d',40.0);

CREATE OR REPLACE TEMP TABLE rB AS SELECT luajit_s('merge_ups_run', {target:'tgt', source:'src', key_cols:['id'], retract:true}) AS j;
SELECT 'B1_retract1', (json_extract_string(j,'$.retract')='1') FROM rB;
SELECT 'B2_new1', (json_extract_string(j,'$.new')='1') FROM rB;
SELECT 'B3_id3_removed', count(*)=0 FROM tgt WHERE id=3;
SELECT 'B4_tgt_3rows', count(*)=3 FROM tgt;

-- ============ C. 幂等：tgt 现={1:a,10  2:b2,20  4:d,40}，与 src 一致 → 全 unchanged ============
CREATE OR REPLACE TEMP TABLE rC AS SELECT luajit_s('merge_ups_run', {target:'tgt', source:'src', key_cols:['id']}) AS j;
SELECT 'C1_in3', (json_extract_string(j,'$.in')='3') FROM rC;
SELECT 'C2_unchanged3', (json_extract_string(j,'$.unchanged')='3') FROM rC;
SELECT 'C3_new0', (json_extract_string(j,'$.new')='0') FROM rC;
SELECT 'C4_changed0', (json_extract_string(j,'$.changed')='0') FROM rC;
SELECT 'C5_overwrite0', (json_extract_string(j,'$.overwrite')='0') FROM rC;
SELECT 'C6_tgt_3rows', count(*)=3 FROM tgt;
