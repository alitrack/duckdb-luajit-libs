-- @lib: mcp_demo
-- @category: mcp
-- @desc: DuckDB 作为 MCP server, 把 luajit UDF 发布成 MCP tools — AI 助手可调用 SQL 里的 Lua 能力
-- @source: original (alitrack, 2026-08-07 实测)
-- @requires: duckdb-luajit v0.31+ + duckdb_mcp 扩展 (INSTALL duckdb_mcp FROM community)
--
-- 用法:
--   duckdb -unsigned -init libs/mcp/mcp-server.sql   (stdio 模式, 吃 stdin LDJSON)
--   duckdb -unsigned -init libs/mcp/mcp-server.sql   (改最后一行 -> HTTP 模式: 0.0.0.0:18080)
--
-- 验证三步 (stdio):
--   1. cat test-calls.ldjson | duckdb -unsigned -init mcp-server.sql
--   2. tools/list 应看到 sudoku_solve / lua_greet 两个自定义 tool
--   3. tools/call sudoku_solve 返回数独解
--
-- 验证三步 (HTTP):
--   1. curl http://localhost:18080/health                     -> {"status":"ok"}
--   2. curl -X POST http://localhost:18080/mcp -H "Content-Type: application/json" \
--        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
--   3. curl -X POST http://localhost:18080/mcp -H "Content-Type: application/json" \
--        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sudoku_solve","arguments":{"puzzle":"000001002000020030004500600007600050080090006100005800001004000070900003400030020"}}}'
--      -> {"solution":"359461782716829534..."}

-- 1. 加载 luajit 扩展 (本地构建产物或 INSTALL luajit FROM community)
LOAD 'luajit';

-- 2. 注册 Lua UDF: 数独求解 (模块文件 sudoku.lua 需同目录, 或改用 install 协议从本仓库拉)
SELECT * FROM luajit_module(mode := 'compile', sql_name := 'sudoku_solve',
  source := 'local s = dofile(''libs/mcp/sudoku.lua'') return function(x) return s.solve(x) end');

-- 3. 加载 duckdb_mcp 扩展
LOAD duckdb_mcp;

-- 4. 把 Lua UDF 发布成 MCP tools (SQL 模板调用 luajit UDF = 任意 Lua 逻辑暴露给 AI)
PRAGMA mcp_publish_tool(
  'sudoku_solve',
  'Solve a 9x9 Sudoku puzzle given an 81-character string (0 = empty cell). Returns the solved 81-character string.',
  'SELECT luajit_s(''sudoku_solve'', $puzzle) AS solution',
  '{"puzzle": {"type": "string", "description": "81-char Sudoku puzzle, digits 0-9, 0 for empty"}}',
  '["puzzle"]'
);

-- 5. 起 server —— 二选一:
--    stdio (MCP 客户端标准通道):
PRAGMA mcp_server_start('stdio');
--    HTTP (浏览器/curl 直测, 绑定 0.0.0.0 供 Windows/局域网访问):
-- PRAGMA mcp_server_start('http', '0.0.0.0', 18080, '{}');
