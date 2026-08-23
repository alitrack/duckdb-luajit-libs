-- cncheck.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_cncheck.sql
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'cncheck',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/cncheck.lua'')');

-- 1. 身份证有效（GB11643 校验位 X）
SELECT json_extract(luajit_s('cncheck', {v: '11010519491231002X', op: 'id_card'}), '$.valid') AS t1;  -- true

-- 2. 身份证无效（末位错）
SELECT json_extract(luajit_s('cncheck', {v: '110105194912310020', op: 'id_card'}), '$.valid') AS t2;  -- false

-- 3. 身份证字段抽取
SELECT luajit_s('cncheck', {v: '11010519491231002X', op: 'id_extract'}) AS t3;  -- {"region":"110105","birth":"1949-12-31","sex":"F"}

-- 4. 15 位老号抽取
SELECT luajit_s('cncheck', {v: '110105491231002', op: 'id_extract'}) AS t4;  -- {"region":"110105","birth":"1949-12-31","sex":"F"}

-- 5. 银行卡 Luhn 有效
SELECT json_extract(luajit_s('cncheck', {v: '4111111111111111', op: 'bank_card'}), '$.valid') AS t5;  -- true

-- 6. 银行卡 Luhn 无效
SELECT json_extract(luajit_s('cncheck', {v: '4111111111111112', op: 'bank_card'}), '$.valid') AS t6;  -- false

-- 7. 手机号有效
SELECT json_extract(luajit_s('cncheck', {v: '13800138000', op: 'phone'}), '$.valid') AS t7;  -- true

-- 8. 手机号无效（号段 12 开头）
SELECT json_extract(luajit_s('cncheck', {v: '12800138000', op: 'phone'}), '$.valid') AS t8;  -- false

-- 9. 统一社会信用代码有效
SELECT json_extract(luajit_s('cncheck', {v: '91350100M000100Y43', op: 'uscc'}), '$.valid') AS t9;  -- true

-- 10. 统一社会信用代码无效
SELECT json_extract(luajit_s('cncheck', {v: '91350100M000100Y44', op: 'uscc'}), '$.valid') AS t10;  -- false

-- 11. 未知 op 优雅降级
SELECT json_extract(luajit_s('cncheck', {v: 'x', op: 'nope'}), '$.valid') AS t11;  -- false
