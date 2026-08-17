-- highs.lua 回归测试套件（duckdb-luajit）
-- 运行：LUAJIT_HIGHS_LIB=/path/to/libhighs.so duckdb -unsigned < test_highs.sql
-- 前置：先有 libhighs.so（见 libs/optimize/README.md @requires）
-- 5 个锚定用例，全部应返回 status:"Optimal" 且 objective/solution 与注释一致。

LOAD luajit;

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'highs',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/optimize/highs.lua'')');

-- 1. LP 饮食问题（MATLAB 官方示例）→ obj=3.15, x=[1.9444,10,10]
SELECT luajit_s('highs', {'op':'lp', 'sense':'min',
  'col_cost':[0.18, 0.23, 0.05],
  'col_lower':[0, 0, 0], 'col_upper':[10, 10, 10],
  'row_lower':[5000, -1e30, 2000, -1e30], 'row_upper':[1e30, 50000, 1e30, 2250],
  'a_start':[0, 2, 4, 5], 'a_index':[0, 2, 0, 2, 2], 'a_value':[107, 72, 500, 121, 65]}) AS t1;

-- 2. MILP 饮食问题全整数 → obj=3.16, x=[2,10,10]
SELECT luajit_s('highs', {'op':'mip', 'sense':'min',
  'col_cost':[0.18, 0.23, 0.05],
  'col_lower':[0, 0, 0], 'col_upper':[10, 10, 10],
  'row_lower':[5000, -1e30, 2000, -1e30], 'row_upper':[1e30, 50000, 1e30, 2250],
  'a_start':[0, 2, 4, 5], 'a_index':[0, 2, 0, 2, 2], 'a_value':[107, 72, 500, 121, 65],
  'integrality':[1, 1, 1]}) AS t2;

-- 3. 运输问题 3×3（等式约束）→ obj=1510, x=[0,10,60,30,0,10,0,50,0]
SELECT luajit_s('highs', {'op':'lp', 'sense':'min',
  'col_cost':[8,6,10, 9,12,13, 14,9,16],
  'col_lower':[0,0,0,0,0,0,0,0,0], 'col_upper':[1e30,1e30,1e30,1e30,1e30,1e30,1e30,1e30,1e30],
  'row_lower':[70,40,50,30,60,70], 'row_upper':[70,40,50,30,60,70],
  'a_start':[0,2,4,6,8,10,12,14,16,18],
  'a_index':[0,3, 0,4, 0,5, 1,3, 1,4, 1,5, 2,3, 2,4, 2,5],
  'a_value':[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]}) AS t3;

-- 4. QP min 0.5(x1²+x2²) s.t. x1+x2=1 → obj=0.25, x=[0.5,0.5]
SELECT luajit_s('highs', {'op':'qp', 'sense':'min',
  'col_cost':[0,0], 'col_lower':[0,0], 'col_upper':[1e30,1e30],
  'row_lower':[1], 'row_upper':[1],
  'a_start':[0,1,2], 'a_index':[0,0], 'a_value':[1,1],
  'q_start':[0,1,3], 'q_index':[0,0,1], 'q_value':[1,0,1]}) AS t4;

-- 5. Max LP max 3x1+2x2 s.t. x1+x2≤4, x1≤2, x2≤3 → obj=10, x=[2,2]
SELECT luajit_s('highs', {'op':'lp', 'sense':'max',
  'col_cost':[3,2], 'col_lower':[0,0], 'col_upper':[2,3],
  'row_lower':[-1e30], 'row_upper':[4],
  'a_start':[0,1,2], 'a_index':[0,0], 'a_value':[1,1]}) AS t5;
