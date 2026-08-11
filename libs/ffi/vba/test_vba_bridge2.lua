-- test_vba_bridge2.lua — 生产版 vba_bridge2 验证：持久状态 + 多次调用
local ffi = require('ffi')
ffi.cdef[[
int vba_init(const char* bundle_path);
int vba_load(const char* code);
const char* vba_call(const char* subname, const char* args_json);
void vba_free(const char* s);
]]
local b = ffi.load('/tmp/vba_bridge2.so')
local ok, fail = 0, 0
local function check(name, cond)
  if cond then ok = ok + 1 else fail = fail + 1; print('FAIL ' .. name) end
end

check('init', b.vba_init('/tmp/vbapkg/package/dist-web/index.js') == 0)

local code = [[
Dim counter As Integer
Function Double2(n)
  Double2 = n * 2
End Function
Sub main
  counter = counter + 1
  debug.print "call #" & counter
  debug.print Double2(21)
  debug.print HOST_RMB(counter)
End Sub
]]
check('load', b.vba_load(code) == 0)

local r1 = ffi.string(b.vba_call('main', '[]'))
local r2 = ffi.string(b.vba_call('main', '[]'))
local r3 = ffi.string(b.vba_call('main', '[]'))
print('call1:', r1)
print('call2:', r2)
print('call3:', r3)
-- 持久状态：counter 应递增
check('state persist', r1:find('call #1') and r2:find('call #2') and r3:find('call #3'))
-- 功能仍对
check('func 42', r3:find('42'))
check('host rmb', r3:find('RMB(3)', 1, true))

-- 重新 load 新代码（换代码后状态重置）
local code2 = [[
sub main
  debug.print "second module"
end sub
]]
check('reload', b.vba_load(code2) == 0)
local r4 = ffi.string(b.vba_call('main', '[]'))
print('call4:', r4)
check('reload works', r4:find('second module'))

print(string.format('vba_bridge2 test: ok=%d fail=%d', ok, fail))
if fail > 0 then os.exit(1) end
