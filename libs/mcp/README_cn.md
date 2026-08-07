# libs/mcp — DuckDB 作为 MCP Server，暴露 Lua 计算能力给 AI（中文版）

> English: [README.md](README.md) · 中文: 本文件（README_cn.md）

2026-08-07 实测：**duckdb_mcp**（社区扩展，MCP client+server）+ **duckdb-luajit**（UDF）合体——
把 SQL 里注册的任意 Lua UDF 发布成 MCP tools，AI 助手（Claude 等）通过标准 MCP 协议调用。

## 为什么有价值

- duckdb_mcp 官方 Custom Tools 只支持 **SQL 模板**（`SELECT ... WHERE x = $param`）
- 把模板指向 luajit UDF = **任意 Lua 逻辑（含 ffi 拉 C 库）变成 AI 可调用工具**
- 一行 SQL 的「查数据」升级成「跑逻辑」：数独、农历、签名 API、格式解析……AI 一句话调用

## 文件

| 文件 | 说明 |
|---|---|
| `mcp-server.sql` | init SQL：LOAD luajit → 注册 UDF → LOAD duckdb_mcp → publish tool → 起 server（stdio / HTTP 二选一） |
| `sudoku.lua` | 示例 Lua 模块（数独求解，锚点验证）——换成任何 Lua 逻辑即可 |
| `test-calls.ldjson` | stdio 路径的示例 MCP 请求（initialize / tools/list / tools/call） |

## 快速开始（stdio）

```bash
# 1. 起 server（stdio 模式，吃 stdin LDJSON）
duckdb -unsigned -init libs/mcp/mcp-server.sql < test-calls.ldjson
# 或一条管道:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sudoku_solve","arguments":{"puzzle":"000001002000020030004500600007600050080090006100005800001004000070900003400030020"}}}' \
  | duckdb -unsigned -init libs/mcp/mcp-server.sql
```

## 快速开始（HTTP，浏览器/curl 直测）

把 `mcp-server.sql` 最后一行改为 `PRAGMA mcp_server_start('http', '0.0.0.0', 18080, '{}');`，然后：

```bash
duckdb -unsigned -init libs/mcp/mcp-server.sql &   # 后台保持

curl http://localhost:18080/health                 # {"status":"ok"}
curl -X POST http://localhost:18080/mcp -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
curl -X POST http://localhost:18080/mcp -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sudoku_solve","arguments":{"puzzle":"000001002000020030004500600007600050080090006100005800001004000070900003400030020"}}}'
# → {"result":{"content":[{"type":"text","text":"[{\"solution\":\"359461782716829534...\"}]"}]}}
```

## 依赖

- `INSTALL duckdb_mcp FROM community`（v1.5.5 对齐）
- duckdb-luajit v0.31+（本地构建产物或 `INSTALL luajit FROM community`）
- 绑定 `0.0.0.0` 才能从 Windows/局域网访问（WSL 里 127.0.0.1 不转发）
- 生产环境务必配置 `auth_token`（demo 用 `{}` 无认证）
