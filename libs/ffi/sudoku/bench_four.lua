-- bench_four.lua — 四种加载方式统一基准:同题、同循环、同进程
--   1. 纯 Lua v2 (libs/mcp/sudoku.lua)
--   2. gcc -O3 预编译 .so
--   3. tcc -shared 编译的 .so
--   4. TCC 内存编译(libtcc 运行时,inline 版同此)
--   5. Rust cdylib(可选项,README 同算法)
-- 用法: cd <LuaJIT>/third_party/LuaJIT/src && ./luajit <repo>/libs/ffi/sudoku/bench_four.lua
local REPO = "/mnt/d/wsl2/duckdb-luajit-libs"
local TCC_PREFIX = "/home/lhy/.local/tcc"
local SUDOKU_DIR = REPO .. "/libs/ffi/sudoku"

local ffi = require("ffi")
ffi.cdef[[ int sudoku_solve(const char *p, char *out); ]]

-- 锚点题(与 README 一致)
local puzzle = "000001002000020030004500600007600050080090006100005800001004000070900003400030020"
local expected = "359461782716829534824573619947682351583197246162345897631254978275918463498736125"

-- ---------- 1. 纯 Lua v2 ----------
package.path = REPO .. "/libs/mcp/?.lua;" .. package.path
local sudoku_lua = require("sudoku")
local got = sudoku_lua.solve(puzzle)
assert(got == expected, "Lua v2 MISMATCH")

-- ---------- 2/3. 预编译 .so ----------
-- gcc .so 与 tcc .so 若不存在则现场编译到 /mnt/d/wsl2/tmp
local function build_so(tool, args, name)
  local so = "/mnt/d/wsl2/tmp/" .. name
  os.execute(tool .. " " .. args .. " -o " .. so .. " " .. SUDOKU_DIR .. "/sudoku_solve.c")
  assert(io.open(so), name .. " build failed")
  return so
end
local so_gcc = "/mnt/d/wsl2/tmp/libsudoku_gcc.so"
local so_tcc = "/mnt/d/wsl2/tmp/libsudoku_tcc.so"
if not io.open(so_gcc) then build_so("gcc", "-O3 -shared -fPIC", "libsudoku_gcc.so") end
if not io.open(so_tcc) then build_so(TCC_PREFIX .. "/bin/tcc", "-shared -fPIC", "libsudoku_tcc.so") end
local gcc_lib = ffi.load(so_gcc)
local tccso_lib = ffi.load(so_tcc)
local buf = ffi.new("char[82]")
assert(gcc_lib.sudoku_solve(puzzle, buf) == 1 and ffi.string(buf) == expected)
assert(tccso_lib.sudoku_solve(puzzle, buf) == 1 and ffi.string(buf) == expected)

local so_rs = "/mnt/d/wsl2/tmp/libsudoku_rs.so"
if not io.open(so_rs) then
  os.execute("rustc --edition 2021 -O --crate-type cdylib -o " .. so_rs .. " " .. SUDOKU_DIR .. "/sudoku_solve.rs")
  assert(io.open(so_rs), "rust build failed")
end
local rs_lib = ffi.load(so_rs)
assert(rs_lib.sudoku_solve(puzzle, buf) == 1 and ffi.string(buf) == expected)

-- ---------- 4. TCC 内存编译 ----------
local ctcc = ffi.load(TCC_PREFIX .. "/lib/libtcc.so")
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
]]
local f = assert(io.open(SUDOKU_DIR .. "/sudoku_solve.c", "rb"))
local c_src = f:read("*a"); f:close()
local st = ctcc.tcc_new()
ctcc.tcc_set_lib_path(st, TCC_PREFIX .. "/lib")
ctcc.tcc_set_options(st, "-O2 -I" .. TCC_PREFIX .. "/lib/tcc/include")
ctcc.tcc_set_output_type(st, 1)
assert(ctcc.tcc_compile_string(st, c_src) == 0)
assert(ctcc.tcc_relocate(st, ffi.cast("void*", 1)) == 0)
local mem_solve = ffi.cast("int (*)(const char*, char*)", ctcc.tcc_get_symbol(st, "sudoku_solve"))
assert(mem_solve(puzzle, buf) == 1 and ffi.string(buf) == expected)
print("four-way correctness: all MATCH ✓\n")

-- ---------- 基准 ----------
local N = 5000
local function bench(name, fn, ...)
  for i = 1, 200 do fn(...) end -- 预热
  local t0 = os.clock()
  for i = 1, N do fn(...) end
  local ms = (os.clock() - t0) / N * 1000
  print(string.format("%-28s %8.4f ms/题", name, ms))
  return ms
end

print("同题循环 " .. N .. " 次(锚点题,先预热 200 次):")
local r1 = bench("1 纯 Lua v2", sudoku_lua.solve, puzzle)
local r2 = bench("2 gcc -O3 .so", gcc_lib.sudoku_solve, puzzle, buf)
local r3 = bench("3 tcc -shared .so", tccso_lib.sudoku_solve, puzzle, buf)
local r4 = bench("4 TCC 内存编译", mem_solve, puzzle, buf)
local r5 = bench("5 Rust cdylib", rs_lib.sudoku_solve, puzzle, buf)

print(string.format("\n相对倍数(以纯 Lua v2 为 1):"))
print(string.format("  Lua v2       1.00x"))
print(string.format("  gcc .so      %.2fx", r1 / r2))
print(string.format("  tcc .so      %.2fx", r1 / r3))
print(string.format("  TCC 内存     %.2fx", r1 / r4))
print(string.format("  Rust .so     %.2fx", r1 / r5))

ctcc.tcc_delete(st)
