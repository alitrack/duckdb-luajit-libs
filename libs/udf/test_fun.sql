-- fun.lua 回归 + A/B 基准（duckdb-luajit）
-- 验证：vendored luafun 在扩展内加载（dofile 长串 dofile）、惰性模型经 UDF 消费、
--       JIT on/off 对链式表达式的真实加速（bench A=手写 for，B=fun 惰性链，同语义）。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'fun',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/fun.lua'')');

-- 1. chain: filter even + map square of 1..10 → [4,16,36,64,100]
SELECT fun({seq:'range', a:1, b:10, op:'chain',
  steps:[{f:'filter', p:'x % 2 == 0'}, {f:'map', p:'x * x'}]}) AS c1;

-- 2. take: first 3 of 1..5 → [1,2,3]
SELECT fun({seq:'range', a:5, op:'chain', steps:[{f:'take', p:3}]}) AS c2;

-- 3. reduce sum 1..100 → 5050
SELECT fun({seq:'range', a:100, op:'reduce', expr:'a + b'}) AS c3;

-- 4. sum of squares 1..100 (with map step) → 338350
SELECT fun({seq:'range', a:100, op:'reduce', expr:'a + b',
  steps:[{f:'map', p:'x * x'}]}) AS c4;

-- 5. list input: [7,8,9] + map x+1 → [8,9,10]
SELECT fun({seq:[7,8,9], op:'chain', steps:[{f:'map', p:'x + 1'}]}) AS c5;

-- 6. drop 4 of 1..6 → [5,6]
SELECT fun({seq:'range', a:6, op:'chain', steps:[{f:'drop', p:4}]}) AS c6;

-- 7. string escaping: quotes/backslash/newline survive JSON round-trip
SELECT fun({seq:['a"b', 'c\d', 'e' || chr(10) || 'f'], op:'arr'}) AS c7;

-- 8. error visibility
SELECT fun({op:'nope'}) AS c8;

-- 9. JIT probe (off state after compile)
SELECT fun({jit:'off'}) AS c9;

-- 10. A/B 微基准：n=1,000,000（filter even + map sq + sum 同语义）
--     先 JIT off 跑两臂，再 JIT on 跑两臂 → 4 行
SELECT 'jit_off' AS phase, fun({bench:'A', n:1000000, its:5}) AS arm_A,
       fun({bench:'B', n:1000000, its:5}) AS arm_B;
SELECT fun({jit:'on'}) AS enable_jit;
SELECT 'jit_on' AS phase, fun({bench:'A', n:1000000, its:5}) AS arm_A,
       fun({bench:'B', n:1000000, its:5}) AS arm_B;
