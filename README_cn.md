# duckdb-luajit-libs

DuckDB 的 Lua 库仓库：**一条 SQL 从仓库加载函数/表函数**，无需编译、无需 INSTALL 扩展。

配合 [duckdb-luajit](https://github.com/alitrack/duckdb-luajit) 使用——DuckDB 读不了的
格式（长尾/私有/小众）在这里找 Lua 库，几十行一个，PR 分钟级。

English README: [README.md](README.md)

> **规模（2026-08）**：40 个库，手写 Lua 逻辑 ≈ **1.16 万行**（另含 pinyin 内嵌
> vendored 词典 17.8 万行数据）；配套测试 SQL 1454 行 + 独立 oracle 交叉校验脚本
> 132 行。每个库"真实编译跑通 + 实测输出 + 独立交叉校验 + PoC 证据"。

## 分类

| 目录 | 定位 | 示例 |
|---|---|---|
| `libs/datasource/` | **数据源**——读文件/目录/格式，补 DuckDB 读不了的数据 | dicom（医疗影像）、dirscan（目录元数据）、inv_ofd（数电发票 OFD 解析）、tdx（通达信行情数据） |
| `libs/export/` | **导出**——存储过程式 COPY 导出（query/表 → parquet/csv/json） | export（Lua 里一条 COPY TO） |
| `libs/etl/` | **ETL 流程层**——审计日志、幂等加载校验、错误自愈、SQL 组件化、增量加载、缓慢变化维度 | etl（audit/validate/safe/q）、incremental、scd2 |
| `libs/parser/` | **解析器**——数据结构/文本解析（JSON/JSONPath/YAML/XML/TOML/INI/Markdown/RSS/CSV/HTML/EPUB/日志…） | json（vendored rxi/json.lua）、yaml、xml、tomlini、markdown、jsonpatch、jsonpath、rss、csvdialect、htmlx、epub、zip_list（zip 清单）、unzip（deflate 解压）、id3 |
| `libs/udf/` | **标量函数**——算法/编码/数学/字符串/网络/LLM UDF | base64、crc32、uuid、html_escape、iconv（编码检测/转码/语言检测）、cncheck（身份证/统一社会信用代码/银行卡/手机校验位 + 15→18 位转换）、fuzzy（相似度/距离）、tail_file（增量 tail）、qr（二维码生成）、cidr（网络 CIDR/IPv4/6）、pinyin（中文→拼音，pypinyin 词典 vendored）、llm_extract（LLM 结构化提取） |
| `libs/tooling/` | **工具**——仓库自维护/批量操作 | init（从 INDEX 批量 dofile+注册全部/指定库，离线可用） |
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
| `libs/parser/yaml.lua` | parser | YAML 解析/编码（自包含纯 Lua）——嵌套映射/序列、行内流式、块标量、注释、标量类型；`op=load` YAML→JSON（配 `json_extract`），`op=encode` JSON→YAML。支持子集诚实标注（无锚点/别名/多文档） | 无 |
| `libs/parser/xml.lua` | parser | XML 解析（自包含纯 Lua，xml2js 风格对象化：属性→`@名`、重复子标签→数组、叶子文本→字符串）。`op=load` XML→JSON；`op=find` 简单路径 `//tag/sub`；`op=attr` 取属性；`op=text` 去标签纯文本（保序） | 无 |
| `libs/parser/log.lua` | parser | 日志归一化表函数：自动识别 JSON-lines / nginx access / syslog / epoch / ISO 行 → `line_no\|ts\|level\|msg\|kvs(JSON)`，ts 统一 ISO8601；内联多行或文件路径两用 | 无（读文件需普通模式） |
| `libs/parser/tomlini.lua` | parser | TOML + INI 配置解析→JSON（自包含纯 Lua）：TOML 分组/`[a.b]` 嵌套/点路径 key/行内表 `{}`/行内数组/多行字符串/单引号字面量/注释；INI 分组/`[=:]` 赋值/`;`与`#` 注释/类型嗅探。`op=toml` 或 `op=ini` → JSON，配 `json_extract` 抽取。诚实边界：无 date-time 专门类型/数组表 `[[..]]`/多文档 | 无 |
| `libs/parser/id3.lua` | parser | MP3 ID3v2 标签解析（TIT2/TPE1/TALB/TYER/TRCK/TCON；ISO-8859-1/UTF-16/UTF-8）——表模式：文件列表 → 扁平行 | 无 |
| `libs/parser/markdown.lua` | parser | Markdown 结构提取（自包含纯 Lua）：`toc` 标题树（含 H1–H6 级）、`links` 链接/图片（label/href/title）、`code` 代码块（语言 + 内容，抠出避免被当正文）、`lists` 列表（嵌套 + 有序/无序 + 复选框）、`quotes` 块引用、`stats` 计数、`plain` 去标签纯文本。代码块/行内 code 内的 `#` 不误判为标题 | 无 |
| `libs/parser/jsonpatch.lua` | parser | RFC 6902 JSON Patch（`add`/`remove`/`replace`/`move`/`copy`/`test`）+ RFC 6901 JSON Pointer + 基础 `diff`（自含纯 Lua JSON 编解码）。DuckDB 有内建 `json_merge_patch`（RFC 7386）但无 RFC 6902 操作数组/JSON Pointer，本库补齐。`apply`/`get`/`set`/`test`/`diff`（diff 结果 apply 回原 doc 闭环=目标 doc） | 无 |
| `libs/parser/rss.lua` | parser | RSS 2.0 / RSS 1.0 (RDF) / Atom 1.0 feed 规整为统一 JSON（`detect`/`feed`/`items`/`count`）：items 每条 {title,link,pubDate,description,author,content}，命名空间容忍（dc:creator/content:encoded）、CDATA/实体正确、`file` 参数读盘。DuckDB 无内建 RSS/Atom/XPath | 无 |
| `libs/parser/jsonpath.lua` | parser | RFC 9535 JSONPath 实用子集（自含纯 Lua）：成员/数组索引(0-based/负)/通配 `*`/递归下降 `$..x`/过滤谓词 `[?(@.p op 字面量)]`（`=` `!=` `<` `<=` `>` `>=` + `and` 组合，`@.key` 存在性）。DuckDB `json_extract` 只支持简单路径，不支持通配/递归/过滤。结果按文档顺序（解码保留键序） | 无 |
| `libs/parser/csvdialect.lua` | parser | CSV 方言探测 + 纯 Lua 状态机解析（自含）：`detect`（delimiter `,;tab|` + quote/doublequote/skipinitialspace/`has_header` 启发式）、`parse`（引号内嵌分隔符/双引号转义/多行 → 二维数组）、`rows`/`ncols`；`file` 参数读盘。DuckDB read_csv 采样嗅探对短/多行/分号文件常误判，本库确定性探测 | 无 |
| `libs/parser/htmlx.lua` | parser | HTML→结构化抽取（自含纯 Lua）：`title`、`links`[{href,text}]、`tables`[{rows:[[cell]]}]、`text`（去标签可见纯文本）、`feed`（一次全取）；剔除 head/script/style/注释，大小写不敏感 + 未闭合容错 + void 元素，`file` 参数读盘。配 rss 做内容抽取 | 无 |
| `libs/udf/pinyin.lua` | udf | 中文→拼音（vendored pypinyin 0.55.0 词典 41923 字符 + 47111 词组，单文件 ~5MB 自包含，纯 Lua 零 FFI）：逐字最长词组匹配解多音字语境（"重庆"→chóngqìng、"一丁不识"→yīdīngbùshí）+ 字符表回退；`op` pinyin/join/first，`style` tones/notones，`unknown` ?/keep。ASCII/数字逐字透传，无映射非 ASCII→`?` | 无 |
| `libs/tooling/init.lua` | tooling | 仓库批量注册入口：从本地 INDEX 一次性 dofile+注册全部（`op='all'`）/指定子集（`op='some'`+names）/只列名（`list`/`names`），注册后 `luajit_s('jsonpath',…)` 等直接可调，免逐库 install；离线可用（本地 INDEX）。dofile 失败（FFI 依赖缺失）记 `skipped` 不中断 | 无 |
| `libs/parser/zip_list.lua` | parser | ZIP 中央目录文件清单（文件名\|压缩方法\|压缩大小\|原始大小\|CRC32），无需解压 | 无 |
| `libs/parser/unzip.lua` | parser | ZIP 解压指定文件（FFI 调 zlib raw inflate，windowBits=-15）——OFD/EPUB/DOCX/xlsx 等 zip 容器读取第一步；中央目录提供原始大小 → 一次分配输出缓冲 | zlib（Linux/macOS 内置；Windows zlib1.dll） |
| `libs/parser/epub.lua` | parser | EPUB 电子书解析（自包含，内嵌 zip 中央目录 + raw inflate，逐字移植自 unzip.lua）：`metadata`（title/creators/language/identifier/publisher/date/version/cover_href，命名空间容忍抽 OPF）、`toc`（EPUB2 NCX navPoint / EPUB3 nav type=toc → [{play_order,label,href}]）、`text`（指定 href 章节去标签纯文本，剥离 head/script/style）、`info`（opf_path/version/doc_count）。container.xml 自动定位 OPF | zlib（读文件需普通模式） |
| `libs/datasource/inv_ofd.lua` | datasource | 数电发票（全电发票）OFD 版式解析：`op='meta'` 标量 → CustomDatas JSON（发票号码/金额/税号/开票日期，诺诺/百望生成器写入 OFD.xml），json_extract 直接展开；表函数 → 版面文本行（TextObject Boundary 坐标按 y 聚类成行、行内按 x 排序，购买方/销售方/明细/价税合计全还原）。OFD = zip 容器，deflate 解压内嵌零库依赖；真实发票实测 9 行全还原 | zlib |
| `libs/udf/base64.lua` | udf | Base64 编解码（vendored [iskolbin/lbase64](https://github.com/iskolbin/lbase64) v1.5.3，public domain） | 无 |
| `libs/udf/crc32.lua` | udf | CRC-32 校验和（IEEE 802.3，8 位大写 hex） | LuaJIT bit |
| `libs/udf/uuid.lua` | udf | UUID v4 生成（math.random，非加密级） | LuaJIT bit |
| `libs/udf/html_escape.lua` | udf | HTML 实体转义/反转义 | 无 |
| `libs/udf/iconv.lua` | udf | 字符编码全家桶：`enc_detect`（BOM→UTF-8 严格校验→GB18030/GBK 特征）、`convert`（FFI 调 libc iconv，//IGNORE 语义剔除半个字/孤立字节，E2BIG 不静默截断）、`file`（GBK 等任意编码文件 → UTF-8 临时文件，喂 `read_csv`/`COPY`）、`lang`（ISO 639-1 语言检测：字符区间 15 语言 + 拉丁停用词细分）——read_csv 的 encoding 只支持 utf-8/utf-16/latin-1，中文编码是真空位 | 无（FFI libc iconv：Linux/macOS 内置；Windows 需 libiconv-2.dll，放 PATH 或设 `LUAJIT_ICONV_LIB` 指定路径） |
| `libs/udf/llm_extract.lua` | udf | 把「LLM 结构化信息提取」封装成 SQL 函数——调任意 OpenAI 兼容端点（默认本地 vLLM），schema + few-shot 约束输出 JSON，再交给 `json_extract` 展开。合同/公告/评论/简历批量字段提取、复杂语言识别一把梭；reasoning 模型默认 `enable_thinking=false` 关思考（`p.thinking=true` 开启）；端点可配（`p.endpoint` / 环境变量 `LLM_EXTRACT_ENDPOINT`） | curl CLI |
| `libs/udf/cncheck.lua` | udf | 中国数据校验位算法全家桶（纯 Lua）：`id_card` 身份证 18 位（GB 11643 加权校验位 + X，兼容 15 位抽取）、`id_15to18` 15 位→18 位转换（插 '19' + 重算校验位）、`uscc` 统一社会信用代码 18 位（GB 32100，31 字符集 mod 31）、`bank_card` 银行卡 Luhn（13–19 位）、`phone` 手机号（1[3-9] 段）、`id_extract` 身份证→区划/出生/性别。各返回 `{valid,reason}` JSON，`json_extract` 取 `$.valid` | 无 |
| `libs/udf/fuzzy.lua` | udf | 字符串相似度/距离（纯 Lua，**UTF-8 代码点感知**）：`lev` 编辑距离、`normlev` 归一化、`jaro`/`jw` Jaro-Winkler、`sim` 选指标、`simrank` 候选列表打分降序（记录链接/姓名匹配/去重核心）。中文按 1 个代码点处理（避免字节级退化：王小明 vs 王小民 字节级 jw=1.0，代码点级=0.8889）；JW 前缀上限 4（经典） | 无 |
| `libs/udf/tail_file.lua` | udf | 增量日志/文件 tail（纯 Lua，无状态偏移状态机）：`tail` 从上次字节偏移续读新增行 → `{offset,count,lines}`（未完结行暂吐、下次补全；文件截断/重建自动重置 offset；`max` 限制条数）。DuckDB 无内建增量读，配合应用存回的 offset 做轮询消费 | 无（读文件需普通模式） |
| `libs/udf/qr.lua` | udf | QR 码生成（纯 Lua，自包含，无 FFI）：`matrix`（模块二维数组 1=黑）、`svg`（可扫 SVG）、`ascii`（终端预览）、`info`（version/size/ec/mask）、`codewords`（数据+Reed-Solomon 码字 hex）。Byte 模式（任意 UTF-8）、EC 级别 L/M/Q/H、自动选 mask（penalty 最小）。**正确性经 python-qrcode 独立实现交叉校验：codewords 逐字节 IDENTICAL**（见 qr_verify.py） | 无 |
| `libs/udf/cidr.lua` | udf | 网络 CIDR / IP 工具（纯 Lua，自包含）：`version`/`ip2int`/`int2ip`/`in_cidr`（成员判定）/`cidr_info`（network/broadcast/prefix/size/mask）/`classify`（public/private/loopback/link-local/multicast…）/`net`/`broadcast`。IPv4(32 位)+IPv6(128 位按 8×16 位 hextet)。DuckDB 无内建 CIDR/IPv4/IPv6 函数。**正确性经 Python ipaddress 独立交叉校验 140/141**（唯一差异=Python 对 1:2:3:4:5:6:7:8 的 is_reserved 误判） | 无 |
| `libs/mcp/` (mcp-server.sql + sudoku.lua) | mcp | DuckDB 作为 MCP server 暴露 Lua UDF 给 AI（duckdb_mcp + luajit 合体） | duckdb_mcp 扩展 |
| `libs/mcp/sudoku.lua` | mcp | 数独求解器（81 位题面 → 解，锚点验证）——模块表库：install 后 compile 包装成 UDF | 无 |
| `libs/ffi/sudoku/` (sudoku_solve.c/.rs + README) | ffi | 同求解器的 C/Rust 版，LuaJIT FFI（`ffi.load`）调用，比 Lua 参考版快 ~7×——源码非 INDEX 可装库；编译 .so 后按路径加载 | gcc/rustc（构建时） |
| `libs/etl/etl.lua` | etl | ETL 流程层：审计日志（`etl.log`/`etl.run`）、幂等加载校验（`etl.validate`）、错误自愈（`etl.safe`/`etl.insert_auto`）、SQL 组件化（`etl.q`/`etl.query`）——需普通模式（非 trusted）用 `_duckdb_call`/`_duckdb_query` | 无 |
| `libs/etl/incremental.lua` | incremental | 增量加载：水位游标（`etl_watermark` 表），`ts`/`id`/`ts_id` 三种游标模式，只加载新行，返回 JSON（`loaded`/`last_ts`/`last_id`）——需普通模式 | 无 |
| `libs/etl/scd2.lua` | scd2 | 缓慢变化维度类型 2：属性指纹（md5）对比，自动建表（`_valid_from`/`_valid_to`/`_is_current`/`_version`），关闭旧版本 + 插入新版本，幂等——需普通模式 | 无 |
| `libs/datasource/tdx.lua` | datasource | 通达信（TDX）股票行情数据：.lc1/.lc5/.day 格式解析，32字节/记录，小端序。**错误可见化**：路径错/文件缺失/扩展名非 .lc1/.lc5/.day/大小非 32 倍数 → 一行 `ERR: <原因> @ <path>`（字段2-7 为 0，`::FLOAT` 可转）+ 全部失败时首行 `0/N files parsed` 汇总，聚合得 NULL 时 select * 即可看到原因。**WSL**：路径用 `/mnt/d/...`（正斜杠），不能用 `D:\...`。**需 `set threads=1`**（扩展并行表函数 init_data 竞态在默认多线程下返回 0 行） | 无（ffi） |

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
-- → available libs: dicom / dirscan / export / json / base64 / crc32 / uuid / html_escape / iconv / llm_extract / zip_list / unzip / inv_ofd / incremental / scd2 / tdx

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
