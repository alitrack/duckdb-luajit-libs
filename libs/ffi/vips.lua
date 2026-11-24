-- vips.lua: libvips image ops as DuckDB UDFs (blob in / blob out)
-- 零外部依赖（只依赖系统/conda 的 libvips.so.42），零 C 代码，纯 LuaJIT FFI。
-- 用法（DuckDB）:
--   LOAD luajit;
--   SELECT * FROM luajit_module(mode := 'install', sql_name := 'vips');
--   SELECT luajit_s('vips', {'op':'info',  'data': blob});          -- JSON: w/h/bands/format
--   SELECT luajit_blob('vips', {'op':'thumb','data': blob, 'width':200, 'suffix':'.webp[Q=75]'}); -- BLOB
--   SELECT luajit_s('vips', {'op':'probe'});                        -- {"ok":true,"version":...}
-- 设计纪律：
--   * 错误一律作为数据返回（'error: ...'），绝不 error()（会被扩展吞成 NULL）
--   * libvips 缺席 → 显式报错降级，不崩（超限必须显式降级）
--   * 只调 C ABI 的固定签名函数 + NULL 结尾 vararg，不碰 GObject/GValue 内省
--   * 所有返回图像 g_object_unref；所有 g_malloc 的 buffer g_free

local ffi = require "ffi"
local pcall, type, tonumber, tostring = pcall, type, tonumber, tostring
local format, sub = string.format, string.sub

-- 幂等 cdef（重复 register 会报 'attempt to redefine'）
local function cdef()
    if pcall(ffi.typeof, "VipsImage") then return end
    ffi.cdef [[
    typedef struct _VipsImage VipsImage;
    int vips_init(const char *argv0);
    const char *vips_error_buffer(void);
    void vips_error_clear(void);
    const char *vips_version_string(void);
    VipsImage *vips_image_new_from_buffer(const void *buf, size_t len,
            const char *option_string, ...);
    int vips_thumbnail_buffer(void *buf, size_t len, VipsImage **out,
            int width, ...);
    int vips_image_write_to_buffer(VipsImage *in, const char *suffix,
            void **buf, size_t *size, ...);
    int vips_image_get_width(const VipsImage *image);
    int vips_image_get_height(const VipsImage *image);
    int vips_image_get_bands(const VipsImage *image);
    int vips_image_get_format(const VipsImage *image);
    const char *vips_foreign_find_load_buffer(const void *data, size_t size);
    void g_object_unref(void *obj);
    void g_free(void *p);
    ]]
end

-- 格式枚举 → 名字（vips/format.h 的 VipsBandFormat 顺序）
local FORMAT_NAMES = {
    [0] = "uchar", [1] = "char", [2] = "ushort", [3] = "short",
    [4] = "uint", [5] = "int", [6] = "float", [7] = "double",
    [8] = "complex", [9] = "double-complex", [10] = "int64",
    [11] = "uint64",
}

-- 候选库名：先 env，再平台默认（Linux 用 soname，Windows 用 libvips-42.dll）
local function load_vips()
    cdef()
    local cands = {}
    local env_path = os.getenv("VIPS_LIB")
    if env_path and #env_path > 0 then cands[#cands + 1] = env_path end
    if ffi.os == "Windows" then
        cands[#cands + 1] = "libvips-42.dll"
        cands[#cands + 1] = "vips"
    else
        cands[#cands + 1] = "vips"
        cands[#cands + 1] = "libvips.so.42"
        cands[#cands + 1] = "libvips.dylib"
    end

    local tried = {}
    for _, name in ipairs(cands) do
        local ok, lib = pcall(ffi.load, name)
        if ok then
            local rc = lib.vips_init("duckdb-luajit-vips")
            if rc == 0 then return lib end
            local err = ffi.string(lib.vips_error_buffer())
            lib.vips_error_clear()
            return nil, "vips_init failed: " .. err
        end
        tried[#tried + 1] = name
    end
    return nil, "libvips not found (tried: " .. table.concat(tried, ", ") ..
        "). Install libvips or set VIPS_LIB=/path/to/libvips.so.42 " ..
        "or add it to LD_LIBRARY_PATH."
end

local vips_lib

local function lib()
    if vips_lib then return vips_lib end
    local l, err = load_vips()
    if not l then return nil, err end
    vips_lib = l
    return vips_lib
end

-- err 缓冲区读取 + 清理
local function last_error(l)
    local msg = ffi.string(l.vips_error_buffer())
    l.vips_error_clear()
    return msg
end

-- Lua string（DuckDB BLOB）→ const void*（调用期有效：Lua 字符串在调用期间不可移动）
local function as_ptr(data)
    return ffi.cast("const void *", ffi.cast("const char *", data))
end

-- ⛔ NULL 判定：数组元素的指针 NULL 与 nil 不相等（`p == nil` 恒 false），
-- 必须走 intptr 比较，否则 NULL 会漏过检查直接进 ffi.string → 抛错/崩溃。
local function is_null(p)
    return p == nil or ffi.cast("intptr_t", p) == 0
end

-- 取出图像字节：既支持 BLOB（Lua string），也支持 LIST(BLOB)（Lua table，取首元素）。
-- 批量场景请逐行调用（DuckDB 自己按 chunk 并行），LIST 形态只为兼容
-- {'data': [blob1, blob2]} 这种写法时不吃静默 nil。
local function as_blob(p)
    local data = p.data
    if type(data) == "table" then
        if #data == 0 then return nil, "'data' LIST is empty" end
        data = data[1]
    end
    if type(data) ~= "string" or #data == 0 then
        return nil, "'data' must be a non-empty BLOB"
    end
    return data
end

-- ── op: probe ────────────────────────────────────────────────────────────
local function op_probe(l)
    return format('{"ok":true,"version":"%s","backend":"ffi"}',
        ffi.string(l.vips_version_string()))
end

-- ── op: info ─────────────────────────────────────────────────────────────
local function op_info(l, p)
    local data, e = as_blob(p)
    if not data then return "error: " .. e end
    local im = l.vips_image_new_from_buffer(as_ptr(data), #data, "",
        ffi.cast("void *", 0))
    if is_null(im) then
        return "error: load failed: " .. last_error(l)
    end
    local w = l.vips_image_get_width(im)
    local h = l.vips_image_get_height(im)
    local b = l.vips_image_get_bands(im)
    local f = l.vips_image_get_format(im)
    l.g_object_unref(im)
    return format(
        '{"ok":true,"width":%d,"height":%d,"bands":%d,"format":"%s","bytes_in":%d}',
        w, h, b, FORMAT_NAMES[f] or ("unknown:" .. f), #data)
end

-- ── op: thumb（返回二进制，配 luajit_blob 使用）────────────────────────────
local function op_thumb(l, p)
    local data, e = as_blob(p)
    if not data then return "error: " .. e end
    local width = tonumber(p.width) or 200
    if width < 1 or width > 100000 then
        return format("error: 'width' out of range: %s", tostring(p.width))
    end
    local suffix = p.suffix
    if type(suffix) ~= "string" or #suffix == 0 then suffix = ".jpg" end

    local out = ffi.new("VipsImage *[1]")
    local rc = l.vips_thumbnail_buffer(
        ffi.cast("void *", ffi.cast("const char *", data)),
        #data, out, width, ffi.cast("void *", 0))
    if rc ~= 0 or is_null(out[0]) then
        return "error: thumbnail failed: " .. last_error(l)
    end

    local im = out[0]
    local buf = ffi.new("void *[1]")
    local size = ffi.new("size_t[1]")
    local rc2 = l.vips_image_write_to_buffer(im, suffix, buf, size,
        ffi.cast("void *", 0))
    l.g_object_unref(im)
    if rc2 ~= 0 or is_null(buf[0]) then
        return "error: encode to '" .. suffix .. "' failed: " .. last_error(l)
    end
    local n = tonumber(size[0])
    local result = ffi.string(buf[0], n)
    l.g_free(buf[0])
    return result
end

-- ── op: transcode（只转格式/保原尺寸，返回二进制）──────────────────────────
local function op_transcode(l, p)
    local data, e = as_blob(p)
    if not data then return "error: " .. e end
    local suffix = p.suffix
    if type(suffix) ~= "string" or #suffix == 0 then suffix = ".jpg" end

    local im = l.vips_image_new_from_buffer(as_ptr(data), #data, "",
        ffi.cast("void *", 0))
    if is_null(im) then
        return "error: load failed: " .. last_error(l)
    end
    local buf = ffi.new("void *[1]")
    local size = ffi.new("size_t[1]")
    local rc = l.vips_image_write_to_buffer(im, suffix, buf, size,
        ffi.cast("void *", 0))
    l.g_object_unref(im)
    if rc ~= 0 or is_null(buf[0]) then
        return "error: encode to '" .. suffix .. "' failed: " .. last_error(l)
    end
    local result = ffi.string(buf[0], tonumber(size[0]))
    l.g_free(buf[0])
    return result
end

-- ── op: sniff（格式识别，不解码像素）──────────────────────────────────────
local function op_sniff(l, p)
    local data, e = as_blob(p)
    if not data then return "error: " .. e end
    local name = l.vips_foreign_find_load_buffer(as_ptr(data), #data)
    if is_null(name) then
        return "error: unknown image format: " .. last_error(l)
    end
    return format('{"ok":true,"loader":"%s","bytes_in":%d}',
        ffi.string(name), #data)
end

-- ── 入口 ─────────────────────────────────────────────────────────────────
local M = {}

function M.run(p)
    -- 双形态：struct 字面量 → table；JSON 字符串 → 裸 string（需自解码）
    -- 注意：图像数据是二进制，JSON 字符串形态无法承载 BLOB ⇒ 数据型 op 必须在
    -- struct 字面量里传 'data'（本仓 test_vips.sql 是范本）；字符串形态只支持
    -- 无数据 op（probe），其余情况返回显式错误而不是静默 NULL。
    if type(p) == "string" then
        local op = string.match(p, '"op"%s*:%s*"([%w_]+)"')
        if op == "probe" then
            local l, err = lib()
            if not l then return "error: " .. err end
            return op_probe(l)
        end
        return format("error: SQL string form only supports {\"op\":\"probe\"} " ..
            "(got '%s'); pass image bytes as a struct literal: " ..
            "{'op':'thumb','data':blob,'width':200} (luajit_blob)", tostring(op))
    end
    if type(p) ~= "table" then
        return "error: options must be a struct/table"
    end
    local op = p.op
    if type(op) ~= "string" then
        return "error: missing 'op' (info|thumb|transcode|sniff|probe)"
    end

    local l, err = lib()
    if not l then return "error: " .. err end

    local body, e
    local fns = { probe = op_probe, info = op_info, thumb = op_thumb,
                  transcode = op_transcode, sniff = op_sniff }
    local fn = fns[op]
    if not fn then
        return format("error: unknown op '%s' (info|thumb|transcode|sniff|probe)", op)
    end
    -- 任何 Lua 侧异常都转成数据型错误串：扩展把 error() 吞成 NULL，而静默 NULL
    -- 与「本来就没数据」在管道里不可区分（本仓纪律：失败要作为数据返回）。
    local ok, res = pcall(fn, l, p)
    if not ok then
        return "error: internal: " .. tostring(res)
    end
    return res
end

-- 单函数形态入口（quick_compile 'return function(p) ... end' 也可用 M.run）
M.entry = M.run

return M
