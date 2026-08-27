# libs/ffi — FFI 资源生命周期规范

> 本目录存放编译型 FFI 资产（C/Rust 源码、.so 加载演示、运行时编译 demo）。
> **绝不进 INDEX**（install 会把条目当 Lua chunk loadstring，.c/.rs 必炸）。
> README 标注 "source, not INDEX-installable"。
>
> 本文档是 FFI 类目的**总纲**：三条铁律 + 已实测坑清单 + 模板索引。
> 新增任何 FFI lib 前先读本文档，把新踩的坑追加进坑清单。

## 三条铁律

### 铁律 1：每个资源类型注册唯一 ffi.gc 释放器，禁止裸指针跨函数传递

LuaJIT 的 `ffi.gc(cdata, finalizer)` 是 C 侧 RAII 的对应物：cdata 被 GC 时自动调
finalizer 释放底层资源。**任何从 C 拿到的资源句柄（指针/句柄/流）必须在创建后立即
绑定 ffi.gc**，否则要么泄漏（无人释放）、要么 double-free（多处释放）。

- ✅ 创建即绑定：`local h = ffi.gc(create_handle(), free_handle)`
- ✅ 包装函数只接收/返回**已绑定 GC 的 cdata**，绝不返回裸 `void*`/`intptr_t`
- ❌ 反例：`ffi.cast("void*", p)` 后跨函数传递再手动 free——释放责任在传递链上丢失

对照参考：Cutter（rizin GUI）的 RizinCpp.h 用模板 RAII（`UniquePtrCP` 绑定
`rz_mem_free` 族、`fromOwned()` 统一走释放函数）把 C API 的裸指针收敛成智能指针——
Lua 侧没有模板系统，等价物就是「ffi.gc 注册 + 传递已绑定 cdata」这一条纪律。

### 铁律 2：释放顺序与使用顺序相反（后开先关）

资源依赖顺序错误 = use-after-free / 数据丢失，且症状与数据内容无关（稳定崩溃或
静默错值）。

- ⛔ **cudaFree 后 D2H 拷贝 = use-after-free**（2026-08-18 实测，稳定 segfault 139）：
  `cudaMemcpy(D2H)` 必须**先于** `cudaFree` 执行——free 的是设备端缓冲，拷贝读的是
  设备内存，先 free 后 memcpy 即悬垂访问。
- ⛔ **QR 的 R 提取必须先于 Dorgqr**（2026-08-18 实测）：`Dorgqr` 原位覆盖 A 为 Q，
  若先调 Dorgqr 再取 R，R 数据已被覆盖。
- 通用模式：资源有依赖链时（A 持有 B、B 依赖 C），释放顺序 = C → B → A，与创建相反。

### 铁律 3：cdef 签名与头文件逐字一致，参数个数精确

FFI 不做类型检查，签名错 = 参数错位 = 段错误或静默错值。**逐字对照头文件**，
一个符号都不许猜。

- ⛔ `Highs_qpCall` 是 **25 参数**（比 lpCall 多 6 个），且 `q_start`/`q_index` 是
  **INT[] 不是 double[]**——声明成 double* → 参数错位 → 段错误（2026-08-17 实测
  core dumped）。LP/MIP 只需 18/20 参数。
- ⛔ **LuaJIT vararg 不能包装 FFI cdata 调用**（2026-08-18 实测）：`f(..., x, y)`
  参数错位 + FFI 拒绝 nil 填充——`bufferSize` 等必须**显式内联精确传参**。
- ⛔ `JSValue` 必须声明为 **2×int64**（真实定义 union{int32,double,ptr}(8B)+int64
  tag，16B struct 在 SysV ABI 归 MEMORY 类隐藏指针返回）——声明 1×int64 即错位
  崩溃（2026-08-14 实测）。
- ⛔ **static inline 符号不导出**：`JS_IsException`/`JS_ToCString`/`JS_FreeValue`
  是内联函数，`ffi.load` 后调用会 nil——用导出的等价符号（`JS_ToCStringLen2`、
  `__JS_FreeValue`），且 `__JS_FreeValue` 跳过 refcount 递减，Lua 侧须手动减
  （JSString/JSObject 前 4 字节即 ref_count），否则 double-free
  （`free_zero_refcount: Assertion` 崩溃）。
- ⛔ cdef 里**不能写 `#define`/带初值常量**——常量直接写数字字面量
  （`TCC_RELOCATE_AUTO` → `ffi.cast("void*",1)`）。

## 已实测坑清单（全部踩通，按类目）

| 类目 | 坑 | 症状 | 根因 | 修复 |
|---|---|---|---|---|
| 生命周期 | cudaFree 后 D2H | segfault 139 | use-after-free | D2H 先于 free |
| 生命周期 | Dorgqr 后取 R | R 静默错值 | 原位覆盖 A 为 Q | 先提取 R |
| 生命周期 | 裸 cdata 跨函数 + 手动 free | 泄漏/double-free | 释放责任丢失 | ffi.gc 创建即绑定 |
| ABI | Highs q_start 声明 double* | 段错误 | 25 参数/INT[] 错位 | 逐字对照头文件 |
| ABI | JSValue 声明 1×int64 | 崩溃 | 16B struct MEMORY 类 | 2×int64 |
| ABI | 调用 static inline 符号 | nil 调用 | 符号不导出 | 用导出等价物 |
| ABI | __JS_FreeValue 不递减 | double-free | 内联语义 | 手动减 ref_count |
| ABI | LuaJIT vararg 包装 cdata | 参数错位 | vararg 尾缀错位 | bufferSize 内联传参 |
| ABI | Fortran 字符参数传值 | 静默错值 | LAPACK 要 const char* | 传字符串；lda 等传 int[1] |
| ABI | 列主序输入不转置 | SVD 错值 | Fortran ABI | col_major_from_flat 转换 |
| 编译 | libtcc 内存编译无 -I | stddef.h 找不到 | libtcc 不带 include 链 | `-I<prefix>/lib/tcc/include` |
| 数据面 | 嵌套 LIST 传矩阵 | 空表 #t=0 | duckdb-luajit 不支持嵌套 LIST | 扁平 DOUBLE[] + m/n |
| 数据面 | 维度除不尽 | FFI 静默截断 | int 截断 | 显式非整数守卫 |
| 数据面 | 全部方阵锚定用例 | 侥幸通过 | 对称性掩盖转置错 | 锚定用例含非方阵 |

## 模板

- `TEMPLATE.lua` — 可复制的 FFI lib 骨架（资源句柄 + ffi.gc 绑定 + 释放顺序注释 +
  JSON 字符串返回约定）。新 FFI lib 复制此文件改名开发。
- 完整工作示例：`sudoku/`（C/Rust 求解器 + TCC 运行时编译 + QuickJS 嵌入三形态）、
  `../optimize/highs.lua`（HiGHS LP/QP/MILP）、`../linalg/linalg.lua`（LAPACK/OpenBLAS
  + CUDA GPU 后端）。

## 约定速查

- 加载链统一：`环境变量 → '库名'/'lib库名' → 常见系统路径`（见 highs/linalg 的
  `ffi.load` 链）
- 函数指针缓存：编译/加载放模块 body 一次（函数指针缓存），别每次调用都编译
- UDF 语义：入口把结果编码成 **JSON 字符串**返回（duckdb-luajit 的 luajit_s 不
  序列化 Lua table，返回裸 table 打印 `table: 0x...` 指针）
- 直测脚本断言先 decode（`r.q` 索引字符串静默 nil 不报错）
- 更新 lua 后必须重跑 `luajit_module(mode := 'install')` 才生效（install 命中缓存）
