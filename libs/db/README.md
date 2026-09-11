# libs/db — 本机 CLI 数据库 transport（duckdb_universal 的长尾总线）

本目录让 DuckDB 通过**本机已有的数据库 CLI** 查询外部数据库，作为 Lua 表函数返回行。
它是 `duckdb_universal` 扩展的**长尾 transport 层**：主流库（MySQL/PG/ClickHouse/Snowflake）
走 Rust 原生 transport（快、有写保护）；这里覆盖**没有现成扩展、但本机有 CLI 的长尾/私有/国产库**，
加一种库 = 装好它的 CLI（或 usql）+ 一条 SQL，**不用写 Rust 驱动、不用重编扩展**。

## 文件
- `dbcli.lua` — 核心表函数。一个通用 client 抽象，可指向任意可执行文件。
- `test_dbcli.sql` — sqlite3 全链路测试（建库/插数/查询/聚合/错误可见化）。
- `test_dbcli_install.sql` — 真实用户链路：`install` 远程拉取后查库。
- `test_dbcli_usql.sql` — usql 集成：一个二进制查 40+ 种库的 DSN。
- 仓库根目录三份 `PoC-dbcli-*-output.txt` 是上述测试的真实输出，作为可复现证据。

## 快速上手

```sql
-- 1) 装载 luajit 扩展 + 拉取 dbcli（新会话走网络，之后走缓存）
LOAD 'path/to/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'install', sql_name := 'dbcli');

-- 2) 查本机 SQLite
SELECT row_idx, val FROM luajit_table('dbcli', list := '{
  "client": "sqlite3",
  "args":   ["-json", "/tmp/x.db"],
  "sql":    "SELECT id, name FROM t"
}');
-- 每行 val = 一个 JSON 对象，如 {"id":1,"name":"alice"}
-- 之后继续用 DuckDB SQL 对它 json_extract / 聚合 / join
```

### spec 字段
| 字段 | 说明 |
|---|---|
| `client` | 可执行文件名或完整路径（sqlite3/psql/mysql/redis-cli/usql/任意） |
| `args` | 参数数组（或空格分隔字符串）。**usql**：放 `-q -J` 等开关 + DSN 位置参数 |
| `sql` | 要执行的语句（走 stdin 临时文件） |
| `kind` | `json`(默认) / `tsv` / `raw` |
| `op` | `query`(默认) / `exec`(取最后一行) / `ping`(自检客户端) |

## usql：一个二进制查 40+ 种库

[usql](https://github.com/xo/usql)（`-tags most` 构建）把 40+ 种数据库的驱动编进一个二进制，
DSN 前缀一换连的库就换。**dbcli 里"支持 40+ 库"= 一条 client 名 + 换 DSN**：

```sql
SELECT val FROM luajit_table('dbcli', list := '{
  "client": "/opt/bin/usql_most",
  "args":   ["-q", "-J", "clickhouse://user:pass@host/db"],
  "sql":    "SELECT count() FROM events"
}');
```

构建 usql 全驱动版（CGO）：
```bash
git clone --depth 1 https://github.com/xo/usql && cd usql
CGO_ENABLED=1 go build -tags most -o /opt/bin/usql_most .
# 全驱动产物约 292MB；默认构建只有 76MB，但只编进 7 种库
```

> `usql/drivers/` 是 45 个驱动目录，`sqlite3`/`moderncsqlite`、`mysql`/`mymysql`、
> `postgres`/`pgx` 各是同一库的不同 Go 绑定 → **40+ 种独立数据库**。
> usql 定位是 **SQL 通用 CLI**：`redis`/`mongo`/`elasticsearch`/`influxdb` 这类**非 SQL 库不在内**。

## 已知坑（都是实测踩出来的，光看文档没有）

1. **SQL 一律走 stdin 临时文件，别当命令行参数传。** `io.popen` 走 `sh -c`，
   shell 单引号转义 ≠ SQL 字面量单引号翻倍，两层规则不同。SQL 当参数传会拿到
   `error here ---^`。stdin 让 SQL 字节完全不进命令行，引号/换行/中文/超长全免疫。
2. **usql 经 stdin 喂 SQL 必须带尾分号**，否则**静默返回空**（`-c` 形式不需要）。
   dbcli 已按 **basename** 识别 usql 并自动补分号（`client` 传完整路径时也能匹配）。
3. **usql 的 sqlite3 DSN 会自动建空库**——查"不存在"的库不会报错，会建个 0 字节文件。
   需要"不存在则报错"语义时，先自己 `ping`/检查。
4. **写外部库不受 DuckDB 侧保护。** dbcli 把 SQL 原样交给子进程执行，
   DuckDB 的 `?read_only=true` / `?production=true` 写保护**管不到子进程**。写外部库自己负责权限。

## 边界（它不解决什么）
- **性能**：Lua 起子进程走 CLI 是"数据搬运"，不是原生驱动。高并发/大结果集/列式直读用原生扩展。这里服务**长尾、低 QPS、一次性**查询。
- **二进制分发**：usql 全驱动版 292MB（默认构建 76MB，但只含 7 种库）、需 CGO。纯 Lua 包要带它得把二进制作为资产一起发。

对外技术文章见 `docs/article-dbcli-usql.md`。
