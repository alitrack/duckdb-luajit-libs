-- @lib: init
-- @category: tooling
-- @desc: 仓库批量注册入口 —— 从 INDEX 一次性 dofile 全部（或指定）库并注册到全局表，
--       之后 luajit_s('jsonpath', doc, path) / luajit_s('cidr', ...) 直接可用，
--       免逐库 quick_compile/install。离线可用（本地 INDEX，不拉远端）。
--       参数（表形式）：
--         root   : 仓库根目录（含 INDEX 的目录），必填
--         op     : 'list'（默认，只列名字）/ 'names'（按 names 过滤列名字）/
--                  'all'（dofile+注册全部）/ 'some'（dofile+注册 names 指定的子集）
--         names  : op='names'/'some' 时的库名数组（{ 'jsonpath', 'cidr' }）
--       返回 JSON：
--         list/names → {"names":["..."], "total":N}
--         all/some   → {"registered":[...], "skipped":{name:reason}, "count":N}
--       注册语义：dofile 库文件，顶层返回 function → 注册为 _G[库名]（luajit_s 直调）；
--         返回 module table → 同样注册（json/etl 等表式库走 .run 或直接引用）。
--         dofile 失败（FFI 依赖缺失等）的库记录到 skipped，不中断其余库。

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a'); f:close()
  return s
end

local function json_escape(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    local m = { ['\\']='\\\\', ['"']='\\"', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
    return m[c] or string.format('\\u%04x', c:byte())
  end))
end

-- 解析 INDEX（name|path 行，# 注释与空行跳过）→ {names, byname{path}}
local function parse_index(index_text)
  local names, byname = {}, {}
  for line in (index_text .. '\n'):gmatch('([^\n]*)\n') do
    line = line:gsub('^%s+', ''):gsub('%s+$', '')
    if line == '' or line:sub(1,1) == '#' then goto cont end
    local name, path = line:match('^([^|]+)%|([%w_%-%/.]+)$')
    if name and path then
      name = name:gsub('^%s+',''):gsub('%s+$','')
      path = path:gsub('^%s+',''):gsub('%s+$','')
      names[#names+1] = name
      byname[name] = path
    end
    ::cont::
  end
  return names, byname
end

return function(p)
  if type(p) == 'string' then p = {root = p} end
  if type(p) ~= 'table' or not p.root or p.root == '' then
    return '{"error":"need root (repo dir containing INDEX)"}'
  end
  local root = p.root:match('^(.*)[/\\]$') or p.root
  local index_text = read_file(root .. '/INDEX')
  if not index_text then return '{"error":"cannot open ' .. json_escape(root .. '/INDEX') .. '"}' end
  local all_names, byname = parse_index(index_text)

  local op = p.op or 'list'

  -- 过滤
  local want, sel
  if op == 'names' or op == 'some' then
    if type(p.names) ~= 'table' then
      return '{"error":"op=' .. json_escape(op) .. ' needs names (array)"}'
    end
    sel = {}
    for _, n in ipairs(p.names) do
      if not byname[n] then sel[n] = 'not in INDEX' end
    end
    want = {}
    for _, n in ipairs(p.names) do
      if byname[n] and not sel[n] then want[#want+1] = n end
    end
  else
    want = all_names
  end

  if op == 'list' then
    local parts = {}
    for _, n in ipairs(all_names) do parts[#parts+1] = '"' .. json_escape(n) .. '"' end
    return '{"names":[' .. table.concat(parts, ',') .. '],"total":' .. #all_names .. '}'
  elseif op == 'names' then
    local parts = {}
    for n, reason in pairs(sel) do
      parts[#parts+1] = '"' .. json_escape(n) .. '": "' .. json_escape(reason) .. '"'
    end
    local good = {}
    for _, n in ipairs(want) do good[#good+1] = '"' .. json_escape(n) .. '"' end
    return '{"names":[' .. table.concat(good, ',') .. '],"missing":{' .. table.concat(parts, ',') .. '}}'
  end

  -- op == 'all' / 'some'：dofile + 注册
  local registered, skipped = {}, {}
  for _, name in ipairs(want) do
    local path = root .. '/' .. byname[name]
    local src = read_file(path)
    if not src then
      skipped[name] = 'cannot open ' .. byname[name]
    else
      local chunk, cerr = load(src, name)
      if not chunk then
        skipped[name] = 'load: ' .. tostring(cerr)
      else
        local ok, ret = pcall(chunk)
        if not ok then
          skipped[name] = 'dofile: ' .. tostring(ret)
        elseif type(ret) == 'function' then
          _G[name] = ret
          registered[#registered+1] = name
        elseif type(ret) == 'table' then
          _G[name] = ret
          registered[#registered+1] = name
        else
          skipped[name] = 'lib returned ' .. type(ret) .. ' (expected function/table)'
        end
      end
    end
  end
  local rp = {}
  for _, n in ipairs(registered) do rp[#rp+1] = '"' .. json_escape(n) .. '"' end
  local sp = {}
  local sk = {}
  for n, r in pairs(skipped) do sk[#sk+1] = n end
  table.sort(sk)
  for _, n in ipairs(sk) do sp[#sp+1] = '"' .. json_escape(n) .. '": "' .. json_escape(skipped[n]:gsub(':', ' : ')) .. '"' end
  return '{"registered":[' .. table.concat(rp, ',') .. '],"count":' .. #registered ..
         ',"skipped":{' .. table.concat(sp, ',') .. '}}'
end
