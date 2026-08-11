# libs/ffi/vba — Run raw VBA in SQL (QuickJS + yiminghe/vba engine)

Persistent QuickJS runtime hosting the `yiminghe/vba` engine (npm `vba` 0.0.26,
a complete TypeScript VBA runtime), callable from duckdb-luajit Lua UDFs via
LuaJIT FFI. **VBA source runs as-is, zero transpilation.**

```sql
SELECT luajit_s('run_vba2', '[10, 32]');
-- {"logs":["42","20","1"],"ret":"undefined"}
```

Key facts:
- **Load once, call many**: module-level `Dim` variables persist across calls
  and across queries (verified: counter 1 → 2 → 3).
- **Args via JSON array**: `[10, 32]` → indexed VBArguments, Sub binds by position.
- `debug.print` is a host SubBinding collecting into `logs`; add your own
  `HOST_*` bindings the same way.
- Async engine requires `JS_ExecutePendingJob` microtask draining.
- QuickJS has no `console` — driver pre-installs a shim (engine references it).
- VBA code must be multi-line (engine is line-oriented); use Lua long-string
  `[[ ... ]]` in SQL, never `''` escapes.

See `README_cn.md` for full build steps, usage, and pitfalls.
Companion pure-Lua port: `libs/udf/vbamod.lua` (VBA runtime library for
manual migration, INDEX-registered).

> Not in INDEX: C source + compiled `.so`, loaded via `ffi.load` by path.
