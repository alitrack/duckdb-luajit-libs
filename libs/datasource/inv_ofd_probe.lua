-- ofd_probe.lua — probe driver: runs inv_ofd.lua's exact test assertions THROUGH the
-- real DuckDB LuaJIT extension (no standalone luajit on this box). Returns a summary
-- string; no print/os.exit (those would kill the host duckdb process). NOT committed.
-- Top-level return is a FUNCTION so quick_compile registers a callable; all logic
-- (fixture build + assertions) runs at luajit_s call time, not load time.
local fn = assert(dofile('/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/inv_ofd.lua'))

return function(_)
  local out = {}
  local passed, failed = 0, 0
  local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1 out[#out + 1] = 'FAIL: ' .. msg end
  end

  -- ============ stored-zip constructor (method=0, crc 0) — copied from inv_ofd_test.lua ============
  local function u16be(n) return string.char(n % 256, math.floor(n / 256)) end
  local function u32le(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
  end
  local function make_zip(entries)
    local parts, cd = {}, {}
    local offset = 0
    for _, e in ipairs(entries) do
      local name, data = e[1], e[2]
      local nlen = #name
      local lh = 'PK\3\4' .. u16be(20) .. u16be(0) .. u16be(0) .. u16be(0) .. u16be(0)
        .. u32le(0) .. u32le(#data) .. u32le(#data) .. u16be(nlen) .. u16be(0) .. name
      parts[#parts + 1] = lh .. data
      local cdentry = 'PK\1\2' .. u16be(20) .. u16be(20) .. u16be(0) .. u16be(0) .. u16be(0) .. u16be(0)
        .. u32le(0) .. u32le(#data) .. u32le(#data) .. u16be(nlen) .. u16be(0) .. u16be(0) .. u16be(0) .. u16be(0)
        .. u32le(0) .. u32le(offset) .. name
      cd[#cd + 1] = cdentry
      offset = offset + #lh + #data
    end
    local cdsize = 0
    for _, c in ipairs(cd) do cdsize = cdsize + #c end
    local eocd = 'PK\5\6' .. u16be(0) .. u16be(0) .. u16be(#entries) .. u16be(#entries)
      .. u32le(cdsize) .. u32le(offset) .. u16be(0)
    return table.concat(parts) .. table.concat(cd) .. eocd
  end

  local OFD_XML = '<?xml version="1.0" encoding="UTF-8"?><ofd:OFD xmlns:ofd="http://www.ofdspec.org/2016">'
    .. '<ofd:DocBody><ofd:DocInfo><ofd:DocID>test</ofd:DocID>'
    .. '<ofd:CustomDatas>'
    .. '<ofd:CustomData Name="发票号码">24000000000012345678</ofd:CustomData>'
    .. '<ofd:CustomData Name="合计金额">172.37</ofd:CustomData>'
    .. '<ofd:CustomData Name="开票日期">2026年06月11日</ofd:CustomData>'
    .. '<ofd:CustomData Name="购买方纳税人识别号">91330106TESTTEST2L</ofd:CustomData>'
    .. '</ofd:CustomDatas></ofd:DocInfo><ofd:DocRoot>Doc_0/Document.xml</ofd:DocRoot></ofd:DocBody></ofd:OFD>'

  local CONTENT_XML = '<?xml version="1.0" encoding="UTF-8"?><ofd:Page xmlns:ofd="http://www.ofdspec.org/2016">'
    .. '<ofd:Content><ofd:Layer ID="2" Type="Body">'
    .. '<ofd:TextObject Boundary="34.5 11.5 18 5" Font="3" ID="1" Size="3.0">'
    .. '<ofd:TextCode DeltaX="3.0" X="0" Y="3"><![CDATA[测试开票方]]></ofd:TextCode></ofd:TextObject>'
    .. '<ofd:TextObject Boundary="34.5 14.0 18 5" Font="3" ID="2" Size="3.0">'
    .. '<ofd:TextCode X="0" Y="3"><![CDATA[100.00]]></ofd:TextCode></ofd:TextObject>'
    .. '<ofd:TextObject Boundary="34.5 11.5 18 5" Font="3" ID="3" Size="3.0">'
    .. '<ofd:TextCode X="6" Y="3"><![CDATA[同行第二块]]></ofd:TextCode></ofd:TextObject>'
    .. '</ofd:Layer></ofd:Content></ofd:Page>'

  local tmp = '/tmp/inv_ofd_probe.ofd'
  local f = io.open(tmp, 'wb')
  f:write(make_zip({ { 'OFD.xml', OFD_XML }, { 'Doc_0/Pages/Page_0/Content.xml', CONTENT_XML } }))
  f:close()

  -- ============ assertions (verbatim from inv_ofd_test.lua) ============
  local meta = fn({ op = 'meta', file = tmp })
  ok(meta:find('error:') == nil, 'meta parses; got: ' .. tostring(meta))
  ok(meta:find('24000000000012345678') ~= nil, 'meta has 发票号码')
  ok(meta:find('172%.37') ~= nil, 'meta has 合计金额')
  ok(meta:find('2026') ~= nil, 'meta has 开票日期')
  ok(meta:find('91330106TESTTEST2L') ~= nil, 'meta has 购买方税号')
  ok(meta:sub(1, 1) == '{' and meta:sub(-1) == '}', 'meta is JSON object')

  local rows = fn(tmp)
  ok(#rows == 2, 'text rows: 2 lines, got ' .. tostring(#rows))
  ok(rows[1] and rows[1]:match('^11%.5|测试开票方同行第二块$') ~= nil, 'row1 y=11.5 merge, got: ' .. tostring(rows[1]))
  ok(rows[2] and rows[2]:match('^14|100%.00$') ~= nil, 'row2 y=14.0, got: ' .. tostring(rows[2]))

  ok(fn({ op = 'meta', file = '/tmp/not_exists_xyz.ofd' }):find('error:') ~= nil, 'missing file errors')
  local nz = io.open('/tmp/notzip_probe.ofd', 'wb'); nz:write('this is not a zip'); nz:close()
  ok(fn({ op = 'meta', file = '/tmp/notzip_probe.ofd' }):find('error:') ~= nil, 'non-zip errors')
  ok(fn({ op = 'unknown', file = tmp }):find('error:') ~= nil, 'unknown op errors')
  ok(fn({ op = 'meta', file = tmp, extra = 1 }):find('error:') == nil, 'extra param tolerated')

  out[#out + 1] = ('SUMMARY %d passed, %d failed'):format(passed, failed)
  out[#out + 1] = 'META: ' .. tostring(meta)
  for i, r in ipairs(rows) do out[#out + 1] = ('ROW%d: %s'):format(i, tostring(r)) end
  return table.concat(out, ' || ')
end
