# libs/ffi/sudoku — Sudoku solver in C and Rust (FFI comparison)

Same bitmask-constraints + MRV algorithm as [`libs/mcp/sudoku.lua`](../../mcp/sudoku.lua)
v2, reimplemented in C and Rust to demonstrate **LuaJIT FFI** from duckdb-luajit:
load a compiled `.so` via `ffi.load` and call it directly from a Lua UDF.

> Not part of the INDEX: these are **source files**, not Lua libs — the `install`
> protocol compiles `.lua` chunks and would reject C/Rust source. Compile to `.so`
> first, then load by path with `ffi.load`.

## Files

| File | Language | C ABI symbol | Build |
|---|---|---|---|
| `sudoku_solve.c` | C | `int sudoku_solve(const char *p, char *out)` | `gcc -O3 -shared -fPIC -o libsudoku_c.so sudoku_solve.c` |
| `sudoku_solve.rs` | Rust (cdylib) | `int sudoku_solve(const char *p, char *out)` | `rustc --edition 2021 -O --crate-type cdylib -o libsudoku_rs.so sudoku_solve.rs` |

Both take an 81-char puzzle (`0` = empty) and write the 81-char solution into a
caller-provided buffer (≥ 82 bytes, NUL-terminated). Return `1` on success, `0` otherwise.

## Use from duckdb-luajit

```sql
LOAD 'path/to/luajit.duckdb_extension';

-- Register a UDF wrapping the C solver via FFI
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'sudoku_c', source := '
return function(p)
  local ffi = require("ffi")
  ffi.cdef[[ int sudoku_solve(const char *p, char *out); ]]
  local lib = ffi.load("/absolute/path/to/libsudoku_c.so")
  local buf = ffi.new("char[82]")
  local rc = lib.sudoku_solve(p, buf)
  if rc ~= 1 then return NULL end
  return ffi.string(buf)
end
');

SELECT luajit_s('sudoku_c', '000001002000020030004500600007600050080090006100005800001004000070900003400030020');
-- → 359461782716829534824573619947682351583197246162345897631254978275918463498736125
```

Swap `libsudoku_c.so` → `libsudoku_rs.so` for the Rust build — the FFI cdef is identical.

## Benchmark (2026-08-08, sudoku17 dataset, same 100-puzzle set, single-process)

| Implementation | ms/puzzle (mixed 100) | ms/puzzle (hardest 20) | Solved |
|---|---|---|---|
| Lua v2 (`libs/mcp/sudoku.lua`) | 0.131 | 0.205 | 100/100 |
| **C** (`sudoku_solve.c`, gcc -O3) | **0.019** | **0.021** | 100/100 |
| Rust (`sudoku_solve.rs`, cdylib) | 0.021 | 0.022 | 100/100 |

- C and Rust are ~7× faster than the Lua v2 reference; C and Rust are at parity.
- Correctness: all three implementations produce identical output on the anchor
  puzzle and solve 100/100 sudoku17 puzzles (verified by row/col/box rules).
- Lua v2 stays the default library: zero compile deps, cross-platform,
  `install`-able. These C/Rust builds are the FFI demonstration layer.

## Notes

- LuaJIT `ffi.load` dlopens the shared object; the UDF above loads it per call —
  for hot loops hoist `ffi.load` into a module-level table (`local lib = ...` in
  the module body, not inside the function).
- macOS: build with `cc -O3 -shared -fPIC -o libsudoku_c.dylib sudoku_solve.c` /
  `rustc --crate-type cdylib -o libsudoku_rs.dylib sudoku_solve.rs` and load the
  `.dylib` path. Windows: MSVC DLL export requires `extern "C"` + a `.def`/`dllexport`
  (not provided here).
