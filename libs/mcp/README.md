# libs/mcp — DuckDB as an MCP Server, exposing Lua compute to AI

Verified 2026-08-07: **duckdb_mcp** (community extension, MCP client+server) + **duckdb-luajit** (UDF) combined — publish any Lua UDF registered in SQL as an MCP tool, callable by AI assistants (Claude etc.) over the standard MCP protocol.

## Why it matters

- duckdb_mcp's official Custom Tools only support **SQL templates** (`SELECT ... WHERE x = $param`)
- Pointing the template at a luajit UDF = **any Lua logic (including ffi-loaded C libraries) becomes an AI-callable tool**
- A one-liner "query data" upgrades to "run logic": sudoku, lunar calendar, signed APIs, format parsing… AI calls it in one sentence

## Files

| File | Description |
|---|---|
| `mcp-server.sql` | init SQL: LOAD luajit → register UDFs → LOAD duckdb_mcp → publish tools → start server (stdio / HTTP, pick one) |
| `sudoku.lua` | sample Lua module (sudoku solver, anchor-verified) — swap in any Lua logic |
| `test-calls.ldjson` | sample MCP requests (initialize / tools/list / tools/call) for the stdio path |

## Quick start (stdio)

```bash
# 1. Start the server (stdio mode, reads LDJSON on stdin)
duckdb -unsigned -init libs/mcp/mcp-server.sql < test-calls.ldjson
# or as a pipeline:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sudoku_solve","arguments":{"puzzle":"000001002000020030004500600007600050080090006100005800001004000070900003400030020"}}}' \
  | duckdb -unsigned -init libs/mcp/mcp-server.sql
```

## Quick start (HTTP, test from browser/curl)

Change the last line of `mcp-server.sql` to `PRAGMA mcp_server_start('http', '0.0.0.0', 18080, '{}');`, then:

```bash
duckdb -unsigned -init libs/mcp/mcp-server.sql &   # keep running in background

curl http://localhost:18080/health                 # {"status":"ok"}
curl -X POST http://localhost:18080/mcp -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
curl -X POST http://localhost:18080/mcp -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sudoku_solve","arguments":{"puzzle":"000001002000020030004500600007600050080090006100005800001004000070900003400030020"}}}'
# → {"result":{"content":[{"type":"text","text":"[{\"solution\":\"359461782716829534...\"}]"}]}}
```

## Dependencies

- `INSTALL duckdb_mcp FROM community` (aligned with v1.5.5)
- duckdb-luajit v0.31+ (local build or `INSTALL luajit FROM community`)
- Bind `0.0.0.0` to reach the server from Windows/LAN (127.0.0.1 inside WSL is not forwarded)
- Configure `auth_token` for production (demo uses `{}` = no auth)
