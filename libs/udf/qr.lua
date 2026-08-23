-- @lib: qr
-- @category: udf
-- @desc: QR 码生成（纯 Lua，自包含，无 FFI）——把文本编码成 QR 模块矩阵。
--       Byte 模式（任意 UTF-8 文本）、EC 级别 L/M/Q/H、自动选 mask（penalty 最小）。
--       布局/纠错算法移植自开源参考实现（python-qrcode / Nayuki，MIT/Apache），
--       常量与流程逐一对齐，可用 ZXing/手机扫码独立验证。
--       op 选项：
--         'matrix' → JSON 二维数组（1=深色 0=浅色）
--         'svg'    → 完整 SVG（白底 + 4 模块静区，1 模块=scale px，默认 4）
--         'info'   → {version,size,ec,mask,codewords,data_capacity}
--       诚实边界：版本 1–6（约 ≤132 字节 Byte 负载），仅 Byte 模式（无数值/字母/
--       汉字压缩模式）。更大负载/多模式请走原生路径。
-- @source: 布局移植自 python-qrcode(MIT) 与 Nayuki QR Code generator(Apache-2.0) 的公开算法
-- @requires: 无（用 LuaJIT 原生位运算 & ~ | << >>；纯 Lua 5.1 需 bit 库）
--
-- Usage (duckdb-luajit, scalar mode):
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='qr');
--   svg:      SELECT luajit_s('qr', {v: 'https://ex.com', op: 'svg', ec: 'M'});
--   matrix:   SELECT luajit_s('qr', {v: 'hello', op: 'matrix'});
--   size:     SELECT json_extract(luajit_s('qr',{v:='x',op:='info'}), '$.size');
--   校验：生成 SVG → ZXing/手机扫码解码回原文，即证明编码正确。

-- ======================================================================
-- GF(256)（QR 多项式 0x11d）
-- ======================================================================
local EXP, LOG = {}, {}
do
  local x = 1
  for i = 0, 254 do
    EXP[i] = x
    LOG[x] = i
    x = x * 2
    if x >= 256 then x = x ~ 0x11d end
  end
end
local function gf_mul(a, b)
  if a == 0 or b == 0 then return 0 end
  return EXP[(LOG[a] + LOG[b]) % 255]
end

-- ======================================================================
-- Reed-Solomon（Nayuki 算法：divisor + remainder）
-- ======================================================================
local function rs_divisor(degree)
  local result = {}
  for j = 1, degree do result[j] = 0 end
  result[degree] = 1
  local root = 1
  for i = 1, degree do
    for j = 1, degree do
      result[j] = gf_mul(result[j], root)
      if j < degree then result[j] = result[j] ~ result[j + 1] end
    end
    root = gf_mul(root, 2)
  end
  return result
end

local function rs_encode(data, ec_len)
  local divisor = rs_divisor(ec_len)
  local result = {}
  for j = 1, ec_len do result[j] = 0 end
  for i = 1, #data do
    local factor = data[i] ~ result[1]
    for j = 1, ec_len - 1 do result[j] = result[j + 1] end
    result[ec_len] = 0
    for j = 1, ec_len do
      result[j] = result[j] ~ gf_mul(factor, divisor[j])
    end
  end
  return result
end

-- ======================================================================
-- 版本/纠错块表（python-qrcode base.py，版本 1–6）
--   entry = {count, total_codewords, data_codewords}；ec = total - data
-- ======================================================================
local RS = {
  [1] = { L = {{1,26,19}}, M = {{1,26,16}}, Q = {{1,26,13}}, H = {{1,26,9}} },
  [2] = { L = {{1,44,34}}, M = {{1,44,28}}, Q = {{1,44,22}}, H = {{1,44,16}} },
  [3] = { L = {{1,70,55}}, M = {{1,70,44}}, Q = {{2,35,17}}, H = {{2,35,13}} },
  [4] = { L = {{1,100,80}}, M = {{2,50,32}}, Q = {{2,50,24}}, H = {{4,25,9}} },
  [5] = { L = {{1,134,108}}, M = {{2,67,43}},
          Q = {{2,33,15},{2,34,16}}, H = {{2,33,11},{2,34,12}} },
  [6] = { L = {{2,86,68}}, M = {{4,43,27}}, Q = {{4,43,19}}, H = {{4,43,15}} },
}
local EC_BITS = { M = 0, L = 1, Q = 2, H = 3 }   -- 格式信息里 EC 的 2 位编码
local ALIGN = { [2] = {6,18}, [3] = {6,22}, [4] = {6,26}, [5] = {6,30}, [6] = {6,34} }

local function data_total_of(v, ec)
  local t = 0
  for _, e in ipairs(RS[v][ec]) do t = t + e[1] * e[3] end
  return t
end

local function choose_version(datalen, ec)
  for v = 1, 6 do
    local need = 4 + 8 + 8 * datalen   -- mode(4) + count(8, v1-9) + data
    if need <= data_total_of(v, ec) * 8 then return v end
  end
  return nil
end

-- ======================================================================
-- 数据位流（Byte 模式 0100）
-- ======================================================================
local function build_bitstream(text, data_total)
  local bits = {}
  local function push(val, n)
    for i = n - 1, 0, -1 do bits[#bits + 1] = (val >> i) & 1 end
  end
  push(4, 4)
  push(#text, 8)
  for i = 1, #text do push(text:byte(i), 8) end
  local cap = data_total * 8
  for _ = 1, 4 do if #bits < cap then bits[#bits + 1] = 0 else break end end
  if #bits % 8 ~= 0 then
    for _ = 1, 8 - (#bits % 8) do bits[#bits + 1] = 0 end
  end
  local pad = 0xEC
  while #bits < cap do
    push(pad, 8)
    pad = (pad == 0xEC) and 0x11 or 0xEC
  end
  local bytes = {}
  for i = 1, #bits, 8 do
    local b = 0
    for j = 0, 7 do b = b * 2 + (bits[i + j] or 0) end
    bytes[#bytes + 1] = b
  end
  return bytes
end

-- 分块 + RS + 交织
local function make_codewords(data_bytes, version, ec)
  local entries = RS[version][ec]
  local blocks, pos = {}, 1
  for _, e in ipairs(entries) do
    for _ = 1, e[1] do
      local blk = {}
      for i = 1, e[3] do
        blk[i] = data_bytes[pos] or 0
        pos = pos + 1
      end
      local ecw = rs_encode(blk, e[2] - e[3])
      blocks[#blocks + 1] = { data = blk, ec = ecw, dl = e[3], el = e[2] - e[3] }
    end
  end
  local maxd, maxe = 0, 0
  for _, b in ipairs(blocks) do
    if b.dl > maxd then maxd = b.dl end
    if b.el > maxe then maxe = b.el end
  end
  local out = {}
  for i = 1, maxd do
    for _, b in ipairs(blocks) do
      if i <= b.dl then out[#out + 1] = b.data[i] end
    end
  end
  for i = 1, maxe do
    for _, b in ipairs(blocks) do
      if i <= b.el then out[#out + 1] = b.ec[i] end
    end
  end
  return out
end

-- ======================================================================
-- 格式信息 BCH(15,5)  G15=0x537, G15_MASK=0x5412
-- ======================================================================
local function bch_digit(x)
  local d = 0
  while x ~= 0 do d = d + 1 x = x >> 1 end
  return d
end
local function bch_format(data)
  local G15, G15_MASK = 0x537, 0x5412
  local d = data << 10
  while bch_digit(d) - bch_digit(G15) >= 0 do
    d = d ~ (G15 << (bch_digit(d) - bch_digit(G15)))
  end
  return (data << 10) ~ d ~ G15_MASK
end

-- mask 函数（python-qrcode util.mask_func，(row, col)）
local function mask_val(m, r, c)
  if m == 0 then return (r + c) % 2 == 0
  elseif m == 1 then return r % 2 == 0
  elseif m == 2 then return c % 3 == 0
  elseif m == 3 then return (r + c) % 3 == 0
  elseif m == 4 then return (math.floor(r / 2) + math.floor(c / 3)) % 2 == 0
  elseif m == 5 then return (r * c) % 2 + (r * c) % 3 == 0
  elseif m == 6 then return ((r * c) % 2 + (r * c) % 3) % 2 == 0
  else return ((r * c) % 3 + (r + c) % 2) % 2 == 0 end
end

-- ======================================================================
-- 矩阵构建（python-qrcode main.py 布局，0-based [r][c]）
-- ======================================================================
local function size_of(v) return 17 + 4 * v end

local function build_matrix(codewords, version, ec, mask)
  local size = size_of(version)
  local grid, reserved = {}, {}
  for r = 0, size - 1 do
    grid[r], reserved[r] = {}, {}
    for c = 0, size - 1 do grid[r][c] = 0 reserved[r][c] = false end
  end

  -- 1) 定位图案 + 分隔区
  local function finder(r0, c0)
    for r = -1, 7 do
      for c = -1, 7 do
        local rr, cc = r0 + r, c0 + c
        if rr >= 0 and cc >= 0 and rr < size and cc < size then
          local v = 0
          if r >= 0 and r <= 6 and c >= 0 and c <= 6 then
            local border = (r == 0 or r == 6 or c == 0 or c == 6)
            local core = (r >= 2 and r <= 4 and c >= 2 and c <= 4)
            v = (border or core) and 1 or 0
          end
          grid[rr][cc] = v
          reserved[rr][cc] = true
        end
      end
    end
  end
  finder(0, 0)
  finder(0, size - 7)
  finder(size - 7, 0)

  -- 2) 时序图案（行 6 / 列 6，偶数坐标深色）
  for i = 0, size - 1 do
    if not reserved[i][6] then
      grid[i][6] = (i % 2 == 0) and 1 or 0
      reserved[i][6] = true
    end
    if not reserved[6][i] then
      grid[6][i] = (i % 2 == 0) and 1 or 0
      reserved[6][i] = true
    end
  end

  -- 3) 对齐图案（v2+；与 finder/timing 重叠处跳过）
  local pos = ALIGN[version]
  if pos then
    for _, row in ipairs(pos) do
      for _, col in ipairs(pos) do
        if not reserved[row][col] then
          for r = -2, 2 do
            for c = -2, 2 do
              local rr, cc = row + r, col + c
              if rr >= 0 and cc >= 0 and rr < size and cc < size then
                local dark = (math.abs(r) == 2 or math.abs(c) == 2 or (r == 0 and c == 0)) and 1 or 0
                grid[rr][cc] = dark
                reserved[rr][cc] = true
              end
            end
          end
        end
      end
    end
  end

  -- 4) 格式信息 + 固定暗模块（先放置，数据放置时跳过 reserved）
  local bits = bch_format((EC_BITS[ec] << 3) | mask)
  for i = 0, 14 do   -- 竖向（列 8）
    local mod = (bits >> i) & 1
    local r
    if i < 6 then r = i
    elseif i < 8 then r = i + 1
    else r = size - 15 + i end
    grid[r][8] = mod
    reserved[r][8] = true
  end
  for i = 0, 14 do   -- 横向（行 8）
    local mod = (bits >> i) & 1
    local c
    if i < 8 then c = size - i - 1
    elseif i == 8 then c = 15 - i
    else c = 15 - i - 1 end
    grid[8][c] = mod
    reserved[8][c] = true
  end
  grid[size - 8][8] = 1
  reserved[size - 8][8] = true

  -- 5) 数据 zigzag + mask（从右下，双列步进，跳列 6）
  local total_bits = #codewords * 8
  local byteIndex, bitIndex = 0, 7
  local row = size - 1
  local inc = -1
  for col = size - 1, 1, -2 do
    if col <= 6 then col = col - 1 end   -- 跳过量时列 6
    while true do
      for _, c in ipairs({ col, col - 1 }) do
        if not reserved[row][c] then
          local dark = 0
          if byteIndex < #codewords then
            dark = (codewords[byteIndex + 1] >> bitIndex) & 1
          end
          if mask_val(mask, row, c) then dark = dark ~ 1 end
          grid[row][c] = dark
          reserved[row][c] = true
          bitIndex = bitIndex - 1
          if bitIndex == -1 then
            byteIndex = byteIndex + 1
            bitIndex = 7
          end
        end
      end
      row = row + inc
      if row < 0 or size <= row then
        row = row - inc
        inc = -inc
        break
      end
    end
  end

  return grid
end

-- ======================================================================
-- Penalty（4 条规则）
-- ======================================================================
local function penalty(grid, size)
  local total = 0
  local function scan(line)
    local s, run, prev = 0, 1, line[1]
    for i = 2, #line do
      if line[i] == prev then
        run = run + 1
        if run == 5 then s = s + 3 end
        if run > 5 then s = s + 1 end
      else
        run, prev = 1, line[i]
      end
    end
    return s
  end
  for r = 0, size - 1 do
    local row, col = {}, {}
    for c = 0, size - 1 do row[c + 1] = grid[r][c] end
    total = total + scan(row)
    for rr = 0, size - 1 do col[rr + 1] = grid[rr][c] end
    total = total + scan(col)
  end
  for r = 0, size - 2 do
    for c = 0, size - 2 do
      local v = grid[r][c]
      if grid[r][c + 1] == v and grid[r + 1][c] == v and grid[r + 1][c + 1] == v then
        total = total + 3
      end
    end
  end
  local function match11(line, idx)
    local p1 = { 1,0,1,1,1,0,1,0,0,0,0 }
    local p2 = { 0,0,0,0,1,0,1,1,1,0,1 }
    for _, p in ipairs({ p1, p2 }) do
      local ok = true
      for k = 1, 11 do
        if line[idx + k - 1] ~= p[k] then ok = false break end
      end
      if ok then return true end
    end
    return false
  end
  for r = 0, size - 1 do
    local line = {}
    for c = 0, size - 1 do line[c + 1] = grid[r][c] end
    for i = 1, #line - 10 do if match11(line, i) then total = total + 40 end end
  end
  for c = 0, size - 1 do
    local line = {}
    for r = 0, size - 1 do line[r + 1] = grid[r][c] end
    for i = 1, #line - 10 do if match11(line, i) then total = total + 40 end end
  end
  local dark = 0
  for r = 0, size - 1 do for c = 0, size - 1 do dark = dark + grid[r][c] end end
  local tot = size * size
  total = total + math.floor(math.abs(dark * 20 - tot * 10) / tot) * 10
  return total
end

-- ======================================================================
-- 主流程
-- ======================================================================
local function encode(text, ec)
  if ec == nil or not EC_BITS[ec] then ec = 'M' end
  local version = choose_version(#text, ec)
  if not version then
    return nil, 'data too long for QR v1-6 (' .. #text .. ' bytes)'
  end
  local data_total = data_total_of(version, ec)
  local data_bytes = build_bitstream(text, data_total)
  local codewords = make_codewords(data_bytes, version, ec)

  local best_mask, best_pen, best_grid = 0, nil, nil
  for m = 0, 7 do
    local g = build_matrix(codewords, version, ec, m)
    local p = penalty(g, size_of(version))
    if not best_pen or p < best_pen then
      best_pen, best_mask, best_grid = p, m, g
    end
  end
  return {
    version = version, size = size_of(version), ec = ec, mask = best_mask,
    codewords = #codewords, data_capacity = data_total, grid = best_grid,
  }
end

-- ======================================================================
-- 输出
-- ======================================================================
local function grid_to_json(grid, size)
  local rows = {}
  for r = 0, size - 1 do
    local cells = {}
    for c = 0, size - 1 do cells[c + 1] = tostring(grid[r][c]) end
    rows[r + 1] = '[' .. table.concat(cells, ',') .. ']'
  end
  return '[' .. table.concat(rows, ',') .. ']'
end

local function grid_to_svg(grid, size, scale)
  scale = scale or 4
  local quiet = 4
  local px = (size + 2 * quiet) * scale
  local out = {}
  out[#out + 1] = string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
    px, px, px, px)
  out[#out + 1] = '<rect width="100%" height="100%" fill="#ffffff"/>'
  for r = 0, size - 1 do
    for c = 0, size - 1 do
      if grid[r][c] == 1 then
        out[#out + 1] = string.format(
          '<rect x="%d" y="%d" width="%d" height="%d" fill="#000000"/>',
          (c + quiet) * scale, (r + quiet) * scale, scale, scale)
      end
    end
  end
  out[#out + 1] = '</svg>'
  return table.concat(out, '')
end

local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local text = p.v or ''
  local ec = p.ec or 'M'
  local op = p.op or 'svg'
  local res, err = encode(text, ec)
  if not res then return '{"error":"' .. tostring(err) .. '"}' end
  if op == 'matrix' then
    return grid_to_json(res.grid, res.size)
  elseif op == 'svg' then
    return grid_to_svg(res.grid, res.size, tonumber(p.scale) or 4)
  elseif op == 'info' then
    return string.format(
      '{"version":%d,"size":%d,"ec":"%s","mask":%d,"codewords":%d,"data_capacity":%d}',
      res.version, res.size, ec, res.mask, res.codewords, res.data_capacity)
  elseif op == 'codewords' then
    -- 调试/校验：返回 数据+EC 全部码字（hex 数组），与参考实现逐字节比对
    local data_total = data_total_of(res.version, res.ec)
    local db = build_bitstream(text, data_total)
    local cw = make_codewords(db, res.version, res.ec)
    local parts = {}
    for i = 1, #cw do parts[i] = string.format('"%02X"', cw[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  return '{}'
end

return function(p)
  return run(p)
end
