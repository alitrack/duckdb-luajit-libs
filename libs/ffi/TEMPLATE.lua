--[[
@lib resource_lifecycle_template
@category ffi
@desc FFI lib skeleton — resource lifecycle conventions (template, not INDEX-installable)
@source duckdb-luajit-libs libs/ffi
@requires ffi (LuaJIT); external C library with a C ABI

⚠ TEMPLATE — not in INDEX, not install-able as a Lua lib. Copy this file to
  libs/ffi/<name>/<name>.lua (or your own location) and adapt. Read
  libs/ffi/README.md (三条铁律) before writing any FFI code.

铁律速查 (see libs/ffi/README.md):
  1. 每个资源类型注册唯一 ffi.gc 释放器，禁止裸指针跨函数传递
  2. 释放顺序与使用顺序相反（后开先关）——cudaFree 后 D2H = use-after-free
  3. cdef 签名与头文件逐字一致，参数个数精确（LuaJIT vararg 不能包装 cdata 调用）
]]

local ffi = require('ffi')

-- 1. cdef: 只声明用到的符号，逐字对照头文件（⛔ 不能写 #define/带初值常量）
--    常量直接写数字字面量；字符参数传字符串；指针参数传 int[1]/double[1] 等
ffi.cdef[[
typedef struct my_ctx my_ctx;
my_ctx *my_create(int param);
void my_free(my_ctx *ctx);
int my_compute(my_ctx *ctx, const double *in, int n, double *out);
]]

-- 2. 加载链统一：环境变量 → 库名变体 → 常见系统路径（照抄 highs/linalg 模式）
local function load_lib()
    local candidates = {
        os.getenv('MYLIB_LIB'), -- 用户可覆盖
        'mylib', 'libmylib',
        '/usr/lib/x86_64-linux-gnu/libmylib.so',
    }
    for _, c in ipairs(candidates) do
        if c then
            local ok, lib = pcall(ffi.load, c)
            if ok then return lib end
        end
    end
    error('mylib: cannot load library (set MYLIB_LIB env or install libmylib)')
end
local lib = load_lib()

-- 3. 资源生命周期：创建即绑定 ffi.gc（铁律 1）——禁止返回裸指针
--    创建与释放函数配对：my_create / my_free 必须成对出现在 ffi.gc 里
local function new_ctx(param)
    local ctx = lib.my_create(param)
    if ctx == nil then
        error('mylib: my_create failed')
    end
    -- ⛔ ffi.gc 绑定 finalizer；ctx 从此是"已绑定 cdata"，可安全跨函数传递
    return ffi.gc(ctx, lib.my_free)
end

-- 4. 计算入口：输入校验 → 调用 → JSON 字符串返回（duckdb-luajit UDF 语义）
--    luajit_s 不序列化 Lua table：返回裸 table 打印 "table: 0x..." 指针
local function json_escape(s)
    return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format('\\u%04x', c:byte())
    end))
end

-- 支持两种入口参数：table（Lua 直调）或 JSON 字符串（duckdb-luajit 传字符串）
-- 参照 linalg.lua：'{"op":"compute","a":[...],"n":3}' 直接可调
local function decode_args(p)
    if type(p) == 'string' then
        local ok, t = pcall(function() return require('json').decode(p) end) -- 或自写轻量 json_decode
        if not ok or type(t) ~= 'table' then error('mylib: bad JSON args: ' .. tostring(p)) end
        return t
    end
    if type(p) ~= 'table' then error('mylib: args must be table or JSON string') end
    return p
end

-- 5. 计算主函数：注意释放顺序（铁律 2）
--    ⛔ 例：若结果在设备内存，D2H 拷贝必须**先于** cudaFree；
--       QR 的 R 提取必须先于 Dorgqr（原位覆盖 A 为 Q）
local function compute(p)
    local a = p.a or error('mylib: missing a')
    local n = p.n or #a
    -- 输入校验：维度除不尽时显式报错（FFI 会静默截断成 int 算错结果）
    if #a % n ~= 0 then error('mylib: dim mismatch: len=' .. #a .. ' n=' .. n) end

    -- 扁平数组 → C 侧布局（列主序等转换按需，参照 linalg col_major_from_flat）
    local in_buf = ffi.new('double[?]', #a, unpack(a)) -- ⚠ 大数据量用 ffi.new + 循环填充，勿 unpack 巨表
    local out_buf = ffi.new('double[?]', n)

    local ctx = new_ctx(p.param or 0) -- ffi.gc 已绑定，作用域结束自动释放
    local rc = lib.my_compute(ctx, in_buf, n, out_buf)
    if rc ~= 0 then
        return string.format('{"ok":false,"rc":%d}', rc) -- 错误走 JSON，不抛异常
    end

    -- 手动收集结果（out_buf 是 cdata，不能直接进 table 序列化）
    local out = {}
    for i = 0, n - 1 do out[i + 1] = out_buf[i] end
    -- ⛔ 若 out_buf 是设备指针：此处(读取)必须先于任何 cudaFree（铁律 2）
    return '{"ok":true,"out":[' .. table.concat(out, ',') .. ']}'
end

-- 6. 入口约定（参照 linalg/highs）：返回函数；参数 = table 或 JSON 字符串
return function(p)
    local ok, res = pcall(compute, decode_args(p))
    if not ok then
        return string.format('{"ok":false,"error":"%s"}', json_escape(res))
    end
    return res
end
