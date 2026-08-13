-- scd2.lua: 缓慢变化维度（SCD 类型 2）——属性变化保留历史版本（2026-08-13）
-- 需要普通模式（非 trusted）：_duckdb_call / _duckdb_query
--
-- 用法（install 后）：
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'scd2');
--   SELECT * FROM luajit_module(mode := 'compile', sql_name := 'scd2_run',
--     source := 'return function(opts) return scd2.run(opts) end');
--   SELECT scd2_run({target:='dim_customer', source:='src_customer', key_col:='cust_id',
--                    attr_cols:={'city','tier'}, ts_col:='ts'});
--
-- 目标表结构（首次自动建）：
--   <源全部业务列> + _valid_from TIMESTAMP + _valid_to TIMESTAMP + _is_current BOOLEAN + _version BIGINT
-- 属性比较：md5(concat_ws('|', cast(a as varchar), ...)) 指纹（DuckDB 内建 md5）
-- 语义：key 相同 + 指纹不同 → 关闭旧版本(_valid_to=ts, _is_current=false)，开新版本(version+1)
--       key 不存在 → 直接插入 version=1
--       指纹相同 → 跳过（幂等，重复跑不产生新版本）
-- 约定：source 为表名；ts_col 也在业务列里（SELECT * 保留）

local scd2 = {}

local function esc(v)
  if type(v) == 'string' then return "'" .. v:gsub("'", "''") .. "'" end
  if v == nil then return 'NULL' end
  return tostring(v)
end

-- 属性指纹表达式
local function fp_expr(attr_cols)
  local parts = {}
  for _, c in ipairs(attr_cols) do
    parts[#parts + 1] = 'coalesce(cast(' .. c .. ' as varchar), chr(0))'
  end
  return "md5(concat_ws('|', " .. table.concat(parts, ', ') .. '))'
end

-- 取表业务列（按定义顺序）
local function columns_of(tbl)
  local rows, err = _duckdb_query(
    "SELECT column_name FROM information_schema.columns WHERE table_name = " .. esc(tbl)
    .. ' AND table_schema = current_schema() ORDER BY ordinal_position')
  if not rows then error('scd2: cannot introspect ' .. tbl .. ': ' .. tostring(err), 0) end
  local cols = {}
  for _, r in ipairs(rows) do cols[#cols + 1] = r.column_name end
  if #cols == 0 then error('scd2: no columns found for ' .. tbl, 0) end
  return cols
end

-- 执行 SCD2 合并
-- opts = { target=目标维度表, source=源表, key_col=业务键, attr_cols={属性...}, ts_col=生效时间 }
-- 返回 {inserted=N, closed=N}
function scd2.run(opts)
  opts = opts or {}
  local target, source = opts.target, opts.source
  local key_col, ts_col = opts.key_col, opts.ts_col
  local attr_cols = opts.attr_cols or {}
  if not target or not source or not key_col or not ts_col or #attr_cols == 0 then
    error('scd2: target, source, key_col, ts_col, attr_cols required', 0) end

  -- 1. 建目标表（复制源结构 + 管理列）
  local r = _duckdb_call('CREATE TABLE IF NOT EXISTS ' .. target
    .. ' AS SELECT * FROM ' .. source .. ' WHERE FALSE')
  if type(r) == 'string' and r:match('^error:') then error(r:sub(7), 0) end
  for _, ddl in ipairs({
    'ALTER TABLE ' .. target .. ' ADD COLUMN IF NOT EXISTS _valid_from TIMESTAMP',
    'ALTER TABLE ' .. target .. ' ADD COLUMN IF NOT EXISTS _valid_to TIMESTAMP',
    'ALTER TABLE ' .. target .. ' ADD COLUMN IF NOT EXISTS _is_current BOOLEAN',
    'ALTER TABLE ' .. target .. ' ADD COLUMN IF NOT EXISTS _version BIGINT',
  }) do
    local rr = _duckdb_call(ddl)
    if type(rr) == 'string' and rr:match('^error:') then error(rr:sub(7), 0) end
  end

  local cols = columns_of(source)
  local fp = fp_expr(attr_cols)
  local src = '(SELECT s.*, ' .. fp .. ' AS _fp FROM ' .. source .. ' s)'
  local cur = '(SELECT ' .. key_col .. ' AS key, ' .. fp .. ' AS _fp, _version FROM '
    .. target .. ' WHERE _is_current)'

  -- 2. 物化待插入集（基于旧状态：新 key 或属性变化；version = 旧版本 + 1）
  local ins = '(SELECT s.*, s.' .. ts_col .. ' AS _valid_from, NULL AS _valid_to, true AS _is_current,'
    .. ' coalesce(c._version, 0) + 1 AS _version FROM ' .. src .. ' s'
    .. ' LEFT JOIN (SELECT * FROM ' .. cur .. ') c ON s.' .. key_col .. ' = c.key'
    .. ' WHERE c.key IS NULL OR s._fp <> c._fp)'
  local iq, ierr = _duckdb_query('SELECT CAST(count(*) AS BIGINT) AS n FROM ' .. ins)
  if not iq then error('scd2: ' .. tostring(ierr), 0) end
  local inserted = tonumber(iq[1].n) or 0
  if inserted > 0 then
    local rr = _duckdb_call('CREATE OR REPLACE TEMP TABLE _scd2_ins AS ' .. ins)
    if type(rr) == 'string' and rr:match('^error:') then error(rr:sub(7), 0) end
  end

  -- 3. 关闭旧版本（基于旧状态；INSERT 尚未发生，cur 快照不变）
  local chg = '(SELECT c.key, s.ts FROM ' .. src .. ' s JOIN (SELECT * FROM ' .. cur .. ') c'
    .. ' ON s.' .. key_col .. ' = c.key WHERE s._fp <> c._fp)'
  local cq, cerr = _duckdb_query('SELECT CAST(count(*) AS BIGINT) AS n FROM ' .. chg)
  if not cq then error('scd2: ' .. tostring(cerr), 0) end
  local closed = tonumber(cq[1].n) or 0
  if closed > 0 then
    local rr = _duckdb_call('UPDATE ' .. target .. ' t SET _valid_to = u.ts, _is_current = false'
      .. ' FROM ' .. chg .. ' u WHERE t.' .. key_col .. ' = u.key AND t._is_current')
    if type(rr) == 'string' and rr:match('^error:') then error(rr:sub(7), 0) end
  end

  -- 4. 插入物化行（不受状态变化影响）
  if inserted > 0 then
    local sel_cols = {}
    for _, c in ipairs(cols) do sel_cols[#sel_cols + 1] = 'i.' .. c end
    local rr = _duckdb_call('INSERT INTO ' .. target
      .. ' (' .. table.concat(cols, ', ') .. ', _valid_from, _valid_to, _is_current, _version)'
      .. ' SELECT ' .. table.concat(sel_cols, ', ')
      .. ', i._valid_from, i._valid_to, i._is_current, i._version FROM _scd2_ins i')
    if type(rr) == 'string' and rr:match('^error:') then error(rr:sub(7), 0) end
  end

  return '{"inserted":' .. tostring(inserted) .. ',"closed":' .. tostring(closed) .. '}'
end

return scd2
