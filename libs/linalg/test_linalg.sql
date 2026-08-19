-- linalg.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_linalg.sql（需 libopenblas，见 @requires）
-- 锚定用例，全部应返回数值正确（误差 < 1e-12）。矩阵=扁平行主序+m/n。

LOAD luajit;

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'linalg',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/linalg/linalg.lua'')');

-- 1. matmul [[1,2],[3,4]]×[[5,6],[7,8]] → [[19,22],[43,50]] 扁平 [19,22,43,50]
SELECT luajit_s('linalg', {'op':'matmul', 'a':[1,2,3,4], 'm':2, 'n':2, 'b':[5,6,7,8], 'mb':2, 'nb':2}) AS t1;

-- 2. svd [[1,2],[3,4]] → σ=[5.4650,0.3660]
SELECT luajit_s('linalg', {'op':'svd', 'a':[1,2,3,4], 'm':2, 'n':2}) AS t2;

-- 3. eigh [[2,1],[1,2]] → λ=[1,3]
SELECT luajit_s('linalg', {'op':'eigh', 'a':[2,1,1,2], 'm':2, 'n':2}) AS t3;

-- 4. inv [[4,7],[2,6]] → [[0.6,-0.7],[-0.2,0.4]] 扁平 [0.6,-0.7,-0.2,0.4]
SELECT luajit_s('linalg', {'op':'inv', 'a':[4,7,2,6], 'm':2, 'n':2}) AS t4;

-- 5. lu [[4,3],[6,3]] → ipiv=[2,2]
SELECT luajit_s('linalg', {'op':'lu', 'a':[4,3,6,3], 'm':2, 'n':2}) AS t5;

-- 6. chol [[4,2],[2,3]] → [[2,1],[0,1.4142]] 扁平 [2,1,0,1.4142]
SELECT luajit_s('linalg', {'op':'chol', 'a':[4,2,2,3], 'm':2, 'n':2}) AS t6;

-- 7. qr [[1,1],[1,-1]] → q=[[0.707,0.707],[0.707,-0.707]], r=[[1.414,0],[0,-1.414]]
SELECT luajit_s('linalg', {'op':'qr', 'a':[1,1,1,-1], 'm':2, 'n':2}) AS t7;

-- 8. norm 矩阵 [[1,2],[3,4]] Frobenius = √30 ≈ 5.4772
SELECT luajit_s('linalg', {'op':'norm', 'v':[1,2,3,4], 'm':2, 'n':2}) AS t8;

-- 9. norm 向量 [3,4] → 5
SELECT luajit_s('linalg', {'op':'norm', 'v':[3,4]}) AS t9;

-- 10. 3×2 SVD [[1,0],[0,1],[1,0]] → σ=[√2,1]≈[1.414,1]
SELECT luajit_s('linalg', {'op':'svd', 'a':[1,0,0,1,1,0], 'm':3, 'n':2}) AS t10;

-- 11. ⛔ 非方阵 matmul a(2×3)×b(3×2) → 2×2（2026-08-19 回归：mb/nb 曾被 flat_row 忽略）
--     a=[[1,2,3],[4,5,6]], b=[[7,8],[9,10],[11,12]] → c=[[58,64],[139,154]]
SELECT luajit_s('linalg', {'op':'matmul', 'a':[1,2,3,4,5,6], 'm':2, 'n':3, 'b':[7,8,9,10,11,12], 'mb':3, 'nb':2}) AS t11;

-- 12. mb 传错（3*2≠6）→ 应报 dim mismatch 而非静默算错
SELECT luajit_s('linalg', {'op':'matmul', 'a':[1,2,3,4,5,6], 'm':2, 'n':3, 'b':[7,8,9,10,11,12], 'mb':2, 'nb':2}) AS t12;
