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
| `demo_tcc_embed.lua` | LuaJIT + libtcc | — | runtime compile, no gcc needed (see below) |
| `demo_tcc_in_duckdb.sql` | SQL + libtcc | — | runtime compile inside the extension (see below) |

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

## No gcc? No problem — build with TCC at runtime

The gcc route above requires a C toolchain. If the target machine has **no gcc**
(but has a `libtcc`, e.g. `sudo apt install tcc` or a local build under
`~/.local/tcc`), you can compile `sudoku_solve.c` **at runtime, in memory**,
with zero pre-built artifacts — no `.so` on disk at all:

```bash
# Quick check (LuaJIT only, no DuckDB needed):
cd <LuaJIT>/third_party/LuaJIT/src
./luajit <repo>/libs/ffi/sudoku/demo_tcc_embed.lua
# → compile+relocate: OK / solve MATCH ✓ / ~0.9 ms/puzzle

# Full DuckDB E2E (compiles inside luajit_module, registers a UDF):
duckdb -unsigned < <repo>/libs/ffi/sudoku/demo_tcc_in_duckdb.sql
```

The mechanism: `ffi.load("libtcc.so")` → `tcc_compile_string` → `tcc_relocate` →
`tcc_get_symbol` → cast the symbol to a C function pointer and call it. See
`demo_tcc_embed.lua` for the complete annotated recipe.

Caveats:
- **Performance**: TCC-generated code is ~5× slower than gcc -O3, and roughly
  *at parity with the pure-Lua v2 solver* (same-puzzle loop, 2026-08-14:
  Lua v2 0.98 ms / tcc .so 0.90 ms / gcc .so 0.16 ms). So if you lack gcc,
  the pure-Lua `libs/mcp/sudoku.lua` is the pragmatic default — no toolchain,
  `install`-able, just as fast. The TCC route's value is the FFI demo itself
  (runtime C compilation), not speed.
- `ffi.cdef` cannot contain `#define`; pass numeric constants directly
  (`TCC_OUTPUT_MEMORY = 1`, `TCC_RELOCATE_AUTO = (void*)1` → `ffi.cast("void*", 1)`).
- libtcc 0.9.27 does not search system include dirs on its own: pass
  `-I<prefix>/lib/tcc/include` via `tcc_set_options`, and point
  `tcc_set_lib_path` at `<prefix>/lib`.
- Hoist the whole compile into the module body once; do not recompile per call.

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
