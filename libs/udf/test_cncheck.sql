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

-- 12. id_15to18：锚点（README 已验证的 18 位 11010519491231002X 的 15 位老号 → 转回）
SELECT json_extract(luajit_s('cncheck', {v: '110105491231002', op: 'id_15to18'}), '$.id18') AS t12;  -- 11010519491231002X

-- 13. id_15to18：普通样本（oracle 独立实现）
SELECT json_extract(luajit_s('cncheck', {v: '350102681001001', op: 'id_15to18'}), '$.id18') AS t13,  -- 350102196810010012
       json_extract(luajit_s('cncheck', {v: '440301760101002', op: 'id_15to18'}), '$.id18') AS t14;  -- 440301197601010025

-- 14. id_15to18：转换结果应能通过 id_card 校验（闭环）
SELECT json_extract(luajit_s('cncheck', {v: '110105491231002', op: 'id_15to18'}), '$.id18') AS conv14,
       json_extract(luajit_s('cncheck', {v: '11010519491231002X', op: 'id_card'}), '$.valid') AS valid14;  -- true

-- 15. id_15to18：错误处理（长度错 / 非数字 / 18 位输入）
SELECT json_extract(luajit_s('cncheck', {v: '12345', op: 'id_15to18'}), '$.id18') AS e15a,   -- null
       json_extract(luajit_s('cncheck', {v: '11010519491231002X', op: 'id_15to18'}), '$.id18') AS e15b;  -- null（18位）
