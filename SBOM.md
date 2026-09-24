# SBOM — duckdb-luajit-libs

Generated 2026-09-24 by `scripts/gen_sbom.py` (idempotent; regenerate after lib changes).

48 distributable libraries. Project license: **MIT** (see LICENSE).

## Vendored / third-party components

| Component | Library | License | Origin |
|---|---|---|---|
| `usql` | libs/db/usql.lua | MIT (alitrack/usql-bridge + original) | alitrack/usql-bridge（Go 桥，MIT）+ 本 FFI 桥（original） |
| `classifier` | libs/ml/classifier.lua | MIT OR Apache-2.0 (Rust cdylib, sources in repo) | libclassifier_capi.so（Rust cdylib, MIT/Apache 2.0, ~770KB，源码 |
| `epub` | libs/parser/epub.lua | MIT (duckdb-luajit-libs project) | 自包含（zip/inflate 逐字移植自 libs/parser/unzip.lua；XML 抽取参考 xml.lua 思路） |
| `json` | libs/parser/json.lua | MIT (vendored rxi/json.lua, rxi 2020) | vendored https://github.com/rxi/json.lua (MIT, rxi 2020) |
| `rng` | libs/stats/rng.lua | MIT OR Apache-2.0 (Rust cdylib, sources in repo) | librng_capi.so（Rust cdylib, MIT/Apache 2.0, 554KB） |
| `base64` | libs/udf/base64.lua | public domain (vendored iskolbin/lbase64, 2017) | vendored https://github.com/iskolbin/lbase64 (public domain, iskolbin 2017) |
| `pinyin` | libs/udf/pinyin.lua | MIT (vendored pinyin-data dictionary, mozillazg) | vendored 词典 https://github.com/mozillazg/pinyin-data → pypinyin |
| `qr` | libs/udf/qr.lua | MIT (algorithm layout) / Apache-2.0 (Nayuki QR generator) | 布局移植自 python-qrcode(MIT) 与 Nayuki QR Code generator(Apache-2.0) 的公开算法 |

## System dependencies (interface-only, NOT distributed)

| Component | License | Note |
|---|---|---|
| OpenBLAS/LAPACK | BSD-3-Clause (OpenBLAS) | libs/linalg/linalg.lua links at runtime via FFI; not distributed here |
| HiGHS | MIT | libs/optimize/highs.lua links at runtime via FFI; not distributed here |

## Full inventory

| Lib | Category | Path | SHA-256 | License | Requires |
|---|---|---|---|---|---|
| `dicom` | datasource | `libs/datasource/dicom.lua` | `e2b198ae79e0ac5a…` | MIT (duckdb-luajit-libs project) | none |
| `dirscan` | datasource | `libs/datasource/dirscan.lua` | `f1ef9847e943aecf…` | MIT (duckdb-luajit-libs project) | none（io.popen 列目录，普通模式） |
| `inv_ofd` | datasource | `libs/datasource/inv_ofd.lua` | `a63694c004a5acaf…` | MIT (duckdb-luajit-libs project) | zlib（Linux/macOS 内置 libz；Windows 需 zlib1.dll）——zip 解压逻辑内嵌，零库依赖 |
| `tdx` | datasource | `libs/datasource/tdx.lua` | `66a1e3113ba8237b…` | MIT (duckdb-luajit-libs project) | ffi（float32 reinterpret） |
| `dbcli` | db | `libs/db/dbcli.lua` | `69b773bdd4db96b0…` | MIT (duckdb-luajit-libs project) | 本机已安装对应 CLI；io.popen 可用（默认非 trusted 模式） |
| `usql` | db | `libs/db/usql.lua` | `5d36914e290bcc24…` | MIT (alitrack/usql-bridge + original) | luajit FFI 可用（默认非 trusted 模式）；usql-bridge 工件（按平台自动解析，见下） |
| `entity` | entity | `libs/entity/entity.lua` | `d38a8aeed0088b60…` | MIT (duckdb-luajit-libs project) | none |
| `export` | export | `libs/export/export.lua` | `d231d2d806f4c372…` | MIT (duckdb-luajit-libs project) | none（需普通模式——_duckdb_call 回调在 trusted 沙箱下不可用） |
| `fake` | fake | `libs/fake/fake.lua` | `2067ea520c0eb9c8…` | MIT (duckdb-luajit-libs project) | none |
| `linalg` | linalg | `libs/linalg/linalg.lua` | `1af462f372c37a3c…` | MIT (duckdb-luajit-libs project) | 系统 OpenBLAS（含 LAPACK）： |
| `classifier` | ml | `libs/ml/classifier.lua` | `b4e4fdaa65bbda0a…` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) | none |
| `highs` | optimize | `libs/optimize/highs.lua` | `7aaa9a57783e24b3…` | MIT (duckdb-luajit-libs project) | libhighs.so（HiGHS ≥1.6，MIT）——编译期安装： |
| `csvdialect` | parser | `libs/parser/csvdialect.lua` | `fca09f18613e4d12…` | MIT (duckdb-luajit-libs project) | none |
| `epub` | parser | `libs/parser/epub.lua` | `0070629f4cbc5dae…` | MIT (duckdb-luajit-libs project) | zlib（Linux/macOS 内置；Windows zlib1.dll 入 PATH）。需普通模式（读文件）。 |
| `htmlx` | parser | `libs/parser/htmlx.lua` | `061c45ba77865640…` | MIT (duckdb-luajit-libs project) | none |
| `id3` | parser | `libs/parser/id3.lua` | `3a13f632c4e4db6a…` | MIT (duckdb-luajit-libs project) | none |
| `json` | parser | `libs/parser/json.lua` | `30a08d4432d2e8da…` | MIT (vendored rxi/json.lua, rxi 2020) | none |
| `jsonpatch` | parser | `libs/parser/jsonpatch.lua` | `fa0b8f4141382930…` | MIT (duckdb-luajit-libs project) | none |
| `jsonpath` | parser | `libs/parser/jsonpath.lua` | `ac39e86d44faa2b2…` | MIT (duckdb-luajit-libs project) | none |
| `log` | parser | `libs/parser/log.lua` | `9b9550464350d3fb…` | MIT (duckdb-luajit-libs project) | 无（普通模式需读文件；trusted 模式不可用） |
| `markdown` | parser | `libs/parser/markdown.lua` | `7df453df76ab6c84…` | MIT (duckdb-luajit-libs project) | 无 |
| `rss` | parser | `libs/parser/rss.lua` | `e00ed542bc270e1c…` | MIT (duckdb-luajit-libs project) | none |
| `tomlini` | parser | `libs/parser/tomlini.lua` | `c1be7a9aa78a3162…` | MIT (duckdb-luajit-libs project) | none |
| `unzip` | parser | `libs/parser/unzip.lua` | `fc67e4942fb84cf0…` | MIT (duckdb-luajit-libs project) | zlib（Linux/macOS 内置 libz；Windows 常见 zlib1.dll） |
| `xml` | parser | `libs/parser/xml.lua` | `974609fa3c7c4d6d…` | MIT (duckdb-luajit-libs project) | none |
| `yaml` | parser | `libs/parser/yaml.lua` | `80a3db2c141e3450…` | MIT (duckdb-luajit-libs project) | none |
| `zip_list` | parser | `libs/parser/zip_list.lua` | `7acd355fc6f49530…` | MIT (duckdb-luajit-libs project) | none |
| `privacy` | privacy | `libs/privacy/privacy.lua` | `66756b368d529cd9…` | MIT (duckdb-luajit-libs project) | none |
| `psi` | quality | `libs/quality/psi.lua` | `90547e199c64ae3b…` | MIT (duckdb-luajit-libs project) | none |
| `audit_chain` | security | `libs/security/audit_chain.lua` | `7c6b087f8bf5ecbf…` | MIT (duckdb-luajit-libs project) | _duckdb_query（普通模式，非 trusted 沙箱）+ DuckDB 内建 sha256() / lag() OVER() |
| `rbac` | security | `libs/security/rbac.lua` | `8b7c49896af09bd4…` | MIT (duckdb-luajit-libs project) | _duckdb_query（普通模式；trusted 沙箱下不可用） |
| `rng` | stats | `libs/stats/rng.lua` | `16b588b160ba3eb2…` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) | none |
| `init` | tooling | `libs/tooling/init.lua` | `10eb4c17db027977…` | MIT (duckdb-luajit-libs project) | none |
| `base64` | udf | `libs/udf/base64.lua` | `87afaaad8916ecef…` | public domain (vendored iskolbin/lbase64, 2017) | none（LuaJIT bit 或纯 Lua 回退） |
| `cidr` | udf | `libs/udf/cidr.lua` | `07b5d5eb5221e708…` | MIT (duckdb-luajit-libs project) | none |
| `cncheck` | udf | `libs/udf/cncheck.lua` | `59075e1313510c40…` | MIT (duckdb-luajit-libs project) | none |
| `crc32` | udf | `libs/udf/crc32.lua` | `a3f9b859ca70edb0…` | MIT (duckdb-luajit-libs project) | LuaJIT bit 库（duckdb-luajit 环境必有） |
| `curl_ffi` | udf | `libs/udf/curl_ffi.lua` | `74c0558428fdf4e2…` | MIT (duckdb-luajit-libs project) | 系统 libcurl 动态库（WSL Ubuntu 自带 libcurl.so.4；Windows 需 libcurl-x64.dll 或 |
| `fuzzy` | udf | `libs/udf/fuzzy.lua` | `d91373b647a7e8f4…` | MIT (duckdb-luajit-libs project) | none |
| `html_escape` | udf | `libs/udf/html_escape.lua` | `9cbf31779e60ab00…` | MIT (duckdb-luajit-libs project) | none |
| `iconv` | udf | `libs/udf/iconv.lua` | `f0e5a1686df12d75…` | MIT (duckdb-luajit-libs project) | none（FFI 调 libc 的 iconv：Linux glibc/macOS 内置；Windows 需 GNU libiconv 的 |
| `jev_ask` | udf | `libs/udf/jev_ask.lua` | `cfab6aca8f226d9a…` | MIT (duckdb-luajit-libs project) | 一个跑着的 jev 型决策服务（HTTP 契约 POST /v1/systemone）。 |
| `llm_extract` | udf | `libs/udf/llm_extract.lua` | `0522f5cba6f6f941…` | MIT (duckdb-luajit-libs project) | curl CLI（io.popen 调系统 curl：Windows 10+ 自带 curl.exe） |
| `pinyin` | udf | `libs/udf/pinyin.lua` | `aa111e2c4df794dc…` | MIT (vendored pinyin-data dictionary, mozillazg) | none（单文件自包含） |
| `pinyin` | udf | `libs/udf/pinyin_engine.lua` | `a2802372381c7bc3…` | MIT (vendored pinyin-data dictionary, mozillazg) | none（单文件自包含） |
| `qr` | udf | `libs/udf/qr.lua` | `54caaec04a3086a1…` | MIT (algorithm layout) / Apache-2.0 (Nayuki QR generator) | 无（用 LuaJIT 原生位运算 & ~ | << >>；纯 Lua 5.1 需 bit 库） |
| `tail_file` | udf | `libs/udf/tail_file.lua` | `55470ba60279dbbf…` | MIT (duckdb-luajit-libs project) | 读文件需普通模式（非 trusted）；内联模式无需 |
| `uuid` | udf | `libs/udf/uuid.lua` | `e4c3b8c3fbea160b…` | MIT (duckdb-luajit-libs project) | LuaJIT bit 库 |

## Embedded in the companion extension (duckdb-luajit)

- duckdb-luajit (extension) embeds the Fennel compiler (src/embedded/fennel_embedded.c, 1.9MB) — MIT, SPDX header preserved. See that repo's SBOM section in README.

## Companion binaries shipped in this repo

| Binary | Library | License |
|---|---|---|
| — | `libs/db/usql.lua` | MIT (alitrack/usql-bridge + original) |
| — | `libs/ml/classifier.lua` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |
| — | `libs/stats/rng.lua` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |
| `libs/stats/librng_capi.so` | rng | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |
