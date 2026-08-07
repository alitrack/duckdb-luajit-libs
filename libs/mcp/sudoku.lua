-- sudoku.lua: 模块表 + solve 函数（位运算优化版 v2）
-- 输入: 81 位字符串 (0=空), 输出: 81 位解
-- 优化: 行/列/块位图 O(1) 约束检查 + MRV 最少候选启发式
-- 锚点验证: 000001002000020030004500600007600050080090006100005800001004000070900003400030020
--   -> 359461782716829534824573619947682351583197246162345897631254978275918463498736125
local sudoku = {}

-- LuaJIT bit 库（duckdb-luajit 内嵌 LuaJIT，bit32 内置）
local bit = bit32 or require("bit")

function sudoku.solve(p)
    if type(p) ~= 'string' then return nil end
    p = p:gsub('%s', '')
    if #p ~= 81 then return nil end

    local board = {}          -- 81 元素一维数组，0=空
    local rows, cols, boxes = {}, {}, {}
    for i = 1, 9 do rows[i] = 0; cols[i] = 0; boxes[i] = 0 end

    -- 预计算 cell → row/col/box 映射
    local cell_r, cell_c, cell_b = {}, {}, {}
    local empty_count = 0
    for i = 1, 81 do
        local r = math.floor((i - 1) / 9) + 1
        local c = (i - 1) % 9 + 1
        cell_r[i], cell_c[i] = r, c
        cell_b[i] = math.floor((r - 1) / 3) * 3 + math.floor((c - 1) / 3) + 1
        local ch = p:byte(i)
        local v = ch and (ch - 48) or 0
        board[i] = v
        if v >= 1 and v <= 9 then
            local bv = bit.lshift(1, v - 1)
            rows[r] = bit.bor(rows[r], bv)
            cols[c] = bit.bor(cols[c], bv)
            boxes[cell_b[i]] = bit.bor(boxes[cell_b[i]], bv)
        else
            empty_count = empty_count + 1
        end
    end
    if empty_count == 0 then return p end

    -- popcount: 数 bit 置位数
    local function popcount(x)
        local n = 0
        while x ~= 0 do
            x = bit.band(x, x - 1)
            n = n + 1
        end
        return n
    end

    local solve
    solve = function()
        -- MRV: 找候选数最少的空位（候选=9-已占位）
        local best, best_mask = 0, 0
        local best_cands = 10
        for i = 1, 81 do
            if board[i] == 0 then
                local mask = bit.bor(rows[cell_r[i]], bit.bor(cols[cell_c[i]], boxes[cell_b[i]]))
                local cands = 9 - popcount(mask)
                if cands == 0 then return false end        -- 死路
                if cands == 1 then                          -- 唯一候选，立即锁定
                    best, best_mask, best_cands = i, mask, 1
                    break
                end
                if cands < best_cands then
                    best, best_mask, best_cands = i, mask, cands
                end
            end
        end
        if best == 0 then return true end                   -- 全填完

        local r, c, b = cell_r[best], cell_c[best], cell_b[best]
        local used = best_mask
        -- 从最小候选开始尝试
        for v = 1, 9 do
            local bv = bit.lshift(1, v - 1)
            if bit.band(used, bv) == 0 then
                board[best] = v
                rows[r] = bit.bor(rows[r], bv)
                cols[c] = bit.bor(cols[c], bv)
                boxes[b] = bit.bor(boxes[b], bv)
                if solve() then return true end
                -- 回滚
                board[best] = 0
                rows[r] = bit.band(rows[r], bit.bnot(bv))
                cols[c] = bit.band(cols[c], bit.bnot(bv))
                boxes[b] = bit.band(boxes[b], bit.bnot(bv))
            end
        end
        return false
    end

    if not solve() then return nil end
    local out = {}
    for i = 1, 81 do
        out[i] = string.char(board[i] + 48)
    end
    return table.concat(out)
end

return sudoku
