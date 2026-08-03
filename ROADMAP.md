# ROADMAP — duckdb-luajit-libs 大工程规划

目标：**慢慢蚕食 DuckDB 插件市场的长尾**——社区扩展覆盖主流格式（parquet/csv/iceberg），
本仓库用"一条 SQL 加载 Lua 库"覆盖社区扩展够不着的长尾（小众格式/私有 API/一次性分析），
靠**库的累积**形成习惯（遇到新格式先查 libs）。

## Phase 0 — 地基（✅ 已完成 2026-08-03）

- [x] 仓库建立 + 五类目录：datasource / parser / udf / network / ffi
- [x] 库头部元数据规范（`@lib/@category/@desc/@source/@requires`）
- [x] 安装协议验证：`read_text(URL)` + `quick_compile` / `luajit_table`
- [x] 首批库：dicom、dirscan（datasource）、json vendored（parser）
- [x] 第三方纯 Lua 库可用性验证（rxi/json.lua 实测）

## Phase 1 — 库积累（打基础）

- [ ] **parser 补全**：id3（MP3 标签）、zip-listing（中央目录文件清单）、csv-sniffer、
      xml（纯 Lua）、ini/yaml 子集
- [ ] **datasource 拆分**：dirscan 拆成独立库 filetype / exif / pdfinfo（可单独加载）
- [ ] **udf 首批**：base64（编解码）、crc32/hash、uuid、html-escape
- [ ] 每库配 docs/ 用法示例（README 或独立小节）
- [ ] 库数量目标：15+

## Phase 2 — 安装体验（工程化）

- [ ] **安装宏**：`CREATE MACRO install_lib(name)` 封装 3 行 SQL（拉取→注册）
- [ ] **版本管理**：元数据加 `@version`，read_text 按 tag/commit 锁定版本
- [ ] **CI 校验**（libs 仓库）：Lua 语法检查 + 元数据格式校验 + 安装协议冒烟测试
      （拉库→编译→调用，全自动）
- [ ] **trusted 模式只读 IO 白名单**（duckdb-luajit 侧）：扫目录/读文件进默认模式
      （现在 io/os 需普通模式）

## Phase 3 — 生态（蚕食发力）

- [ ] **FFI 绑定文档化**：dcmtk（DICOM 解码）、open62541（OPC UA 物联网）——
      绑定模式写成参考（extern "C" 或纯 C 库）
- [ ] **network 类**：signed-api（已有 demo）入库、http 抓取（ffi curl 已证明）
- [ ] **贡献规范落地**：PR 模板 + CI 门禁（元数据/语法/冒烟必过）
- [ ] duckdb-luajit 主仓库 README 宣传 libs 模式（联合入口）

## Phase 4 — 蚕食效果（规模）

- [ ] 库数量 20+，README 索引**脚本自动生成**（扫头部元数据）
- [ ] 社区 PR #2428 合并后的联合推广（duckdb-luajit 发布页指 libs）
- [ ] 真实用户 PR（非本人）≥ 3
- [ ] 系列文章配套：每篇 demo 沉淀一个库（库增长 = 蚕食进度）

## 治理原则

- **分类固定**：新增库必须归入五类之一（或经讨论新增类目）
- **元数据必填**：缺 `@category/@desc/@requires` 的库 CI 不过
- **自包含优先**：单文件零依赖；vendored 第三方必须标注来源+许可
- **诚实边界**：C 依赖库（lpeg/luasocket）标注"需 FFI 桥或 .so"，纯 Lua 替代优先
