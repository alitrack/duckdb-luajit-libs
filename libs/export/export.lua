-- @lib: export
-- @category: export
-- @desc: 存储过程式导出——Lua 里一条 COPY (query) TO file，参数化格式/路径；配合 CREATE MACRO 当导出过程用
-- @source: original（duckdb-luajit 系列）
-- @requires: none（需普通模式——_duckdb_call 回调在 trusted 沙箱下不可用）
-- Stored-procedure style export for duckdb-luajit (LuaJIT 5.1).
-- Runs COPY via the _duckdb_call callback on the extension's second connection.
-- Usage:
--   SET VARIABLE src = (SELECT content FROM read_text('https://raw.githubusercontent.com/alitrack/duckdb-luajit-libs/main/libs/export/export.lua'));
--   SELECT message FROM luajit_module(mode := 'quick_compile', sql_name := 'export', source := getvariable('src'));
--   SELECT export({query: 'SELECT * FROM t WHERE qty >= 2', file: '/tmp/out.parquet'});
--   -- or by table name (tbl — 'table' is a DuckDB keyword):
--   SELECT export({tbl: 't', file: '/tmp/out.csv', format: 'csv'});
local FORMATS = { parquet = true, csv = true, json = true }

local function esc(s)
  return (s:gsub("'", "''"))
end

return function(p)
  if not p or not p.file then return 'error: need file' end
  local fmt = p.format or 'parquet'
  if not FORMATS[fmt] then return 'error: unsupported format: ' .. tostring(fmt) end
  local src
  if p.query then
    src = p.query
  elseif p.tbl then
    src = 'SELECT * FROM ' .. p.tbl
  else
    return 'error: need query or tbl'
  end
  local sql = "COPY (" .. src .. ") TO '" .. esc(p.file) .. "' (FORMAT " .. fmt .. ")"
  local st = _duckdb_call(sql)
  if st ~= 'ok' then return st end
  return 'ok: ' .. p.file .. ' (' .. fmt .. ')'
end
