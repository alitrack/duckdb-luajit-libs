# duckdb-luajit-libs

DuckDB 的 Lua 库仓库：**一条 SQL 从仓库加载函数/表函数**，无需编译、无需 INSTALL 扩展。

配合 [duckdb-luajit](https://github.com/alitrack/duckdb-luajit) 使用——DuckDB 读不了的
格式（长尾/私有/小众）在这里找 Lua 库，几十行一个，PR 分钟级。

## 分类

| 目录 | 定位 | 示例 |
|---|---|---|
| `libs/datasource/` | **数据源**——读文件/目录/格式，补 DuckDB 读不了的数据 | dicom（医疗影像）、dirscan（目录元数据） |
| `libs/parser/` | **解析器**——数据结构/文本解析（JSON/CSV/XML…） | json（vendored rxi/json.lua） |
| `libs/udf/` | **标量函数**——算法/编码/数学/字符串 UDF | （规划：hash、base64、sentencepiece） |
| `libs/network/` | **网络/API**——HTTP/签名/私域 API 数据源 | （规划：signed-api、http 抓取） |
| `libs/ffi/` | **FFI 绑定**——系统 C 库（dcmtk/open62541…） | （规划：需 extern "C" 或纯 C 库） |

## 库索引

| 库 | 分类 | 说明 | 依赖 |
|---|---|---|---|
| `libs/datasource/dicom.lua` | datasource | DICOM 医疗影像 19 tag（Explicit VR LE） | 无 |
| `libs/datasource/dirscan.lua` | datasource | 目录扫描：文件类型 + EXIF（相机/时间）+ PDF /Info | 无 |
| `libs/parser/json.lua` | parser | JSON 解析/编码（[rxi/json.lua](https://github.com/rxi/json.lua)，MIT） | 无 |

## 一条 SQL 安装协议

```sql
LOAD 'luajit';
-- 1. 从仓库拉 Lua 库（read_text 支持 https）
SET VARIABLE src = (SELECT content FROM read_text(
  'https://raw.githubusercontent.com/alitrack/duckdb-luajit-libs/main/libs/datasource/dicom.lua'));
-- 2. 注册为函数（库 + 调用包装；库尾部是 return function(...) 时可直接编译）
SELECT message FROM luajit_module(mode := 'quick_compile', sql_name := 'dicom', source := getvariable('src'));
-- 3. 表函数直接用（luajit_table 无参调用，库内 io.popen 兜底列目录）
SELECT count(*) FROM luajit_table(getvariable('src'));
```

## 贡献一个库（分类规则）

1. **选对分类目录**：数据源（读外部数据）→ `datasource/`；数据结构解析 → `parser/`；
   标量函数 → `udf/`；网络/API → `network/`；C 库绑定 → `ffi/`
2. **头部元数据**（`-- @key: value`，格式固定，未来脚本扫描生成索引）：
   `@lib`（库名）/ `@category` / `@desc`（一句话）/ `@source`（original 或 vendored URL+许可）/ `@requires`（依赖）
3. 纯 Lua、单文件、零外部依赖（或 vendored 进库内并标注来源）
4. 库尾部是 `return function(...)` 形式（luajit_module 的调用约定）
5. 提交 PR——merge 后即可被 `read_text` 加载

## 边界（诚实）

- **纯 Lua 库直接可用**；带 C 依赖的（lpeg/luasocket/lua-cjson）需要 FFI 桥或
  系统 .so——纯 Lua 替代优先（如 json 用 rxi 纯 Lua 版，非 lua-cjson）
- 安装协议目前是"拉源码 + quick_compile"（免包管理器）；依赖管理（require 链）
  靠"单文件自包含"约定解决
