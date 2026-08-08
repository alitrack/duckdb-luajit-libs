//! sudoku_solve.rs — Sudoku solver (bitmask constraints + MRV heuristic)
//! Same algorithm as libs/mcp/sudoku.lua v2, in Rust for FFI comparison.
//!
//! C ABI: `int sudoku_solve(const char *p, char *out)`
//!   p   — 81-char puzzle (0 = empty)
//!   out — caller-provided buffer (>=82 bytes), receives 81-char solution + NUL
//!   returns 1 on success, 0 on no solution / bad input
//!
//! Build (cdylib, Linux x86_64):
//!   rustc --edition 2021 -O --crate-type cdylib -o libsudoku_rs.so sudoku_solve.rs
//!
//! Use from duckdb-luajit:
//!   local ffi = require("ffi")
//!   ffi.cdef[[ int sudoku_solve(const char *p, char *out); ]]
//!   local lib = ffi.load("/path/to/libsudoku_rs.so")
//!   local buf = ffi.new("char[82]")
//!   lib.sudoku_solve(puzzle, buf)
//!   return ffi.string(buf)
//!
//! Benchmark (2026-08-08, sudoku17 first 100, same-dataset as Lua v2):
//!   Rust: 0.021 ms/puzzle vs Lua v2 0.13 ms/puzzle vs C 0.019 ms/puzzle

use std::ffi::{c_char, CStr};
use std::os::raw::c_int;

#[no_mangle]
pub extern "C" fn sudoku_solve(p: *const c_char, out: *mut c_char) -> c_int {
    if p.is_null() || out.is_null() {
        return 0;
    }
    let s = unsafe {
        match CStr::from_ptr(p).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        }
    };
    let bytes = s.as_bytes();
    if bytes.len() < 81 {
        return 0;
    }

    // 一维数组 + 位图约束
    let mut board = [0u8; 81];
    let mut rows = [0u16; 9];
    let mut cols = [0u16; 9];
    let mut boxes = [0u16; 9];
    let cell_r: [usize; 81] = core::array::from_fn(|i| i / 9);
    let cell_c: [usize; 81] = core::array::from_fn(|i| i % 9);
    let cell_b: [usize; 81] = core::array::from_fn(|i| (i / 27) * 3 + (i % 9) / 3);

    let mut empty = 0;
    for i in 0..81 {
        let ch = bytes[i];
        let v = if ch.is_ascii_digit() { ch - b'0' } else { 0 };
        board[i] = v;
        if v >= 1 && v <= 9 {
            let bv = 1u16 << (v - 1);
            rows[cell_r[i]] |= bv;
            cols[cell_c[i]] |= bv;
            boxes[cell_b[i]] |= bv;
        } else {
            empty += 1;
        }
    }
    if empty == 0 {
        for i in 0..81 {
            unsafe { *out.add(i) = (board[i] + b'0') as c_char };
        }
        unsafe { *out.add(81) = 0 };
        return 1;
    }

    fn popcount(mut x: u16) -> i32 {
        let mut n = 0;
        while x != 0 {
            x &= x - 1;
            n += 1;
        }
        n
    }

    fn solve(board: &mut [u8; 81], rows: &mut [u16; 9], cols: &mut [u16; 9], boxes: &mut [u16; 9]) -> bool {
        // MRV: 候选最少的空位
        let mut best = 81usize;
        let mut best_mask = 0u16;
        let mut best_cands = 10i32;
        for i in 0..81 {
            if board[i] == 0 {
                let mask = rows[i / 9] | cols[i % 9] | boxes[(i / 27) * 3 + (i % 9) / 3];
                let cands = 9 - popcount(mask);
                if cands == 0 {
                    return false;
                }
                if cands == 1 {
                    best = i;
                    best_mask = mask;
                    break;
                }
                if cands < best_cands {
                    best = i;
                    best_mask = mask;
                    best_cands = cands;
                }
            }
        }
        if best == 81 {
            return true;
        }
        let r = best / 9;
        let c = best % 9;
        let b = (best / 27) * 3 + (best % 9) / 3;
        for v in 1..=9u8 {
            let bv = 1u16 << (v - 1);
            if best_mask & bv == 0 {
                board[best] = v;
                rows[r] |= bv;
                cols[c] |= bv;
                boxes[b] |= bv;
                if solve(board, rows, cols, boxes) {
                    return true;
                }
                board[best] = 0;
                rows[r] &= !bv;
                cols[c] &= !bv;
                boxes[b] &= !bv;
            }
        }
        false
    }

    if !solve(&mut board, &mut rows, &mut cols, &mut boxes) {
        return 0;
    }
    for i in 0..81 {
        unsafe { *out.add(i) = (board[i] + b'0') as c_char };
    }
    unsafe { *out.add(81) = 0 };
    1
}
