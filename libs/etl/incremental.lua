-- incremental.lua: 增量加载（水位游标）——append-only 表只加载新行（2026-08-13）
-- 需要普通模式（非 trusted）：_duckdb_call / _duckdb_query
--
-- 用法（install 后）：
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'incremental');
--   SELECT * FROM luajit_module(mode := 'compile', sql_name := 'incr_run',
--     source := 'return function(opts) return incremental.run(opts) end');
--   SELECT incr_run({target:='tgt_orders', source:='src_orders', ts_col:='ts', mode:='ts'});
--
-- 游标模式 mode：
--   'ts'    —— WHERE ts > last_ts                        按时间增量
--   'id'    —— WHERE id > last_id                        按自增键增量
--   'ts_id' —— WHERE ts > last_ts OR (ts = last_ts AND id > last_id)  复合游标，同时间戳不漏不重
--
-- 水位表：etl_watermark(name VARCHAR PK, last_ts TIMESTAMP, last_id BIGINT, updated_at TIMESTAMP)
-- 约定：source 与 target 列序一致（INSERT INTO target SELECT * FROM source）

local incremental = {}
incremental.watermark_table = 'etl_watermark'

local function esc(v)
  if type(v) == 'string' then return "'" .. v:gsub("'", "''") .. "'" end
  if v == nil then return 'NULL' end
  return tostring(v)
end

-- JSON 字符串转义（返回值给 SQL 端 json_extract 用）
local function jstr(v)
  if v == nil then return 'null' end
  if type(v) == 'number' then return tostring(v) end
  return '"' .. tostring(v):gsub('"', '\\"') .. '"'
end

local function jres(loaded, last_ts, last_id)
  return '{"loaded":' .. tostring(loaded) .. ',"last_ts":' .. jstr(last_ts)
    .. ',"last_id":' .. jstr(last_id) .. '}'
end

-- 初始化水位表（幂等）
function incremental.init()
  _duckdb_call('CREATE TABLE IF NOT EXISTS ' .. incremental.watermark_table
    .. ' (name VARCHAR PRIMARY KEY, last_ts TIMESTAMP, last_id BIGINT, updated_at TIMESTAMP)')
end

-- 读水位：返回 {ts=..., id=...} 或 nil（首次）
function incremental.watermark(name)
  incremental.init()
  local rows = _duckdb_query('SELECT last_ts, last_id FROM ' .. incremental.watermark_table
    .. ' WHERE name = ' .. esc(name))
  if not rows or #rows == 0 then return nil end
  return { ts = rows[1].last_ts, id = rows[1].last_id }
end

-- 清水位（重新全量）
function incremental.reset(name)
  incremental.init()
  _duckdb_call('DELETE FROM ' .. incremental.watermark_table .. ' WHERE name = ' .. esc(name))
end

-- 执行增量加载
-- opts = { target=目标表, source=源表, ts_col=?, id_col=?, mode='ts'|'id'|'ts_id' }
-- 返回 {loaded=N, last_ts=?, last_id=?}
function incremental.run(opts)
  opts = opts or {}
  local target, source = opts.target, opts.source
  if not target or not source then error('incremental: target and source required', 0) end
  local mode = opts.mode or 'ts'
  local ts_col, id_col = opts.ts_col, opts.id_col
  if mode == 'ts' and not ts_col then error('incremental: ts_col required for mode=ts', 0) end
  if mode == 'id' and not id_col then error('incremental: id_col required for mode=id', 0) end
  if mode == 'ts_id' and (not ts_col or not id_col) then
    error('incremental: ts_col and id_col required for mode=ts_id', 0) end

  local wm = incremental.watermark(target)
  local where = ''
  if wm then
    if mode == 'ts' then
      where = ' WHERE ' .. ts_col .. ' > ' .. esc(wm.ts)
    elseif mode == 'id' then
      where = ' WHERE ' .. id_col .. ' > ' .. esc(wm.id)
    else
      where = ' WHERE (' .. ts_col .. ' > ' .. esc(wm.ts) .. ') OR ('
        .. ts_col .. ' = ' .. esc(wm.ts) .. ' AND ' .. id_col .. ' > ' .. esc(wm.id) .. ')'
    end
  end
  local sel = 'SELECT * FROM ' .. source .. where

  -- 预估本次加载行数
  local nq, err = _duckdb_query('SELECT CAST(count(*) AS BIGINT) AS n FROM (' .. sel .. ')')
  if not nq then error('incremental: ' .. tostring(err), 0) end
  local n = tonumber(nq[1].n) or 0

  if n > 0 then
    local r = _duckdb_call('INSERT INTO ' .. target .. ' ' .. sel)
    if type(r) == 'string' and r:match('^error:') then error(r:sub(7), 0) end

    -- 新水位：ts 取本次最大；id 取本次最大
    local new_ts, new_id = nil, nil
    if mode ~= 'id' then
      local m = _duckdb_query('SELECT max(' .. ts_col .. ') AS t FROM (' .. sel .. ')')
      if m then new_ts = m[1].t end
    end
    if mode ~= 'ts' then
      local m = _duckdb_query('SELECT max(' .. id_col .. ') AS i FROM (' .. sel .. ')')
      if m then new_id = m[1].i end
    end
    if new_ts or new_id then
      _duckdb_call('INSERT OR REPLACE INTO ' .. incremental.watermark_table
        .. ' VALUES (' .. esc(target) .. ', ' .. esc(new_ts) .. ', ' .. esc(new_id) .. ', now())')
    end
    return jres(n, new_ts, new_id)
  end
  return jres(0, wm and wm.ts or nil, wm and wm.id or nil)
end

return incremental
