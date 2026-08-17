# duckdb-luajit-libs

A library repo for DuckDB: **load Lua functions/table functions from a repo with one SQL statement** — no compilation, no `INSTALL` extension.

Works with [duckdb-luajit](https://github.com/alitrack/duckdb-luajit). Formats DuckDB cannot read (long-tail / private / niche) live here as Lua libraries — tens of lines each, minute-level PRs.

中文版说明见 [README_cn.md](README_cn.md).

## Categories

| Directory | Purpose | Examples |
|---|---|---|
| `libs/datasource/` | **Data sources** — read files/dirs/formats DuckDB cannot | dicom (medical imaging), dirscan (directory metadata) |
| `libs/export/` | **Export** — stored-procedure style COPY export (query/table → parquet/csv/json) | export (one COPY TO in Lua) |
| `libs/etl/` | **ETL flow layer** — audit log, idempotent load validation, error self-healing, componentized SQL | etl (audit/validate/safe/q) |
| `libs/parser/` | **Parsers** — data structures / text (JSON/CSV/XML…) | json (vendored rxi/json.lua) |
| `libs/udf/` | **Scalar UDFs** — algorithms / encodings / math / string | base64, crc32, uuid, html_escape |
| `libs/network/` | **Network/API** — HTTP / signed / private API data sources | (planned: signed-api, http fetch) |
| `libs/optimize/` | **Optimization** — LP/QP/MILP solvers (HiGHS via FFI) | highs (diet problem demo) |
| `libs/linalg/` | **Linear algebra** — matmul/SVD/eigh/inv/LU/chol/QR (LAPACK/OpenBLAS via FFI) | linalg |
| `libs/ffi/` | **FFI bindings** — system C libraries (dcmtk/open62541…) / compiled solvers | sudoku (C/Rust solver, ~7× faster than Lua reference, [libs/ffi/sudoku](libs/ffi/sudoku/README.md)) |
| `libs/mcp/` | **MCP integration** — DuckDB as MCP server exposing Lua UDFs as tools to AI assistants | mcp-server (sudoku_solve demo) |

## Library Index

| Library | Category | Description | Deps |
|---|---|---|---|
| `libs/datasource/dicom.lua` | datasource | DICOM medical imaging 19 tags (Explicit VR LE) | none |
| `libs/datasource/dirscan.lua` | datasource | Directory scan: file types + EXIF (camera/time) + PDF /Info | none |
| `libs/export/export.lua` | export | Stored-procedure export: `export({query\|tbl, file, format})` → COPY TO parquet/csv/json | none (needs normal mode, `_duckdb_call`) |
| `libs/parser/json.lua` | parser | JSON parse/encode ([rxi/json.lua](https://github.com/rxi/json.lua), MIT) | none |
| `libs/parser/id3.lua` | parser | MP3 ID3v2 tag parser (TIT2/TPE1/TALB/TYER/TRCK/TCON; ISO-8859-1/UTF-16/UTF-8) — table-mode: file list → flat rows | none |
| `libs/parser/zip_list.lua` | parser | ZIP central-directory file listing (name\|method\|compressed\|size\|CRC32), no extraction — table-mode | none |
| `libs/udf/base64.lua` | udf | Base64 codec (vendored [iskolbin/lbase64](https://github.com/iskolbin/lbase64) v1.5.3, public domain) | none |
| `libs/udf/crc32.lua` | udf | CRC-32 checksum (IEEE 802.3, 8-digit uppercase hex) | LuaJIT bit |
| `libs/udf/uuid.lua` | udf | UUID v4 generation (math.random, non-crypto) | LuaJIT bit |
| `libs/udf/html_escape.lua` | udf | HTML entity escape/unescape | none |
| `libs/mcp/` (mcp-server.sql + sudoku.lua) | mcp | DuckDB as MCP server exposing Lua UDFs to AI (duckdb_mcp + luajit) | duckdb_mcp ext |
| `libs/mcp/sudoku.lua` | mcp | Sudoku solver (81-char puzzle → solution, anchor-verified) — module-table lib: install then `compile` a wrapper UDF | none |
| `libs/optimize/highs.lua` | optimize | LP/QP/MILP solver via LuaJIT FFI → [HiGHS](https://github.com/ERGO-Code/HiGHS) (MIT, default LP/MIP solver in SciPy/MATLAB) — `{'op':'lp'\|'mip'\|'qp', ...}` → JSON result; diet/transport/QP anchor-verified vs CLI & hand-solved | libhighs.so (build-time, `LUAJIT_HIGHS_LIB` to override) |
| `libs/linalg/linalg.lua` | linalg | Linear algebra via LuaJIT FFI → system LAPACK/OpenBLAS (40-yr industry standard, same kernels as MATLAB/R/numpy) — `matmul`/`svd`/`eigh`/`inv`/`lu`/`chol`/`qr`/`norm`, flat row-major `DOUBLE[]`+m/n in → flat out; 10 anchored cases incl. 3×2 SVD (U·Σ·Vᵀ=A) | libopenblas.so (system, `LUALINALG_LIB` to override) |
| `libs/ffi/sudoku/` (sudoku_solve.c/.rs + README) | ffi | Same solver in C/Rust via LuaJIT FFI (`ffi.load`), ~7× faster than Lua reference — source, not INDEX-installable; compile `.so` then load by path | gcc/rustc (build-time) |
| `libs/etl/etl.lua` | etl | ETL flow layer: audit log (`etl.log`/`etl.run`), idempotent load validation (`etl.validate`), error self-healing (`etl.safe`/`etl.insert_auto`), componentized SQL (`etl.q`/`etl.query`) — needs normal mode (non-trusted) for `_duckdb_call`/`_duckdb_query` | none |

## One-SQL Install Protocol (v0.31+ recommended: `install` / `list_remote`)

duckdb-luajit **v0.31+ has built-in package management** — `luajit_module` gained `install` / `list_remote` modes: fetch libs from this repo via the INDEX, cache to `~/.duckdb/luajit-libs/`, auto-register. No hand-written fetch SQL:

```sql
LOAD 'luajit';

-- 0. List available libs (INDEX protocol, cached automatically)
SELECT * FROM luajit_module(mode := 'list_remote');
-- → available libs: dicom / dirscan / export / json / base64 / crc32 / uuid / html_escape / sudoku

-- 1. Install & register with one statement (scalar UDFs callable right away)
SELECT * FROM luajit_module(mode := 'install', sql_name := 'base64');
-- → installed 'base64' (UDF) — cached at ~/.duckdb/luajit-libs/base64.lua

-- 2. Use it immediately (registered name, no source)
SELECT luajit_s('base64', 'hello');  -- → aGVsbG8=

-- Table-function libs (dicom/dirscan) work as source right after install
SELECT * FROM luajit_table('dicom', list := '<file path>');

-- Module-table libs (e.g. sudoku): install registers the global module,
-- then wrap it with a one-liner UDF before calling:
SELECT * FROM luajit_module(mode := 'install', sql_name := 'sudoku');
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'sudoku_solve',
  source := 'return function(x) return sudoku.solve(x) end');
SELECT luajit_s('sudoku_solve',
  '000001002000020030004500600007600050080090006100005800001004000070900003400030020');
-- → 359461782716829534824573619947682351583197246162345897631254978275918463498736125

-- ETL flow layer (module-table lib, needs normal mode for _duckdb_call/_duckdb_query):
SELECT * FROM luajit_module(mode := 'install', sql_name := 'etl');
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'etl_demo',
  source := 'return function(x) etl.init(); etl.log(1, ''demo'', ''{"k":"v"}'', 3, 1, true, nil); return etl.validate(''t_src'', ''throw_if_empty'') end');
```

> **v0.30 and earlier**: the `quick_compile` protocol (removed) — `SET VARIABLE src = (SELECT content FROM read_text('https://raw.githubusercontent.com/alitrack/duckdb-luajit-libs/main/libs/<cat>/<lib>.lua'))` + `luajit_module(mode := 'quick_compile', sql_name := 'x', source := getvariable('src'))`.

## Contributing a Library (categorization rules)

1. **Pick the right category**: data source (reads external data) → `datasource/`; data-structure parsing → `parser/`;
   scalar functions → `udf/`; network/API → `network/`; C library bindings → `ffi/`
2. **Header metadata** (`-- @key: value`, fixed format, scanned by future index tooling):
   `@lib` (name) / `@category` / `@desc` (one-liner) / `@source` (original or vendored URL+license) / `@requires` (deps)
3. Pure Lua, single file, zero external deps (or vendored into the lib with source noted)
4. Library ends with `return function(...)` (luajit_module call convention)
5. Open a PR — once merged, it is loadable via `install` / `list_remote`

## Boundaries (honest)

- **Pure-Lua libs work directly**; C-dependent ones (lpeg/luasocket/lua-cjson) need an FFI bridge or a
  system .so — prefer pure-Lua alternatives (e.g. json uses rxi pure-Lua, not lua-cjson)
- Install protocol = `install`/`list_remote` (built-in package management, INDEX + local cache); dependency management (require chains)
  relies on the "single self-contained file" convention
