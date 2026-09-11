# 让 DuckDB 用一条 SQL 查 40+ 种数据库：一个 Lua 文件 + 一个 292MB 的二进制

> 文里的数字都是本机跑出来的，不是演示。复现命令、测试脚本和原始输出都在仓库里。

## 一个反直觉的事实

DuckDB 是列式分析引擎，但它**天生只能查自己**。想让它顺手查一下你本地那个 MySQL、那个 Postgres、那个 ClickHouse？社区扩展里 `mysql`、`postgres`、`clickhouse` 各有专门包——可它们也就覆盖最主流的这几种。

再往下那一大堆数据库，DuckDB 根本没有现成扩展：

- 你公司内网那个**私有协议的 OLAP**
- 某个**国产数据库**（达梦、人大金仓、openGauss……）
- 一堆**长尾 NoSQL**（Cassandra、Couchbase、DynamoDB、Cosmos……）
- 一个只有**命令行客户端**、没有数据库扩展的小众工具

每加一种，正规做法是：**写一个 Rust 驱动 → 编译成 DuckDB 扩展 → 签名发布**。对一个"一年只查一次"的数据库，这套流程的成本完全不成比例。

## 思路：别给每种库写驱动，给它找一个"已有的 CLI"

几乎所有数据库，本机都装着一个命令行客户端（`mysql`、`psql`、`clickhouse-client`……）。这些 CLI 已经实现了最难的活：**连接协议、认证、wire 格式**。

那能不能让 DuckDB **直接调这个 CLI**，把结果当表读回来？

能。这就是 `dbcli.lua` 做的事。

它是个 Lua 表函数，挂在 DuckDB 的 `luajit` 扩展上。你给它一个 JSON 规格，它就去调本机某个可执行文件，把输出解析成行：

```sql
SELECT row_idx, val FROM luajit_table('dbcli', list := '{
  "client": "sqlite3",
  "args":   ["-json", "/tmp/x.db"],
  "sql":    "SELECT id, name, score FROM users ORDER BY score DESC"
}');
```

返回的每一行，就是一个 JSON 对象：

```
{"id":1,"name":"alice","score":91.5}
{"id":2,"name":"bob","score":84}
{"id":3,"name":"charlie","score":77.25}
```

然后你就能继续用 DuckDB 的 SQL 对它做聚合、join、窗口——**Lua 负责"把数据搬进来"，DuckDB 负责"算"**。这就是我们说的"transport 层"：它不管你怎么查，只负责把外部数据库的行喂给 DuckDB。

## 关键一跳：usql 一个二进制 = 40+ 种数据库

如果只是"调本机 CLI"，那你有多少种库就得认识多少个客户端的名字。真正省事的是 **usql**——[github.com/xo/usql](https://github.com/xo/usql)，"通用 SQL 命令行"。

它把 40+ 种数据库的 Go 驱动编译进**同一个二进制**。一个 `usql_most`（全驱动构建，292MB），DSN 前缀一换，连的库就换：

| DSN 前缀 | 数据库 |
|---|---|
| `sqlite3://` | SQLite |
| `postgres://` | PostgreSQL / Redshift / openGauss |
| `mysql://` | MySQL / Doris / StarRocks |
| `clickhouse://` | ClickHouse |
| `mssql://` / `sqlserver://` | SQL Server |
| `snowflake://` | Snowflake |
| `bigquery://` / `spanner://` | BigQuery / Spanner |
| `databricks://` / `trino://` / `presto://` | Databricks / Trino / Presto |
| `cassandra://` / `hive://` / `impala://` | 经 Avatica/FlightSQL |
| `cosmos://` / `dynamodb://` / `ots://` | 文档/宽表 |
| `oracle://` / `godror://` / `firebird://` / `h2://` / `ignite://` / `vertica://` / `voltdb://` / `ydb://` … | 其余 20+ 种 |

> 数字口径：`usql` 的 `drivers/` 下是 **45 个驱动目录**，其中 `sqlite3`/`moderncsqlite`、`mysql`/`mymysql`、`postgres`/`pgx` 各是同一个库的不同 Go 绑定，所以独立数据库算 **40+ 种**。另外 usql 的定位是 **SQL 通用 CLI**——`redis`、`mongo`、`elasticsearch`、`influxdb` 这类非 SQL 库**不在内**。体积上，全驱动版 292MB；默认构建只有 76MB，但里面只编进了 7 种库。

所以 `dbcli.lua` 里，"支持 40+ 种数据库"不是 40 段代码，是**一条 client 名 + 换 DSN**：

```sql
SELECT val FROM luajit_table('dbcli', list := '{
  "client": "/opt/bin/usql_most",
  "args":   ["-q", "-J", "clickhouse://user:pass@host/db"],
  "sql":    "SELECT count() FROM events"
}');
```

`-J` 让 usql 输出 JSON 数组，`dbcli` 解析后每行一个对象。实测（`usql_most` 是 `-tags most` 全驱动构建）：

```
U1  {"a":1,"b":"x"}      ← sqlite3 查 3 行
    {"a":2,"b":"y"}
    {"a":3,"b":"z"}
U2  {"n":3,"mx":3}       ← 聚合
U3  usql 0.0.0-dev       ← ping 自检
U4  a,b / 1,x / 2,y …   ← -C CSV 模式
U5  {"q":7}              ← 连 DuckDB 自己的文件库（most 里含 duckdb 驱动）
```

## 两个"先跑一遍才知道"的坑

这部分结论全是实测出来的。踩到两个坑，光看文档看不出来。

**坑 1：SQL 单引号 vs shell 单引号。**

`dbcli` 用 `io.popen` 起子进程，走的是 `sh -c`。如果你把 SQL 当**命令行参数**传，会撞上两层转义——shell 的单引号规则和 SQL 字面量的单引号翻倍规则**不一样**。实测拿到的是 sqlite3 的 `error here ---^`。

**正解**：SQL 一律走 **stdin 临时文件**，字节完全不进命令行，引号 / 换行 / 中文 / 超长语句全免疫。

**坑 2：usql 的 stdin 必须带尾分号。**

usql 从 stdin 读 SQL 时，语句**不带 `;` 就静默返回空**（用 `-c` 形式则不用）。这个行为没有任何文档写过。更坑的是，如果 `client` 传的是完整路径（`/opt/bin/usql_most`），你写 `client == "usql"` 判断补分号永远不成立——得按 **basename** 匹配。

这两个坑，都是"跑一遍"才暴露的。这也是为什么我坚持：**宣称能力之前，先验执行层**。

## 它解决什么问题 / 不解决什么

**解决**：DuckDB 想查一个"没有现成扩展、但本机有 CLI"的数据库，**不用写 Rust、不用重编扩展**。加一种库 = 装好它的 CLI（或 usql）+ 一条 SQL。

**不解决**：

- **性能**：Lua 起子进程走 CLI，是"数据搬运"，不是"原生驱动"。高并发 / 大结果集 / 需要列式直读的场景，该用原生扩展就用原生。它服务的是**长尾、低 QPS、一次性**的查询。
- **写保护**：`dbcli` 把 SQL 原样交给外部 CLI 执行，DuckDB 侧的 read-only / production 写保护**管不到子进程里**。要写外部库，权限自己负责。
- **二进制分发**：usql 全驱动版 292MB、需要 `CGO` 构建。要把它塞进一个纯 Lua 的包，得把二进制作为资产一起发。

## 一句话总结

> 主流数据库（MySQL/PG/ClickHouse/Snowflake……）→ 用 DuckDB **原生扩展**，快、稳、有写保护。
> 长尾数据库（几十种、私有、国产、小众）→ 用 **`dbcli.lua` + usql**，一个二进制 + 一条 SQL，免写 Rust 驱动。

DuckDB 的 `duckdb_universal` 已经有 15 个 Rust transport；`dbcli` 是它缺的那块**热插拔长尾总线**——让"加一种数据库"的成本，从"写驱动 + 重编译 + 发布"降到"装个 CLI + 丢一行 SQL"。

---

### 复现

```bash
# 1. 构建 usql 全驱动版（-tags most，45 个驱动目录，产物约 292MB，CGO）
git clone --depth 1 https://github.com/xo/usql
cd usql && CGO_ENABLED=1 go build -tags most -o /opt/bin/usql_most .

# 2. 跑测试（需要 duckdb + luajit 扩展）
duckdb -unsigned -f libs/db/test_dbcli_usql.sql
```

脚本里有两处本机绝对路径（`luajit` 扩展、`usql` 二进制），换成你自己的再跑。

代码在 `duckdb-luajit-libs` 仓库（[github.com/alitrack/duckdb-luajit-libs](https://github.com/alitrack/duckdb-luajit-libs)）：`libs/db/dbcli.lua`（MIT）、测试脚本 `libs/db/test_dbcli*.sql`；本文用到的原始输出作为 `PoC-dbcli-*-output.txt` 提交在仓库根目录。
