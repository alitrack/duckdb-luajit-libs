-- demo_tcc_embed.lua — 无 gcc 环境复现:用 LuaJIT FFI 驱动 libtcc,
-- 在内存里编译 sudoku_solve.c 并求解(零预编译,读源码即跑)
--
-- 前置:
--   1. 本机有 tcc (Ubuntu: sudo apt install tcc; 或源码装到 ~/.local/tcc)
--   2. 修改下方 REPO_ROOT 为你的 duckdb-luajit-libs 路径
-- 运行:
--   cd <LuaJIT>/third_party/LuaJIT/src && ./luajit <repo>/libs/ffi/sudoku/demo_tcc_embed.lua
-- 预期输出: solve MATCH ✓ / 0.9 ms/题 级别
local REPO_ROOT = "/mnt/d/wsl2/duckdb-luajit-libs"
local TCC_PREFIX = "/home/lhy/.local/tcc" -- 你的 tcc 安装前缀(libtcc.so 所在)

local ffi = require("ffi")
ffi.cdef[[
typedef struct TCCState TCCState;
TCCState *tcc_new(void);
void tcc_delete(TCCState *s);
void tcc_set_lib_path(TCCState *s, const char *path);
void tcc_set_options(TCCState *s, const char *str);
int tcc_compile_string(TCCState *s, const char *buf);
int tcc_set_output_type(TCCState *s, int output_type);
int tcc_relocate(TCCState *s1, void *ptr);
void *tcc_get_symbol(TCCState *s, const char *name);
int sudoku_solve(const char *p, char *out);
]]

-- 1) 编译 sudoku_solve.c 进内存
local tcc = ffi.load(TCC_PREFIX .. "/lib/libtcc.so")
local f = assert(io.open(REPO_ROOT .. "/libs/ffi/sudoku/sudoku_solve.c", "rb"))
local src = f:read("*a"); f:close()

local st = tcc.tcc_new()
assert(st ~= nil, "tcc_new failed")
tcc.tcc_set_lib_path(st, TCC_PREFIX .. "/lib")
tcc.tcc_set_options(st, "-O2 -I" .. TCC_PREFIX .. "/lib/tcc/include")
tcc.tcc_set_output_type(st, 1) -- TCC_OUTPUT_MEMORY
assert(tcc.tcc_compile_string(st, src) == 0, "compile failed")
assert(tcc.tcc_relocate(st, ffi.cast("void*", 1)) == 0, "relocate failed")
local fn = assert(tcc.tcc_get_symbol(st, "sudoku_solve"), "symbol missing")
local solve = ffi.cast("int (*)(const char*, char*)", fn)
print("compile+relocate: OK")

-- 2) 求解并验证(README 锚点题)
local puzzle = "000001002000020030004500600007600050080090006100005800001004000070900003400030020"
local expected = "359461782716829534824573619947682351583197246162345897631254978275918463498736125"
local buf = ffi.new("char[82]")
assert(solve(puzzle, buf) == 1)
local got = ffi.string(buf)
assert(got == expected, "MISMATCH:\n" .. got)
print("solve MATCH ✓")

-- 3) 性能抽样(同一题循环,参考值;机器/题集不同数字会变)
local N = 2000
local t0 = os.clock()
for i = 1, N do solve(puzzle, buf) end
print(string.format("TCC in-memory: %.3f ms/题 (单题循环 %d 次)", (os.clock() - t0) / N * 1000, N))

tcc.tcc_delete(st)
print("tcc_delete OK")
