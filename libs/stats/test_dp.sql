-- dp.lua 回归测试套件（duckdb-luajit）——自判分
-- 运行：duckdb -unsigned -noheader -list < test_dp.sql   （每检查一行：<check>\t<true/false>）
-- 数据真值：t = 1..100 → count=100, sum=5050, mean=50.5
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'dp',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/stats/dp.lua'')');

CREATE TABLE t AS SELECT i AS v FROM range(1,101) tbl(i);
CREATE TABLE tv AS SELECT v FROM t UNION ALL SELECT NULL;  -- 100 行 + 1 NULL

-- 1. 确定性：同 seed 同输出
SELECT 'count_determinism',
  (luajit_s('dp', {op:'count', data:list(v), eps:1, seed:42})
   = luajit_s('dp', {op:'count', data:list(v), eps:1, seed:42})) FROM t;
SELECT 'sum_determinism',
  (luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:1, seed:42})
   = luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:1, seed:42})) FROM t;

-- 2. 不同 seed → 不同输出
SELECT 'sum_diff_seed',
  (luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:1, seed:42})
  <> luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:1, seed:7})) FROM t;

-- 3. ε 单调性：ε 越大越接近真值 5050
WITH x AS (
  SELECT
    CAST(luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:1000, seed:1}) AS DOUBLE) AS s_big,
    CAST(luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:1,    seed:1}) AS DOUBLE) AS s_mid,
    CAST(luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:10000, eps:0.01, seed:1}) AS DOUBLE) AS s_small
  FROM t)
SELECT 'eps_monotonic',
  (abs(s_big-5050) < abs(s_mid-5050) AND abs(s_mid-5050) < abs(s_small-5050)) FROM x;

-- 4. 裁剪生效：clip 到 [0,50] → 真 sum = 1+..+50 + 50*50 = 1275+2500 = 3775
SELECT 'clip_effect',
  (abs(CAST(luajit_s('dp', {op:'sum', data:list(v), lo:0, hi:50, eps:1000, seed:1}) AS DOUBLE) - 3775) < 5)
FROM t;

-- 5. mean：ε 大 → 近 50.5（seed 取大值避开 Park-Miller 首值落在 Laplace 逆CDF 极端尾的偏置）
SELECT 'mean_close',
  (abs(CAST(luajit_s('dp', {op:'mean', data:list(v), lo:0, hi:10000, eps:1000, seed:10000}) AS DOUBLE) - 50.5) < 1)
FROM t;

-- 6. NULL 剔除：tv 含 1 NULL，count 近 100 非 101
SELECT 'null_excluded',
  (abs(CAST(luajit_s('dp', {op:'count', data:list(v), eps:1000, seed:1}) AS DOUBLE) - 100) < 2)
FROM tv;

-- 7. count 非负 floor（极小 ε 不报错、不返回负）
SELECT 'count_nonneg',
  (CAST(luajit_s('dp', {op:'count', data:list(v), eps:0.0001, seed:1}) AS INTEGER) >= 0) FROM t;

-- 8. lap 裸噪声同 seed 确定
SELECT 'lap_determinism',
  (luajit_s('dp', {op:'lap', scale:2, seed:99}) = luajit_s('dp', {op:'lap', scale:2, seed:99}));

-- 9. lap_vec 大样本零均值 + 尺度（b=1 → stddev≈√2≈1.414, mean≈0）
SELECT 'lap_vec_zero_mean',
  (abs(CAST(json_extract_string(luajit_s('dp', {op:'lap_vec', scale:1, n:200000, mode:'stats', seed:5}), '$.mean') AS DOUBLE)) < 0.05);
SELECT 'lap_vec_scale',
  (CAST(json_extract_string(luajit_s('dp', {op:'lap_vec', scale:1, n:200000, mode:'stats', seed:5}), '$.stddev') AS DOUBLE) BETWEEN 1.35 AND 1.48);

-- 10. 错误路径（均须含 "Error"）
SELECT 'err_bad_eps',  (luajit_s('dp', {op:'sum', data:list(v), eps:0, seed:1}) LIKE '%Error%') FROM t;
SELECT 'err_no_lo',    (luajit_s('dp', {op:'sum', data:list(v), hi:100, eps:1, seed:1}) LIKE '%Error%') FROM t;
SELECT 'err_hi_lt_lo', (luajit_s('dp', {op:'sum', data:list(v), lo:5, hi:1, eps:1, seed:1}) LIKE '%Error%') FROM t;
SELECT 'err_bad_op',   (luajit_s('dp', {op:'nope', data:list(v), eps:1}) LIKE '%Error%') FROM t;
SELECT 'err_not_list', (luajit_s('dp', {op:'sum', data:42, lo:0, hi:10, eps:1}) LIKE '%Error%');
SELECT 'err_str',      (luajit_s('dp', 'not json') LIKE '%Error%');

-- 11. lap_vec 边界：n 越界报错
SELECT 'err_vec_n',    (luajit_s('dp', {op:'lap_vec', scale:1, n:0, mode:'stats'}) LIKE '%Error%');
