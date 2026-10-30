-- @lib: soundex
-- @category: udf
-- @desc: 美国 Soundex 音编码 + difference 相似度（SQLite extension-functions.c 的 soundex()/difference()）。
--       DuckDB 原生只有 levenshtein（编辑距离），没有音近匹配 → 这是字符串 gap 里唯一真缺口。
--       op='soundex'   ：p.v → 4 位 Soundex 编码（'R163' 形式，标准美国 Soundex）
--       op='difference': p.a + p.b → 0-4 整数（两个 Soundex 编码逐位相同的位数，
--                        与 SQLite difference() 语义一致：对各自 soundex 后逐位比较）
--       算法 = 标准美国 Soundex（Census 规则）：
--         * 只保留字母，首字母保留（首字母同码也计）
--         * BFPV=1 CGJKQSXZ=2 DT=3 L=4 MN=5 R=6，其余元音(AEIOU)不编码且**重置**前码
--         * H/W/Y 不编码但**不重置**前码（同码被 H/W/Y 隔开仍算相邻同码，只取一次）
--         * 连续同码只取第一个；不足补 0 到 4 位
-- @source: 标准美国 Soundex（U.S. Census）；语义对齐 SQLite extension-functions.c
-- @requires: 无（纯 Lua）
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested（对拍 python3 标准 Soundex oracle，见 test_soundex.sql）
--
-- Usage:
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='soundex');
--   SELECT luajit_s('soundex', {v:'Robert', op:'soundex'});          → 'R163'
--   SELECT luajit_s('soundex', {v:'Rabart', op:'soundex'});          → 'R163'
--   SELECT luajit_s('soundex', {a:'Robert', b:'Rabart', op:'difference'}); → 4

local code = {
  B='1', F='1', P='1', V='1',
  C='2', G='2', J='2', K='2', Q='2', S='2', X='2', Z='2',
  D='3', T='3',
  L='4',
  M='5', N='5',
  R='6',
}
local HWY = { H=true, W=true, Y=true }

local function soundex(word)
  local w = ''
  for ch in tostring(word):upper():gmatch('%a') do
    w = w .. ch
  end
  if w == '' then return '' end
  local res = w:sub(1, 1)
  local prev = code[w:sub(1, 1)]
  for i = 2, #w do
    local c = w:sub(i, i)
    local d = code[c]
    if d == nil then
      if HWY[c] then
        -- H/W/Y：不重置 prev（不重复相邻同码）
      else
        prev = nil  -- 元音等：重置 prev（分隔符）
      end
    else
      if d ~= prev then
        res = res .. d
        prev = d
      end
    end
  end
  return (res .. '000'):sub(1, 4)
end

local function difference(a, b)
  local sa, sb = soundex(a), soundex(b)
  local n = #sa < #sb and #sa or #sb
  local same = 0
  for i = 1, n do
    if sa:sub(i, i) == sb:sub(i, i) then same = same + 1 end
  end
  return tostring(same)
end

local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '' end
  local op = p.op or 'soundex'
  if op == 'soundex' then
    return soundex(p.v or '')
  elseif op == 'difference' then
    return difference(p.a or '', p.b or '')
  end
  return 'ERR: unknown op ' .. tostring(op)
end

return function(p)
  local ok, r = pcall(run, p)
  if ok then return r end
  return 'ERR: ' .. tostring(r)
end
