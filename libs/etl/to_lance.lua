-- to_lance.lua: 增量加载 → Lance 数据集落地端（2026-10-16）
-- @lib: to_lance
-- @category: etl
-- @desc: 增量加载的 Lance 落地端——与 incremental 同构（水位表 etl_watermark / ts|id|ts_id 三游标），target 是 Lance 数据集：首跑 COPY Create、后续 COPY APPEND，每次写发布新 dataset version（需 lance_conversion 扩展）
-- @source: original
-- @requires: lance_conversion 扩展（同会话 LOAD）；普通模式（非 trusted）：_duckdb_call / _duckdb_query
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--
-- 与 incremental.run 的分工（同一水位协议，两个出口）：
--   incremental → DuckDB 表 / DuckLake 表（管快照/CDC）
--   to_lance    → Lance 数据集（管向量/多模态/检索；官方 lance 扩展可读回）
--
-- 用法（install 后）：
--   LOAD lance_conversion;  -- 写侧依赖
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'to_lance');
--   SELECT * FROM luajit_module(mode := 'compile', sql_name := 'lance_run',
--     source := 'return function(opts) return to_lance.run(opts) end');
--   SELECT lance_run({source:='src_orders', dest:='orders.lance', ts_col:='ts', mode:='ts'});
--
-- 游标模式 mode（同 incremental）：
--   'ts'    —— WHERE ts > last_ts                        按时间增量
--   'id'    —— WHERE id > last_id                        按自增键增量
--   'ts_id' —— WHERE ts > last_ts OR (ts = last_ts AND id > last_id)  复合游标，同时间戳不漏不重
--
-- 水位表：etl_watermark(name VARCHAR PK, last_ts TIMESTAMP, last_id BIGINT, updated_at TIMESTAMP)
--         与 incremental 共用（name 用 dest 路径字符串）
-- 返回 JSON：{"loaded":N,"last_ts":...,"last_id":...,"write":"create"|"append"|"noop"}
-- 另有 op='reset'：清水位重新全量（SELECT lance_run({op:'reset', dest:'orders.lance'});）
--
-- 已知边界：
--   lance 与 lance_conversion 不能同会话 LOAD（LANCE CopyFunction 重名冲突）——
--   写读分离：本库写（lance_conversion 会话），另起会话 LOAD lance 读回。
--   Lance APPEND 要求 schema 兼容；dest 首跑必须不存在（Create 语义）。

local to_lance = {}
to_lance.watermark_table = 'etl_watermark'

-- 内联 JSON 编解码（自包含，单文件约定；encoder 参考 rxi/json.lua 思路的最小子集）
local function json_decode(s)
  -- 最小 JSON 对象解析：键值均为字符串/数字（本库入参形态）
  local t = {}
  local body = s:match('^%s*{(.*)}%s*$')
  if not body then return nil end
  local pos = 1
  local function skip() pos = body:find('[^,%s]', pos) or #body + 1 end
  while pos <= #body do
    skip()
    if pos > #body then break end
    local k_s, k_e = body:find('^"([^"]*)"%s*:', pos)
    if not k_s then break end
    local key = body:match('^"([^"]*)"%s*:', pos)
    pos = k_e + 1
    local v_s = body:find('[^,%s]', pos)
    if not v_s then break end
    local val
    local q = body:sub(v_s, v_s)
    if q == '"' then
      val = body:match('^"([^"]*)"', v_s)
      pos = v_s + #val + 2
    elseif q == '{' or q == '[' then
      error('to_lance: nested JSON values not supported in opts', 0)
    else
      local num = body:match('^[%-%d%.eE]+', v_s)
      val = tonumber(num) or num
      pos = v_s + #(num or '')
    end
    t[key] = val
    pos = body:find(',', pos) or #body + 1
    pos = pos + 1
  end
  return t
end

local function json_encode(v)
  if v == nil then return 'null' end
  if type(v) == 'number' then
    return v == math.floor(v) and string.format('%d', v) or tostring(v)
  end
  if type(v) ~= 'string' then return tostring(v) end
  return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function jres(loaded, last_ts, last_id, write)
  local parts = {}
  parts[#parts + 1] = '"loaded":' .. tostring(loaded)
  parts[#parts + 1] = '"last_ts":' .. json_encode(last_ts)
  parts[#parts + 1] = '"last_id":' .. json_encode(last_id)
  parts[#parts + 1] = '"write":' .. json_encode(write)
  return '{' .. table.concat(parts, ',') .. '}'
end

local function esc(v)
  if type(v) == 'string' then return "'" .. v:gsub("'", "''") .. "'" end
  if v == nil then return 'NULL' end
  return tostring(v)
end

-- 初始化水位表（幂等；与 incremental 共用）
function to_lance.init()
  _duckdb_call('CREATE TABLE IF NOT EXISTS ' .. to_lance.watermark_table
    .. ' (name VARCHAR PRIMARY KEY, last_ts TIMESTAMP, last_id BIGINT, updated_at TIMESTAMP)')
end

-- 读水位：返回 {ts=..., id=...} 或 nil（首次）
function to_lance.watermark(name)
  to_lance.init()
  local rows = _duckdb_query('SELECT last_ts, last_id FROM ' .. to_lance.watermark_table
    .. ' WHERE name = ' .. esc(name))
  if not rows or #rows == 0 then return nil end
  return { ts = rows[1].last_ts, id = rows[1].last_id }
end

-- 清水位（重新全量）
function to_lance.reset(name)
  to_lance.init()
  _duckdb_call('DELETE FROM ' .. to_lance.watermark_table .. ' WHERE name = ' .. esc(name))
end

-- 执行增量 → Lance
-- opts = { source=源表, dest=Lance 数据集路径, ts_col=?, id_col=?, mode='ts'|'id'|'ts_id' }
-- 返回 JSON 字符串
function to_lance.run(opts)
  opts = opts or {}
  local source, dest = opts.source, opts.dest
  if not source or not dest then error('to_lance: source and dest required', 0) end
  local mode = opts.mode or 'ts'
  local ts_col, id_col = opts.ts_col, opts.id_col
  if mode == 'ts' and not ts_col then error('to_lance: ts_col required for mode=ts', 0) end
  if mode == 'id' and not id_col then error('to_lance: id_col required for mode=id', 0) end
  if mode == 'ts_id' and (not ts_col or not id_col) then
    error('to_lance: ts_col and id_col required for mode=ts_id', 0) end

  local wm = to_lance.watermark(dest)
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
  if not nq then error('to_lance: ' .. tostring(err), 0) end
  local n = tonumber(nq[1].n) or 0
  if n == 0 then
    return jres(0, wm and wm.ts or nil, wm and wm.id or nil, 'noop')
  end

  -- 首跑 Create、后续 APPEND（Lance dataset version 语义天然适配增量）
  local copy_mode = wm and ', APPEND' or ''
  local r = _duckdb_call("COPY (" .. sel .. ") TO '" .. dest:gsub("'", "''")
    .. "' (FORMAT LANCE" .. copy_mode .. ")")
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
    _duckdb_call('INSERT OR REPLACE INTO ' .. to_lance.watermark_table
      .. ' VALUES (' .. esc(dest) .. ', ' .. esc(new_ts) .. ', ' .. esc(new_id) .. ', now())')
  end
  return jres(n, new_ts, new_id, wm and 'append' or 'create')
end

-- 入口：接 luajit_s 的 JSON 字符串（调用约定：字符串参数；本库自带极简解码），
-- 或 struct 直传（compile wrapper 闭包场景）。op：run（默认）/ reset。
function to_lance.entry(raw)
  local opts = raw
  if type(raw) == 'string' then
    opts = json_decode(raw)
    if type(opts) ~= 'table' then error('to_lance: bad JSON opts: ' .. tostring(raw), 0) end
  end
  opts = opts or {}
  local op = opts.op or 'run'
  if op == 'reset' then
    to_lance.reset(opts.dest)
    return '{"ok":true,"reset":' .. json_encode(opts.dest) .. '}'
  end
  return to_lance.run(opts)
end

return to_lance
