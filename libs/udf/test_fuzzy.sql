-- fuzzy.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_fuzzy.sql
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'fuzzy',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/fuzzy.lua'')');

-- 1. Levenshtein 编辑距离（经典锚点）
SELECT luajit_s('fuzzy', {a:'kitten', b:'sitting', op:'lev'}) AS lev_kitten_sitting;   -- 3
SELECT luajit_s('fuzzy', {a:'flew',   b:'flow',    op:'lev'}) AS lev_flew_flow;         -- 1

-- 2. 归一化编辑距离
SELECT luajit_s('fuzzy', {a:'kitten', b:'sitting', op:'normlev'}) AS normlev;          -- 0.4286
SELECT luajit_s('fuzzy', {a:'abc',    b:'abc',     op:'normlev'}) AS normlev_same;     -- 0.0000

-- 3. Jaro / Jaro-Winkler（经典锚点）
SELECT luajit_s('fuzzy', {a:'kitten', b:'sitting', op:'jaro'}) AS jaro_kitten;         -- 0.7460
SELECT luajit_s('fuzzy', {a:'martha', b:'marhta',  op:'jw'})   AS jw_martha;           -- 0.9861

-- 4. UTF-8 感知（核心差异点：字节级会退化成 1.0）
SELECT luajit_s('fuzzy', {a:'王小明', b:'王小民', op:'jw'})    AS jw_cn;               -- 0.8889
SELECT luajit_s('fuzzy', {a:'中文',   b:'中文',   op:'lev'})   AS lev_cn_same;         -- 0
SELECT luajit_s('fuzzy', {a:'中文',   b:'中文A',  op:'lev'})   AS lev_cn_diff;         -- 1

-- 5. simrank（候选打分排序，LIST 参数）
SELECT luajit_s('fuzzy', {v:'北京', cands: ['北京','北京上海','京','北京上海广州'], op:'simrank'}) AS simrank_list;
-- 期望：1:1.0000 居首（精确匹配），其余按 jw 降序
