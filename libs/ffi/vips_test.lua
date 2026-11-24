-- vips_test.lua: 单元测试（LuaJIT CLI，须 cd 到本目录跑）
--   cd libs/ffi && /mnt/d/wsl2/luajit/third_party/LuaJIT/src/luajit vips_test.lua
-- 需要 libvips 可被 ffi.load 到（VIPS_LIB / LD_LIBRARY_PATH / 系统库任一）

local vips = dofile("vips.lua")

local pass, fail = 0, 0
local function check(cond, name, detail)
    if cond then
        pass = pass + 1
        print(string.format("ok   %s", name))
    else
        fail = fail + 1
        print(string.format("FAIL %s  %s", name, detail or ""))
    end
end

-- 4x3 RGB PNG（含 eXIf 元数据），由 `vips black ... && vips pngsave` 生成后 hexdump 而来
local TINY_PNG_HEX =
    "89504e470d0a1a0a0000000d49484452000000040000000308020000003b963991000000b46558496649492a00080000000600120103000100000001" ..
    "0000001a01050001000000560000001b010500010000005e000000280103000100000002000000130203000100000001000000698704000100000066" ..
    "0000000000000038630000e803000038630000e8030000060000900700040000003032313001910700040000000102030000a0070004000000303130" ..
    "3001a0030001000000ffff000002a00400010000000400000003a0040001000000030000000000000040ee9d4e0000000970485973000003e8000003" ..
    "e801b57b526b0000000c4944415408996360200a0000002700019f5a3c1c0000000049454e44ae426082"

local function unhex(h)
    return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local PNG = unhex(TINY_PNG_HEX)

check(#PNG == 282, "fixture png bytes == 282", "#PNG=" .. #PNG)
check(PNG:sub(1, 8) == "\137PNG\r\n\26\n", "fixture png signature")

-- 1) probe
local r = vips.run({ op = "probe" })
check(r:find('"ok":true') ~= nil, "probe ok", r)
check(r:find('"version":"8%.') ~= nil, "probe reports libvips 8.x", r)

-- 2) info
r = vips.run({ op = "info", data = PNG })
check(r:find('"width":4') ~= nil, "info width 4", r)
check(r:find('"height":3') ~= nil, "info height 3", r)
check(r:find('"bands":3') ~= nil, "info bands 3", r)
check(r:find('"format":"uchar"') ~= nil, "info format uchar", r)
check(r:find('"bytes_in":282') ~= nil, "info bytes_in", r)

-- 3) sniff（libvips 返回的是类名 VipsForeignLoadPngBuffer，不是昵称 pngload）
r = vips.run({ op = "sniff", data = PNG })
check(r:find('"loader":"VipsForeignLoadPngBuffer"') ~= nil, "sniff png buffer loader", r)

-- 4) thumb → png（放大小图也能工作）
r = vips.run({ op = "thumb", data = PNG, width = 8, suffix = ".png" })
check(type(r) == "string" and r:sub(1, 4) == "\137PNG", "thumb png signature", type(r))
check(r:find("^error:") == nil, "thumb no error", r:sub(1, 200))

-- 5) thumb → jpg（JPEG 魔数 FFD8FF）
r = vips.run({ op = "thumb", data = PNG, width = 8, suffix = ".jpg[Q=80]" })
check(type(r) == "string" and r:sub(1, 3) == "\255\216\255", "thumb jpg magic", type(r))

-- 6) thumb → webp（RIFF....WEBP）
r = vips.run({ op = "thumb", data = PNG, width = 8, suffix = ".webp[Q=70]" })
check(type(r) == "string" and r:sub(1, 4) == "RIFF" and r:sub(9, 12) == "WEBP",
    "thumb webp magic", type(r))

-- 7) thumb 宽度必须是数字型非法值报错
r = vips.run({ op = "thumb", data = PNG, width = -1 })
check(r:find("^error:.*out of range") ~= nil, "thumb bad width -> error", r)
r = vips.run({ op = "thumb", data = PNG, width = 200000 })
check(r:find("^error:.*out of range") ~= nil, "thumb huge width -> error", r)

-- 8) transcode 保尺寸
r = vips.run({ op = "transcode", data = PNG, suffix = ".jpg" })
check(type(r) == "string" and r:sub(1, 3) == "\255\216\255", "transcode jpg magic", type(r))

-- 9) 错误路径：空 BLOB / 垃圾数据 / 缺 data / 未知 op
r = vips.run({ op = "info", data = "" })
check(r:find("^error:.*non%-empty BLOB") ~= nil, "empty blob -> error", r)
r = vips.run({ op = "info" })
check(r:find("^error:.*non%-empty BLOB") ~= nil, "missing data -> error", r)
r = vips.run({ op = "info", data = "not an image at all" })
check(r:find("^error:.*load failed") ~= nil, "junk bytes -> error", r)
r = vips.run({ op = "sniff", data = "not an image at all" })
check(r:find("^error:.*unknown image format") ~= nil, "sniff junk -> error", r)
r = vips.run({ op = "nope" })
check(r:find("^error:.*unknown op") ~= nil, "unknown op -> error", r)
r = vips.run({})
check(r:find("^error:.*missing 'op'") ~= nil, "missing op -> error", r)
r = vips.run("plain string")
check(r:find("^error:.*string form only supports") ~= nil, "string form data op -> error", r)

-- 10) 字符串形态只支持 probe
r = vips.run('{"op":"probe"}')
check(r:find('"ok":true') ~= nil, "string form probe ok", r)

-- 11) 幂等：重复调用不崩、结果稳定（cdef / lib 句柄均缓存）
local ok1 = vips.run({ op = "info", data = PNG })
local ok2 = vips.run({ op = "info", data = PNG })
check(ok1 == ok2, "repeated info identical", ok1 .. " vs " .. ok2)

-- 12) 截断图像（20 字节）→ 必须是 error 串，不能崩也不能 NULL
local T = PNG:sub(1, 20)
local okk, r12 = pcall(vips.run, { op = "transcode", data = T, suffix = ".png" })
check(okk, "truncated input does not raise", tostring(r12))
check(type(r12) == "string" and r12:find("^error:") ~= nil,
    "truncated input -> error string", tostring(r12):sub(1, 120))
okk, r12 = pcall(vips.run, { op = "info", data = T })
check(okk and type(r12) == "string", "truncated info returns string", tostring(r12):sub(1, 120))

-- 13) 头部合法但数据截断（PNG 签名 + 半截 IHDR）
okk, r12 = pcall(vips.run, { op = "thumb", data = PNG:sub(1, 40), width = 8 })
check(okk, "half-png thumb does not raise", tostring(r12))
check(type(r12) == "string", "half-png thumb returns string", type(r12))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end