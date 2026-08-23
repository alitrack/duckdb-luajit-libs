-- @lib: cncheck
-- @category: udf
-- @desc: 中国数据校验位算法全家桶（纯 Lua，自包含）。
--       op='id_card'：18 位身份证（GB 11643-1999 加权校验位 + X），兼容 15 位老号；
--       op='uscc'：统一社会信用代码 18 位（GB 32100-2015，31 字符集加权 mod 31）；
--       op='bank_card'：银行卡 Luhn（MOD-10，13–19 位）；
--       op='phone'：大陆手机号（11 位，1[3-9] 段近似，实用校验）；
--       op='id_extract'：身份证 → 区划/出生/性别 JSON。
--       各校验 op 返回 JSON：{"valid":true|false,"reason":"..."}（配 json_extract 用）。
-- @source: original（duckdb-luajit 系列，自包含无外部依赖）
-- @requires: none
-- 锚点（已验证）：身份证 11010519491231002X 有效 / 110105194912310020 无效；
--   USCC 91350100M000100Y43 有效 / …44 无效；银行卡 4111111111111111 有效；手机 13800138000 有效。
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='cncheck');
--   身份证:  SELECT json_extract(luajit_s('cncheck', {v: '11010519491231002X', op: 'id_card'}), '$.valid');
--   USCC:    SELECT luajit_s('cncheck', {v: '91350100M000100Y43', op: 'uscc'});
--   银行:    SELECT luajit_s('cncheck', {v: '4111111111111111', op: 'bank_card'});
--   手机:    SELECT luajit_s('cncheck', {v: '13800138000', op: 'phone'});
--   身份证字段: SELECT luajit_s('cncheck', {v: '11010519491231002X', op: 'id_extract'});
--             → {"region":"110105","birth":"1949-12-31","sex":"M"}

-- ======================================================================
-- JSON 编码（精简自包含）
-- ======================================================================
local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"'
    elseif c == '\\' then return '\\\\'
    elseif c == '\n' then return '\\n'
    elseif c == '\t' then return '\\t'
    else return c end
  end))
end

local function jbool(b) return b and 'true' or 'false' end

local function result(valid, reason)
  return '{"valid":' .. jbool(valid) .. ',"reason":"' .. json_escape(tostring(reason)) .. '"}'
end

-- ======================================================================
-- 身份证（GB 11643-1999）
-- ======================================================================
local ID_WEIGHTS = { 7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2 }
local ID_CHECK = { ['0']='1', ['1']='0', ['2']='X', ['3']='9', ['4']='8',
                   ['5']='7', ['6']='6', ['7']='5', ['8']='4', ['9']='3', ['10']='2' }

local function id_card_check(v)
  local s = (tostring(v):gsub('%s+', ''):upper())
  if #s ~= 18 then return result(false, '长度须为 18 位（15 位老号不支持校验位）') end
  if not s:match('^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d[%dX]$') then
    return result(false, '含非法字符（17 位数字 + 末位数字或 X）')
  end
  local sum = 0
  for i = 1, 17 do
    sum = sum + (tonumber(s:sub(i, i)) or 0) * ID_WEIGHTS[i]
  end
  local expect = ID_CHECK[tostring(sum % 11)]
  local got = s:sub(18, 18)
  if expect == got then return result(true, 'OK') end
  return result(false, '校验位不符：期望 ' .. expect .. '，实为 ' .. got)
end

local function id_extract(v)
  local s = (tostring(v):gsub('%s+', ''):upper())
  local region, birth, sex
  if #s == 18 then
    if not s:match('^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d[%dX]$') then
      return result(false, '非法身份证')
    end
    region = s:sub(1, 6)
    birth = s:sub(7, 14)
    sex = (tonumber(s:sub(17, 17)) or 0) % 2 == 1 and 'M' or 'F'
  elseif #s == 15 then
    if not s:match('^%d+$') then return result(false, '非法身份证') end
    region = s:sub(1, 6)
    birth = '19' .. s:sub(7, 12)
    sex = (tonumber(s:sub(15, 15)) or 0) % 2 == 1 and 'M' or 'F'
  else
    return result(false, '长度须为 15 或 18 位')
  end
  local by = birth:sub(1, 4)
  local bm = birth:sub(5, 6)
  local bd = birth:sub(7, 8)
  return '{"region":"' .. json_escape(region) .. '","birth":"' ..
         json_escape(by .. '-' .. bm .. '-' .. bd) .. '","sex":"' .. sex .. '"}'
end

-- ======================================================================
-- 统一社会信用代码（GB 32100-2015）
-- ======================================================================
local USCC_CHARS = '0123456789ABCDEFGHJKLMNPQRTUWXY'  -- 31 字符，去 I O S V Z
local uscc_map = {}
for i = 1, 31 do uscc_map[USCC_CHARS:sub(i, i)] = i - 1 end
local USCC_WEIGHTS = { 1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28 }

local function uscc_check(v)
  local s = (tostring(v):gsub('%s+', ''):upper())
  if #s ~= 18 then return result(false, '长度须为 18 位') end
  local sum = 0
  for i = 1, 17 do
    local ch = s:sub(i, i)
    local val = uscc_map[ch]
    if val == nil then return result(false, '位置 ' .. i .. ' 字符 ' .. ch .. ' 不在 31 字符集') end
    sum = sum + val * USCC_WEIGHTS[i]
  end
  local c18 = 31 - (sum % 31)
  local expect = (c18 >= 31) and '0' or USCC_CHARS:sub(c18 + 1, c18 + 1)
  local got = s:sub(18, 18)
  if expect == got then return result(true, 'OK') end
  return result(false, '校验位不符：期望 ' .. expect .. '，实为 ' .. got)
end

-- ======================================================================
-- 银行卡（Luhn / MOD-10）
-- ======================================================================
local function luhn_valid(s)
  local sum, alt = 0, false
  for i = #s, 1, -1 do
    local d = tonumber(s:sub(i, i))
    if d == nil then return false end
    if alt then
      d = d * 2
      if d > 9 then d = d - 9 end
    end
    sum = sum + d
    alt = not alt
  end
  return sum % 10 == 0
end

local function bank_card_check(v)
  local s = (tostring(v):gsub('%s+', ''))
  if not s:match('^%d+$') then return result(false, '含非数字字符') end
  if #s < 13 or #s > 19 then return result(false, '长度须为 13–19 位') end
  if luhn_valid(s) then return result(true, 'Luhn OK') end
  return result(false, 'Luhn 校验失败')
end

-- ======================================================================
-- 手机号（大陆，实用近似：1[3-9] + 9 位）
-- ======================================================================
local function phone_check(v)
  local s = (tostring(v):gsub('%s+', ''))
  if not s:match('^%d+$') then return result(false, '含非数字字符') end
  if #s ~= 11 then return result(false, '长度须为 11 位') end
  if s:match('^1[3-9]') then
    return result(true, 'OK（1[3-9] 段）')
  end
  return result(false, '号段不符（非 1[3-9] 开头）')
end

-- ======================================================================
-- UDF 分发包装
-- ======================================================================
local OPS = {
  id_card = id_card_check,
  uscc = uscc_check,
  bank_card = bank_card_check,
  phone = phone_check,
}

return function(p)
  if type(p) ~= 'table' then
    return result(false, '参数须为表 {v=..., op=...}')
  end
  local v = p.v
  if v == nil or v == '' then return result(false, '空值') end
  local op = p.op or 'id_card'
  if op == 'id_extract' then
    return id_extract(v)
  end
  local fn = OPS[op]
  if not fn then
    return result(false, '未知 op：' .. op .. '（可选 id_card/uscc/bank_card/phone/id_extract）')
  end
  return fn(v)
end
