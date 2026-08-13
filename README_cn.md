# duckdb-luajit-libs

DuckDB 的 Lua 库仓库：**一条 SQL 从仓库加载函数/表函数**，无需编译、无需 INSTALL 扩展。

配合 [duckdb-luajit](https://github.com/alitrack/duckdb-luajit) 使用——DuckDB 读不了的
格式（长尾/私有/小众）在这里找 Lua 库，几十行一个，PR 分钟级。

English README: [README.md](README.md)

## 分类

| 目录 | 定位 | 示例 |
|---|---|---|
| `libs/datasource/` | **数据源**——读文件/目录/格式，补 DuckDB 读不了的数据 | dicom（医疗影像）、dirscan（目录元数据）、inv_ofd（数电发票 OFD 解析） |
| `libs/export/` | **导出**——存储过程式 COPY 导出（query/表 → parquet/csv/json） | export（Lua 里一条 COPY TO） |
| `libs/etl/` | **ETL 流程层**——审计日志、幂等加载校验、错误自愈、SQL 组件化、增量加载、缓慢变化维度 | etl（audit/validate/safe/q）、incremental、scd2 |
| `libs/parser/` | **解析器**——数据结构/文本解析（JSON/CSV/XML…） | json（vendored rxi/json.lua）、zip_list（zip 清单）、unzip（deflate 解压） |
| `libs/udf/` | **标量函数**——算法/编码/数学/字符串/LLM UDF | base64、crc32、uuid、html_escape、iconv（编码检测/转码/语言检测）、llm_extract（LLM 结构化提取） |
| `libs/network/` | **网络/API**——HTTP/签名/私域 API 数据源 | （规划：signed-api、http 抓取） |
| `libs/ffi/` | **FFI 绑定**——系统 C 库（dcmtk/open62541…）/编译型求解器 | sudoku（C/Rust 版，比 Lua 参考版快 ~7×，[libs/ffi/sudoku](libs/ffi/sudoku/README_cn.md)） |
| `libs/mcp/` | **MCP 集成**——DuckDB 作为 MCP server，把 Lua UDF 发布成 tools 给 AI 助手调用 | mcp-server（sudoku_solve 示例） |

## 库索引

| 库 | 分类 | 说明 | 依赖 |
|---|---|---|---|
| `libs/datasource/dicom.lua` | datasource | DICOM 医疗影像 19 tag（Explicit VR LE） | 无 |
| `libs/datasource/dirscan.lua` | datasource | 目录扫描：文件类型 + EXIF（相机/时间）+ PDF /Info | 无 |
| `libs/export/export.lua` | export | 存储过程式导出：`export({query\|tbl, file, format})` → COPY TO parquet/csv/json | 无（需普通模式，_duckdb_call） |
| `libs/parser/json.lua` | parser | JSON 解析/编码（[rxi/json.lua](https://github.com/rxi/json.lua)，MIT） | 无 |
| `libs/parser/id3.lua` | parser | MP3 ID3v2 标签解析（TIT2/TPE1/TALB/TYER/TRCK/TCON；ISO-8859-1/UTF-16/UTF-8）——表模式：文件列表 → 扁平行 | 无 |
| `libs/parser/zip_list.lua` | parser | ZIP 中央目录文件清单（文件名\|压缩方法\|压缩大小\|原始大小\|CRC32），无需解压 | 无 |
| `libs/parser/unzip.lua` | parser | ZIP 解压指定文件（FFI 调 zlib raw inflate，windowBits=-15）——OFD/EPUB/DOCX/xlsx 等 zip 容器读取第一步；中央目录提供原始大小 → 一次分配输出缓冲 | zlib（Linux/macOS 内置；Windows zlib1.dll） |
| `libs/datasource/inv_ofd.lua` | datasource | 数电发票（全电发票）OFD 版式解析：`op='meta'` 标量 → CustomDatas JSON（发票号码/金额/税号/开票日期，诺诺/百望生成器写入 OFD.xml），json_extract 直接展开；表函数 → 版面文本行（TextObject Boundary 坐标按 y 聚类成行、行内按 x 排序，购买方/销售方/明细/价税合计全还原）。OFD = zip 容器，deflate 解压内嵌零库依赖；真实发票实测 9 行全还原 | zlib |
| `libs/udf/base64.lua` | udf | Base64 编解码（vendored [iskolbin/lbase64](https://github.com/iskolbin/lbase64) v1.5.3，public domain） | 无 |
| `libs/udf/crc32.lua` | udf | CRC-32 校验和（IEEE 802.3，8 位大写 hex） | LuaJIT bit |
| `libs/udf/uuid.lua` | udf | UUID v4 生成（math.random，非加密级） | LuaJIT bit |
| `libs/udf/html_escape.lua` | udf | HTML 实体转义/反转义 | 无 |
| `libs/udf/iconv.lua` | udf | 字符编码全家桶：`enc_detect`（BOM→UTF-8 严格校验→GB18030/GBK 特征）、`convert`（FFI 调 libc iconv，//IGNORE 语义剔除半个字/孤立字节，E2BIG 不静默截断）、`file`（GBK 等任意编码文件 → UTF-8 临时文件，喂 `read_csv`/`COPY`）、`lang`（ISO 639-1 语言检测：字符区间 15 语言 + 拉丁停用词细分）——read_csv 的 encoding 只支持 utf-8/utf-16/latin-1，中文编码是真空位 | 无（FFI libc iconv：Linux/macOS 内置；Windows 需 libiconv-2.dll，放 PATH 或设 `LUAJIT_ICONV_LIB` 指定路径） |
| `libs/udf/llm_extract.lua` | udf | 把「LLM 结构化信息提取」封装成 SQL 函数——调任意 OpenAI 兼容端点（默认本地 vLLM），schema + few-shot 约束输出 JSON，再交给 `json_extract` 展开。合同/公告/评论/简历批量字段提取、复杂语言识别一把梭；reasoning 模型默认 `enable_thinking=false` 关思考（`p.thinking=true` 开启）；端点可配（`p.endpoint` / 环境变量 `LLM_EXTRACT_ENDPOINT`） | curl CLI |
| `libs/mcp/` (mcp-server.sql + sudoku.lua) | mcp | DuckDB 作为 MCP server 暴露 Lua UDF 给 AI（duckdb_mcp + luajit 合体） | duckdb_mcp 扩展 |
| `libs/mcp/sudoku.lua` | mcp | 数独求解器（81 位题面 → 解，锚点验证）——模块表库：install 后 compile 包装成 UDF | 无 |
| `libs/ffi/sudoku/` (sudoku_solve.c/.rs + README) | ffi | 同求解器的 C/Rust 版，LuaJIT FFI（`ffi.load`）调用，比 Lua 参考版快 ~7×——源码非 INDEX 可装库；编译 .so 后按路径加载 | gcc/rustc（构建时） |
| `libs/etl/etl.lua` | etl | ETL 流程层：审计日志（`etl.log`/`etl.run`）、幂等加载校验（`etl.validate`）、错误自愈（`etl.safe`/`etl.insert_auto`）、SQL 组件化（`etl.q`/`etl.query`）——需普通模式（非 trusted）用 `_duckdb_call`/`_duckdb_query` | 无 |
| `libs/etl/incremental.lua` | incremental | 增量加载：水位游标（`etl_watermark` 表），`ts`/`id`/`ts_id` 三种游标模式，只加载新行，返回 JSON（`loaded`/`last_ts`/`last_id`）——需普通模式 | 无 |
| `libs/etl/scd2.lua` | scd2 | 缓慢变化维度类型 2：属性指纹（md5）对比，自动建表（`_valid_from`/`_valid_to`/`_is_current`/`_version`），关闭旧版本 + 插入新版本，幂等——需普通模式 | 无 |

### 增量加载 × DuckLake 数据湖（实测组合）

增量加载天然配数据湖：**incremental 管水位**（读哪些新行），**DuckLake 管存储/快照/CDC**（写哪、时间旅行、变更流）。`incremental.run` 的目标表直接指 DuckLake 表，**零代码修改**——实测（DuckDB v1.5.5 + ducklake 扩展 + incremental 8171577）：

```sql
LOAD ducklake;
ATTACH 'ducklake:meta.ducklake' AS dl (DATA_PATH 'data/');
CREATE TABLE dl.orders(id BIGINT, ts TIMESTAMP, amount DOUBLE);

SELECT incr_run({'op':'run', 'target':'dl.orders', 'source':'src_orders', 'ts_col':'ts', 'mode':'ts'});
-- → {"loaded":3,...} 首次全量；再跑只增量 → {"loaded":2,...}

-- 白赚三件套：
-- 1. 时间旅行
FROM dl.orders AT (VERSION => 2);   -- 首载快照 3 行
-- 2. 变更数据流（CDC，供下游消费）
FROM dl.table_changes('orders', 1, 2);  -- snapshot_id / rowid / change_type / 行
-- 3. 数据落 parquet（可被 Spark/Polars 读）；小变更自动 Data Inlining 进 metadata 库，不写小文件
```

分工哲学不变：Lua 只做它擅长的（游标/水位 SQL 逻辑），存储引擎交给 DuckLake。

## 一条 SQL 安装协议（v0.31+ 推荐：`install` / `list_remote`）

duckdb-luajit **v0.31 起内置包管理**——`luajit_module` 新增 `install` / `list_remote` 模式，从本仓库按 INDEX 拉库、缓存到 `~/.duckdb/luajit-libs/`、自动注册，免手写拉取 SQL：

```sql
LOAD 'luajit';

-- 0. 看仓库里有哪些库（INDEX 协议，自动缓存）
SELECT * FROM luajit_module(mode := 'list_remote');
-- → available libs: dicom / dirscan / export / json / base64 / crc32 / uuid / html_escape / iconv / llm_extract / zip_list / unzip / inv_ofd / incremental / scd2

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
