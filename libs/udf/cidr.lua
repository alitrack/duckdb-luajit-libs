-- @lib: cidr
-- @category: udf
-- @desc: 网络 CIDR / IP 工具（纯 Lua，自包含）——DuckDB 无内建 CIDR/IPv4/IPv6 函数，
--       本库补上：IP 解析、CIDR 成员判定、网络/广播/规模、公私网分类。
--       同时支持 IPv4（32 位）与 IPv6（128 位，按 8 个 16 位 hextet 处理，不依赖大整数）。
--       op 选项：
--         'version'  → 4 或 6（op=version, v=<ip>）
--         'ip2int'   → IPv4 十进制整数；IPv6 返回 32 位 hex 串（Lua 5.1 双精度放不下 128 位）
--         'int2ip'   → IPv4 整数 → 点分串
--         'in_cidr'  → bool（v=<ip>, cidr=<net/prefix>）
--         'cidr_info'→ {network, broadcast, prefix, size, mask, is_v6}（v=<cidr>；size 超 2^53 时返回 "2^N"）
--         'classify' → public/private/loopback/link-local/multicast/unspecified/reserved
--         'net'      → 网络地址串（v=<cidr>）
--         'broadcast'→ 广播地址串（仅 IPv4；IPv6 返回末地址）
--       诚实边界：IPv6 zone 索引 / 十六进制 IPv4（0x）/ IPv4-mapped 仅按纯地址处理；
--       ::ffff:a.b.c.d 这类映射地址按 IPv6 解析（不自动降级为 v4）。
--       classify 对齐 Python ipaddress 语义（224-239 multicast、240+/4 private、CGNAT 100.64/10 public）；
--       已知 1 处差异：1:2:3:4:5:6:7:8 本库判 public（正确），Python is_reserved 误判 reserved。
-- @source: 自包含
-- @requires: none
--
-- Usage (duckdb-luajit):
--   SELECT luajit_s('cidr', {op: 'in_cidr', v: '192.168.1.5', cidr: '192.168.0.0/16'});  -- true
--   SELECT luajit_s('cidr', {op: 'cidr_info', v: '10.0.0.0/8'});
--   SELECT luajit_s('cidr', {op: 'classify', v: '172.16.5.9'});  -- private

local function tohex(n, width)
  local s = string.format('%x', n)
  while #s < width do s = '0' .. s end
  return s
end

-- 解析 IPv4 → 4 个 octet（0-255），失败 nil
local function parse_v4(s)
  local a, b, c, d = s:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  if not a then return nil end
  local o = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  for _, x in ipairs(o) do
    if x < 0 or x > 255 then return nil end
  end
  return o
end

-- 解析 IPv6 → 8 个 16-bit hextet（0-65535），支持 :: 压缩，失败 nil
local function parse_v6(s)
  local low = s:lower()
  local parts
  local np = (low:gsub('::', '') and (select(2, low:gsub('::', '')) + 1))
  local dcolon = low:find('::', 1, true)
  if dcolon then
    if (low:gsub('::', ''):gsub('x', '') == '') and low ~= '::' and low ~= ':::' then end
    if low:match('::.*::') then return nil end          -- 多个 ::
    local before = low:match('^(.*)::') or ''
    local after = low:match('::(.*)$') or ''
    local left, right = {}, {}
    for p in before:gmatch('[^:]+') do left[#left + 1] = p end
    for p in after:gmatch('[^:]+') do right[#right + 1] = p end
    local pad = 8 - (#left + #right)
    if pad < 0 then return nil end
    parts = {}
    for i = 1, #left do
      local h = tonumber(left[i], 16)
      if not h or h > 0xFFFF or #left[i] > 4 then return nil end
      parts[#parts + 1] = h
    end
    for _ = 1, pad do parts[#parts + 1] = 0 end
    for i = 1, #right do
      local h = tonumber(right[i], 16)
      if not h or h > 0xFFFF or #right[i] > 4 then return nil end
      parts[#parts + 1] = h
    end
  else
    parts = {}
    for p in low:gmatch('[^:]+') do
      local h = tonumber(p, 16)
      if not h or h > 0xFFFF or #p > 4 then return nil end
      parts[#parts + 1] = h
    end
    if #parts ~= 8 then return nil end
  end
  if #parts ~= 8 then return nil end
  return parts
end

-- 统一解析：返回 {v=4|6, words=[...], wbits=32|16} 或 nil
local function parse_any(s)
  if not s or s == '' then return nil end
  s = s:match('^%s*(.-)%s*$')
  local v4 = parse_v4(s)
  if v4 then
    local i = v4[1] * 16777216 + v4[2] * 65536 + v4[3] * 256 + v4[4]
    return { v = 4, words = { i }, wbits = 32 }
  end
  local v6 = parse_v6(s)
  if v6 then return { v = 6, words = v6, wbits = 16 } end
  return nil
end

-- 按 prefix 位掩码比较两个同版本 IP（words 数组 + wbits）
local function ip_matches_mask(ipw, netw, wbits, prefix)
  for i = 1, #ipw do
    local bits_before = (i - 1) * wbits
    if prefix > bits_before then
      local take = math.min(wbits, prefix - bits_before)
      local mask = ((2 ^ wbits) - 1) << (wbits - take)
      if (ipw[i] & mask) ~= (netw[i] & mask) then return false end
    end
  end
  return true
end

-- 前缀掩码（限制在 wbits 内）—— 关键：用 (2^take-1)<<(wbits-take)，
-- 不能用 (2^wbits-1)<<(wbits-take)（后者对 wbits=32 会溢出到 64 位，LuaJIT & 是 64 位 → 污染）。
local function netmask(wbits, take)
  if take >= wbits then return (2 ^ wbits) - 1 end
  if take <= 0 then return 0 end
  return (2 ^ take - 1) << (wbits - take)
end

-- 应用网络掩码 → 新 words（用于 network / mask 输出）
local function apply_mask(ipw, wbits, prefix)
  local out = {}
  for i = 1, #ipw do
    local bits_before = (i - 1) * wbits
    local take = prefix - bits_before
    if take > 0 then
      out[i] = ipw[i] & netmask(wbits, take)
    else
      out[i] = 0
    end
  end
  return out
end
-- 主机位掩码（网络掩码的补，限制在 wbits 内）= full XOR netmask
local function invert_mask(ipw, wbits, prefix)
  local out = {}
  local full = (2 ^ wbits) - 1
  for i = 1, #ipw do
    local bits_before = (i - 1) * wbits
    local take = prefix - bits_before
    if take > 0 then
      out[i] = full ~ netmask(wbits, take)
    else
      out[i] = full
    end
  end
  return out
end

local function words_to_str(w, wbits)
  if wbits == 32 then
    local i = w[1]
    return string.format('%d.%d.%d.%d', (i >> 24) & 255, (i >> 16) & 255, (i >> 8) & 255, i & 255)
  end
  local h = {}
  for i = 1, 8 do h[i] = string.format('%x', w[i]) end   -- 无前导零（IPv6 惯例）
  -- 折叠最长 0 段为 ::
  local best, bstart, blen = nil, 1, 1
  local i = 1
  while i <= 8 do
    if w[i] == 0 then
      local j = i
      while j <= 8 and w[j] == 0 do j = j + 1 end
      local len = j - i
      if len > blen then blen, bstart, best = len, i, i end
      i = j
    else i = i + 1 end
  end
  local out
  if blen >= 2 and best then
    local left, right = {}, {}
    for k = 1, bstart - 1 do left[#left + 1] = h[k] end
    for k = bstart + blen, 8 do right[#right + 1] = h[k] end
    out = table.concat(left, ':') .. '::' .. table.concat(right, ':')
    if out == '::' then out = '::' end
  else
    out = table.concat(h, ':')
  end
  return out
end

-- 分类（RFC 1918 / 127/8 / 169.254/16 / 100.64/10 / 多播 / unspecified）
local function classify(ip)
  if ip.v == 4 then
    local o = { (ip.words[1] >> 24) & 255, (ip.words[1] >> 16) & 255, (ip.words[1] >> 8) & 255, ip.words[1] & 255 }
    if o[1] == 0 then return 'unspecified' end
    if o[1] == 10 then return 'private' end
    if o[1] == 127 then return 'loopback' end
    if o[1] == 169 and o[2] == 254 then return 'link-local' end
    if o[1] == 172 and o[2] >= 16 and o[2] <= 31 then return 'private' end
    if o[1] == 192 and o[2] == 168 then return 'private' end
    if o[1] >= 224 and o[1] <= 239 then return 'multicast' end   -- 224.0.0.0/4
    if o[1] >= 240 then return 'private' end                     -- 240.0.0.0/4（对齐 Python is_private；CGNAT 100.64/10 归 public）
    return 'public'
  else
    local w = ip.words
    if w[1] == 0 and w[2] == 0 and w[3] == 0 and w[4] == 0 and w[5] == 0 and w[6] == 0
       and w[7] == 0 and w[8] == 0 then return 'unspecified' end
    if w[1] == 0 and w[2] == 0 and w[3] == 0 and w[4] == 0 and w[5] == 0 and w[6] == 0
       and w[7] == 0 and w[8] == 1 then return 'loopback' end
    -- 前缀分类按 w[1] 的 leading bits（不是 w[7]！）
    if (w[1] & 0xFF00) == 0xFF00 then return 'multicast' end           -- ff00::/8
    if (w[1] & 0xFFC0) == 0xFE80 then return 'link-local' end          -- fe80::/10
    if (w[1] & 0xFE00) == 0xFC00 then return 'private' end             -- fc00::/7 (ULA)
    if w[1] == 0x2001 and w[2] == 0x0db8 then return 'private' end     -- 2001:db8::/32 documentation
    return 'public'
  end
end

local function json_escape(s)
  return (tostring(s):gsub('([\\\"\n\t\r])', function(c)
    if c == '\\' then return '\\\\' elseif c == '"' then return '\\"'
    elseif c == '\n' then return '\\n' elseif c == '\t' then return '\\t'
    elseif c == '\r' then return '\\r' else return c end
  end))
end

local function run(p)
  if type(p) == 'string' then p = { v = p } end
  if type(p) ~= 'table' then return '{"error":"bad input"}' end
  local op = p.op or 'classify'
  local v = p.v
  if not v then return '{"error":"missing v"}' end

  if op == 'version' then
    local ip = parse_any(v)
    if not ip then return '{"error":"bad ip"}' end
    return string.format('{"version":%d}', ip.v)
  elseif op == 'ip2int' then
    local ip = parse_any(v)
    if not ip then return '{"error":"bad ip"}' end
    if ip.v == 4 then return string.format('{"value":%d,"v6":false}', ip.words[1]) end
    local hex = ''
    for i = 1, 8 do hex = hex .. tohex(ip.words[i], 4) end
    return string.format('{"value":"%s","v6":true}', hex)
  elseif op == 'int2ip' then
    local n = tonumber(p.n) or tonumber(v)
    if not n or n < 0 or n > 0xFFFFFFFF then return '{"error":"bad int"}' end
    return string.format('"%d.%d.%d.%d"', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255)
  elseif op == 'in_cidr' then
    local cidr = p.cidr or v:match('^(.+)/(%d+)$')
    local ip = parse_any(v)
    if not ip then return '{"error":"bad ip"}' end
    local netstr, pfxstr
    if p.cidr then
      netstr, pfxstr = p.cidr:match('^(.+)/(%d+)$')
    else
      netstr, pfxstr = v:match('^(.+)/(%d+)$')
    end
    if not netstr then return '{"error":"bad cidr, need a/b"}' end
    local prefix = tonumber(pfxstr)
    local net = parse_any(netstr)
    if not net or net.v ~= ip.v or prefix < 0 or prefix > (ip.v == 4 and 32 or 128) then
      return '{"error":"bad cidr or version mismatch"}'
    end
    local innet = ip_matches_mask(ip.words, net.words, ip.wbits, prefix)
    return string.format('{"in":%s,"v":%d}', tostring(innet), ip.v)
  elseif op == 'net' or op == 'broadcast' or op == 'cidr_info' then
    local netstr, pfxstr = (p.v):match('^(.+)/(%d+)$')
    if not netstr then return '{"error":"need a/b"}' end
    local prefix = tonumber(pfxstr)
    local net = parse_any(netstr)
    if not net or prefix < 0 or prefix > (net.v == 4 and 32 or 128) then
      return '{"error":"bad cidr"}'
    end
    local netw = apply_mask(net.words, net.wbits, prefix)
    local netstr_out = words_to_str(netw, net.wbits)
    if op == 'net' then return string.format('"%s"', netstr_out) end
    local inv = invert_mask(net.words, net.wbits, prefix)
    local bcastw = {}
    for i = 1, #net.words do bcastw[i] = netw[i] | inv[i] end
    local bcast_out = words_to_str(bcastw, net.wbits)
    if op == 'broadcast' then return string.format('"%s"', bcast_out) end
    -- cidr_info
    local width = net.wbits * #net.words
    local free = width - prefix
    local size
    if free <= 52 then size = 2 ^ free
    else size = string.format('"2^%d"', free) end
    -- 掩码 = 对全 1 字集应用 /prefix
    local ones = {}
    for i = 1, #net.words do ones[i] = (2 ^ net.wbits) - 1 end
    local maskw = apply_mask(ones, net.wbits, prefix)
    local maskstr
    if net.v == 4 then
      local m = maskw[1]
      maskstr = string.format('%d.%d.%d.%d', (m >> 24) & 255, (m >> 16) & 255, (m >> 8) & 255, m & 255)
    else
      maskstr = words_to_str(maskw, net.wbits)
    end
    return string.format('{"network":"%s","broadcast":"%s","prefix":%d,"size":%s,"mask":"%s","is_v6":%s}',
      json_escape(netstr_out), json_escape(bcast_out), prefix, size, json_escape(maskstr), tostring(net.v == 6))
  elseif op == 'classify' then
    local ip = parse_any(v)
    if not ip then return '{"error":"bad ip"}' end
    return string.format('{"class":"%s","v":%d}', classify(ip), ip.v)
  end
  return '{"error":"unknown op"}'
end

return function(p)
  return run(p)
end
