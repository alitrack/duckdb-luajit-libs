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
