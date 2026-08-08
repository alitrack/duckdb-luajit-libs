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

## 基准（2026-08-08 实测，sudoku17 数据集，同 100 题集，单进程）

| 实现 | ms/题（混合 100） | ms/题（最难 20） | 解出 |
|---|---|---|---|
| Lua v2（`libs/mcp/sudoku.lua`） | 0.131 | 0.205 | 100/100 |
| **C**（`sudoku_solve.c`，gcc -O3） | **0.019** | **0.021** | 100/100 |
| Rust（`sudoku_solve.rs`，cdylib） | 0.021 | 0.022 | 100/100 |

- C/Rust 比 Lua v2 快约 **7 倍**；C 与 Rust 基本持平。
- 正确性：三实现锚点输出一致，sudoku17 100/100 全解（行列块规则验证）。
- 默认库仍是 Lua v2：零编译依赖、跨平台、可 `install`。C/Rust 版是 FFI 演示层。

## 备注

- LuaJIT `ffi.load` 是 dlopen；上面 UDF 每次调用都加载——热循环应把
  `ffi.load` 提升到模块级 table（函数体外的模块 body 里 `local lib = ...`）。
- macOS：`cc -O3 -shared -fPIC -o libsudoku_c.dylib ...`，加载 `.dylib` 路径；
  Windows：MSVC DLL 导出需 `extern "C"` + `.def`/`dllexport`（本目录未提供）。
