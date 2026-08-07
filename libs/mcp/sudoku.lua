-- sudoku.lua: 模块表 + solve 函数
-- 输入: 81 位字符串 (0=空), 输出: 81 位解
-- 锚点验证: 000001002000020030004500600007600050080090006100005800001004000070900003400030020
--   -> 359461782716829534824573619947682351583197246162345897631254978275918463498736125
local sudoku = {}

function sudoku.solve(p)
    if type(p) ~= 'string' then return nil end
    p = p:gsub('%s', '')
    if #p ~= 81 then return nil end
    local board = {}
    for i = 1, 9 do
        board[i] = {}
        for j = 1, 9 do
            board[i][j] = tonumber(p:sub((i-1)*9 + j, (i-1)*9 + j)) or 0
        end
    end
    local function ok(r, c, v)
        for k = 1, 9 do
            if board[r][k] == v then return false end
            if board[k][c] == v then return false end
        end
        local br, bc = math.floor((r-1)/3)*3, math.floor((c-1)/3)*3
        for i = 1, 3 do for j = 1, 3 do
            if board[br+i][bc+j] == v then return false end
        end end
        return true
    end
    local function find_empty()
        for i = 1, 9 do for j = 1, 9 do
            if board[i][j] == 0 then return i, j end
        end end
        return nil
    end
    local function solve()
        local r, c = find_empty()
        if not r then return true end
        for v = 1, 9 do
            if ok(r, c, v) then
                board[r][c] = v
                if solve() then return true end
                board[r][c] = 0
            end
        end
        return false
    end
    if not solve() then return nil end
    local out = {}
    for i = 1, 9 do for j = 1, 9 do
        out[#out+1] = tostring(board[i][j])
    end end
    return table.concat(out)
end

return sudoku
