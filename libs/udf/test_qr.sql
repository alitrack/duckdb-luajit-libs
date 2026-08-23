-- qr.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_qr.sql
-- 正确性证据：codewords（数据+Reed-Solomon 纠错码字，与 mask 无关）与独立实现
--   python-qrcode（MIT，get_matrix/create_data 路径）逐字节比对 = IDENTICAL，
--   见 libs/udf/PoC-qr-output.txt 与提交信息。矩阵层面：5/7 样例与参考逐模块相同，
--   其余为 mask 选择差异（两种 mask 均合法可解码）。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'qr',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/qr.lua'')');

-- 1. info：ASCII 短文本 → v1 size21（21=17+4*1）
SELECT json_extract(r, '$.version') AS ver, json_extract(r, '$.size') AS size,
       json_extract(r, '$.ec') AS ec, json_extract(r, '$.codewords') AS cw
FROM (SELECT luajit_s('qr', {v: 'hello', op: 'info', ec: 'M'}) AS r);
-- 1 | 21 | "M" | 26

-- 2. 中文 UTF-8 → v2 size25（证明字节模式编码 CJK 正确）
SELECT json_extract(r, '$.version') AS ver, json_extract(r, '$.size') AS size,
       json_extract(r, '$.codewords') AS cw
FROM (SELECT luajit_s('qr', {v: '中文测试QR码', op: 'info', ec: 'M'}) AS r);
-- 2 | 25 | 44

-- 3. codewords 与 python-qrcode 逐字节一致（'short' ec=Q）
SELECT r = '["40","57","36","86","F7","27","40","EC","11","EC","11","EC","11","08","51","58","21","17","61","3B","28","B8","93","03","02","A5"]' AS matches_ref
FROM (SELECT luajit_s('qr', {v: 'short', op: 'codewords', ec: 'Q'}) AS r);
-- true

-- 4. codewords（'abc' ec=L）与参考一致
SELECT r = '["40","36","16","26","30","EC","11","EC","11","EC","11","EC","11","EC","11","EC","11","EC","11","B6","A0","2C","78","BA","19","6A"]' AS matches_ref
FROM (SELECT luajit_s('qr', {v: 'abc', op: 'codewords', ec: 'L'}) AS r);
-- true

-- 5. matrix：合法 JSON 二维数组，v1=21x21（每行 21 个 0/1）
SELECT json_array_length(r) AS rows,
       json_array_length(json_extract(r, '$[0]')) AS cols
FROM (SELECT luajit_s('qr', {v: 'short', op: 'matrix', ec: 'Q'}) AS r);
-- 21 | 21

-- 6. svg：以 <svg 开头、含 viewBox 与深色 rect
SELECT luajit_s('qr', {v: 'hi', op: 'svg', ec: 'M'}) LIKE '<svg%'            AS is_svg,
       luajit_s('qr', {v: 'hi', op: 'svg', ec: 'M'}) LIKE '%viewBox%'       AS has_viewbox,
       luajit_s('qr', {v: 'hi', op: 'svg', ec: 'M'}) LIKE '%#000000%'       AS has_dark
FROM (SELECT 1);
-- true | true | true

-- 7. 超限（200 字节 > v6 容量）→ 明确报错而非静默
SELECT luajit_s('qr', {v: repeat('x', 200), op: 'info', ec: 'L'}) LIKE '%error%' AS is_err
FROM (SELECT 1);
-- true
