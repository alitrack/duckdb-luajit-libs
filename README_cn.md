# duckdb-luajit-libs

DuckDB 的 Lua 库仓库：**一条 SQL 从仓库加载函数/表函数**，无需编译、无需 INSTALL 扩展。

配合 [duckdb-luajit](https://github.com/alitrack/duckdb-luajit) 使用——DuckDB 读不了的
格式（长尾/私有/小众）在这里找 Lua 库，几十行一个，PR 分钟级。

English README: [README.md](README.md)

## 分类

| 目录 | 定位 | 示例 |
|---|---|---|
| `libs/datasource/` | **数据源**——读文件/目录/格式，补 DuckDB 读不了的数据 | dicom（医疗影像）、dirscan（目录元数据） |
| `libs/export/` | **导出**——存储过程式 COPY 导出（query/表 → parquet/csv/json） | export（Lua 里一条 COPY TO） |
| `libs/parser/` | **解析器**——数据结构/文本解析（JSON/CSV/XML…） | json（vendored rxi/json.lua） |
| `libs/udf/` | **标量函数**——算法/编码/数学/字符串 UDF | base64、crc32、uuid、html_escape |
| `libs/network/` | **网络/API**——HTTP/签名/私域 API 数据源 | （规划：signed-api、http 抓取） |
| `libs/ffi/` | **FFI 绑定**——系统 C 库（dcmtk/open62541…） | （规划：需 extern "C" 或纯 C 库） |
| `libs/mcp/` | **MCP 集成**——DuckDB 作为 MCP server，把 Lua UDF 发布成 tools 给 AI 助手调用 | mcp-server（sudoku_solve 示例） |

## 库索引

| 库 | 分类 | 说明 | 依赖 |
|---|---|---|---|
| `libs/datasource/dicom.lua` | datasource | DICOM 医疗影像 19 tag（Explicit VR LE） | 无 |
| `libs/datasource/dirscan.lua` | datasource | 目录扫描：文件类型 + EXIF（相机/时间）+ PDF /Info | 无 |
| `libs/export/export.lua` | export | 存储过程式导出：`export({query\|tbl, file, format})` → COPY TO parquet/csv/json | 无（需普通模式，_duckdb_call） |
| `libs/parser/json.lua` | parser | JSON 解析/编码（[rxi/json.lua](https://github.com/rxi/json.lua)，MIT） | 无 |
| `libs/udf/base64.lua` | udf | Base64 编解码（vendored [iskolbin/lbase64](https://github.com/iskolbin/lbase64) v1.5.3，public domain） | 无 |
| `libs/udf/crc32.lua` | udf | CRC-32 校验和（IEEE 802.3，8 位大写 hex） | LuaJIT bit |
| `libs/udf/uuid.lua` | udf | UUID v4 生成（math.random，非加密级） | LuaJIT bit |
| `libs/udf/html_escape.lua` | udf | HTML 实体转义/反转义 | 无 |
| `libs/mcp/` (mcp-server.sql + sudoku.lua) | mcp | DuckDB 作为 MCP server 暴露 Lua UDF 给 AI（duckdb_mcp + luajit 合体） | duckdb_mcp 扩展 |

## 一条 SQL 安装协议（v0.31+ 推荐：`install` / `list_remote`）

duckdb-luajit **v0.31 起内置包管理**——`luajit_module` 新增 `install` / `list_remote` 模式，从本仓库按 INDEX 拉库、缓存到 `~/.duckdb/luajit-libs/`、自动注册，免手写拉取 SQL：

```sql
LOAD 'luajit';

-- 0. 看仓库里有哪些库（INDEX 协议，自动缓存）
SELECT * FROM luajit_module(mode := 'list_remote');
-- → available libs: dicom / dirscan / export / json / base64 / crc32 / uuid / html_escape

-- 1. 一条 SQL 装库并注册（标量 UDF 直接可调用）
SELECT * FROM luajit_module(mode := 'install', sql_name := 'base64');
-- → installed 'base64' (UDF) — cached at ~/.duckdb/luajit-libs/base64.lua

-- 2. 立即使用（注册名直调，免传源码）
SELECT luajit_s('base64', 'hello');  -- → aGVsbG8=

-- 表函数类库（dicom/dirscan）装完直接当 source 用
SELECT * FROM luajit_table('dicom', list := '文件路径');
```

> **v0.30 及更早**：`quick_compile` 协议（已移除）——`SET VARIABLE src = (SELECT content FROM read_text('https://raw.githubusercontent.com/alitrack/duckdb-luajit-libs/main/libs/<cat>/<lib>.lua'))` + `luajit_module(mode := 'quick_compile', sql_name := 'x', source := getvariable('src'))`。

## 贡献一个库（分类规则）

1. **选对分类目录**：数据源（读外部数据）→ `datasource/`；数据结构解析 → `parser/`；
   标量函数 → `udf/`；网络/API → `network/`；C 库绑定 → `ffi/`
2. **头部元数据**（`-- @key: value`，格式固定，未来脚本扫描生成索引）：
   `@lib`（库名）/ `@category` / `@desc`（一句话）/ `@source`（original 或 vendored URL+许可）/ `@requires`（依赖）
3. 纯 Lua、单文件、零外部依赖（或 vendored 进库内并标注来源）
4. 库尾部是 `return function(...)` 形式（luajit_module 的调用约定）
5. 提交 PR——merge 后即可被 `install` / `list_remote` 加载

## 边界（诚实）

- **纯 Lua 库直接可用**；带 C 依赖的（lpeg/luasocket/lua-cjson）需要 FFI 桥或
  系统 .so——纯 Lua 替代优先（如 json 用 rxi 纯 Lua 版，非 lua-cjson）
- 安装协议 = `install`/`list_remote`（内置包管理，INDEX 索引 + 本地缓存）；依赖管理（require 链）
  靠"单文件自包含"约定解决
