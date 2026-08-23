-- @lib: pinyin
-- @category: udf
-- @desc: 中文 → 拼音（vendored pypinyin 0.55.0 词典快照，纯 Lua，零 FFI，单文件）。
--       逐字最长词组匹配（词组优先解决多音字语境，如 "重庆"→chóngqìng、
--       "一丁不识"→yīdīngbùshí）+ 字符表回退；ASCII/数字原样透传；
--       无映射的非 ASCII 字符 → "?"（unknown='keep' 时保留原字符）。
--       词典规模：41923 字符 + 47111 词组（内嵌于本文件，由 make_pinyin_data.py
--       从 pypinyin 生成，勿手改）。
--       op：
--         'pinyin'（默认）→ {"pinyin":["chóngqìng",...],"joined":"chóngqìng..."}
--         'join'          → 仅拼接字符串（分隔符 sep，默认空）
--         'first'         → 首字母（first_join=true 拼成串，默认数组）
--       参数：
--         v        : 输入文本
--         style    : 'tones'（默认，带声调）/ 'notones'（无声调字母，数据 P0/PH0）
--         sep      : join 的拼接分隔符（默认 ''）
--         unknown  : '?'（默认）/ 'keep'（无映射非 ASCII 字符保留原字符）
-- @source: vendored 词典 https://github.com/mozillazg/pinyin-data → pypinyin
--          (pypinyin 0.55.0, MIT)；转换引擎 original
-- @requires: none（单文件自包含）
-- Usage:
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'pinyin');
--   SELECT luajit_s('pinyin', {v: '重庆'});             -- {"pinyin":["chóngqìng"],"joined":"chóngqìng"}
--   SELECT luajit_s('pinyin', {v: '中国', op: 'join'});  -- zhōngguó
--   SELECT luajit_s('pinyin', {v: '北京', style: 'notones'}); -- {"pinyin":["beijing"],...}

-- codepoint → utf8 字节串（LuaJIT 位运算可用 >> &）
local function cp_to_utf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + (cp >> 6), 0x80 + (cp & 0x3F))
  elseif cp < 0x10000 then
    return string.char(0xE0 + (cp >> 12), 0x80 + ((cp >> 6) & 0x3F), 0x80 + (cp & 0x3F))
  else
    return string.char(0xF0 + (cp >> 18), 0x80 + ((cp >> 12) & 0x3F),
                       0x80 + ((cp >> 6) & 0x3F), 0x80 + (cp & 0x3F))
  end
end

-- utf8 串 → codepoint 数组（非法序列 → 原字节透传为 0x80-0xFF 伪码点，convert 原样还原）
local function to_codes(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b1 = s:byte(i)
    local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
    if b1 < 0x80 then
      out[#out + 1] = b1; i = i + 1
    elseif b1 >= 0xF0 and b2 and b3 and b4 and
           ((b2 & 0xC0) == 0x80) and ((b3 & 0xC0) == 0x80) and ((b4 & 0xC0) == 0x80) then
      out[#out + 1] = ((b1 & 0x07) << 18) + ((b2 & 0x3F) << 12) + ((b3 & 0x3F) << 6) + (b4 & 0x3F)
      i = i + 4
    elseif b1 >= 0xE0 and b2 and b3 and
           ((b2 & 0xC0) == 0x80) and ((b3 & 0xC0) == 0x80) then
      out[#out + 1] = ((b1 & 0x0F) << 12) + ((b2 & 0x3F) << 6) + (b3 & 0x3F)
      i = i + 3
    elseif b1 >= 0xC0 and b2 and ((b2 & 0xC0) == 0x80) then
      out[#out + 1] = ((b1 & 0x1F) << 6) + (b2 & 0x3F)
      i = i + 2
    else
      -- 非法/孤立字节：透传（用负值标记，convert 直接原样输出字节）
      out[#out + 1] = -b1
      i = i + 1
    end
  end
  return out
end

local function json_escape(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    local m = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return m[c] or string.format('\\u%04x', c:byte())
  end))
end

-- P   : {[codepoint]=pinyin}          -- 字符表（多音取首读）
-- PH  : {[phrase]=pinyin}             -- 词组表
-- P0  : 无调字符表；PH0: 无调词组表    -- 可选
local function build(d)
  assert(type(d) == 'table', 'pinyin_dict_data: expected table {P, PH, P0, PH0}')
  local P, PH, P0, PH0 = d.P, d.PH, d.P0, d.PH0
  assert(type(P) == 'table', 'pinyin_dict_data: P missing')

  -- codes[i..j] → utf8 串（词组键）
  local function slice_utf8(codes, i, j)
    local buf = {}
    for k = i, j do
      local cp = codes[k]
      if cp >= 0 then buf[#buf + 1] = cp_to_utf8(cp) end
    end
    return table.concat(buf)
  end

  -- 逐字最长匹配转换 → 拼音段数组 + unk_codes（仅无映射汉字的码点，按出现序，供 keep 还原）。
  -- 无映射汉字 → unk；非汉字 → 透传原字节；非法字节 → 透传。
  local function convert(codes, unk, P2, PH2)
    local out, unk_codes = {}, {}
    local i, n = 1, #codes
    while i <= n do
      local cp = codes[i]
      if cp < 0 then
        -- 非法/孤立字节：原样透传
        out[#out + 1] = string.char(-cp)
        i = i + 1
      else
        local matched = false
        if PH2 then
          local maxl = math.min(n - i + 1, 12)
          for l = maxl, 1, -1 do
            local hit = PH2[slice_utf8(codes, i, i + l - 1)]
            if hit then
              out[#out + 1] = hit
              i = i + l
              matched = true
              break
            end
          end
        end
        if not matched then
          local p = P2[cp]
          if p then
            out[#out + 1] = p
          elseif cp < 0x80 then
            out[#out + 1] = cp_to_utf8(cp)  -- ASCII 透传
          else
            out[#out + 1] = unk            -- 非 ASCII 无映射字符 → unknown
            unk_codes[#unk_codes + 1] = cp
          end
          i = i + 1
        end
      end
    end
    return out, unk_codes
  end

  return function(p)
    if type(p) == 'string' then p = {v = p} end
    if type(p) ~= 'table' then return '{"error":"bad input"}' end
    local v = p.v
    if not v or v == '' then return '{"error":"missing v"}' end
    local op = p.op or 'pinyin'
    local sep = p.sep or ''
    local notones = (p.style == 'notones')
    local P2 = notones and (P0 or P) or P
    local PH2 = notones and (PH0 or nil) or (PH or nil)
    local unk = (p.unknown == 'keep') and '\0' or '?'

    local codes = to_codes(v)
    if #codes == 0 then return '{"error":"empty after utf8 decode"}' end
    local parts, unk_codes = convert(codes, unk, P2, PH2)

    if p.unknown == 'keep' then
      -- '\0' 占位 → 按出现序还原为原汉字（unk_codes 与占位一一对应）
      local ci = 1
      for pi = 1, #parts do
        if parts[pi] == '\0' then
          parts[pi] = cp_to_utf8(unk_codes[ci])
          ci = ci + 1
        end
      end
    end

    if op == 'join' then
      return '"' .. json_escape(table.concat(parts, sep)) .. '"'
    elseif op == 'first' then
      local firsts = {}
      for i, s in ipairs(parts) do
        firsts[i] = (s:sub(1, 1):lower())
      end
      if p.first_join then
        return '"' .. json_escape(table.concat(firsts, sep)) .. '"'
      end
      local arr = {}
      for _, f in ipairs(firsts) do arr[#arr + 1] = '"' .. json_escape(f) .. '"' end
      return '[' .. table.concat(arr, ',') .. ']'
    else
      local arr = {}
      for _, s in ipairs(parts) do arr[#arr + 1] = '"' .. json_escape(s) .. '"' end
      return '{"pinyin":[' .. table.concat(arr, ',') ..
             '],"joined":"' .. json_escape(table.concat(parts, sep)) .. '"}'
    end
  end
end

-- 入口：build(d) → UDF 函数，d = dofile('pinyin_dict_data.lua') 的返回表。
-- 用法：dofile('pinyin.lua')(dofile('pinyin_dict_data.lua'))
return build
