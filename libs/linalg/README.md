# libs/linalg/linalg — 数值线性代数（OpenBLAS/LAPACK 内核）

在 SQL 里做**矩阵运算与分解**——LuaJIT FFI 直调系统 OpenBLAS
（`libopenblas.so`，含完整 LAPACK），无 Python、无 numpy、无绑定代码。

> duckdb-luajit 系列第二个"FFI 直调工业级 C 库" lib（第一个是
> [libs/optimize/highs](../optimize/README.md)）。LAPACK 是 40 年工业标准，
> MATLAB/R/numpy 的矩阵分解底层就是它。

## 依赖

**libopenblas.so（含 LAPACK）**。Debian/Ubuntu：

```bash
sudo apt install libopenblas-dev   # 通常系统已装 libopenblas.so.0
```

macOS：`brew install openblas`。找不到库时设 `LUALINALG_LIB` 指向完整路径。

## 用法

```sql
LOAD luajit;
SELECT * FROM luajit_module(mode := 'install', sql_name := 'linalg');
```

矩阵传参 = **扁平行主序 DOUBLE[] + m/n 维度**（luajit_s 不支持嵌套 LIST）：

```sql
-- matmul: [[1,2],[3,4]] × [[5,6],[7,8]] = [[19,22],[43,50]]
SELECT luajit_s('linalg', {'op':'matmul', 'a':[1,2,3,4], 'm':2, 'n':2,
                           'b':[5,6,7,8], 'mb':2, 'nb':2});
-- → {"c":[19,22,43,50]}

-- SVD: [[1,2],[3,4]] → σ=[5.465,0.366]
SELECT luajit_s('linalg', {'op':'svd', 'a':[1,2,3,4], 'm':2, 'n':2});
-- → {"s":[5.465,0.366],"u":[...],"vt":[...],"dims":[2,2]}

-- 对称特征值: [[2,1],[1,2]] → λ=[1,3]
SELECT luajit_s('linalg', {'op':'eigh', 'a':[2,1,1,2], 'm':2, 'n':2});
-- → {"w":[1,3],"v":[...]}  （v 列 = 特征向量）
```

结果同样为扁平行主序数组（`dims` 给出实际行列），配合 DuckDB 原生
`unnest`/`from_json` 还原矩阵。

## 算子一览

| op | 输入 | 输出 | LAPACK 例程 |
|---|---|---|---|
| `matmul` | a(m×n), b(mb×nb) | c=[...] | cblas_dgemm |
| `svd` | a(m×n) | s/u/vt/dims（thin，`thin:false` 全尺寸） | dgesvd |
| `eigh` | a(n×n 对称) | w（升序）/v（列=特征向量） | dsyevd |
| `inv` | a(n×n) | inv=[...] | dgetrf+dgetri |
| `lu` | a(m×n) | lu（原位）/ipiv | dgetrf |
| `chol` | a(n×n 对称正定) | chol=[...]（上三角） | dpotrf |
| `qr` | a(m×n) | q/r（thin QR） | dgeqrf+dorgqr |
| `norm` | v 向量 / v+m+n 矩阵 | norm（2 范数/Frobenius） | cblas_dnrm2 |

错误返回 `{"status":"Error","message":...}`（含 LAPACK info 码：正数=第 k 个
对角元位置，负数=第 |k| 个参数非法）。

## 验证记录（2026-08-17，duckdb v1.5.5 + OpenBLAS 0.3.26）

| 用例 | 结果 | 对拍 |
|---|---|---|
| matmul 2×2 | [19,22,43,50] | 手算 ✓ |
| svd [[1,2],[3,4]] | σ=[5.4650,0.3660] | numpy.linalg.svd（±1e-15）✓ |
| svd 3×2 [[1,0],[0,1],[1,0]] | σ=[√2,1]，U·Σ·Vt 还原 A | 解析 ✓ |
| eigh [[2,1],[1,2]] | λ=[1,3] | 解析 ✓ |
| inv [[4,7],[2,6]] | [0.6,-0.7,-0.2,0.4] | 手算 ✓ |
| lu [[4,3],[6,3]] | ipiv=[2,2] | LAPACK 约定 ✓ |
| chol [[4,2],[2,3]] | [2,1,0,√2] | 解析 ✓ |
| qr [[1,1],[1,-1]] | Q·R=A | 解析 ✓ |
| norm | √30 / 5 | 手算 ✓ |

## 设计要点 / 坑

- **LAPACK 是列主序**（Fortran ABI）：行主序输入必须转列主序再调，输出再转回
  —— `col_major_from_flat`/`flat_from_col_major` 封装。**忘了转 SVD 就错**
  （2×2 因 A 与 Aᵀ 奇异值相同而侥幸通过，3×2 立即暴露——教训：锚定用例必须
  覆盖非方阵）
- Fortran ABI 字符参数（`'S'/'A'/'U'`）在 FFI 声明为 `const char*`，Lua 传字符串
- LAPACK 惯例 **lwork=-1 两段式查询** workspace 长度
- `dgesvd_` 的 `ldu/ldvt` 也要传指针（int[1]），不是值
- workspace 上限场景（超大型矩阵）可用 `dgesdd_` 替代（更快但内存更多）
- 与 duckdb-ml 的 PCA 不重叠：这里是通用矩阵算子层，PCA 是上层应用
