# duckdb-luajit-libs

DuckDB 的 Lua 库仓库：**一条 SQL 从仓库加载函数/表函数**，无需编译、无需 INSTALL 扩展。

配合 [duckdb-luajit](https://github.com/alitrack/duckdb-luajit) 使用——DuckDB 读不了的
格式（长尾/私有/小众）在这里找 Lua 库，几十行一个，PR 分钟级。

## 一条 SQL 安装协议

```sql
LOAD 'luajit';
-- 1. 从仓库拉 Lua 库（read_text 支持 https）
SET VARIABLE src = (SELECT content FROM read_text(
  'https://raw.githubusercontent.com/alitrack/duckdb-luajit-libs/main/libs/dicom.lua'));
-- 2. 注册为函数（库 + 调用包装）
SELECT message FROM luajit_module(mode := 'quick_compile', sql_name := 'dicom', source := getvariable('src'));
-- 3. 直接用
SELECT luajit_s('dicom', '/path/file.dcm');
```

表函数场景（批量/目录）用 `luajit_table` 同样加载。

## 库索引

| 库 | 说明 | 依赖 |
|---|---|---|
| `libs/dicom.lua` | DICOM 医疗影像 19 tag（Explicit VR LE） | 无（纯 Lua） |
| `libs/dirscan.lua` | 目录扫描：文件类型 magic + EXIF（相机/时间）+ PDF /Info | 无（纯 Lua，io.popen 列目录） |
| `libs/json.lua` | JSON 解析/编码（vendored [rxi/json.lua](https://github.com/rxi/json.lua)，MIT） | 无（纯 Lua） |

## 贡献一个库

1. 纯 Lua、单文件、零外部依赖（或 vendored 进 `libs/` 并标注来源）
2. 文件尾部是 `return function(...)` 形式（luajit_module 的调用约定）
3. 提交 PR——merge 后即可被 `read_text` 加载

## 边界（诚实）

- **纯 Lua 库直接可用**；带 C 依赖的（lpeg/luasocket/lua-cjson）需要 FFI 桥或
  系统 .so——纯 Lua 替代优先（如本仓库 json.lua 是 rxi 纯 Lua 版，非 lua-cjson）
- 安装协议目前是"拉源码 + quick_compile"（免包管理器）；依赖管理（require 链）
  靠"单文件自包含"约定解决
