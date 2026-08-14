-- demo_tcc_inline_in_duckdb.sql — TCC 直接嵌入 C 代码(扩展内,自包含)
-- C 源码内嵌在 luajit_module 的 source 字符串里,运行时用 libtcc 编译进内存。
-- 不读磁盘 .c 文件、不需要 gcc、不产生 .so —— 整个模块可进 install 协议。
--
-- ⚠ 本文件由 gen_inline.lua 从 sudoku_solve.c 生成,勿手改;改 C 源码后重跑生成器。
--
-- 前置: 本机有 tcc (sudo apt install tcc; 或 ~/.local/tcc),路径见下
-- 运行: duckdb -unsigned < demo_tcc_inline_in_duckdb.sql
-- 预期输出: compile OK + correct = true
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

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
/*
 * sudoku_solve.c — Sudoku solver (bitmask constraints + MRV heuristic)
 * Same algorithm as libs/mcp/sudoku.lua v2, in C for FFI comparison.
 *
 * C ABI: int sudoku_solve(const char *p, char *out)
 *   p   — 81-char puzzle (0 = empty)
 *   out — caller-provided buffer (>=82 bytes), receives 81-char solution + NUL
 *   returns 1 on success, 0 on no solution / bad input
 *
 * Build (Linux x86_64):
 *   gcc -O3 -shared -fPIC -o libsudoku_c.so sudoku_solve.c
 *
 * Use from duckdb-luajit:
 *   local ffi = require("ffi")
 *   ffi.cdef[[ int sudoku_solve(const char *p, char *out); ]]
 *   local lib = ffi.load("/path/to/libsudoku_c.so")
 *   local buf = ffi.new("char[82]")
 *   lib.sudoku_solve(puzzle, buf)
 *   return ffi.string(buf)
 *
 * Benchmark (2026-08-08, sudoku17 first 100, same-dataset as Lua v2):
 *   C: 0.019 ms/puzzle vs Lua v2 0.13 ms/puzzle vs Rust 0.021 ms/puzzle
 */
#include <stdint.h>
#include <string.h>

static int popcount(uint16_t x) {
    int n = 0;
    while (x) { x &= (uint16_t)(x - 1); n++; }
    return n;
}

static int solve_rec(uint16_t *b, uint16_t *r_, uint16_t *c_, uint16_t *bx_,
                     const int *cr, const int *cc, const int *cb);
static int finish(const uint16_t *b, char *out);

int sudoku_solve(const char *p, char *out) {
    if (!p || strlen(p) < 81) return 0;

    uint16_t board[81];
    uint16_t rows[9] = {0}, cols[9] = {0}, boxes[9] = {0};
    int cell_r[81], cell_c[81], cell_b[81];

    for (int i = 0; i < 81; i++) {
        int r = i / 9;
        int c = i % 9;
        cell_r[i] = r;
        cell_c[i] = c;
        cell_b[i] = (r / 3) * 3 + (c / 3);
        char ch = p[i];
        int v = (ch >= '0' && ch <= '9') ? ch - '0' : 0;
        board[i] = (uint16_t)v;
        if (v >= 1 && v <= 9) {
            uint16_t bv = (uint16_t)(1u << (v - 1));
            rows[r] |= bv;
            cols[c] |= bv;
            boxes[cell_b[i]] |= bv;
        }
    }

    return solve_rec(board, rows, cols, boxes, cell_r, cell_c, cell_b) ? finish(board, out) : 0;
}

/* MRV: pick the empty cell with fewest candidates */
static int solve_rec(uint16_t *b, uint16_t *r_, uint16_t *c_, uint16_t *bx_,
                     const int *cr, const int *cc, const int *cb) {
    int best = -1, best_cands = 10;
    uint16_t best_mask = 0;
    for (int i = 0; i < 81; i++) {
        if (b[i] == 0) {
            uint16_t mask = (uint16_t)(r_[cr[i]] | c_[cc[i]] | bx_[cb[i]]);
            int cands = 9 - popcount(mask);
            if (cands == 0) return 0;
            if (cands == 1) { best = i; best_mask = mask; best_cands = 1; break; }
            if (cands < best_cands) { best = i; best_mask = mask; best_cands = cands; }
        }
    }
    if (best < 0) return 1;

    int r = cr[best], c = cc[best], bx = cb[best];
    for (int v = 1; v <= 9; v++) {
        uint16_t bv = (uint16_t)(1u << (v - 1));
        if (!(best_mask & bv)) {
            b[best] = (uint16_t)v;
            r_[r] |= bv; c_[c] |= bv; bx_[bx] |= bv;
            if (solve_rec(b, r_, c_, bx_, cr, cc, cb)) return 1;
            b[best] = 0;
            r_[r] &= (uint16_t)~bv; c_[c] &= (uint16_t)~bv; bx_[bx] &= (uint16_t)~bv;
        }
    }
    return 0;
}

static int finish(const uint16_t *b, char *out) {
    for (int i = 0; i < 81; i++) out[i] = (char)('0' + b[i]);
    out[81] = '\0';
    return 1;
}

]==]
-- =====================================================

local tcc = ffi.load("/home/lhy/.local/tcc/lib/libtcc.so")
local st = tcc.tcc_new()
assert(st ~= nil, "tcc_new failed")
tcc.tcc_set_lib_path(st, "/home/lhy/.local/tcc/lib")
tcc.tcc_set_options(st, "-O2 -I/home/lhy/.local/tcc/lib/tcc/include")
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
