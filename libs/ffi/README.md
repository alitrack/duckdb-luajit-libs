# libs/ffi — FFI Resource Lifecycle Conventions

> This directory holds **compiled FFI assets** (C/Rust sources, .so-loading demos,
> runtime-compiled demos). **Never add them to INDEX** (install treats entries as
> Lua chunks to loadstring — .c/.rs will explode). Mark READMEs as
> "source, not INDEX-installable".
>
> Full Chinese reference: [`README_cn.md`](README_cn.md). This file is the
> condensed English version — read the Chinese one before writing any FFI lib.

## Three hard rules

1. **Bind a unique `ffi.gc` finalizer to every resource type at creation; never
   pass raw pointers across functions.** `ffi.gc(cdata, finalizer)` is the LuaJIT
   equivalent of C++ RAII — a cdata created without a bound finalizer either
   leaks or gets double-freed. Wrap functions must accept/return **GC-bound
   cdata only**, never bare `void*`/`intptr_t`. (Pattern borrowed from Cutter's
   RizinCpp.h: `UniquePtrCP` binds the `rz_mem_free` family, `fromOwned()` routes
   every release through one free function.)
2. **Release in reverse order of acquisition (last opened, first closed).**
   ⛔ `cudaMemcpy(D2H)` must run **before** `cudaFree` (use-after-free, stable
   segfault 139, measured 2026-08-18). ⛔ For QR decomposition, extract R
   **before** `Dorgqr` (it overwrites A in place). Dependency chains release
   innermost-first.
3. **cdef signatures must match the header verbatim; argument counts exact.**
   FFI does zero type checking — a wrong signature is misaligned arguments,
   which is a segfault or silent wrong values. ⛔ `Highs_qpCall` has **25 args**
   (6 more than lpCall) and `q_start`/`q_index` are **INT[] not double[]**
   (measured: core dump). ⛔ LuaJIT varargs cannot wrap FFI cdata calls —
   pass `bufferSize` etc. inline, explicitly. ⛔ Declare `JSValue` as **2×int64**
   (16-byte struct → SysV ABI MEMORY class). ⛔ `static inline` symbols are not
   exported — use the exported equivalents (`JS_ToCStringLen2`, `__JS_FreeValue`,
   the latter skips refcount decrement → decrement manually or double-free).

## Verified pitfalls (all hit & fixed in this repo)

| Area | Pitfall | Symptom | Fix |
|---|---|---|---|
| lifecycle | cudaFree before D2H copy | segfault 139 | D2H first |
| lifecycle | R extraction after Dorgqr | silent wrong R | extract R first |
| lifecycle | raw cdata across functions + manual free | leak/double-free | ffi.gc at creation |
| ABI | Highs q_start declared double* | segfault | INT[] per header |
| ABI | JSValue declared 1×int64 | crash | 2×int64 |
| ABI | calling static inline symbols | nil call | exported equivalents |
| ABI | __JS_FreeValue without refcount | double-free | decrement ref_count |
| ABI | varargs wrapping cdata | arg misalignment | inline exact params |
| ABI | Fortran char args passed by value | silent wrong | const char* strings; lda via int[1] |
| ABI | row-major input not transposed | wrong SVD | col_major_from_flat |
| build | libtcc memory compile without -I | stddef.h missing | `-I<prefix>/lib/tcc/include` |
| data | nested LIST matrices | empty table #t=0 | flat DOUBLE[] + m/n |
| data | non-integer derived dims | silent truncation | explicit guard |
| data | square-only anchor tests | false pass | include non-square cases |

## Template

- `TEMPLATE.lua` — copyable FFI lib skeleton (load-chain → ffi.gc binding →
  release-order comments → JSON-string return convention). Copy and adapt for
  every new FFI lib.
- Working examples: `sudoku/` (C/Rust solvers + TCC runtime compile + QuickJS
  embed), `../optimize/highs.lua` (LP/QP/MILP), `../linalg/linalg.lua`
  (LAPACK/OpenBLAS + CUDA GPU backend).

## Quick conventions

- Load chain: `env var → 'name'/'libname' → common system paths` (see highs/linalg)
- Cache function pointers: compile/load once in module body, never per call
- UDF semantics: return results as a **JSON string** (luajit_s does not
  serialize Lua tables — bare table prints `table: 0x...`)
- Decode before asserting in direct-test scripts (`r.q` string-index nil fails
  silently)
- After updating a lib, re-run `luajit_module(mode := 'install')` (cache)
