-- pinyin.lua 回归（duckdb-luajit）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'pinyin',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/pinyin.lua'')');

-- 1. 基础：单字/多音词组
SELECT luajit_s('pinyin', {v: '中'}) AS t1,       -- {"pinyin":["zhōng"],"joined":"zhōng"}
       luajit_s('pinyin', {v: '重庆'}) AS t2,       -- {"pinyin":["chóngqìng"],"joined":"chóngqìng"}
       luajit_s('pinyin', {v: '中国'}) AS t3;       -- zhōngguó

-- 2. join op + 分隔符（词组整体不拆分，sep 只作用于段间）
SELECT luajit_s('pinyin', {v: '中国', op: 'join'}) AS j1,          -- zhōngguó（词组命中，整体单段）
       luajit_s('pinyin', {v: '天气', op: 'join', sep: '-'}) AS j2; -- tiān-qì（非词组，逐字 2 段 + sep）

-- 3. ASCII/数字逐字透传 + 混合
SELECT luajit_s('pinyin', {v: 'ab中国cd'}) AS m1,   -- ["a","b","zhōngguó","c","d"]
       luajit_s('pinyin', {v: '中国123'}) AS m2;    -- ["zhōngguó","1","2","3"]

-- 4. notones 风格
SELECT luajit_s('pinyin', {v: '中国', style: 'notones'}) AS n1,  -- {"pinyin":["zhongguo"],"joined":"zhongguo"}
       luajit_s('pinyin', {v: '重庆', style: 'notones', op: 'join'}) AS n2;  -- chongqing

-- 5. first：首字母（数组 + 拼接）
SELECT luajit_s('pinyin', {v: '中国', op: 'first'}) AS f1,        -- ["z","g"]
       luajit_s('pinyin', {v: '中国', op: 'first', first_join: true, sep: '-'}) AS f2;  -- "z-g"

-- 6. unknown：无映射汉字（ㄐ 无拼音）
SELECT luajit_s('pinyin', {v: '中ㄐ国'}) AS u1,   -- ["zhōng","?","guó"]
       luajit_s('pinyin', {v: '中ㄐ国', unknown: 'keep'}) AS u2;  -- ["zhōng","ㄐ","guó"]

-- 7. 长句（词组优先）
SELECT luajit_s('pinyin', {v: '重庆一中', op: 'join'}) AS s1,
       luajit_s('pinyin', {v: '一丁不识', op: 'join'}) AS s2;  -- 词组命中 → yīdīngbùshí

-- 8. 错误处理
SELECT luajit_s('pinyin', {op: 'join'}) AS e1;   -- error: missing v
