# 不装二进制也能查 40 种数据库：把 usql 编译进 DuckDB 的 Lua 里

上一篇写 dbcli 接 usql：DuckDB 里查外部数据库，靠的是在用户机器上装一个 usql 二进制，每次查询拉一个子进程。能用，但有两个绕不开的成本：一个 292MB 的二进制要分发到每台机器，每次查询 30 到 100 毫秒的进程冷启。

这篇讲另一条路：不装任何东西。把 usql 的核心编进 DuckDB 的 Lua 里，连接常驻在进程内，实测持续查询 0.01 到 0.2 毫秒一次。

## 为什么能省掉那个二进制

关键是一个很多人忽略的事实：**usql 的每个驱动都是一个标准的 `database/sql` driver。**

usql 是个 Go 项目，它的 `drivers/` 目录下 40 多个驱动，每个在 `init()` 时向 Go 标准库 `database/sql` 注册自己。这意味着你不需要 usql 的 CLI、REPL、查询解析器那一整套——那些是给人用的。程序内嵌时，你只需要：

```go
db, _ := drivers.Open(ctx, url, nil, nil)  // 返回一个 *sql.DB
db.Query("SELECT 1")
```

`database/sql.DB` 是长命的、可复用的。一次 `Open` 建连接，之后 `Query` 多少次都不再有进程冷启。这正是"装二进制"方案每查询都在付的冷启成本，在这里被彻底消掉了。

## 架构：三层，各自该干的事

整条链路分三层，每层只做一件事：

**Go 桥（独立仓 `alitrack/usql-bridge`）。** 一个 `main.go`，用 cgo 导出四个函数 `usql_connect / usql_query / usql_exec / usql_close`。内部维护一个 `map[int]*sql.DB`，连接按 int id 常驻复用。`usql_connect` 里调一次 `db.Ping()`，把冷启动前置到建连那一刻，让第一个真正的查询不背冷启。编译成 c-shared 动态库，`go build -buildmode=c-shared`。

**Lua FFI 桥（labs 里的 `libs/db/usql.lua`）。** 一个 `.lua` 文件，`ffi.load` 上面那个 Go 库，把四个函数包装成 DuckDB 的表函数。

**DuckDB luajit 扩展。** 早就有的东西，Lua 在 DuckDB 里跑、`ffi` 可用这件事它已经保证了。

所以"加一个 in-process 数据库连接"的最终交付物是：**一个 15MB 的 `.so` + 一个 `.lua`**。没有新的 DuckDB 扩展，没有 292MB 的二进制。

## 那个 `.so` 从哪来

这里有个工程决策值得说。labs 这个仓库的约定是"每个库一个自包含的 `.lua` 文件，`luajit_module(mode:='install')` 从 raw.githubusercontent 拉下来即用"。纯文本，零二进制。

Go 桥是个二进制，塞进 labs 会破坏这个约定。所以它单独成仓 `alitrack/usql-bridge`，按 GitHub release 发工件：

- 源码、`go.mod`、构建脚本在这个仓
- `build-release.sh` 交叉编译 linux amd64/arm64、darwin（windows 需要 mingw，单独处理）
- release `v0.1.0` 带 `usqlbridge-linux-amd64.so`

labs 里的 `usql.lua` 负责在运行时把 `.so` 找出来，解析顺序是：

1. spec 里的 `lib` 字段（显式指定路径，最高优先，调试用）
2. 环境变量 `USQL_BRIDGE_LIB`
3. `~/.duckdb/luajit-libs/`（install 的缓存目录，和 Lua 缓存放一起）
4. 以上都没有，`curl` 从 GitHub release 拉一次到缓存目录

第 4 步是 best-effort。我在这台开发机上实测过：GitHub release 的下载 CDN 有时慢到 15MB 拉 3 分钟拉不全，而 raw.githubusercontent（Lua 文件走的那条）是秒回。两条是不同 CDN，可靠性不一样。所以 `.so` 不依赖在线拉取兜底——拉失败就返回一行清晰的 `ERR:`，告诉用户手动 `gh release download` 放哪。

## 一个真实的坑：闭包捕获不到后面的 local

写 `usql.lua` 时踩了个 Lua 的坑，值得记一下。我一开始把解析 spec 用的 `json` 库加载函数写在了文件前部，它内部要调 `cache_dir()` 拼路径。但 `cache_dir` 是个 `local function`，定义在 `json` 加载函数**后面**。

Lua 的闭包只能捕获**定义时**已经在作用域里的 local。`load_json` 定义那一刻，`cache_dir` 这个 local 还不存在，所以它内部引用的 `cache_dir` 被当成**全局变量**去找——运行到那里时当然是 `nil`，一调用就炸。

修法很简单：把依赖的 `local` 定义放到前面。但这类"定义顺序决定闭包捕获"的问题不报错在定义处，报错在**调用处**，且症状是 nil 而不是"undefined"，排查时容易走偏。顺带一提，这也是为什么后来我把 spec 解析整个内联成一个极简解析器（只认扁平的 `{"k":"str","n":123}`），省掉了对 `json` 库的依赖，`usql.lua` 真正自包含。

## 实测

环境：Go 1.26、DuckDB 1.5.5、luajit ELF 扩展、SQLite（via usql 的 `moderncsqlite` 纯 Go 驱动，免 CGO）。

| 项 | 结果 |
|---|---|
| connect + Ping | `id=1`，冷启前置到此 |
| CREATE / INSERT / SELECT / 聚合 / 写读回 / close | 全对 |
| 单次查询延迟 | 0.01 到 0.2ms（含 FFI 跨语言 + JSON 编码） |
| 200 次持续查询 | 2ms 到 40ms，约 0.01 到 0.2ms 每次，无冷启无退化 |

最后一行是核心卖点：同一个连接连跑 200 个查询，没有一次是 30 毫秒起步的进程冷启。

驱动覆盖目前是 SQLite 一个。不是 usql 不行——它是编译期决定的：要支持哪个库，在 Go 桥的 `main.go` 里 `import _ github.com/xo/usql/drivers/<scheme>` 一行，重新编译发布 `.so`。要 postgres 就 import `drivers/postgres`，全驱动就 import 全部。这是"快"和"全"之间的取舍：编进去的越多，`.so` 越大、编译越慢；按需编，每个库一个针对性的小 `.so`。

## 两条路怎么选

| | dbcli + usql 二进制（上篇） | usql-bridge in-process（本篇） |
|---|---|---|
| 安装 | 用户机器装 292MB 二进制 | 不装，`.so` 随 release 拉 |
| 查询延迟 | 每查询进程冷启 30-100ms | 进程内常驻 0.01-0.2ms |
| 驱动覆盖 | 40+（`-tags most` 全编进一个二进制） | 编译期决定，按需 |
| 适用 | 低 QPS、一次性、跨 40+ 库的通用分析 | 固定几个库、要快、不想让用户装东西 |

不冲突。上篇那个方案的价值是"一条命令覆盖 40+ 库、用户装了个通用工具"，适合什么库都可能碰一下的场景。这篇的价值是"产品化地把某几个库的连接常驻在 DuckDB 进程里"，适合我的数据产品那种——语义层服务端分发，客户端就该只有一个 DuckDB 进程，不该再让他装东西。

---

*代码：Go 桥在 `alitrack/usql-bridge`，Lua 库在 `alitrack/duckdb-luajit-libs` 的 `libs/db/usql.lua`。复现和实测输出都在仓库里。*

---

## 附：体积口径补注（2026-09-14 实测）

正文里的「292MB 二进制」指**全驱动、未 strip** 的构建读数。三个口径分开看（Go 1.26.1 / `CGO_ENABLED=1`，官方发布配方复现差 0.11%）：

- 官方 `usql` v0.21.4 linux-amd64 发布件（`most` + 7 个 sqlite tag + `-ldflags "-s -w"`）= **208,037,792 B（198 MiB）**
- 同 tag 未 strip = 278.4 MB
- 零驱动基线（`-tags no_base`）= **18.2 MiB**；单驱动边际 +2.4 MB（mysql）～**+67.8 MB**（duckdb）

所以本篇 `.so` 的 **20.8 MB** 与「292MB」不是同一口径的两件东西：前者只编进一个驱动（`moderncsqlite`）+ Parquet 导出，后者是把 46 个驱动目录全编进一个可执行文件。全文归因（逐驱动边际表、dbx 侧对照）见 wiki `dbx-vs-usql-binary-size-20260914`。
