# libs/ffi/vba — QuickJS + yiminghe/vba 引擎持久 runtime（SQL 里跑原始 VBA）

在 duckdb-luajit 的 Lua UDF 里通过 LuaJIT FFI 调用本桥，**VBA 源码零转译直接执行**：
`SELECT luajit_s('run_vba2', '[10, 32]')` → `{"logs":["42","20","1"],"ret":"undefined"}`。

引擎：`yiminghe/vba`（npm `vba` 0.0.26，TS 完整 VBA 运行时：类型/表达式/控制流/goto/static/宿主 SubBinding）。
宿主：QuickJS（duckdb-luajit 已内嵌同款引擎，此处独立编译 libquickjs.so 供 FFI 使用）。

> **不进入 INDEX**：这是 C 源码 + 编译产物，不是 Lua 库。先编译成 `.so`，再 `ffi.load` 按路径加载。

## 文件

| 文件 | 说明 |
|---|---|
| `vba_bridge2.c` | 生产版 C 桥：持久 runtime + pthread mutex + `vba_init/vba_load/vba_call` |
| `test_vba_bridge2.lua` | 断言测试（持久状态/功能/重载） |
| `../vba/vbamod.lua`（libs/udf/vbamod.lua） | 配套的 VBA 运行时库（手工移植路线，纯 Lua） |

## 编译

```bash
# QuickJS 源码 + libquickjs.so（Bellard QuickJS，make 只产 .a，需 -fPIC 手动编）：
git clone --depth 1 https://github.com/bellard/quickjs /tmp/quickjs
cd /tmp/quickjs
gcc -O2 -fPIC -D_GNU_SOURCE -DCONFIG_VERSION='"1.2.0"' -I. -c cutils.c dtoa.c libregexp.c libunicode.c quickjs.c quickjs-libc.c
gcc -shared -o libquickjs.so *.o -lm   # 产物 1.1MB / 181 个 JS_ 符号

# vba 引擎 bundle（纯 ESM 零 Node 依赖）：
cd /tmp && npm pack vba@0.0.26 && tar xzf vba-0.0.26.tgz

# 本桥：
gcc -shared -fPIC -O2 -pthread -I/tmp/quickjs -o /tmp/vba_bridge2.so \
  vba_bridge2.c -L/tmp/quickjs -lquickjs -lm
```

## 使用（duckdb-luajit）

```sql
LOAD '/path/to/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode:='compile', sql_name:='run_vba2', source:='
local ffi = require("ffi")
ffi.cdef[[
int vba_init(const char* bundle_path);
int vba_load(const char* code);
const char* vba_call(const char* subname, const char* args_json);
void vba_free(const char* s);
]]
local b = ffi.load("/tmp/vba_bridge2.so")
if b.vba_init("/tmp/package/dist-web/index.js") ~= 0 then
  return function() return "ERR init" end
end
local ok = b.vba_load([[
Dim counter As Integer
Sub show(a, b)
  counter = counter + 1
  debug.print a + b
End Sub
]])
if ok ~= 0 then return function() return "ERR load" end end
return function(args)
  local c = b.vba_call("show", args)
  local s = ffi.string(c)
  b.vba_free(c)
  return s
end');

SELECT luajit_s('run_vba2', '[10, 32]');  -- {"logs":["42","1"],"ret":"undefined"}
```

要点：
- **load 一次、call 任意次**：VBA 模块级变量（Dim）跨调用/跨查询保持（实测 counter 1→2→3）。
- 参数走 JSON 数组（`[10, 32]`），引擎侧映射为 indexed VBArguments，Sub 按位置收参。
- `debug.print` 是宿主绑定，输出收集到 `logs` 数组；可自行增删绑定（HOST_* 模式）。
- libquickjs.so 需在 `LD_LIBRARY_PATH`（或放系统库目录）。

## 踩坑

1. **QuickJS 无 `console`**：引擎内部引用 console，driver 必须预置 shim（否则 callSub 静默 reject、结果 null）。
2. **VBA 代码必须多行**：引擎按行解析语句，单行拼接（`Dim x As Integer Sub f()`）会语法错误且 load 静默失败；SQL 里用 Lua 长字符串 `[[ ... ]]` 包 VBA 代码（勿用 `''` 转义，会变成 Lua 空字符串字面量）。
3. **微任务排空**：async 引擎必须 `JS_ExecutePendingJob` 循环（`flush_jobs`），否则 Promise 不落地、`__result` 停在初始值。
4. **JSValue 泄漏**：`JS_GetGlobalObject` 返回值必须显式 `JS_FreeValue`，否则 `JS_FreeRuntime` GC 断言崩溃。
5. 每调用一个独立 runtime 的单次版（验证用）见 `vba_bridge.c` 历史版本；生产务必用持久版（每次建 runtime 约几十 ms，且丢状态）。
6. 引擎停更于 2022-05（0.0.26），子集覆盖够用（VBA UDF 高频构造），对象模型/On Error 不完整——超出部分走 vbamod 移植路线。
