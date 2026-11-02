# 性能指南：让 Lua UDF 跑在 JIT 上（而非解释器里）

> duckdb-luajit 内嵌 LuaJIT 2.1（追踪式 JIT）。但 **JIT 只在「循环留在 Lua 里」时生效**——
> 本指南给出一手实测的数字与写法，避免最常见的两个性能陷阱。
> 实测环境：DuckDB v2.0.0-alpha + LuaJIT 2.1.1785192264，2026-11-02。

## 一句话规则

**数据批进批出、循环写在 Lua 里 = JIT 编译；每行调一次 = 370ns/次的跨界税，JIT 帮不上。**

## 实测数字

同一份数值逻辑（50 次内层浮点循环），100,000 次计算：

| 形态 | 写法 | 耗时 | 相对 |
| --- | --- | ---: | --- |
| **逐行 scalar** | `SELECT luajit_s('mylib', {'op':'f','x':i}) FROM range(100000)` | 37 ms | 1× |
| **批量（循环在 Lua）** | `SELECT luajit_s('mylib', {'op':'f_batch','n':100000})` | **3 ms** | **~10× 快** |

LuaJIT 层对照（1e7 次纯数值循环）：JIT 编译 8ms vs 解释器 32ms（**JIT 增益 4×**）；
逐行 + 每行跨 C 边界 = 52ms（比批量慢 6.5×）。DuckDB 端到端差距（~10×）略大于纯 LuaJIT 差距，
因为逐行形态还额外付了 100k 次 STRUCT→Lua table 的参数转换。

参照系：DuckDB 内置 C++ 函数（`hash`）×1M = 14ms。**逐行 Lua UDF 比内置 C++ 慢 14-24×**——
这是跨界开销的物理极限，不是 Lua 写得差。

## 正确写法（库作者侧）

```lua
-- ❌ 逐行形态：调用方每行调一次，trace 永远不热
return function(p) return workload(p.x) end

-- ✅ 批量形态：循环留在 Lua 里，LuaJIT trace 编译整个循环
return function(p)
  local n, s = p.n or 0, 0.0
  for i = 1, n do s = s + workload(i * 0.001) end
  return string.format('%.6f', s)
end
```

数值密集型库优先提供 `*_vec` / `*_batch` op（一次调用吃数组、吐数组），
SQL 侧用 `unnest(from_json(result, '["DOUBLE"]'))` 展开或直接消费聚合值。
`linalg`（矩阵一次进 Lua）、`fake`（`op:'rows'` 批量生成）都是这个形态的正面范例。

## 陷阱一：NYI 构造会静默退回解释器（无告警）

LuaJIT 对部分构造 **不做 trace 编译**（NYI, Not Yet Implemented），命中即静默降级到解释器，
性能掉 ~4× 且没有任何警告。实测 `gsub` 回调热循环：JIT on = 0.135s，JIT off = 0.133s——**零差距，即零 JIT**。

热循环里避开（常见者）：
- `string.gsub(s, pat, function(...) ... end)`（函数替换回调）
- `pairs()` 遍历哈希表（`ipairs` 数组部分可 trace）
- `pcall`/`error` 包住热路径
- 字符串拼接 `..` 在超紧循环里（适度使用没问题）

诊断：`require('jit').status()` 查开关；进阶用 `jit.dump`/`-jv` 观察 trace 生成与 abort 原因。

## 陷阱二：DuckDB 常量折叠会伪造基准

给 `luajit_s` 传**恒定参数**时，DuckDB 可能预先算掉整次调用（实测逐行查询显示 0.001s 的假象）。
跑基准或验证性能时，参数必须逐行不同：`{'op':'f','x': i}`（引用列）而非 `{'op':'f','x': 2}`（常量）。

## 陷阱三：参数用 STRUCT，不要拼 JSON 字符串

`luajit_s('lib', {'op':'x','v':1})`（DuckDB STRUCT）直达 table；
`luajit_s('lib', '{"op":"x","v":1}')`（字符串）走 string 分支——除非库显式支持 JSON 解码
（如 base64 的 `{v:..., op:...}` 是它自己的 string/table 双分支处理），否则语义不同。

## wasm 边界（诚实声明）

LuaJIT 是 C + 手写汇编，**无法编译进 wasm**。DuckDB-wasm 场景下没有本扩展的 JIT 档
（也不存在「wasm 版 LuaJIT」）。浏览器/边缘场景请评估纯 Rust 的 Luau 实现（如 ulua）
作为可移植档位——性能仍低于真 LuaJIT 约 3 倍，且需自行评估许可证。
