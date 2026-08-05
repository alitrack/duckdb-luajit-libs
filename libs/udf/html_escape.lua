-- @lib: html_escape
-- @category: udf
-- @desc: HTML 实体转义/反转义（& < > " '；数值实体不解码）
-- @source: original（duckdb-luajit 系列）
-- @requires: none
-- Usage (duckdb-luajit):
--   install: SELECT * FROM luajit_module(mode:='install', sql_name:='html_escape');
--   escape:  SELECT luajit_s('html_escape', {v: '<a href="x">', op: 'escape'});
--   unescape:SELECT luajit_s('html_escape', {v: '&lt;a&gt;', op: 'unescape'});
local MAP_ESC = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ["'"] = '&#39;' }

return function(p)
  if type(p) == 'string' then
    return (p:gsub('[&<>"\']', MAP_ESC))
  end
  if type(p) ~= 'table' then return '' end
  local v = p.v or ''
  local op = p.op or 'escape'
  if op == 'unescape' then
    -- Lua 5.1 pattern has no | alternation: chain gsubs, &amp; last to avoid double-decode
    v = v:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&#39;', "'")
    return (v:gsub('&amp;', '&'))
  end
  return (v:gsub('[&<>"\']', MAP_ESC))
end
