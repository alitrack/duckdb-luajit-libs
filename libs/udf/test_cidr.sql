-- cidr.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_cidr.sql
-- 正确性对照：Python ipaddress 模块（见 test 下方注释的预期值）。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'cidr',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/cidr.lua'')');

-- 1. IPv4 解析 + ip2int
SELECT json_extract(luajit_s('cidr', {op: 'version', v: '192.168.1.1'}), '$.version') AS v4,
       json_extract(luajit_s('cidr', {op: 'ip2int',  v: '192.168.1.1'}), '$.value')   AS i1,
       json_extract(luajit_s('cidr', {op: 'version', v: '2001:db8::1'}), '$.version')  AS v6
FROM (SELECT 1);
-- 4 | 3232235777 | 6

-- 2. in_cidr（IPv4）—— json_extract 取布尔（JSON 里有空格，别用 LIKE 裸配）
SELECT json_extract(luajit_s('cidr', {op: 'in_cidr', v: '192.168.1.5', cidr: '192.168.0.0/16'}), '$.in') AS in1,
       json_extract(luajit_s('cidr', {op: 'in_cidr', v: '10.0.0.5',      cidr: '192.168.0.0/16'}), '$.in') AS out1
FROM (SELECT 1);
-- true | false

-- 3. cidr_info（10.0.0.0/8 → net 10.0.0.0, bcast 10.255.255.255, size 2^24）
SELECT json_extract(r, '$.network')     AS net,
       json_extract(r, '$.broadcast')   AS bcast,
       json_extract(r, '$.prefix')      AS pfx,
       json_extract(r, '$.size')        AS size,
       json_extract(r, '$.mask')        AS mask
FROM (SELECT luajit_s('cidr', {op: 'cidr_info', v: '10.0.0.0/8'}) AS r);
-- 10.0.0.0 | 10.255.255.255 | 8 | 16777216 | 255.0.0.0

-- 4. classify（IPv4 各段）
SELECT luajit_s('cidr', {op: 'classify', v: '8.8.8.8'})        LIKE '%"class":"public"%'      AS pub,
       luajit_s('cidr', {op: 'classify', v: '172.16.5.9'})     LIKE '%"class":"private"%'     AS priv,
       luajit_s('cidr', {op: 'classify', v: '127.0.0.1'})      LIKE '%"class":"loopback"%'    AS loop,
       luajit_s('cidr', {op: 'classify', v: '169.254.1.1'})    LIKE '%"class":"link-local"%'  AS ll,
       luajit_s('cidr', {op: 'classify', v: '224.0.0.5'})      LIKE '%"class":"multicast"%'   AS mc
FROM (SELECT 1);
-- true | true | true | true | true

-- 5. IPv6 in_cidr + classify（ULA/loopback/link-local）
SELECT json_extract(luajit_s('cidr', {op: 'in_cidr', v: '2001:db8:1::5',   cidr: '2001:db8::/32'}), '$.in') AS v6in,
       luajit_s('cidr', {op: 'classify', v: 'fd12::1'})       LIKE '%"class":"private"%'  AS v6ula,
       luajit_s('cidr', {op: 'classify', v: '::1'})           LIKE '%"class":"loopback"%' AS v6loop,
       luajit_s('cidr', {op: 'classify', v: 'fe80::1'})       LIKE '%"class":"link-local"%' AS v6ll
FROM (SELECT 1);
-- true | true | true | true

-- 6. net/broadcast（IPv6 /64）
SELECT json_extract(luajit_s('cidr', {op: 'net', v: '2001:db8:abcd:1234::abcd/64'}), '$') AS v6net,
       luajit_s('cidr', {op: 'net', v: '192.168.5.13/24'})   AS v4net
FROM (SELECT 1);
-- 2001:db8:abcd:1234:: | "192.168.5.0"

-- 7. 错误处理
SELECT luajit_s('cidr', {op: 'version', v: '999.1.1.1'})  LIKE '%error%' AS bad1,
       luajit_s('cidr', {op: 'in_cidr', v: '1.2.3.4', cidr: 'bad'}) LIKE '%error%' AS bad2
FROM (SELECT 1);
-- true | true
