# libs/optimize/highs — LP / QP / MILP 优化求解（HiGHS 内核）

在 SQL 里解**线性规划（LP）/ 二次规划（QP）/ 混合整数规划（MILP）**——
LuaJIT FFI 直调 [HiGHS](https://github.com/ERGO-Code/HiGHS)（MIT，SciPy / MATLAB
Optimization Toolbox / JuMP / NAG 的默认求解器），无 Python、无绑定代码。

> DuckDB 生态目前**没有**任何 LP/MIP 求解器扩展——这是 `highs` lib 的空白占位
> （2026-08-17 调研结论，见
> [duckdb-luajit-next-directions-20260817](../../../claw/wiki/raw/articles/research/duckdb-luajit-next-directions-20260817.md)
> 或 wiki 索引）。

## 依赖

**libhighs.so（HiGHS ≥ 1.6，MIT）**。编译安装（~1 分钟）：

```bash
git clone --depth 1 https://github.com/ERGO-Code/HiGHS
cmake -S HiGHS -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
cmake --build build -j && sudo cmake --install build && sudo ldconfig
```

找不到库时，设 `LUAJIT_HIGHS_LIB` 指向 libhighs.so 完整路径。

## 用法

```sql
LOAD luajit;
SELECT * FROM luajit_module(mode := 'install', sql_name := 'highs');
-- 或快速编译：mode := 'quick_compile', source := 'return dofile(''/path/to/highs.lua'')'
```

### LP：饮食问题（Diet Problem，MATLAB 官方示例）

min `0.18C + 0.23M + 0.05B`，约束 `107C+500M ∈ [5000,50000]`、
`72C+121M+65B ∈ [2000,2250]`、`0 ≤ C,M,B ≤ 10`。已知最优 C=1.944, M=10, B=10, obj=3.15：

```sql
SELECT luajit_s('highs', {'op':'lp', 'sense':'min',
  'col_cost':[0.18, 0.23, 0.05],
  'col_lower':[0,0,0], 'col_upper':[10,10,10],
  'row_lower':[5000,-1e30,2000,-1e30], 'row_upper':[1e30,50000,1e30,2250],
  'a_start':[0,2,4,5], 'a_index':[0,2,0,2,2], 'a_value':[107,72,500,121,65]});
-- → {"status":"Optimal","objective":3.15,"model_status":7,"solution":[1.9444,10,10]}
```

### MILP：同题加整数约束（面包必须整份）

加 `'integrality':[1,1,1]`（0=连续 1=整数）→ `{objective:3.16, solution:[2,10,10]}`。

### QP：min 0.5·(x1²+x2²)  s.t. x1+x2=1

Hessian 下三角列压缩 `q_start/q_index/q_value`：

```sql
SELECT luajit_s('highs', {'op':'qp', 'sense':'min',
  'col_cost':[0,0], 'col_lower':[0,0], 'col_upper':[1e30,1e30],
  'row_lower':[1], 'row_upper':[1],
  'a_start':[0,1,2], 'a_index':[0,0], 'a_value':[1,1],
  'q_start':[0,1,3], 'q_index':[0,0,1], 'q_value':[1,0,1]});
-- → {"status":"Optimal","objective":0.25,"model_status":7,"solution":[0.5,0.5]}
```

### 结果解析（DuckDB 原生）

```sql
SELECT * FROM from_json(
  luajit_s('highs', {'op':'lp', ...}),
  '{"status":"VARCHAR","objective":"DOUBLE","solution":"DOUBLE[]"}');
```

## 参数格式

`luajit_s('highs', {...})` 的 STRUCT 字段：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `op` | VARCHAR | ✅ | `'lp'` / `'mip'` / `'qp'` |
| `sense` | VARCHAR | | `'min'`（默认）/ `'max'` |
| `col_cost` | DOUBLE[] | ✅ | 目标系数 |
| `col_lower` / `col_upper` | DOUBLE[] | | 变量界（缺省 0 / +inf） |
| `row_lower` / `row_upper` | DOUBLE[] | ✅* | 约束界（相等约束 = 上下界相同；无约束行传空数组） |
| `a_start` / `a_index` / `a_value` | INT[]/DOUBLE[] | ✅* | 约束矩阵 **压缩稀疏列格式**（CSC，`a_start` 长度 = 列数+1） |
| `integrality` | INT[] | mip | 每列 0/1 |
| `q_start` / `q_index` / `q_value` | INT[]/DOUBLE[] | qp | Hessian **下三角** CSC |
| `offset` | DOUBLE | | 目标常数项 |

\* 有约束行时必须给；无约束（仅变量界）可省略矩阵。

返回 JSON：`{"status":..., "model_status":..., "objective":..., "solution":[...]}`。
`status` 为 `Optimal` / `Infeasible` / `Unbounded` / `TimeLimit` 等（HiGHS model status
映射）；`model_status` 为原始整数码（7=Optimal）。

## 验证记录（2026-08-17，duckdb v1.5.5 + HiGHS 1.10.0）

| 用例 | 类型 | 结果 | 对拍 |
|---|---|---|---|
| 饮食问题 | LP | obj=3.15, x=[1.9444,10,10] | MATLAB 官方示例一致 |
| 饮食问题+整数 | MILP | obj=3.16, x=[2,10,10] | 手算一致 |
| 运输问题 3×3 | LP | obj=1510, 约束全满足 | HiGHS CLI 独立对拍一致 |
| 0.5·(x1²+x2²), x1+x2=1 | QP | obj=0.25, x=[0.5,0.5] | 解析解一致 |
| max 3x1+2x2, x1+x2≤4 | LP max | obj=10, x=[2,2] | 手算一致 |

## 设计要点

- 只做「建模 → 求解 → 结果序列化」，矩阵组装交给 SQL（LIST 聚合构造 CSC 稀疏矩阵），
  Lua 层保持薄胶水，算法全在 HiGHS
- `ffi.cdef` 只声明用到的三个 Call 接口（`Highs_lpCall`/`Highs_mipCall`/`Highs_qpCall`）；
  需高级功能（灵敏度分析、callback、option 设置）可扩展 `Highs_create`/`Highs_run` 系列
- HiGHS `Call` 接口不返回目标值 → Lua 侧自行计算（LP 线性项 + QP 二次项 0.5·x'Qx）
- 结果用自包含极简 JSON encode（零依赖，不 require parser/json）
- 注意：QP 的 `q_start` 是 **INT[]**（与 `a_start` 同型），且 `Highs_qpCall` 比
  `Highs_lpCall` 多 2 个 basis status 参数——cdef 签名必须与头文件逐字一致（段错误教训）
