# duckdb-luajit-libs

A library repo for DuckDB: **load Lua functions/table functions from a repo with one SQL statement** — no compilation, no `INSTALL` extension.

Works with [duckdb-luajit](https://github.com/alitrack/duckdb-luajit). Formats DuckDB cannot read (long-tail / private / niche) live here as Lua libraries — tens of lines each, minute-level PRs.

中文版说明见 [README_cn.md](README_cn.md).

## Categories

| Directory | Purpose | Examples |
|---|---|---|
| `libs/datasource/` | **Data sources** — read files/dirs/formats DuckDB cannot | dicom (medical imaging), dirscan (directory metadata) |
| `libs/export/` | **Export** — stored-procedure style COPY export (query/table → parquet/csv/json) | export (one COPY TO in Lua) |
| `libs/parser/` | **Parsers** — data structures / text (JSON/CSV/XML…) | json (vendored rxi/json.lua) |
| `libs/udf/` | **Scalar UDFs** — algorithms / encodings / math / string | base64, crc32, uuid, html_escape |
| `libs/network/` | **Network/API** — HTTP / signed / private API data sources | (planned: signed-api, http fetch) |
| `libs/ffi/` | **FFI bindings** — system C libraries (dcmtk/open62541…) | (planned: needs extern "C" or pure-C lib) |

## Library Index

| Library | Category | Description | Deps |
|---|---|---|---|
| `libs/datasource/dicom.lua` | datasource | DICOM medical imaging 19 tags (Explicit VR LE) | none |
| `libs/datasource/dirscan.lua` | datasource | Directory scan: file types + EXIF (camera/time) + PDF /Info | none |
| `libs/export/export.lua` | export | Stored-procedure export: `export({query\|tbl, file, format})` → COPY TO parquet/csv/json | none (needs normal mode, `_duckdb_call`) |
| `libs/parser/json.lua` | parser | JSON parse/encode ([rxi/json.lua](https://github.com/rxi/json.lua), MIT) | none |
| `libs/udf/base64.lua` | udf | Base64 codec (vendored [iskolbin/lbase64](https://github.com/iskolbin/lbase64) v1.5.3, public domain) | none |
| `libs/udf/crc32.lua` | udf | CRC-32 checksum (IEEE 802.3, 8-digit uppercase hex) | LuaJIT bit |
| `libs/udf/uuid.lua` | udf | UUID v4 generation (math.random, non-crypto) | LuaJIT bit |
| `libs/udf/html_escape.lua` | udf | HTML entity escape/unescape | none |

## One-SQL Install Protocol (v0.31+ recommended: `install` / `list_remote`)

duckdb-luajit **v0.31+ has built-in package management** — `luajit_module` gained `install` / `list_remote` modes: fetch libs from this repo via the INDEX, cache to `~/.duckdb/luajit-libs/`, auto-register. No hand-written fetch SQL:

```sql
LOAD 'luajit';

-- 0. List available libs (INDEX protocol, cached automatically)
SELECT * FROM luajit_module(mode := 'list_remote');
-- → available libs: dicom / dirscan / export / json / base64 / crc32 / uuid / html_escape

-- 1. Install & register with one statement (scalar UDFs callable right away)
SELECT * FROM luajit_module(mode := 'install', sql_name := 'base64');
-- → installed 'base64' (UDF) — cached at ~/.duckdb/luajit-libs/base64.lua

-- 2. Use it immediately (registered name, no source)
SELECT luajit_s('base64', 'hello');  -- → aGVsbG8=

-- Table-function libs (dicom/dirscan) work as source right after install
SELECT * FROM luajit_table('dicom', list := '<file path>');
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
