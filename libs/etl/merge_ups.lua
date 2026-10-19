-- merge_ups.lua: 增量 MERGE upsert + skip-unchanged（duckdb/duckdb 讨论 #26075：
--   "MERGE for delta loads - skip not changed records"）——纯 SQL，零 FFI/零外部依赖。
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
-- 需要普通模式（非 trusted）：_duckdb_call / _duckdb_query（同 incremental.lua 的宿主能力）。
--
-- 语义（按主键 upsert，跳过未变化行）：
--   对 source 里每一行，按 key_cols 在 target 里定位：
--     · target 无此行        → INSERT（new）
--     · 有此行但 value 变了   → DELETE 旧 + INSERT 新（changed）
--     · 有此行且 value 全同   → SKIP（unchanged，不动 target，不触发重写）
--   retract=true 时额外：target 里有、source 里没有的 key → DELETE（全量 MERGE 语义）；
--   默认 retract=false = 纯 upsert（delta load 不删除缺行）。
--   "value 没变" 的判定 = 各 value 列逐列 md5 后按分隔符拼接再 md5 的签名一致（逐字段哈希，
--   分隔符歧义为零；NULL→固定哨兵，NULL==NULL 视为未变）。
--
-- 与 incremental.lua 的分工：incremental = 水位游标 append-only（只拉新行、按 ts/id 过滤，
--   不比对值、不更新旧行）；merge_ups = 按主键 upsert + 值比对 + 跳过未变（CDC/delta 落地）。
--   二者可组合：先 incremental 拉增量进 staging 表，再 merge_ups 把 staging 合并进正式表。
--
-- 用法（install 后）：
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'merge_ups');
--   SELECT * FROM luajit_module(mode := 'compile', sql_name := 'merge_ups_run',
--     source := 'return function(o) return merge_ups.run(o) end');
--   SELECT merge_ups_run({
--     target:='tgt_orders', source:='src_orders',
--     key_cols:['order_id'],
--     -- cols 省略=自动取 target 所有非主键列参与比对
--     -- retract:false
--   });
--   -- → {"in":N,"new":..,"changed":..,"unchanged":..,"overwrite":..,"retract":..}
--
-- 参数：
--   target    目标表（ident，可 schema.table；需与 source 列名兼容）
--   source    源（表 / 视图 / 子查询 / CTE；须暴露 target 的全部 key+value 列）
--   key_cols  主键列名数组（定位行身份，须非空）
--   cols      参与"变没变"比对的列名数组；省略=自动取 target 所有非 key 列
--   retract   默认 false；true=额外删除 target 有而 source 无的 key（全量 MERGE）
--
-- 返回（JSON 字符串，SQL 侧 json_extract）：
--   in         source 总行数
--   new        插入的新行（target 原无此 key）
--   changed    更新（target 有此 key 但 value 变）
--   unchanged  跳过（target 有此 key 且 value 全同）
--   overwrite  = changed（被覆盖删除的旧行数）
--   retract    因 retract 删除的行数（未开 retract 恒 0）
--
-- 诚实边界：
--   · 列比对按 CAST(col AS VARCHAR)——同类型不同表示（如 '1' vs 1、1.0 vs 1）会判为"变"；
--     要数值容忍请用 ROUND 后的源/目标列。
--   · 主键须唯一且非空（NULL 主键的"未变"判定用 IS NOT DISTINCT FROM 兜底，但语义弱）。
--   · 非事务最佳努力：DELETE 与 INSERT 为两条语句，中途失败可能半更新（正式用请包事务）。
--   · 大表：target 全量算一次签名（TGT 临时表），O(target) 内存/时间；千万行级建议先按
--     水位（incremental）预过滤 source 再 merge_ups。

local merge_ups = {}

local seq = 0
local function fresh(name)
  seq = seq + 1
  return name .. '_' .. os.time() .. '_' .. seq
end

local function esc(v)
  if type(v) == 'string' then return "'" .. v:gsub("'", "''") .. "'" end
  if v == nil then return 'NULL' end
  return tostring(v)
end

-- 简单 ident 校验：只允许 [A-Za-z0-9_]，最多一个 '.'（schema.table），不首尾点。
-- 用 gsub 剥合法字符后看是否残留（避免捕获组，本 Lua 的 %(...) 组解析不稳）。
local function ident(c)
  if type(c) ~= 'string' or c == '' then
    error('merge_ups: bad column/table identifier: ' .. tostring(c), 0)
  end
  if c:match('[^A-Za-z0-9_.]') then   -- 出现非法字符
    error('merge_ups: bad column/table identifier: ' .. tostring(c), 0)
  end
  if c:match('%.%.') or c:match('^%.') or c:match('%.$') then  -- 多个/首尾点
    error('merge_ups: bad column/table identifier: ' .. tostring(c), 0)
  end
  return c
end

local function in_arr(arr, x)
  for _, v in ipairs(arr) do if v == x then return true end end
  return false
end

-- target 列清单（information_schema，按 ordinal_position）
local function target_columns(target)
  -- 取裸表名（schema.tgt → tgt；tgt → tgt）
  local bare = target:match('^(.-)%.(%w+)$')
  if not bare then bare = target end
  local sql = "SELECT column_name FROM information_schema.columns "
    .. "WHERE lower(table_name) = lower(" .. esc(bare) .. ") ORDER BY ordinal_position"
  local rows = _duckdb_query(sql)
  if type(rows) == 'string' then error('merge_ups: target_columns: ' .. rows, 0) end
  local cols = {}
  for i = 1, #rows do cols[#cols + 1] = rows[i].column_name end
  return cols
end

-- value 列的签名表达式：逐列 md5(COALESCE(CAST(c AS VARCHAR), RS)) 后按 US 拼接再 md5
local function sig_expr(cols, us, rs)
  local fields = {}
  for _, c in ipairs(cols) do
    fields[#fields + 1] = "md5(COALESCE(CAST(" .. c .. " AS VARCHAR), " .. esc(rs) .. "))"
  end
  if #fields == 0 then return "md5('')" end
  return "md5(concat_ws(" .. esc(us) .. ", " .. table.concat(fields, ", ") .. "))"
end

function merge_ups.run(opts)
  opts = opts or {}
  local target, source = opts.target, opts.source
  local key_cols = opts.key_cols
  local cols = opts.cols
  local retract = (opts.retract == true)
  if not target or target == '' then error('merge_ups: target required', 0) end
  if not source or source == '' then error('merge_ups: source required', 0) end
  if type(key_cols) ~= 'table' or #key_cols == 0 then
    error('merge_ups: key_cols required (non-empty array)', 0)
  end
  target = ident(target)
  for i, k in ipairs(key_cols) do key_cols[i] = ident(k) end

  -- 解析 value 列（默认=target 所有非 key 列）
  local tcols = target_columns(target)
  if #tcols == 0 then error('merge_ups: target not found / no columns: ' .. target, 0) end
  if cols == nil then
    cols = {}
    for _, c in ipairs(tcols) do
      if not in_arr(key_cols, c) then cols[#cols + 1] = c end
    end
  else
    for i, c in ipairs(cols) do cols[i] = ident(c) end
  end

  local us, rs = '\x1f', '\x1e'  -- 分隔符 / NULL 哨兵前缀（控制字符，避免与数据撞）
  local key_sql = table.concat(key_cols, ", ")
  local col_sql = (cols and #cols > 0) and table.concat(cols, ", ") or nil
  local all_sql = key_sql .. (col_sql and ("," .. col_sql) or "")

  local sig = sig_expr(cols or {}, us, rs)
  local join_tgt = {}   -- t.<k> IS NOT DISTINCT FROM s.<k>
  for _, k in ipairs(key_cols) do join_tgt[#join_tgt + 1] = "t." .. k .. " IS NOT DISTINCT FROM s." .. k end
  local join_cond = table.concat(join_tgt, " AND ")

  local STAGE = fresh('_mup_stage')
  local TGT = fresh('_mup_tgt')
  local UPG = fresh('_mup_up')
  local RCT = fresh('_mup_rct')

  local function call(sql)
    local r = _duckdb_call(sql)
    if type(r) == 'string' and r:match('^error:') then error(r:sub(7), 0) end
    return r
  end
  local function q1(sql)
    local r = _duckdb_query(sql)
    if type(r) == 'string' then error('merge_ups: ' .. r, 0) end
    return r[1] and r[1].c or 0
  end

  -- 1. 暂存 source（带签名）
  call("CREATE OR REPLACE TEMP TABLE " .. STAGE .. " AS SELECT *, (" .. sig .. ") AS _sig FROM " .. source)

  -- 2. target 主键+签名
  call("CREATE OR REPLACE TEMP TABLE " .. TGT .. " AS SELECT " .. key_sql .. ", (" .. sig .. ") AS _sig FROM " .. target)

  -- 3. 需要 upsert 的行（新 或 变）：target 无匹配(_sig IS NULL) 或 签名不同
  call("CREATE OR REPLACE TEMP TABLE " .. UPG .. " AS "
    .. "SELECT s.* FROM " .. STAGE .. " s "
    .. "LEFT JOIN " .. TGT .. " t ON " .. join_cond .. " "
    .. "WHERE t._sig IS NULL OR t._sig <> s._sig")

  -- 4. 计数
  local total_in = q1("SELECT count(*)::BIGINT AS c FROM " .. STAGE)
  local upsert_count = q1("SELECT count(*)::BIGINT AS c FROM " .. UPG)
  local new_count = q1("SELECT count(*)::BIGINT AS c FROM " .. UPG .. " s "
    .. "LEFT JOIN " .. TGT .. " t ON " .. join_cond .. " WHERE t._sig IS NULL")
  local changed_count = upsert_count - new_count
  local unchanged_count = total_in - upsert_count
  local overwrite_count = changed_count   -- 覆盖删除的旧行 = 更新数（主键 1:1）

  -- 5. 删除 target 里将被 upsert 的 key（让 changed 行可重插）
  local del_keys = {}
  for _, k in ipairs(key_cols) do del_keys[#del_keys + 1] = target .. "." .. k .. " IS NOT DISTINCT FROM u." .. k end
  call("DELETE FROM " .. target .. " WHERE EXISTS (SELECT 1 FROM " .. UPG .. " u WHERE "
    .. table.concat(del_keys, " AND ") .. ")")

  -- 6. 插入 upsert 行
  call("INSERT INTO " .. target .. " (" .. all_sql .. ") SELECT " .. all_sql .. " FROM " .. UPG)

  -- 7. 可选 retract：删 target 有而 source 无的 key
  local retract_count = 0
  if retract then
    local rct_keys = {}
    for _, k in ipairs(key_cols) do rct_keys[#rct_keys + 1] = target .. "." .. k .. " IS NOT DISTINCT FROM s." .. k end
    retract_count = q1("SELECT count(*)::BIGINT AS c FROM " .. target
      .. " WHERE NOT EXISTS (SELECT 1 FROM " .. STAGE .. " s WHERE "
      .. table.concat(rct_keys, " AND ") .. ")")
    if retract_count > 0 then
      call("DELETE FROM " .. target .. " WHERE NOT EXISTS (SELECT 1 FROM " .. STAGE .. " s WHERE "
        .. table.concat(rct_keys, " AND ") .. ")")
    end
  end

  -- 8. 清理临时表
  call("DROP TABLE IF EXISTS " .. STAGE)
  call("DROP TABLE IF EXISTS " .. TGT)
  call("DROP TABLE IF EXISTS " .. UPG)

  local function js(n) return tostring(tonumber(n) or 0) end
  return '{"in":' .. js(total_in)
    .. ',"new":' .. js(new_count)
    .. ',"changed":' .. js(changed_count)
    .. ',"unchanged":' .. js(unchanged_count)
    .. ',"overwrite":' .. js(overwrite_count)
    .. ',"retract":' .. js(retract_count) .. '}'
end

return merge_ups
