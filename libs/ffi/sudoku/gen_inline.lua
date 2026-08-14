#!/usr/bin/env luajit
-- gen_inline.lua — 从 sudoku_solve.c 生成两个"直接嵌入 C"的 demo,
-- 保证内嵌源码与 .c 文件单一事实来源一致,避免手抄脱同步。
-- 用法: <luajit>/third_party/LuaJIT/src/luajit gen_inline.lua
-- 输出: demo_tcc_inline.lua / demo_tcc_inline_in_duckdb.sql(覆盖)
local REPO = "/mnt/d/wsl2/duckdb-luajit-libs"
local TCC_PREFIX = "/home/lhy/.local/tcc"
-- duckdb-luajit 扩展的绝对路径(独立于 REPO,按你本机构建位置改)
local EXT_PATH = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"

local f = assert(io.open(REPO .. "/libs/ffi/sudoku/sudoku_solve.c", "rb"))
local c_src = f:read("*a"); f:close()

-- 安全校验:内嵌边界符不得出现在 C 源码里
assert(not c_src:find("]==]", 1, true), "C source contains ]==] — change Lua long-bracket level")
assert(not c_src:find("$$", 1, true), "C source contains $$ — change SQL dollar-quote tag")

local embed_lua = [====[
-- demo_tcc_inline.lua — TCC 直接嵌入 C 代码:源码内嵌为 Lua 字符串,
-- 运行时用 libtcc 编译进内存并调用。自包含,不读磁盘 .c 文件。
--
-- 前置:
--   1. 本机有 tcc (sudo apt install tcc; 或 ~/.local/tcc)
--   2. 修改下方 TCC_PREFIX 为你的 tcc 安装前缀
-- 运行:
--   cd <LuaJIT>/third_party/LuaJIT/src && ./luajit <repo>/libs/ffi/sudoku/demo_tcc_inline.lua
-- 预期输出: compile+relocate (inline C): OK / solve MATCH ✓
--
-- ⚠ 本文件由 gen_inline.lua 从 sudoku_solve.c 生成,勿手改;改 C 源码后重跑生成器。

local TCC_PREFIX = "@@TCC_PREFIX@@"

-- ========== 直接嵌入的 C 源码(与 sudoku_solve.c 同算法,位图约束 + MRV) ==========
local C_SRC = [==[
@@C_SRC@@
]==]
-- =============================================================================

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

-- 编译内嵌 C 源码(与读文件版完全相同的流程)
local tcc = ffi.load(TCC_PREFIX .. "/lib/libtcc.so")
local st = tcc.tcc_new()
assert(st ~= nil, "tcc_new failed")
tcc.tcc_set_lib_path(st, TCC_PREFIX .. "/lib")
tcc.tcc_set_options(st, "-O2 -I" .. TCC_PREFIX .. "/lib/tcc/include")
tcc.tcc_set_output_type(st, 1) -- TCC_OUTPUT_MEMORY
assert(tcc.tcc_compile_string(st, C_SRC) == 0, "compile failed")
assert(tcc.tcc_relocate(st, ffi.cast("void*", 1)) == 0, "relocate failed")
local fn = assert(tcc.tcc_get_symbol(st, "sudoku_solve"), "symbol missing")
local solve = ffi.cast("int (*)(const char*, char*)", fn)
print("compile+relocate (inline C): OK")

-- 求解并验证(README 锚点题)
local puzzle = "000001002000020030004500600007600050080090006100005800001004000070900003400030020"
local expected = "359461782716829534824573619947682351583197246162345897631254978275918463498736125"
local buf = ffi.new("char[82]")
assert(solve(puzzle, buf) == 1)
local got = ffi.string(buf)
assert(got == expected, "MISMATCH:\n" .. got)
print("solve MATCH ✓")

-- 性能抽样
local N = 2000
local t0 = os.clock()
for i = 1, N do solve(puzzle, buf) end
print(string.format("TCC inline C: %.3f ms/题 (单题循环 %d 次)", (os.clock() - t0) / N * 1000, N))

tcc.tcc_delete(st)
print("tcc_delete OK")
]====]

local embed_sql = [====[
-- demo_tcc_inline_in_duckdb.sql — TCC 直接嵌入 C 代码(扩展内,自包含)
-- C 源码内嵌在 luajit_module 的 source 字符串里,运行时用 libtcc 编译进内存。
-- 不读磁盘 .c 文件、不需要 gcc、不产生 .so —— 整个模块可进 install 协议。
--
-- ⚠ 本文件由 gen_inline.lua 从 sudoku_solve.c 生成,勿手改;改 C 源码后重跑生成器。
--
-- 前置: 本机有 tcc (sudo apt install tcc; 或 ~/.local/tcc),路径见下
-- 运行: duckdb -unsigned < demo_tcc_inline_in_duckdb.sql
-- 预期输出: compile OK + correct = true
LOAD '@@EXT_PATH@@';

SELECT * FROM luajit_module(mode := 'compile', sql_name := 'sudoku_tcc_inline', source := $$
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

-- ===== 直接嵌入的 C 源码(与 sudoku_solve.c 同算法) =====
local C_SRC = [==[
@@C_SRC@@
]==]
-- =====================================================

local tcc = ffi.load("@@TCC_PREFIX@@/lib/libtcc.so")
local st = tcc.tcc_new()
assert(st ~= nil, "tcc_new failed")
tcc.tcc_set_lib_path(st, "@@TCC_PREFIX@@/lib")
tcc.tcc_set_options(st, "-O2 -I@@TCC_PREFIX@@/lib/tcc/include")
tcc.tcc_set_output_type(st, 1)
assert(tcc.tcc_compile_string(st, C_SRC) == 0, "compile failed")
assert(tcc.tcc_relocate(st, ffi.cast("void*", 1)) == 0, "relocate failed")
local fn = assert(tcc.tcc_get_symbol(st, "sudoku_solve"), "symbol missing")
local solve = ffi.cast("int (*)(const char*, char*)", fn)
return function(p)
  local buf = ffi.new("char[82]")
  if solve(p, buf) ~= 1 then return NULL end
  return ffi.string(buf)
end
$$);

WITH got AS (
  SELECT luajit_s('sudoku_tcc_inline', '000001002000020030004500600007600050080090006100005800001004000070900003400030020') AS sol
)
SELECT sol, sol = '359461782716829534824573619947682351583197246162345897631254978275918463498736125' AS correct FROM got;
]====]

-- C 源码在 [==[ ]==] 里会被原样保留;但模板里 C_SRC 出现在 Lua 长字符串内部,
-- 直接替换即可(替换发生在生成器侧,不经过 Lua 解析)。
local function gen(tpl, out)
  local s = tpl
  s = s:gsub("@@C_SRC@@", function() return c_src end)
  s = s:gsub("@@TCC_PREFIX@@", TCC_PREFIX)
  s = s:gsub("@@EXT_PATH@@", EXT_PATH)
  local w = assert(io.open(REPO .. "/libs/ffi/sudoku/" .. out, "wb"))
  w:write(s); w:close()
  print("wrote " .. out)
end

gen(embed_lua, "demo_tcc_inline.lua")
gen(embed_sql, "demo_tcc_inline_in_duckdb.sql")
print("done")
