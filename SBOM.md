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

| Lib | Category | Path | SHA-256 | License | Maturity | Requires |
|---|---|---|---|---|---|---|
| `dicom` | datasource | `libs/datasource/dicom.lua` | `04e877fff364e333…` | MIT (duckdb-luajit-libs project) | tested | none |
| `dirscan` | datasource | `libs/datasource/dirscan.lua` | `8a2432be02012b9b…` | MIT (duckdb-luajit-libs project) | tested | none（io.popen 列目录，普通模式） |
| `inv_ofd` | datasource | `libs/datasource/inv_ofd.lua` | `381bf56b20251467…` | MIT (duckdb-luajit-libs project) | tested | zlib（Linux/macOS 内置 libz；Windows 需 zlib1.dll）——zip 解压逻辑内嵌，零库依赖 |
| `tdx` | datasource | `libs/datasource/tdx.lua` | `38677605ecba096e…` | MIT (duckdb-luajit-libs project) | tested | ffi（float32 reinterpret） |
| `dbcli` | db | `libs/db/dbcli.lua` | `06d0db66e1fc0033…` | MIT (duckdb-luajit-libs project) | tested | 本机已安装对应 CLI；io.popen 可用（默认非 trusted 模式） |
| `usql` | db | `libs/db/usql.lua` | `6fa40360925c2a66…` | MIT (alitrack/usql-bridge + original) | tested | luajit FFI 可用（默认非 trusted 模式）；usql-bridge 工件（按平台自动解析，见下） |
| `entity` | entity | `libs/entity/entity.lua` | `544c42dbf12ad85d…` | MIT (duckdb-luajit-libs project) | tested | none |
| `export` | export | `libs/export/export.lua` | `9d96f2ed4291ab1c…` | MIT (duckdb-luajit-libs project) | tested | none（需普通模式——_duckdb_call 回调在 trusted 沙箱下不可用） |
| `fake` | fake | `libs/fake/fake.lua` | `cc20741ba098f838…` | MIT (duckdb-luajit-libs project) | tested | none |
| `linalg` | linalg | `libs/linalg/linalg.lua` | `922507b622b19e5f…` | MIT (duckdb-luajit-libs project) | audited | 系统 OpenBLAS（含 LAPACK）： |
| `classifier` | ml | `libs/ml/classifier.lua` | `7f2f2bbfd272ac59…` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) | audited | none |
| `highs` | optimize | `libs/optimize/highs.lua` | `33118d06af91ad3b…` | MIT (duckdb-luajit-libs project) | audited | libhighs.so（HiGHS ≥1.6，MIT）——编译期安装： |
| `csvdialect` | parser | `libs/parser/csvdialect.lua` | `166c533aa0be5777…` | MIT (duckdb-luajit-libs project) | tested | none |
| `epub` | parser | `libs/parser/epub.lua` | `01a6ee383c47267e…` | MIT (duckdb-luajit-libs project) | tested | zlib（Linux/macOS 内置；Windows zlib1.dll 入 PATH）。需普通模式（读文件）。 |
| `htmlx` | parser | `libs/parser/htmlx.lua` | `15d59f479ea28eb0…` | MIT (duckdb-luajit-libs project) | tested | none |
| `id3` | parser | `libs/parser/id3.lua` | `aa854d54d2ca318a…` | MIT (duckdb-luajit-libs project) | tested | none |
| `json` | parser | `libs/parser/json.lua` | `7df37521174e0880…` | MIT (vendored rxi/json.lua, rxi 2020) | audited | none |
| `jsonpatch` | parser | `libs/parser/jsonpatch.lua` | `9597a95f46c97fc0…` | MIT (duckdb-luajit-libs project) | tested | none |
| `jsonpath` | parser | `libs/parser/jsonpath.lua` | `d97a388dc9fa5687…` | MIT (duckdb-luajit-libs project) | tested | none |
| `log` | parser | `libs/parser/log.lua` | `bf5eaf4c02b4cbdd…` | MIT (duckdb-luajit-libs project) | tested | 无（普通模式需读文件；trusted 模式不可用） |
| `markdown` | parser | `libs/parser/markdown.lua` | `dea4cefb8989047a…` | MIT (duckdb-luajit-libs project) | tested | 无 |
| `rss` | parser | `libs/parser/rss.lua` | `525c81c07c9d19c4…` | MIT (duckdb-luajit-libs project) | tested | none |
| `tomlini` | parser | `libs/parser/tomlini.lua` | `ad7d519d719225e6…` | MIT (duckdb-luajit-libs project) | tested | none |
| `unzip` | parser | `libs/parser/unzip.lua` | `1495beb0da14a5ce…` | MIT (duckdb-luajit-libs project) | tested | zlib（Linux/macOS 内置 libz；Windows 常见 zlib1.dll） |
| `xml` | parser | `libs/parser/xml.lua` | `dfea8b4ded8ccbb1…` | MIT (duckdb-luajit-libs project) | tested | none |
| `yaml` | parser | `libs/parser/yaml.lua` | `6b02ae0689118eec…` | MIT (duckdb-luajit-libs project) | tested | none |
| `zip_list` | parser | `libs/parser/zip_list.lua` | `70ace608e5f50abe…` | MIT (duckdb-luajit-libs project) | tested | none |
| `privacy` | privacy | `libs/privacy/privacy.lua` | `93cab1511969bb78…` | MIT (duckdb-luajit-libs project) | audited | none |
| `psi` | quality | `libs/quality/psi.lua` | `edf2480304b5ba37…` | MIT (duckdb-luajit-libs project) | tested | none |
| `audit_chain` | security | `libs/security/audit_chain.lua` | `46c98e2d8e9a0e3d…` | MIT (duckdb-luajit-libs project) | tested | _duckdb_query（普通模式，非 trusted 沙箱）+ DuckDB 内建 sha256() / lag() OVER() |
| `rbac` | security | `libs/security/rbac.lua` | `48c7e1f3bedcddbf…` | MIT (duckdb-luajit-libs project) | tested | _duckdb_query（普通模式；trusted 沙箱下不可用） |
| `rng` | stats | `libs/stats/rng.lua` | `13a5567c6f517621…` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) | audited | none |
| `init` | tooling | `libs/tooling/init.lua` | `51e1e51d27f1e55e…` | MIT (duckdb-luajit-libs project) | tested | none |
| `base64` | udf | `libs/udf/base64.lua` | `0bf27c64c502b68d…` | public domain (vendored iskolbin/lbase64, 2017) | tested | none（LuaJIT bit 或纯 Lua 回退） |
| `cidr` | udf | `libs/udf/cidr.lua` | `c29110b610f141b6…` | MIT (duckdb-luajit-libs project) | tested | none |
| `cncheck` | udf | `libs/udf/cncheck.lua` | `a41431d6d654b77f…` | MIT (duckdb-luajit-libs project) | tested | none |
| `crc32` | udf | `libs/udf/crc32.lua` | `a06f698d275ccaaf…` | MIT (duckdb-luajit-libs project) | tested | LuaJIT bit 库（duckdb-luajit 环境必有） |
| `curl_ffi` | udf | `libs/udf/curl_ffi.lua` | `da7b75539027140b…` | MIT (duckdb-luajit-libs project) | tested | 系统 libcurl 动态库（WSL Ubuntu 自带 libcurl.so.4；Windows 需 libcurl-x64.dll 或 |
| `fuzzy` | udf | `libs/udf/fuzzy.lua` | `8379ba4845a43c77…` | MIT (duckdb-luajit-libs project) | tested | none |
| `html_escape` | udf | `libs/udf/html_escape.lua` | `8e9e206183705cfa…` | MIT (duckdb-luajit-libs project) | tested | none |
| `iconv` | udf | `libs/udf/iconv.lua` | `dec0956f104d8f2d…` | MIT (duckdb-luajit-libs project) | tested | none（FFI 调 libc 的 iconv：Linux glibc/macOS 内置；Windows 需 GNU libiconv 的 |
| `jev_ask` | udf | `libs/udf/jev_ask.lua` | `643f997c7d9514e4…` | MIT (duckdb-luajit-libs project) | tested | 一个跑着的 jev 型决策服务（HTTP 契约 POST /v1/systemone）。 |
| `llm_extract` | udf | `libs/udf/llm_extract.lua` | `5890b11f85d00274…` | MIT (duckdb-luajit-libs project) | tested | curl CLI（io.popen 调系统 curl：Windows 10+ 自带 curl.exe） |
| `pinyin` | udf | `libs/udf/pinyin.lua` | `6ec0aa08fd74265e…` | MIT (vendored pinyin-data dictionary, mozillazg) | tested | none（单文件自包含） |
| `pinyin` | udf | `libs/udf/pinyin_engine.lua` | `05c8114d562cc54d…` | MIT (vendored pinyin-data dictionary, mozillazg) | tested | none（单文件自包含） |
| `qr` | udf | `libs/udf/qr.lua` | `65b97d21bed9276d…` | MIT (algorithm layout) / Apache-2.0 (Nayuki QR generator) | tested | 无（用 LuaJIT 原生位运算 & ~ | << >>；纯 Lua 5.1 需 bit 库） |
| `tail_file` | udf | `libs/udf/tail_file.lua` | `a8f847b5c6f90878…` | MIT (duckdb-luajit-libs project) | tested | 读文件需普通模式（非 trusted）；内联模式无需 |
| `uuid` | udf | `libs/udf/uuid.lua` | `84e9aee5a6bfdfec…` | MIT (duckdb-luajit-libs project) | tested | LuaJIT bit 库 |

## Maturity tiers

- `audited` — anchor-verified against known answers / third-party-reviewed
- `tested` — has a runnable test in this repo (default)
- `poc` — demo/probe script, not hardened


## Embedded in the companion extension (duckdb-luajit)

- duckdb-luajit (extension) embeds the Fennel compiler (src/embedded/fennel_embedded.c, 1.9MB) — MIT, SPDX header preserved. See that repo's SBOM section in README.

## Companion binaries shipped in this repo

| Binary | Library | License |
|---|---|---|
| — | `libs/db/usql.lua` | MIT (alitrack/usql-bridge + original) |
| — | `libs/ml/classifier.lua` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |
| — | `libs/stats/rng.lua` | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |
| `libs/stats/librng_capi.so` | rng | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |
