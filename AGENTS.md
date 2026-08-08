# AGENTS.md — duckdb-luajit-libs

duckdb-luajit 的 Lua 库仓库：**一条 SQL 加载 Lua 函数/表函数**（`luajit_module(mode := 'install'/'list_remote')`），无编译、无 INSTALL 扩展。覆盖社区扩展够不着的长尾格式（小众格式/私有 API/一次性分析）。默认分支 `main`（不是 master）。

## Protocol & Commands
```bash
# 安装/列出（用户侧，一条 SQL）
SELECT * FROM luajit_module(mode := 'list_remote');
SELECT * FROM luajit_module(mode := 'install', sql_name := 'base64');
SELECT luajit_s('base64', 'hello');   # → aGVsbG8=
```
- **INDEX（根目录 `name|path` 每行）是唯一索引**：C 侧零硬编码，加库只改 INDEX 推送；install/list_remote 共用，INDEX 也缓存到本地（离线可用）
- 拉取顺序：lib 缓存 → INDEX 缓存 → 网络；install 前清缓存 `rm -f ~/.duckdb/luajit-libs/{INDEX,<name>.lua}` 才强制拉新
- 同步纪律：**推送后立即 `git pull` 同步本地正式仓库**（历史教训：/tmp clone 推送 8 提交、正式仓库停在旧版）；未跟踪目录会挡住 pull → 先确认归属再提交/忽略

## Architecture
- `INDEX` — 唯一索引，条目 = 可被 install 当 Lua chunk 编译的 .lua 库
- `libs/datasource/` — 数据源：读 DuckDB 读不了的格式（dicom、dirscan）
- `libs/export/` — 存储过程式导出（export：query/table → parquet/csv/json）
- `libs/etl/` — ETL 流程层：审计日志、幂等校验、错误自愈、组件化 SQL
- `libs/parser/` — 数据结构/文本解析器（json vendored、id3、zip_list）
- `libs/udf/` — 标量 UDF（base64、crc32、uuid、html_escape）
- `libs/ffi/` — **编译型 FFI 资产**（sudoku 的 C/Rust 求解器）：源码放这里，**绝不进 INDEX**
- `libs/mcp/` — MCP 集成（duckdb_mcp + luajit 发布 UDF 为 AI 工具）
- `libs/network/` — 网络/API 数据源（planned）
- 每库头部元数据规范：`@lib/@category/@desc/@source/@requires`

## Key Patterns
- 库分类：模块表库（`return {f=...}`，install 后 setglobal，包装 UDF 直接引用全局名）vs UDF 库（`return function` 直接可调）
- 表函数库（dicom/dirscan/id3/zip_list）：install 后 `luajit_table('name', list := '...')` 即用
- 多函数模块：源文件保持模块表不动，dofile 包装挑函数注册
- 纯 Lua 库零门槛接入：dofile 即用（vendored 第三方库如 rxi/json.lua、lbase64）
- 性能库双形态：Lua 参考实现（默认，零编译依赖）+ C/Rust FFI 版（`libs/ffi/`，演示三层能力）

## Risk Gates
- AUTO-APPROVED: 新增/修改 libs/ 下 .lua 库、改 INDEX、README/ROADMAP 文档、新增 ffi 资产
- REQUIRES APPROVAL: 改安装协议语义（INDEX 格式、install 行为）、删库、大改既有库 API
- BOUNDARY: 主仓库（duckdb-luajit）C 代码、社区扩展 PR、release tag

## Conventions
- **⛔ INDEX 只收「能编译成 Lua chunk 的 .lua 库」**——init SQL/README/配方文件（如 mcp-server.sql）走文档路径，进 INDEX 会 install loadstring 失败
- **⛔ 编译型 FFI 资产（.c/.rs/.so）放 `libs/ffi/<name>/`，绝不进 INDEX**（.c/.rs 会被当 Lua 源码编译炸掉）；README 标注 "source, not INDEX-installable"
- **⛔ Lua chunk 顶层只能一个 return**：vendored 库自带顶层 return + 追加 UDF 包装 = 语法错；删掉 vendored 顶层 return，包装在同一 chunk 引用其 local
- Lua 5.1：pattern 无 `|` 交替（链式 gsub）；`luajit -e "assert(loadfile('f'))"` 做语法检查（`luajit -b` 不是语法检查）
- 新库先本地断言验证再走 install 全链路（锚点示例：crc32('hello')=3610A686、base64('hello')=aGVsbG8=、uuid v4 正则校验）
- 安装消息/路径必须正斜杠（Windows USERPROFILE 反斜杠会炸 Lua 字符串转义）
- 目录规划：datasource / export / etl / parser / udf / network / ffi / mcp，新库按能力归位
