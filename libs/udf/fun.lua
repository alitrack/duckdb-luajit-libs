-- @lib: fun
-- @category: udf
-- @desc: 函数式原语库（map/filter/reduce/foldl/take/drop/zip/partition/uniq/flatten/…，
--       50+ 原语），vendored 自 luafun/luafun（MIT/X11，上游单文件 fun.lua，
--       vendored 于 vendored/luafun/fun.lua，逐字节未改）。为 LuaJIT trace JIT 设计：
--       map/filter/reduce 链可被折叠成单个无 CALL 的机器循环（luajit -jdump 可见）。
--       形态=模块表库：install/quick_compile 后全局 _G['luafun'] = 上游模块表，
--       其它 lib 可 `local fun = _G['luafun']` 直接复用（dofile 本文件即得）。
--       本库同时注册 UDF fun(...)（struct 参数，JSON 字符串返回）：
--         op='arr'   seq 物化为 JSON 数组：
--                    seq='range' + a[,b]  → 1..a 或 a..b
--                    seq=[...]            → DuckDB list 直接当输入
--                    steps=[{f:.., p:..}] → map/filter/take/drop 链（f='map'/'filter' 时
--                                           p 是含 x 的表达式串，如 'x % 2 == 0'；
--                                           f='take'/'drop' 时 p 是数字）
--         op='reduce'  同 seq/steps 建链后 reduce：expr 是含 a,b 的表达式（如 'a + b'），
--                      acc 为初值（数字）
--         jit='on'|'off'  开/关 JIT 并回显 jit.status()（性能探针用）
--         bench='A'|'B' + n  内置 A/B 微基准：A=手写 for 循环，B=fun 惰性链
--                      （filter 偶数 + map 平方 + reduce 求和，同语义）
--       ⚠️ 惰性模型（最重要）：上游原语返回惰性 Sequence，必须用库自己的消费者
--       （each/reduce/length/all/any）消费；裸 `for x in seq` 会报错
--       （attempt to index local 'param'）。SQL 侧一律走本 UDF，内部已按惰性模型消费。
--       示例（SQL）：
--         SELECT fun({seq:'range', a:1, b:10, op:'chain',
--           steps:[{f:'filter', p:'x % 2 == 0'}, {f:'map', p:'x * x'}]});  -- [4,16,36,64,100]
--       上游 README 小瑕疵（不影响库本体）：sum(x^2, x=1..100) 示例值印成 328350，
--       正确值 338350（2026-11-09 在真实 LuaJIT 2.1 实测复核）。
-- @license: MIT/X11 (luafun/luafun, Roman Tsisyk; vendored 2026-11-09, 逐字节未改)
-- @requires: 无（纯 Lua，LuaJIT 5.1 语义；无 5.2+/5.3+ 构造，真实 LuaJIT 实测 SYNTAX OK）

local FUN_SRC = [[
---
--- Lua Fun - a high-performance functional programming library for LuaJIT
---
--- Copyright (c) 2013-2017 Roman Tsisyk <roman@tsisyk.com>
---
--- Distributed under the MIT/X11 License. See COPYING.md for more details.
---

local exports = {}
local methods = {}

-- compatibility with Lua 5.1/5.2
local unpack = rawget(table, "unpack") or unpack

-- table.maxn was removed in Lua 5.3+
local maxn = table.maxn or function(t)
    local maxn = 0.0
    for k in pairs(t) do
        if type(k) == "number" and k > maxn then
            maxn = k
        end
    end
    return maxn
end

--------------------------------------------------------------------------------
-- Tools
--------------------------------------------------------------------------------

local return_if_not_empty = function(state_x, ...)
    if state_x == nil then
        return nil
    end
    return ...
end

local call_if_not_empty = function(fun, state_x, ...)
    if state_x == nil then
        return nil
    end
    return state_x, fun(...)
end

local function deepcopy(orig) -- used by cycle()
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
    else
        copy = orig
    end
    return copy
end

local iterator_mt = {
    -- usually called by for-in loop
    __call = function(self, param, state)
        return self.gen(param, state)
    end;
    __tostring = function(_self)
        return '<generator>'
    end;
    -- add all exported methods
    __index = methods;
}

local wrap = function(gen, param, state)
    return setmetatable({
        gen = gen,
        param = param,
        state = state
    }, iterator_mt), param, state
end
exports.wrap = wrap

local unwrap = function(self)
    return self.gen, self.param, self.state
end
methods.unwrap = unwrap

--------------------------------------------------------------------------------
-- Basic Functions
--------------------------------------------------------------------------------

local nil_gen = function(_param, _state)
    return nil
end

local string_gen = function(param, state)
    local state = state + 1
    if state > #param then
        return nil
    end
    local r = string.sub(param, state, state)
    return state, r
end

local ipairs_gen = ipairs({}) -- get the generating function from ipairs

local pairs_gen = pairs({ a = 0 }) -- get the generating function from pairs
local map_gen = function(tab, key)
    local key, value = pairs_gen(tab, key)
    return key, key, value
end

local rawiter = function(obj, param, state)
    assert(obj ~= nil, "invalid iterator")
    if type(obj) == "table" then
        local mt = getmetatable(obj);
        if mt ~= nil then
            if mt == iterator_mt then
                return obj.gen, obj.param, obj.state
            elseif mt.__ipairs ~= nil then
                return mt.__ipairs(obj)
            elseif mt.__pairs ~= nil then
                return mt.__pairs(obj)
            end
        end
        if #obj > 0 then
            -- array
            return ipairs(obj)
        else
            -- hash
            return map_gen, obj, nil
        end
    elseif (type(obj) == "function") then
        return obj, param, state
    elseif (type(obj) == "string") then
        if #obj == 0 then
            return nil_gen, nil, nil
        end
        return string_gen, obj, 0
    end
    error(string.format('object %s of type "%s" is not iterable',
          obj, type(obj)))
end

local iter = function(obj, param, state)
    return wrap(rawiter(obj, param, state))
end
exports.iter = iter

local method0 = function(fun)
    return function(self)
        return fun(self.gen, self.param, self.state)
    end
end

local method1 = function(fun)
    return function(self, arg1)
        return fun(arg1, self.gen, self.param, self.state)
    end
end

local method2 = function(fun)
    return function(self, arg1, arg2)
        return fun(arg1, arg2, self.gen, self.param, self.state)
    end
end

local export0 = function(fun)
    return function(gen, param, state)
        return fun(rawiter(gen, param, state))
    end
end

local export1 = function(fun)
    return function(arg1, gen, param, state)
        return fun(arg1, rawiter(gen, param, state))
    end
end

local export2 = function(fun)
    return function(arg1, arg2, gen, param, state)
        return fun(arg1, arg2, rawiter(gen, param, state))
    end
end

local each = function(fun, gen, param, state)
    repeat
        state = call_if_not_empty(fun, gen(param, state))
    until state == nil
end
methods.each = method1(each)
exports.each = export1(each)
methods.for_each = methods.each
exports.for_each = exports.each
methods.foreach = methods.each
exports.foreach = exports.each

--------------------------------------------------------------------------------
-- Generators
--------------------------------------------------------------------------------

local range_gen = function(param, state)
    local stop, step = param[1], param[2]
    local state = state + step
    if state > stop then
        return nil
    end
    return state, state
end

local range_rev_gen = function(param, state)
    local stop, step = param[1], param[2]
    local state = state + step
    if state < stop then
        return nil
    end
    return state, state
end

local range = function(start, stop, step)
    if step == nil then
        if stop == nil then
            if start == 0 then
                return nil_gen, nil, nil
            end
            stop = start
            start = stop > 0 and 1 or -1
        end
        step = start <= stop and 1 or -1
    end

    assert(type(start) == "number", "start must be a number")
    assert(type(stop) == "number", "stop must be a number")
    assert(type(step) == "number", "step must be a number")
    assert(step ~= 0, "step must not be zero")

    if (step > 0) then
        return wrap(range_gen, {stop, step}, start - step)
    elseif (step < 0) then
        return wrap(range_rev_gen, {stop, step}, start - step)
    end
end
exports.range = range

local duplicate_table_gen = function(param_x, state_x)
    return state_x + 1, unpack(param_x)
end

local duplicate_fun_gen = function(param_x, state_x)
    return state_x + 1, param_x(state_x)
end

local duplicate_gen = function(param_x, state_x)
    return state_x + 1, param_x
end

local duplicate = function(...)
    if select('#', ...) <= 1 then
        return wrap(duplicate_gen, select(1, ...), 0)
    else
        return wrap(duplicate_table_gen, {...}, 0)
    end
end
exports.duplicate = duplicate
exports.replicate = duplicate
exports.xrepeat = duplicate

local tabulate = function(fun)
    assert(type(fun) == "function")
    return wrap(duplicate_fun_gen, fun, 0)
end
exports.tabulate = tabulate

local zeros = function()
    return wrap(duplicate_gen, 0, 0)
end
exports.zeros = zeros

local ones = function()
    return wrap(duplicate_gen, 1, 0)
end
exports.ones = ones

local rands_gen = function(param_x, _state_x)
    return 0, math.random(param_x[1], param_x[2])
end

local rands_nil_gen = function(_param_x, _state_x)
    return 0, math.random()
end

local rands = function(n, m)
    if n == nil and m == nil then
        return wrap(rands_nil_gen, 0, 0)
    end
    assert(type(n) == "number", "invalid first arg to rands")
    if m == nil then
        m = n
        n = 0
    else
        assert(type(m) == "number", "invalid second arg to rands")
    end
    assert(n < m, "empty interval")
    return wrap(rands_gen, {n, m - 1}, 0)
end
exports.rands = rands

--------------------------------------------------------------------------------
-- Slicing
--------------------------------------------------------------------------------

---@param n integer
---@param state_x integer
local nth = function(n, gen_x, param_x, state_x)
    assert(n > 0, "invalid first argument to nth")
    -- An optimization for arrays and strings
    if gen_x == ipairs_gen then
        return param_x[state_x + n]
    elseif gen_x == string_gen then
        if state_x + n <= #param_x then
            return string.sub(param_x, state_x + n, state_x + n)
        else
            return nil
        end
    end
    for _=1,n-1,1 do
        state_x = gen_x(param_x, state_x)
        if state_x == nil then
            return nil
        end
    end
    return return_if_not_empty(gen_x(param_x, state_x))
end
methods.nth = method1(nth)
exports.nth = export1(nth)

local head_call = function(state, ...)
    if state == nil then
        error("head: iterator is empty")
    end
    return ...
end

local head = function(gen, param, state)
    return head_call(gen(param, state))
end
methods.head = method0(head)
exports.head = export0(head)
exports.car = exports.head
methods.car = methods.head

local tail = function(gen, param, state)
    state = gen(param, state)
    if state == nil then
        return wrap(nil_gen, nil, nil)
    end
    return wrap(gen, param, state)
end
methods.tail = method0(tail)
exports.tail = export0(tail)
exports.cdr = exports.tail
methods.cdr = methods.tail

local take_n_gen_x = function(i, state_x, ...)
    if state_x == nil then
        return nil
    end
    return {i, state_x}, ...
end

local take_n_gen = function(param, state)
    local n, gen_x, param_x = param[1], param[2], param[3]
    local i, state_x = state[1], state[2]
    if i >= n then
        return nil
    end
    return take_n_gen_x(i + 1, gen_x(param_x, state_x))
end

local take_n = function(n, gen, param, state)
    assert(n >= 0, "invalid first argument to take_n")
    return wrap(take_n_gen, {n, gen, param}, {0, state})
end
methods.take_n = method1(take_n)
exports.take_n = export1(take_n)

local take_while_gen_x = function(fun, state_x, ...)
    if state_x == nil or not fun(...) then
        return nil
    end
    return state_x, ...
end

local take_while_gen = function(param, state_x)
    local fun, gen_x, param_x = param[1], param[2], param[3]
    return take_while_gen_x(fun, gen_x(param_x, state_x))
end

local take_while = function(fun, gen, param, state)
    assert(type(fun) == "function", "invalid first argument to take_while")
    return wrap(take_while_gen, {fun, gen, param}, state)
end
methods.take_while = method1(take_while)
exports.take_while = export1(take_while)

local take = function(n_or_fun, gen, param, state)
    if type(n_or_fun) == "number" then
        return take_n(n_or_fun, gen, param, state)
    else
        return take_while(n_or_fun, gen, param, state)
    end
end
methods.take = method1(take)
exports.take = export1(take)

local drop_n = function(n, gen, param, state)
    assert(n >= 0, "invalid first argument to drop_n")
    for _=1,n,1 do
        state = gen(param, state)
        if state == nil then
            return wrap(nil_gen, nil, nil)
        end
    end
    return wrap(gen, param, state)
end
methods.drop_n = method1(drop_n)
exports.drop_n = export1(drop_n)

-- Unpack values from param[3] on the first iteration, then return
-- values from the provided iterator.
--
-- A generator function for drop_while().
local drop_while_gen = function(param, state)
    local results = param[3]
    if not results then
        return param[1](param[2], state)
    else
        param[3] = nil
        return state, unpack(results, 1, maxn(results))
    end
end

-- Checks if drop_while should continue skipping. If iterator is not exhausted
-- and skipping is over, elements returned by iterator are wrapped into a table
-- and returned as the second return value. Note that a table is created only
-- once, on the last iteration, for the sake of performance.
local drop_while_x = function(fun, state_x, ...)
    if state_x ~= nil and not fun(...) then
        return state_x, {...}
    end
    return state_x
end

local drop_while = function(fun, gen_x, param_x, state_x)
    assert(type(fun) == "function", "invalid first argument to drop_while")
    local pivot = nil
    while state_x ~= nil and pivot == nil do
        state_x, pivot = drop_while_x(fun, gen_x(param_x, state_x))
    end
    if state_x == nil then
        return wrap(nil_gen, nil, nil)
    end
    return wrap(drop_while_gen, {gen_x, param_x, pivot}, state_x)
end
methods.drop_while = method1(drop_while)
exports.drop_while = export1(drop_while)

local drop = function(n_or_fun, gen_x, param_x, state_x)
    if type(n_or_fun) == "number" then
        return drop_n(n_or_fun, gen_x, param_x, state_x)
    else
        return drop_while(n_or_fun, gen_x, param_x, state_x)
    end
end
methods.drop = method1(drop)
exports.drop = export1(drop)

local split = function(n_or_fun, gen_x, param_x, state_x)
    return take(n_or_fun, gen_x, param_x, state_x),
           drop(n_or_fun, gen_x, param_x, state_x)
end
methods.split = method1(split)
exports.split = export1(split)
methods.split_at = methods.split
exports.split_at = exports.split
methods.span = methods.split
exports.span = exports.split

--------------------------------------------------------------------------------
-- Indexing
--------------------------------------------------------------------------------

local index = function(x, gen, param, state)
    local i = 1
    for _k, r in gen, param, state do
        if r == x then
            return i
        end
        i = i + 1
    end
    return nil
end
methods.index = method1(index)
exports.index = export1(index)
methods.index_of = methods.index
exports.index_of = exports.index
methods.elem_index = methods.index
exports.elem_index = exports.index

local indexes_gen = function(param, state)
    local x, gen_x, param_x = param[1], param[2], param[3]
    local i, state_x = state[1], state[2]
    local r
    while true do
        state_x, r = gen_x(param_x, state_x)
        if state_x == nil then
            return nil
        end
        i = i + 1
        if r == x then
            return {i, state_x}, i
        end
    end
end

local indexes = function(x, gen, param, state)
    return wrap(indexes_gen, {x, gen, param}, {0, state})
end
methods.indexes = method1(indexes)
exports.indexes = export1(indexes)
methods.elem_indexes = methods.indexes
exports.elem_indexes = exports.indexes
methods.indices = methods.indexes
exports.indices = exports.indexes
methods.elem_indices = methods.indexes
exports.elem_indices = exports.indexes

--------------------------------------------------------------------------------
-- Filtering
--------------------------------------------------------------------------------

local filter1_gen = function(fun, gen_x, param_x, state_x, a)
    while true do
        if state_x == nil or fun(a) then break; end
        state_x, a = gen_x(param_x, state_x)
    end
    return state_x, a
end

-- call each other
local filterm_gen
local filterm_gen_shrink = function(fun, gen_x, param_x, state_x)
    ---@diagnostic disable-next-line: need-check-nil
    return filterm_gen(fun, gen_x, param_x, gen_x(param_x, state_x))
end

filterm_gen = function(fun, gen_x, param_x, state_x, ...)
    if state_x == nil then
        return nil
    end
    if fun(...) then
        return state_x, ...
    end
    return filterm_gen_shrink(fun, gen_x, param_x, state_x)
end

local filter_detect = function(fun, gen_x, param_x, state_x, ...)
    if select('#', ...) < 2 then
        return filter1_gen(fun, gen_x, param_x, state_x, ...)
    else
        return filterm_gen(fun, gen_x, param_x, state_x, ...)
    end
end

local filter_gen = function(param, state_x)
    local fun, gen_x, param_x = param[1], param[2], param[3]
    return filter_detect(fun, gen_x, param_x, gen_x(param_x, state_x))
end

local filter = function(fun, gen, param, state)
    return wrap(filter_gen, {fun, gen, param}, state)
end
methods.filter = method1(filter)
exports.filter = export1(filter)
methods.remove_if = methods.filter
exports.remove_if = exports.filter

local grep = function(fun_or_regexp, gen, param, state)
    local fun = fun_or_regexp
    if type(fun_or_regexp) == "string" then
        fun = function(x) return string.find(x, fun_or_regexp) ~= nil end
    end
    return filter(fun, gen, param, state)
end
methods.grep = method1(grep)
exports.grep = export1(grep)

local partition = function(fun, gen, param, state)
    local neg_fun = function(...)
        return not fun(...)
    end
    return filter(fun, gen, param, state),
           filter(neg_fun, gen, param, state)
end
methods.partition = method1(partition)
exports.partition = export1(partition)

--------------------------------------------------------------------------------
-- Reducing
--------------------------------------------------------------------------------

local foldl_call = function(fun, start, state, ...)
    if state == nil then
        return nil, start
    end
    return state, fun(start, ...)
end

local foldl = function(fun, start, gen_x, param_x, state_x)
    while true do
        state_x, start = foldl_call(fun, start, gen_x(param_x, state_x))
        if state_x == nil then
            break;
        end
    end
    return start
end
methods.foldl = method2(foldl)
exports.foldl = export2(foldl)
methods.reduce = methods.foldl
exports.reduce = exports.foldl

local length = function(gen, param, state)
    if gen == ipairs_gen or gen == string_gen then
        return #param - state
    end
    local len = 0
    repeat
        state = gen(param, state)
        len = len + 1
    until state == nil
    return len - 1
end
methods.length = method0(length)
exports.length = export0(length)

local is_null = function(gen, param, state)
    return gen(param, deepcopy(state)) == nil
end
methods.is_null = method0(is_null)
exports.is_null = export0(is_null)

local is_prefix_of = function(iter_x, iter_y)
    local gen_x, param_x, state_x = iter(iter_x)
    local gen_y, param_y, state_y = iter(iter_y)

    local r_x, r_y
    repeat
        state_x, r_x = gen_x(param_x, state_x)
        if state_x == nil then
            return true
        end

        state_y, r_y = gen_y(param_y, state_y)
    until state_y == nil or r_x ~= r_y

    return false
end
methods.is_prefix_of = is_prefix_of
exports.is_prefix_of = is_prefix_of

local all = function(fun, gen_x, param_x, state_x)
    local r
    repeat
        state_x, r = call_if_not_empty(fun, gen_x(param_x, state_x))
    until state_x == nil or not r
    return state_x == nil
end
methods.all = method1(all)
exports.all = export1(all)
methods.every = methods.all
exports.every = exports.all

local any = function(fun, gen_x, param_x, state_x)
    local r
    repeat
        state_x, r = call_if_not_empty(fun, gen_x(param_x, state_x))
    until state_x == nil or r
    return not not r
end
methods.any = method1(any)
exports.any = export1(any)
methods.some = methods.any
exports.some = exports.any

local sum = function(gen, param, state)
    local s = 0
    local r = 0
    repeat
        s = s + r
        state, r = gen(param, state)
    until state == nil
    return s
end
methods.sum = method0(sum)
exports.sum = export0(sum)

local product = function(gen, param, state)
    local p = 1
    local r = 1
    repeat
        p = p * r
        state, r = gen(param, state)
    until state == nil
    return p
end
methods.product = method0(product)
exports.product = export0(product)

local min_cmp = function(m, n)
    if n < m then return n else return m end
end

local max_cmp = function(m, n)
    if n > m then return n else return m end
end

local min = function(gen, param, state)
    local state, m = gen(param, state)
    if state == nil then
        error("min: iterator is empty")
    end

    local cmp
    if type(m) == "number" then
        -- An optimization: use math.min for numbers
        cmp = math.min
    else
        cmp = min_cmp
    end

    for _, r in gen, param, state do
        m = cmp(m, r)
    end
    return m
end
methods.min = method0(min)
exports.min = export0(min)
methods.minimum = methods.min
exports.minimum = exports.min

local min_by = function(cmp, gen_x, param_x, state_x)
    local state_x, m = gen_x(param_x, state_x)
    if state_x == nil then
        error("min: iterator is empty")
    end

    for _, r in gen_x, param_x, state_x do
        m = cmp(m, r)
    end
    return m
end
methods.min_by = method1(min_by)
exports.min_by = export1(min_by)
methods.minimum_by = methods.min_by
exports.minimum_by = exports.min_by

local max = function(gen_x, param_x, state_x)
    local state_x, m = gen_x(param_x, state_x)
    if state_x == nil then
        error("max: iterator is empty")
    end

    local cmp
    if type(m) == "number" then
        -- An optimization: use math.max for numbers
        cmp = math.max
    else
        cmp = max_cmp
    end

    for _, r in gen_x, param_x, state_x do
        m = cmp(m, r)
    end
    return m
end
methods.max = method0(max)
exports.max = export0(max)
methods.maximum = methods.max
exports.maximum = exports.max

local max_by = function(cmp, gen_x, param_x, state_x)
    local state_x, m = gen_x(param_x, state_x)
    if state_x == nil then
        error("max: iterator is empty")
    end

    for _, r in gen_x, param_x, state_x do
        m = cmp(m, r)
    end
    return m
end
methods.max_by = method1(max_by)
exports.max_by = export1(max_by)
methods.maximum_by = methods.max_by
exports.maximum_by = exports.max_by

local totable = function(gen_x, param_x, state_x)
    local tab, val = {}
    while true do
        state_x, val = gen_x(param_x, state_x)
        if state_x == nil then
            break
        end
        table.insert(tab, val)
    end
    return tab
end
methods.totable = method0(totable)
exports.totable = export0(totable)

local tomap = function(gen_x, param_x, state_x)
    local tab, key, val = {}
    while true do
        state_x, key, val = gen_x(param_x, state_x)
        if state_x == nil then
            break
        end
        tab[key] = val
    end
    return tab
end
methods.tomap = method0(tomap)
exports.tomap = export0(tomap)

--------------------------------------------------------------------------------
-- Transformations
--------------------------------------------------------------------------------

local map_gen = function(param, state)
    local gen_x, param_x, fun = param[1], param[2], param[3]
    return call_if_not_empty(fun, gen_x(param_x, state))
end

local map = function(fun, gen, param, state)
    return wrap(map_gen, {gen, param, fun}, state)
end
methods.map = method1(map)
exports.map = export1(map)

local enumerate_gen_call = function(_state, i, state_x, ...)
    if state_x == nil then
        return nil
    end
    return {i + 1, state_x}, i, ...
end

local enumerate_gen = function(param, state)
    local gen_x, param_x = param[1], param[2]
    local i, state_x = state[1], state[2]
    return enumerate_gen_call(state, i, gen_x(param_x, state_x))
end

local enumerate = function(gen, param, state)
    return wrap(enumerate_gen, {gen, param}, {1, state})
end
methods.enumerate = method0(enumerate)
exports.enumerate = export0(enumerate)

local intersperse_call = function(i, state_x, ...)
    if state_x == nil then
        return nil
    end
    return {i + 1, state_x}, ...
end

local intersperse_gen = function(param, state)
    local x, gen_x, param_x = param[1], param[2], param[3]
    local i, state_x = state[1], state[2]
    if i % 2 == 1 then
        return {i + 1, state_x}, x
    else
        return intersperse_call(i, gen_x(param_x, state_x))
    end
end

-- TODO: interperse must not add x to the tail
local intersperse = function(x, gen, param, state)
    return wrap(intersperse_gen, {x, gen, param}, {0, state})
end
methods.intersperse = method1(intersperse)
exports.intersperse = export1(intersperse)

--------------------------------------------------------------------------------
-- Compositions
--------------------------------------------------------------------------------

local function zip_gen_r(param, state, state_new, ...)
    if #state_new == #param / 2 then
        return state_new, ...
    end

    local i = #state_new + 1
    local gen_x, param_x = param[2 * i - 1], param[2 * i]
    local state_x, r = gen_x(param_x, state[i])
    if state_x == nil then
        return nil
    end
    table.insert(state_new, state_x)
    return zip_gen_r(param, state, state_new, r, ...)
end

local zip_gen = function(param, state)
    return zip_gen_r(param, state, {})
end

-- A special hack for zip/chain to skip last two state, if a wrapped iterator
-- has been passed
local numargs = function(...)
    local n = select('#', ...)
    if n >= 3 then
        -- Fix last argument
        local it = select(n - 2, ...)
        if type(it) == 'table' and getmetatable(it) == iterator_mt and
           it.param == select(n - 1, ...) and it.state == select(n, ...) then
            return n - 2
        end
    end
    return n
end

local zip = function(...)
    local n = numargs(...)
    if n == 0 then
        return wrap(nil_gen, nil, nil)
    end
    local param = { [2 * n] = 0 }
    local state = { [n] = 0 }

    local gen_x, param_x, state_x
    for i=1,n,1 do
        local it = select(n - i + 1, ...)
        gen_x, param_x, state_x = rawiter(it)
        param[2 * i - 1] = gen_x
        param[2 * i] = param_x
        state[i] = state_x
    end

    return wrap(zip_gen, param, state)
end
methods.zip = zip
exports.zip = zip

local cycle_gen_call = function(param, state_x, ...)
    if state_x == nil then
        local gen_x, param_x, state_x0 = param[1], param[2], param[3]
        return gen_x(param_x, deepcopy(state_x0))
    end
    return state_x, ...
end

local cycle_gen = function(param, state_x)
    local gen_x, param_x = param[1], param[2]
    return cycle_gen_call(param, gen_x(param_x, state_x))
end

local cycle = function(gen, param, state)
    return wrap(cycle_gen, {gen, param, state}, deepcopy(state))
end
methods.cycle = method0(cycle)
exports.cycle = export0(cycle)

-- call each other
local chain_gen_r1
local chain_gen_r2 = function(param, state, state_x, ...)
    if state_x == nil then
        local i = state[1]
        i = i + 1
        if param[3 * i - 2] == nil then
            return nil
        end
        ---@diagnostic disable-next-line: need-check-nil
        return chain_gen_r1(param, {i, param[3 * i]})
    end
    return {state[1], state_x}, ...
end

chain_gen_r1 = function(param, state)
    local i = state[1]
    local gen_x, param_x = param[3 * i - 2], param[3 * i - 1]
    return chain_gen_r2(param, state, gen_x(param_x, state[2]))
end

local chain = function(...)
    local n = numargs(...)
    if n == 0 then
        return wrap(nil_gen, nil, nil)
    end

    local param = { [3 * n] = 0 }
    local gen_x, param_x, state_x
    for i=1,n,1 do
        local elem = select(i, ...)
        gen_x, param_x, state_x = iter(elem)
        param[3 * i - 2] = gen_x
        param[3 * i - 1] = param_x
        param[3 * i] = state_x
    end

    return wrap(chain_gen_r1, param, {1, param[3]})
end
methods.chain = chain
exports.chain = chain

--------------------------------------------------------------------------------
-- Operators
--------------------------------------------------------------------------------

local operator = {
    ----------------------------------------------------------------------------
    -- Comparison operators
    ----------------------------------------------------------------------------
    lt  = function(a, b) return a < b end,
    le  = function(a, b) return a <= b end,
    eq  = function(a, b) return a == b end,
    ne  = function(a, b) return a ~= b end,
    ge  = function(a, b) return a >= b end,
    gt  = function(a, b) return a > b end,

    ----------------------------------------------------------------------------
    -- Arithmetic operators
    ----------------------------------------------------------------------------
    add = function(a, b) return a + b end,
    div = function(a, b) return a / b end,
    floordiv = function(a, b) return math.floor(a/b) end,
    intdiv = function(a, b)
        local q = a / b
        if a >= 0 then return math.floor(q) else return math.ceil(q) end
    end,
    mod = function(a, b) return a % b end,
    mul = function(a, b) return a * b end,
    neq = function(a) return -a end,
    unm = function(a) return -a end, -- an alias
    pow = function(a, b) return a ^ b end,
    sub = function(a, b) return a - b end,
    truediv = function(a, b) return a / b end,

    ----------------------------------------------------------------------------
    -- String operators
    ----------------------------------------------------------------------------
    concat = function(a, b) return a..b end,
    len = function(a) return #a end,
    length = function(a) return #a end, -- an alias

    ----------------------------------------------------------------------------
    -- Logical operators
    ----------------------------------------------------------------------------
    land = function(a, b) return a and b end,
    lor = function(a, b) return a or b end,
    lnot = function(a) return not a end,
    truth = function(a) return not not a end,
}
exports.operator = operator
methods.operator = operator
exports.op = operator
methods.op = operator

--------------------------------------------------------------------------------
-- module definitions
--------------------------------------------------------------------------------

-- a special syntax sugar to export all functions to the global table
setmetatable(exports, {
    __call = function(t, override)
        for k, v in pairs(t) do
            if rawget(_G, k) ~= nil then
                local msg = 'function ' .. k .. ' already exists in global scope.'
                if override then
                    rawset(_G, k, v)
                    print('WARNING: ' .. msg .. ' Overwritten.')
                else
                    print('NOTICE: ' .. msg .. ' Skipped.')
                end
            else
                rawset(_G, k, v)
            end
        end
    end,
})

return exports
]]

--------------------------------------------------------------------------------
-- duckdb-luajit-libs wrapper: load vendored upstream, expose UDF dispatch
--------------------------------------------------------------------------------
local fun = assert(load(FUN_SRC, "luafun-vendored"))()

local esc = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
local function escs(s)
  return (s:gsub('[%c\\"]', esc))
end

local function encode(v)
  local tv = type(v)
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if math.floor(v) == v and math.abs(v) < 1e15 then
      return string.format('%.0f', v)
    end
    return tostring(v)
  elseif tv == 'string' then
    return '"' .. escs(v) .. '"'
  elseif tv == 'boolean' then
    return v and 'true' or 'false'
  elseif tv == 'table' then
    local out, n = {}, 0
    for i = 1, #v do n = n + 1 out[n] = encode(v[i]) end
    if n > 0 then return '[' .. table.concat(out, ',') .. ']' end
    local parts, k = {}, 0
    for key, val in pairs(v) do
      k = k + 1
      parts[k] = '"' .. escs(tostring(key)) .. '":' .. encode(val)
    end
    if k == 0 then return '[]' end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local STEPS_OK = { map = true, filter = true, take = true, drop = true,
                   take_n = true, drop_n = true }

local function build_seq(p)
  local s = p.seq
  if type(s) == 'table' then
    return fun.iter(s)
  end
  if s == 'range' then
    local a = tonumber(p.a)
    local b = tonumber(p.b)
    if not a then return nil, 'seq=range needs numeric a' end
    if b then return fun.range(a, b) end
    return fun.range(a)
  end
  return nil, 'seq must be "range" (string) or a list (table)'
end

local function expr_fn(body, vars, tag)
  local chunk, cerr = load('return function(' .. vars .. ') return ' .. body .. ' end',
    tag, 't', setmetatable({ x = 0, a = 0, b = 0, math = math },
      { __index = _G }))
  if not chunk then return nil, 'expr: ' .. tostring(cerr) end
  return chunk()
end

local function apply_steps(seq, steps)
  for i, st in ipairs(steps or {}) do
    if type(st) ~= 'table' or type(st.f) ~= 'string' then
      return nil, 'step[' .. i .. '] must be {f:..., p:...}'
    end
    if not STEPS_OK[st.f] then
      return nil, 'unknown step function ' .. tostring(st.f)
    end
    if st.f == 'map' or st.f == 'filter' then
      if type(st.p) ~= 'string' then return nil, st.f .. ' needs p=expression string' end
      local f, e = expr_fn(st.p, 'x', 'fun-step')
      if not f then return nil, e end
      seq = fun[st.f](f, seq)
    else
      local n = tonumber(st.p)
      if not n then return nil, st.f .. ' needs numeric p' end
      seq = fun[st.f](n, seq)
    end
  end
  return seq
end

local function jit_report()
  local n = select('#', jit.status())
  local parts = {}
  for i = 1, n do parts[i] = tostring(select(i, jit.status())) end
  return table.concat(parts, ' | ')
end

local M = function(p)
  if type(p) ~= 'table' then
    return 'ERR: expected struct arg, got ' .. type(p)
  end
  if p.jit == 'on' or p.jit == 'off' then
    if p.jit == 'on' then
      local ok = pcall(jit.on)
      return 'jit ' .. (ok and 'on-requested' or 'on-failed') .. ' | ' .. jit_report()
    end
    jit.off()
    return 'jit off | ' .. jit_report()
  end

  if p.bench == 'A' or p.bench == 'B' then
    local n = tonumber(p.n) or 1000000
    local its = tonumber(p.its) or 5
    local it
    if p.bench == 'A' then
      it = function()
        local s = 0
        for i = 1, n do
          if i % 2 == 0 then s = s + i * i end
        end
        return s
      end
    else
      it = function()
        return fun.reduce(function(a, b) return a + b end, 0,
          fun.map(function(x) return x * x end,
            fun.filter(function(x) return x % 2 == 0 end, fun.range(n))))
      end
    end
    local sink = 0
    for w = 1, 2 do sink = sink + it() end -- warmup (trace JIT)
    local t0 = os.clock()
    for w = 1, its do sink = sink + it() end
    local ms = (os.clock() - t0) * 1000.0
    return string.format('{"arm":"%s","n":%d,"its":%d,"ms":%.3f,"sum":%.0f}',
      p.bench, n, its, ms, sink)
  end

  if p.op == 'chain' or p.op == 'arr' or p.op == 'reduce' then
    local seq, e = build_seq(p)
    if not seq then return 'ERR: ' .. e end
    if p.op == 'reduce' then
      if type(p.expr) ~= 'string' then return 'ERR: reduce needs expr (a,b expression)' end
      local f, ee = expr_fn(p.expr, 'a, b', 'fun-reduce')
      if not f then return 'ERR: ' .. ee end
      local seq2, e2 = apply_steps(seq, p.steps)
      if not seq2 then return 'ERR: ' .. e2 end
      return encode(fun.reduce(f, tonumber(p.acc) or 0, seq2))
    end
    local seq2, e2 = apply_steps(seq, p.steps)
    if not seq2 then return 'ERR: ' .. e2 end
    local out = {}
    fun.each(function(x) out[#out + 1] = x end, seq2)
    return encode(out)
  end
  return 'ERR: op required (chain|arr|reduce) or jit=on|off or bench=A|B'
end

_G['luafun'] = fun
return M
