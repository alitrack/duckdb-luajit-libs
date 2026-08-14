# libs/ffi/sudoku — C 与 Rust 版数独求解器（FFI 对比演示）

与 [`libs/mcp/sudoku.lua`](../../mcp/sudoku.lua) v2 同算法（位图约束 + MRV），
分别用 C 和 Rust 重写，演示 duckdb-luajit 的 **LuaJIT FFI** 能力：
编译 `.so` 后用 `ffi.load` 在 Lua UDF 里直接调用。

> **不进入 INDEX**：这两个是**源码**，不是 Lua 库——`install` 协议只编译 `.lua`
> 块，C/Rust 源码会被拒绝。先编译成 `.so`，再用 `ffi.load` 按路径加载。

## 文件

| 文件 | 语言 | C ABI 符号 | 编译 |
|---|---|---|---|
| `sudoku_solve.c` | C | `int sudoku_solve(const char *p, char *out)` | `gcc -O3 -shared -fPIC -o libsudoku_c.so sudoku_solve.c` |
| `sudoku_solve.rs` | Rust (cdylib) | 同上 | `rustc --edition 2021 -O --crate-type cdylib -o libsudoku_rs.so sudoku_solve.rs` |
| `demo_tcc_embed.lua` | LuaJIT + libtcc | — | 运行时编译,不需要 gcc(见下文) |
| `demo_tcc_in_duckdb.sql` | SQL + libtcc | — | 扩展内运行时编译(见下文) |
| `demo_tcc_inline.lua` | LuaJIT + libtcc | — | **C 源码直接内嵌**在 Lua 字符串,自包含 |
| `demo_tcc_inline_in_duckdb.sql` | SQL + libtcc | — | **C 源码直接内嵌**,自包含、可 install |
| `gen_inline.lua` | 生成器 | — | 从 `sudoku_solve.c` 重新生成两个 inline demo |
| `bench_four.lua` | 基准 | — | 五方式同题基准(Lua/gcc/tcc-so/TCC内存/Rust) |

两者都接收 81 位题目串（`0`=空），把 81 位解写入调用方提供的缓冲区
（≥82 字节，NUL 结尾）。成功返回 `1`，无解/非法输入返回 `0`。

## 在 duckdb-luajit 中使用

```sql
LOAD 'path/to/luajit.duckdb_extension';

-- 注册包装 C 求解器的 UDF（FFI）
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'sudoku_c', source := '
return function(p)
  local ffi = require("ffi")
  ffi.cdef[[ int sudoku_solve(const char *p, char *out); ]]
  local lib = ffi.load("/绝对路径/libsudoku_c.so")
  local buf = ffi.new("char[82]")
  local rc = lib.sudoku_solve(p, buf)
  if rc ~= 1 then return NULL end
  return ffi.string(buf)
end
');

SELECT luajit_s('sudoku_c', '000001002000020030004500600007600050080090006100005800001004000070900003400030020');
-- → 359461782716829534824573619947682351583197246162345897631254978275918463498736125
```

Rust 版把 `libsudoku_c.so` 换成 `libsudoku_rs.so` 即可——FFI cdef 完全一样。

## 没有 gcc?用 TCC 运行时编译,零预编译产物

上面 gcc 路线要求本机有 C 工具链。如果目标机器**没有 gcc**、但装了 libtcc
(`sudo apt install tcc`,或源码装到 `~/.local/tcc`),可以**在运行时把
`sudoku_solve.c` 编译进内存**——磁盘上不需要任何 `.so`:

```bash
# 快速验证(只用 LuaJIT,不需要 DuckDB):
cd <LuaJIT>/third_party/LuaJIT/src
./luajit <repo>/libs/ffi/sudoku/demo_tcc_embed.lua
# → compile+relocate: OK / solve MATCH ✓ / 约 0.9 ms/题

# DuckDB 全链路(在 luajit_module 内部编译并注册 UDF):
duckdb -unsigned < <repo>/libs/ffi/sudoku/demo_tcc_in_duckdb.sql
```

机制:`ffi.load("libtcc.so")` → `tcc_compile_string` → `tcc_relocate` →
`tcc_get_symbol` → 把符号 cast 成 C 函数指针直接调用。完整带注释的示例见
`demo_tcc_embed.lua`。

**完全内嵌变体(C 源码直接嵌在字符串里)**:两个 `demo_tcc_inline*` 文件把整个
C 源码直接内嵌进 Lua/SQL 字符串——运行时**不读 .c 文件、不产 .so**,完全自包含,
扩展内嵌版甚至能走 `install` 协议:

```bash
# 从 sudoku_solve.c 重新生成两个 inline demo(单一事实来源):
./luajit <repo>/libs/ffi/sudoku/gen_inline.lua
# 验证:
./luajit <repo>/libs/ffi/sudoku/demo_tcc_inline.lua
duckdb -unsigned < <repo>/libs/ffi/sudoku/demo_tcc_inline_in_duckdb.sql
```

注意事项:
- **性能**:TCC 生成的代码比 gcc -O3 慢约 5 倍,且**与纯 Lua v2 基本持平**
  (2026-08-14 同题循环实测:Lua v2 0.98 ms / tcc .so 0.90 ms / gcc .so 0.16 ms)。
  所以没有 gcc 时,**纯 Lua `libs/mcp/sudoku.lua` 才是务实默认**——零工具链、
  可 `install`、速度一样。TCC 路线的价值是 FFI 演示本身(运行时编译 C),不是速度。
- `ffi.cdef` 里不能写 `#define`,常量直接写数字
  (`TCC_OUTPUT_MEMORY = 1`;relocate 传 `ffi.cast("void*", 1)`)。
- libtcc 0.9.27 不会自动搜系统 include 目录:必须经 `tcc_set_options` 传
  `-I<前缀>/lib/tcc/include`,`tcc_set_lib_path` 指 `<前缀>/lib`。
- 整个编译放模块 body 只做一次,函数指针缓存,不要每次调用都编译。

## 基准（2026-08-08 实测，sudoku17 数据集，同 100 题集，单进程）

| 实现 | ms/题（混合 100） | ms/题（最难 20） | 解出 |
|---|---|---|---|
| Lua v2（`libs/mcp/sudoku.lua`） | 0.131 | 0.205 | 100/100 |
| **C**（`sudoku_solve.c`，gcc -O3） | **0.019** | **0.021** | 100/100 |
| Rust（`sudoku_solve.rs`，cdylib） | 0.021 | 0.022 | 100/100 |

- C/Rust 比 Lua v2 快约 **7 倍**；C 与 Rust 基本持平。
- 正确性：三实现锚点输出一致，sudoku17 100/100 全解（行列块规则验证）。
- 默认库仍是 Lua v2：零编译依赖、跨平台、可 `install`。C/Rust 版是 FFI 演示层。

## 基准（2026-08-14 同题循环，统一口径）

同一锚点题、每方式循环 5000 次、预热 200 次、单进程、单脚本（`bench_four.lua`）：

| 方式 | ms/题 | vs Lua v2 |
|---|---|---|
| 1. 纯 Lua v2（`libs/mcp/sudoku.lua`） | 0.976 | 1.00× |
| 2. gcc -O3 预编译 `.so` | 0.166 | **5.9×** |
| 3. tcc -shared 编译 `.so` | 0.905 | 1.08× |
| 4. TCC 内存编译（inline） | 0.893 | 1.09× |
| 5. Rust cdylib | 0.190 | 5.1× |

结论：
- gcc -O3 与 Rust 是第一梯队（约为纯 Lua 的 5–6 倍）。
- TCC 生成的代码（.so 和内存编译都一样）与纯 Lua 基本持平——**TCC 路线是能力演示
  （运行时编译 C），不是性能优势**。
- 没有 gcc 工具链时,务实默认就是纯 Lua v2：零依赖、和 TCC 编译的 C 一样快、可 install。

下表是更早的 sudoku17 混合题集基准，题集难度不同，绝对 ms/题 数值不可直接比，
但相对排序一致。

## 备注

- LuaJIT `ffi.load` 是 dlopen；上面 UDF 每次调用都加载——热循环应把
  `ffi.load` 提升到模块级 table（函数体外的模块 body 里 `local lib = ...`）。
- macOS：`cc -O3 -shared -fPIC -o libsudoku_c.dylib ...`，加载 `.dylib` 路径；
  Windows：MSVC DLL 导出需 `extern "C"` + `.def`/`dllexport`（本目录未提供）。
