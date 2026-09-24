-- @lib: fake
-- @category: fake
-- @desc: fakeit 风格假数据生成器（纯 Lua，自包含，零 FFI/零外部依赖）——标量占位符 +
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: tested
--       模板 + 行级批量，seed 可复现。55 种 kind（person/contact/company/address/
--       internet/finance/card/car/text(EN+CN)/date/time/number/color/bool/uuid）。
--       双形态：
--         1) 标量 luajit_s：gen/template/rows/kinds
--         2) 表函数 luajit_table('fake', list := '<spec JSON>')：row_idx|val，
--            val = 一行数据（pipe 分隔，\ → \x07 / | → \x07p / 换行 → \x07n；
--            format='json' 时每行一个 JSON 对象）
--       列名自动判断调用：cols 值留空（或等于列名）→ 按列名推断 kind
--         （name→person.full, email→contact.email, lat→address.lat,
--          created_at→date.datetime, zip→address.zip …）；显式 kind 始终优先。
--       实体关联（默认开启）：每行共享一个"人"上下文——姓名/邮箱/电话/
--         城市/州/邮编/年龄/生日 从同一实体派生（邮箱名=人名、city→state/zip、
--         age↔dob 吻合）；金额/工资走对数正态右长尾。spec.entity=false 可关闭。
--
-- 用法（duckdb-luajit）：
--   install:  SELECT * FROM luajit_module(mode:='install', sql_name:='fake');
--   占位符:   SELECT luajit_s('fake', {op:'gen', kind:'person.last'});          -- 'Molina'
--   模板:     SELECT luajit_s('fake', {op:'template',
--             template:'{person.first} <{contact.email}> {company.name} {date.iso}'});
--   行级:     SELECT luajit_s('fake', {op:'rows', spec:{cols:{name:'person.full'}, rows:3}});
--   表函数:   SELECT * FROM luajit_table('fake',
--             list := '{"cols":{"name":"person.full","email":"contact.email","age":"int:18,65"},
--                       "rows":5,"seed":42}');
--   列名自动推断: cols 值留空 → 按列名猜 kind（无需手写 kind 串）：
--             SELECT * FROM luajit_table('fake',
--             list := '{"cols":{"name":"","email":"","phone":"","lat":"","zip":""},
--                       "rows":5,"seed":42}');
--
-- 参数（表形式；JSON 字符串也可）：
--   op        : 'gen'（单值）/ 'template'（模板展开）/ 'rows'（行级 JSON 数组）/
--               'table'（行级 pipe 行，供表函数）/ 'kinds'（列出全部 kind）
--   kind      : op='gen' 时的占位符名（见下）；gen/template 成功返回裸值（VARCHAR），
--               失败返回 JSON 错误对象 {"status":"Error","message":...}
--   template  : op='template' 的模板串；{a.b} 占位符 + #? 随机 hex
--   spec      : op='rows'/'table' 的行规格表/JSON：
--                 cols  : {列名=kind 串, ...}，kind 串支持 'int:18,65' 参数语法
--                 rows  : 行数（默认 10，上限 100000）
--                 seed  : 复现种子（同一 seed 两次调用逐字节一致）
--                 format: 'pipe'（默认）/ 'json'
--   lo, hi    : op='gen' 且 kind='int:lo,hi' 之外的便捷数值参数（未用，kind 参数串优先）
--
-- kind 列表（55 个，与 go-fakeit / Rust fakeit 命名对齐子集）：
--   person.first   英文名（first）    person.last    英文姓（last）
--   person.full    名+姓              person.first_cn 中文名（姓+名）
--   person.gender  male/female
--   contact.email  邮箱（本地部分 = first.last 派生，域名池）
--   contact.phone  美式电话 (NNN) NNN-NNNN
--   company.name   商业组合名（Name + 行业词 + 可选 Suffix）
--   address.street 门牌+街名+后缀     address.city_cn  中国城市
--   address.city_us 美国城市          address.state    美国州名
--   address.country 国家名            address.country_abbr 国家 ISO 缩写
--   date.iso       YYYY-MM-DD（可 :lo,hi 区间）
--   date.datetime  YYYY-MM-DD HH:MM:SS（可 :lo,hi 区间）
--   date.day       DDDD（1..31）      time.hm        HH:MM
--   number.int     随机整数 0..9999   number.float   随机 0..1（7 位小数）
--   int            number.int 短别名  number.hex     8 位 hex
--   number.int:a,b / int:a,b  区间整数
--   bool.b         true/false（字符串）
--   text.word      单个英文词         text.words     2..5 词短语
--   text.sentence  3..8 词句子（尾句点）
--   text.slug      kebab-case 2..3 词
--   color.name     颜色名             color.hex      #RRGGBB
--   uuid           UUID v4
--   实体关联: person.age + person.dob 年龄↔生日吻合（同一行共享出生年份）
--   finance.amount / finance.salary 对数正态右长尾（金额/工资）
--
-- 诚实边界：词表内置 ~700 词（英文 first/last 各 32、中文姓 30/名 16、城市 28、
-- 国家 34、行业词 24、颜色 16、州 32、街后缀 16）——分布是均匀词表抽样，不是真实人口
-- 分布；要更真实的中文/人口数据请挂 pinyin/真实字典。日期默认区间 2001-01-01..2020-12-31
-- （seed 稳定，不随"现在"漂移；需要当前时间区间请显式传 date_lo/date_hi 参数到 kind：
-- 'date.iso:2024-01-01,2024-12-31'）。性能为纯 Lua 逐行生成，万行级毫秒~秒级，够用；
-- 十万行以上建议 SQL 端 generate_series + 列级 gen。
--
-- Usage (duckdb-luajit, scalar mode):
--   gen:      SELECT luajit_s('fake', {op:'gen', kind:'person.last'});   -- → 'Molina'
--   template: SELECT luajit_s('fake', {op:'template', template:'{person.full} {date.iso}'});
--   rows:     SELECT luajit_s('fake', {op:'rows', spec:{cols:{n:'person.first'}, rows:3, seed:7}});
--   kinds:    SELECT luajit_s('fake', {op:'kinds'});
-- ======================================================================
-- 轻量 JSON 解码（自包含，rng.lua 同款）——仅供 spec/template 传 JSON 串用
-- ======================================================================
local function json_decode(s)
  if type(s) ~= 'string' then return s end
  local pos = 1
  local function skipws()
    while pos <= #s and s:sub(pos, pos):match('%s') do pos = pos + 1 end
  end
  local function parse()
    skipws()
    local c = s:sub(pos, pos)
    if c == '{' then
      pos = pos + 1
      local t = {}
      skipws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        local k = parse()
        skipws()
        if s:sub(pos, pos) ~= ':' then return nil end
        pos = pos + 1
        t[k] = parse()
        skipws()
        local cc = s:sub(pos, pos)
        if cc == ',' then pos = pos + 1
        elseif cc == '}' then pos = pos + 1 break
        else return nil end
      end
      return t
    elseif c == '[' then
      pos = pos + 1
      local t = {}
      skipws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = parse()
        skipws()
        local cc = s:sub(pos, pos)
        if cc == ',' then pos = pos + 1
        elseif cc == ']' then pos = pos + 1 break
        else return nil end
      end
      return t
    elseif c == '"' then
      pos = pos + 1
      local out = {}
      while true do
        local ch = s:sub(pos, pos)
        if ch == '"' then pos = pos + 1 break end
        if ch == '\\' then
          local nxt = s:sub(pos + 1, pos + 1)
          if nxt == 'n' then out[#out + 1] = '\n'
          elseif nxt == 't' then out[#out + 1] = '\t'
          elseif nxt == 'r' then out[#out + 1] = '\r'
          elseif nxt == '\\' then out[#out + 1] = '\\'
          elseif nxt == '"' then out[#out + 1] = '"'
          else out[#out + 1] = nxt end
          pos = pos + 1
        else
          out[#out + 1] = ch
        end
        pos = pos + 1
      end
      return table.concat(out)
    elseif c == 't' then pos = pos + 4 return true
    elseif c == 'f' then pos = pos + 5 return false
    elseif c == 'n' then pos = pos + 4 return nil
    else
      local b, e = s:find('[-%d%.eE+]+', pos)
      if not b then return nil end
      local num = tonumber(s:sub(b, e))
      pos = e + 1
      return num
    end
  end
  return parse()
end

-- 极简 JSON 编码（标量/数组/对象；行级输出走自写 jsesc 拼接）
local function json_encode(v)
  local t = type(v)
  if t == 'number' then return string.format('%.17g', v)
  elseif t == 'string' then return '"' .. v:gsub('[%c"\\]', function(c)
      local m = { ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['"'] = '\\"', ['\\'] = '\\\\' }
      return m[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif t == 'boolean' then return v and 'true' or 'false'
  elseif t == 'nil' then return 'null'
  elseif t == 'table' then
    local n = #v
    if n > 0 then
      local parts = {}
      for i = 1, n do parts[i] = json_encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    -- 对象：key 序稳定（排序）保证可复现
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
      parts[i] = json_encode(tostring(keys[i])) .. ':' .. json_encode(v[keys[i]])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local json = { decode = json_decode, encode = json_encode }

-- ======================================================================
-- 种子化 PRNG（Park–Miller MINSTD LCG：s = s*16807 mod (2^31-1)）
-- 确定性：同 seed 同序列，跨平台一致。全程 double 精确（最大乘积 ~3.6e13 < 2^53），
-- 无位运算，LuaJIT 5.1 安全。周期 2^31-2。
-- ======================================================================
local M2147483647 = 2147483647  -- 2^31-1（梅森素数）
local A16807 = 16807

local function make_rng(seed)
  local s = math.floor(seed or os.time()) % M2147483647
  if s < 1 then s = s + (M2147483647 - 1) end  -- 映射到 [1, 2^31-2]
  return function()
    s = (s * A16807) % M2147483647
    return s / M2147483647  -- [0,1)
  end
end

local function ri(rng, lo, hi)
  if hi < lo then lo, hi = hi, lo end
  return lo + math.floor(rng() * (hi - lo + 1))
end
local function pick(rng, list) return list[ri(rng, 1, #list)] end
-- 浮点区间：rf(rng, lo, hi, dp) → 字符串，dp 位小数
local function rf(rng, lo, hi, dp)
  if hi < lo then lo, hi = hi, lo end
  return string.format('%.' .. (dp or 3) .. 'f', lo + rng() * (hi - lo))
end
local function shuffle(rng, list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  for i = #out, 2, -1 do
    local j = ri(rng, 1, i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end
-- 高斯（Box-Muller，基于 [0,1) rng）→ 均值 mu 方差 sigma 的正态样本
local function gauss(rng, mu, sigma)
  local u1 = math.max(rng(), 1e-12)
  local u2 = rng()
  local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
  return mu + z * sigma
end
-- 对数正态：右长尾（金额/价格/工资类）→ 字符串，dp 位小数
local function lognormal(rng, mu, sigma, dp)
  return string.format('%.' .. (dp or 2) .. 'f', math.exp(gauss(rng, mu, sigma)))
end
-- ======================================================================
-- 词表（内置，均匀分布；~700 词）
-- ======================================================================
local FIRST_EN = {
  'James','Mary','John','Patricia','Robert','Jennifer','Michael','Linda','David','Elizabeth',
  'William','Barbara','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen',
  'Christopher','Nancy','Daniel','Lisa','Matthew','Betty','Anthony','Sandra','Mark','Ashley',
  'Donald','Emily','Steven',
}
local LAST_EN = {
  'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez',
  'Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas','Taylor','Moore','Jackson','Martin',
  'Lee','Perez','Thompson','White','Harris','Sanchez','Clark','Ramirez','Lewis','Robinson',
  'Walker','Young',
}
local LAST_CN = {
  '王','李','张','刘','陈','杨','赵','黄','周','吴',
  '徐','孙','胡','朱','高','林','何','郭','马','罗',
  '梁','宋','郑','谢','韩','唐','冯','于','董','萧',
}
-- 中文"名"（given name）分单字 / 双字两个池，按近年真实占比抽——
-- 双字名（总 3 字名）占大头约 55%，单字名约 45%。旧版是扁平 22 词池里仅 2 个双字，
-- 导致 91% 的名字是"姓+单字"的 2 字名，一眼假。
local GIVEN_CN_1 = {
  '伟','芳','娜','敏','静','丽','强','磊','军','洋',
  '勇','艳','杰','娟','涛','明','超','霞','平','刚',
  '斌','鹏','琳','鑫','宇','浩','博','婷','欣','凯',
}
local GIVEN_CN_2 = {
  '秀英','桂英','建国','建军','志刚','海燕','淑珍','淑兰','玉兰','玉梅',
  '丽华','凤英','美玲','雪梅','桂兰','淑芬','雅静','雅芳','志强','国栋',
  '俊杰','晓燕','春梅','秀梅','玉华','美华','淑华','凤仙','桂香','伟民',
}
local CN_DOUBLE_GIVEN_PROB = 0.55  -- 双字名（→ 总 3 字名）占比
local function cn_given(rng)
  if rng() < CN_DOUBLE_GIVEN_PROB then return pick(rng, GIVEN_CN_2) end
  return pick(rng, GIVEN_CN_1)
end
local CITY_US = {
  'New York','Los Angeles','Chicago','Houston','Phoenix','Philadelphia','San Antonio','San Diego',
  'Dallas','San Jose','Austin','Jacksonville','Fort Worth','Columbus','Charlotte','Indianapolis',
  'San Francisco','Seattle','Denver','Boston','Nashville','Detroit','Portland','Las Vegas','Memphis',
  'Louisville','Baltimore','Milwaukee',
}
local CITY_CN = {
  '北京','上海','广州','深圳','杭州','成都','武汉','西安','南京','重庆',
  '苏州','天津','长沙','郑州','东莞','青岛','沈阳','宁波','昆明','合肥',
  '福州','大连','厦门','无锡','济南','贵阳','哈尔滨','南宁',
}
local STATE_US = {
  'Alabama','Alaska','Arizona','Arkansas','California','Colorado','Connecticut','Delaware',
  'Florida','Georgia','Hawaii','Idaho','Illinois','Indiana','Iowa','Kansas','Kentucky','Louisiana',
  'Maine','Maryland','Massachusetts','Michigan','Minnesota','Mississippi','Missouri','Montana',
  'Nebraska','Nevada','New Hampshire','New Jersey','New Mexico','New York',
}
-- 城市 → 州 + 邮编前缀（关联层：city 定了，state/zip 跟着走，不再各自独立抽）
local CITY_INFO = {
  ['New York']    = { st = 'New York',        zip = '10' },
  ['Los Angeles'] = { st = 'California',      zip = '90' },
  ['Chicago']     = { st = 'Illinois',        zip = '60' },
  ['Houston']     = { st = 'Texas',           zip = '77' },
  ['Phoenix']     = { st = 'Arizona',         zip = '85' },
  ['Philadelphia']= { st = 'Pennsylvania',    zip = '19' },
  ['San Antonio'] = { st = 'Texas',           zip = '78' },
  ['San Diego']   = { st = 'California',      zip = '92' },
  ['Dallas']      = { st = 'Texas',           zip = '75' },
  ['San Jose']    = { st = 'California',      zip = '95' },
  ['Austin']      = { st = 'Texas',           zip = '78' },
  ['Jacksonville']= { st = 'Florida',         zip = '32' },
  ['Fort Worth']  = { st = 'Texas',           zip = '76' },
  ['Columbus']    = { st = 'Ohio',            zip = '43' },
  ['Charlotte']   = { st = 'North Carolina',  zip = '28' },
  ['Indianapolis']= { st = 'Indiana',         zip = '46' },
  ['San Francisco'] = { st = 'California',    zip = '94' },
  ['Seattle']     = { st = 'Washington',      zip = '98' },
  ['Denver']      = { st = 'Colorado',        zip = '80' },
  ['Boston']      = { st = 'Massachusetts',   zip = '02' },
  ['Nashville']   = { st = 'Tennessee',       zip = '37' },
  ['Detroit']     = { st = 'Michigan',        zip = '48' },
  ['Portland']    = { st = 'Oregon',          zip = '97' },
  ['Las Vegas']   = { st = 'Nevada',          zip = '89' },
  ['Memphis']     = { st = 'Tennessee',       zip = '38' },
  ['Louisville']  = { st = 'Kentucky',        zip = '40' },
  ['Baltimore']   = { st = 'Maryland',        zip = '21' },
  ['Milwaukee']   = { st = 'Wisconsin',       zip = '53' },
}
local COUNTRY = {
  'United States','China','Japan','Germany','United Kingdom','France','Canada','Australia',
  'Brazil','India','Italy','Spain','Russia','Mexico','South Korea','Netherlands','Sweden','Norway',
  'Denmark','Switzerland','Austria','Belgium','Finland','Poland','Ireland','Portugal','Greece',
  'Turkey','Argentina','Chile','Colombia','South Africa','New Zealand',
}
local COUNTRY_ABBR = {
  'US','CN','JP','DE','GB','FR','CA','AU','BR','IN','IT','ES','RU','MX','KR','NL','SE','NO',
  'DK','CH','AT','BE','FI','PL','IE','PT','GR','TR','AR','CL','CO','ZA','NZ',
}
local STREET_NAME = {
  'Main','Oak','Pine','Maple','Cedar','Elm','Washington','Lake','Hill','Park',
  'Spring','Sunset','River','Forest','Meadow','Highland',
}
local STREET_SUFFIX = {
  'Street','Avenue','Boulevard','Drive','Lane','Road','Court','Place','Terrace','Way',
  'Circle','Path','Crossing','Parkway','Trail','Row',
}
local COMPANY_A = {
  'Alpha','Apex','Blue','Bright','Cedar','Delta','Dynamo','Everest','Falcon','Granite',
  'Harbor','Iron','Jade','Keystone','Lumen','Maverick','Nimbus','Onyx','Pacific','Quantum',
  'Redwood','Summit','Titan','Vertex',
}
local COMPANY_B = {
  'Technologies','Solutions','Systems','Dynamics','Analytics','Labs','Group','Partners',
  'Industries','Networks','Software','Digital','Media','Logistics','Robotics','Security',
  'Energy','Foods','Airlines','Insurance','Capital','Holdings','Ventures','Interactive',
}
local COMPANY_SUFFIX = { 'Inc', 'Corp', 'LLC', 'Ltd', 'Co' }
local COLORS = {
  'red','orange','yellow','green','blue','purple','pink','brown','black','white',
  'gray','silver','gold','teal','maroon','navy',
}
local WORDS = {
  'data','cloud','network','signal','vector','matrix','orbit','pulse','spark','ridge',
  'harbor','summit','meadow','canyon','glacier','prairie','willow','cedar','amber','coral',
  'drift','echo','flux','grove','haven','ionic','jungle','koala','lagoon','mist',
}

-- kind 注册表：fn(rng) → 标量值
local KINDS = {}
local ALL_KINDS = {}
local function reg(name, fn)
  KINDS[name] = fn
  ALL_KINDS[#ALL_KINDS + 1] = name
end

-- ======================================================================
-- 行级实体上下文（关联层）：同一行的"一个人"共享 ctx，姓名/邮箱/地址
-- 从同一实体派生 → 邮箱名=人名、city 定了 state/zip 跟着走、age↔dob 吻合。
-- 无 ctx（标量单值调用）时各 kind 独立随机，行为与旧版一致。
-- ======================================================================
local function new_person_ctx(rng)
  local ctx = {}
  function ctx.first() if not ctx._f then ctx._f = pick(rng, FIRST_EN) end return ctx._f end
  function ctx.last() if not ctx._l then ctx._l = pick(rng, LAST_EN) end return ctx._l end
  function ctx.full() return ctx.first() .. ' ' .. ctx.last() end
  function ctx.first_cn() if not ctx._fc then ctx._fc = pick(rng, LAST_CN) .. cn_given(rng) end return ctx._fc end
  function ctx.gender() if not ctx._g then ctx._g = rng() < 0.5 and 'male' or 'female' end return ctx._g end
  local EMAIL_DOMAINS = {'example.com','example.org','example.net','test.com','mail.example.com'}
  function ctx.email()
    if not ctx._e then
      local fn, ln = ctx.first():lower(), ctx.last():lower()
      local local_part
      local r = rng()
      if r < 0.34 then local_part = fn .. '.' .. ln
      elseif r < 0.67 then local_part = fn .. tostring(ri(rng, 1, 99))
      else local_part = fn .. '.' .. ln .. tostring(ri(rng, 1, 999)) end
      ctx._e = local_part .. '@' .. pick(rng, EMAIL_DOMAINS)
    end
    return ctx._e
  end
  function ctx.phone()
    if not ctx._p then ctx._p = string.format('(%03d) %03d-%04d', ri(rng, 200, 989), ri(rng, 200, 989), ri(rng, 0, 9999)) end
    return ctx._p
  end
  function ctx.city()
    if not ctx._c then ctx._c = pick(rng, CITY_US) end
    return ctx._c
  end
  function ctx.state()
    if not ctx._s then ctx._s = (CITY_INFO[ctx.city()] or {}).st or pick(rng, STATE_US) end
    return ctx._s
  end
  function ctx.zip()
    if not ctx._z then
      local p = (CITY_INFO[ctx.city()] or {}).zip
      if p then ctx._z = p .. string.format('%03d', ri(rng, 0, 999))
      else ctx._z = string.format('%05d', ri(rng, 10000, 99999)) end
    end
    return ctx._z
  end
  return ctx
end

reg('person.first', function(rng, ctx) if ctx then return ctx.first() end return pick(rng, FIRST_EN) end)
reg('person.last', function(rng, ctx) if ctx then return ctx.last() end return pick(rng, LAST_EN) end)
reg('person.full', function(rng, ctx) if ctx then return ctx.full() end return pick(rng, FIRST_EN) .. ' ' .. pick(rng, LAST_EN) end)
reg('person.first_cn', function(rng, ctx) if ctx then return ctx.first_cn() end return pick(rng, LAST_CN) .. cn_given(rng) end)
reg('person.gender', function(rng, ctx) if ctx then return ctx.gender() end return rng() < 0.5 and 'male' or 'female' end)
reg('contact.email', function(rng, ctx)
  if ctx then return ctx.email() end
  local fn, ln = pick(rng, FIRST_EN):lower(), pick(rng, LAST_EN):lower()
  local local_part
  local r = rng()
  if r < 0.34 then local_part = fn .. '.' .. ln
  elseif r < 0.67 then local_part = fn .. tostring(ri(rng, 1, 99))
  else local_part = fn .. '.' .. ln .. tostring(ri(rng, 1, 999)) end
  local domain = pick(rng, {'example.com','example.org','example.net','test.com','mail.example.com'})
  return local_part .. '@' .. domain
end)
reg('contact.phone', function(rng, ctx)
  if ctx then return ctx.phone() end
  return string.format('(%03d) %03d-%04d', ri(rng, 200, 989), ri(rng, 200, 989), ri(rng, 0, 9999))
end)
reg('company.name', function(rng)
  local n = pick(rng, COMPANY_A) .. ' ' .. pick(rng, COMPANY_B)
  if rng() < 0.5 then n = n .. ' ' .. pick(rng, COMPANY_SUFFIX) end
  return n
end)
reg('address.street', function(rng)
  return string.format('%d %s %s', ri(rng, 1, 9999), pick(rng, STREET_NAME), pick(rng, STREET_SUFFIX))
end)
reg('address.city_us', function(rng, ctx) if ctx then return ctx.city() end return pick(rng, CITY_US) end)
reg('address.city_cn', function(rng) return pick(rng, CITY_CN) end)
reg('address.state', function(rng, ctx) if ctx then return ctx.state() end return pick(rng, STATE_US) end)
reg('address.country', function(rng)
  local i = ri(rng, 1, #COUNTRY)
  return COUNTRY[i]
end)
reg('address.country_abbr', function(rng)
  local i = ri(rng, 1, #COUNTRY_ABBR)
  return COUNTRY_ABBR[i]
end)
reg('number.int', function(rng) return tostring(ri(rng, 0, 9999)) end)
reg('int', function(rng) return tostring(ri(rng, 0, 9999)) end)  -- number.int 的短别名（常带 :lo,hi）
reg('number.float', function(rng) return string.format('%.7f', rng()) end)
reg('number.hex', function(rng)
  return string.format('%08x', ri(rng, 0, 0xFFFFFFFF))
end)
reg('bool.b', function(rng) return rng() < 0.5 and 'true' or 'false' end)
reg('text.word', function(rng) return pick(rng, WORDS):lower() end)
reg('text.words', function(rng)
  local n = ri(rng, 2, 5)
  local out = shuffle(rng, WORDS)
  local parts = {}
  for i = 1, n do parts[i] = out[i]:lower() end
  return table.concat(parts, ' ')
end)
reg('text.sentence', function(rng)
  local n = ri(rng, 3, 8)
  local out = shuffle(rng, WORDS)
  local parts = {}
  for i = 1, n do parts[i] = out[i]:lower() end
  return table.concat(parts, ' ') .. '.'
end)
reg('text.slug', function(rng)
  local n = ri(rng, 2, 3)
  local out = shuffle(rng, WORDS)
  local parts = {}
  for i = 1, n do parts[i] = out[i]:lower() end
  return table.concat(parts, '-')
end)
reg('color.name', function(rng) return pick(rng, COLORS) end)
reg('color.hex', function(rng)
  return string.format('#%02x%02x%02x', ri(rng, 0, 255), ri(rng, 0, 255), ri(rng, 0, 255))
end)
reg('uuid', function(rng)
  local hex = {}
  for i = 1, 16 do
    local x = ri(rng, 0, 255)
    if i == 7 then x = (x & 0x0F) | 0x40 end   -- version 4
    if i == 9 then x = (x & 0x3F) | 0x80 end   -- variant 10xx
    hex[i] = string.format('%02x', x)
  end
  return table.concat(hex, '', 1, 4) .. '-' .. table.concat(hex, '', 5, 6)
    .. '-' .. table.concat(hex, '', 7, 8) .. '-' .. table.concat(hex, '', 9, 10)
    .. '-' .. table.concat(hex, '', 11, 16)
end)
reg('uuid_v4', KINDS['uuid'])
-- 人名补充
reg('person.username', function(rng)
  local fn, ln = pick(rng, FIRST_EN):lower(), pick(rng, LAST_EN):lower()
  local r = rng()
  local sep = r < 0.4 and '_' or (r < 0.7 and '.' or '')
  local s = fn .. sep .. ln
  if rng() < 0.4 then s = s .. tostring(ri(rng, 1, 99)) end
  return s
end)
reg('person.prefix', function(rng) return pick(rng, {'Mr.', 'Mrs.', 'Ms.', 'Dr.', 'Prof.'}) end)
reg('person.suffix', function(rng) return pick(rng, {'Jr.', 'Sr.', 'II', 'III', 'IV'}) end)
-- 联系方式补充
reg('contact.phone_unformatted', function(rng)
  return string.format('%03d%03d%04d', ri(rng, 200, 989), ri(rng, 200, 989), ri(rng, 0, 9999))
end)
-- 地址补充：门牌 / 邮编 / 经纬度 / 完整地址（zip/full 走实体关联：跟 city 走）
reg('address.street_number', function(rng) return tostring(ri(rng, 1, 9999)) end)
reg('address.zip', function(rng, ctx)
  if ctx then return ctx.zip() end
  return string.format('%05d', ri(rng, 10000, 99999))
end)
reg('address.lat', function(rng) return rf(rng, -90, 90, 6) end)
reg('address.lon', function(rng) return rf(rng, -180, 180, 6) end)
reg('address.full', function(rng, ctx)
  if ctx then
    return string.format('%d %s %s, %s, %s %s',
      ri(rng, 1, 9999), pick(rng, STREET_NAME), pick(rng, STREET_SUFFIX),
      ctx.city(), ctx.state(), ctx.zip())
  end
  return pick(rng, STREET_NAME) .. ' ' .. pick(rng, STREET_SUFFIX)
    .. ', ' .. pick(rng, CITY_US) .. ', ' .. pick(rng, STATE_US) .. ' ' .. tostring(ri(rng, 10000, 99999))
end)
-- 网络 / 互联网
local DOMAIN_TLD = {'com','org','net','io','co','dev','app','tech','ai','xyz','info','me'}
reg('internet.domain', function(rng)
  return pick(rng, WORDS) .. tostring(ri(rng, 1, 999)) .. '.' .. pick(rng, DOMAIN_TLD)
end)
reg('internet.url', function(rng)
  return 'https://www.' .. pick(rng, WORDS) .. tostring(ri(rng, 1, 999)) .. '.' .. pick(rng, DOMAIN_TLD)
end)
reg('internet.ip', function(rng)
  return string.format('%d.%d.%d.%d', ri(rng, 1, 254), ri(rng, 0, 255), ri(rng, 0, 255), ri(rng, 1, 254))
end)
-- 财务（对数正态：右长尾——一串订单里冒出几个大额，才真实）
-- amount 默认量级：median≈35 (e^3.55)，P99≈5k；salary 量级：median≈55k (e^10.9)
reg('finance.amount', function(rng) return lognormal(rng, 3.55, 1.6, 2) end)
reg('finance.salary', function(rng) return lognormal(rng, 10.9, 0.55, 0) end)
reg('card.number', function(rng)
  local out = {}
  for i = 1, 4 do out[i] = string.format('%04d', ri(rng, 0, 9999)) end
  return table.concat(out, ' ')
end)
reg('card.cvv', function(rng) return string.format('%03d', ri(rng, 0, 999)) end)
-- 职业 / 行业 / 车辆
local JOBS = {
  'Software Engineer','Data Scientist','Product Manager','UX Designer','DevOps Engineer',
  'Accountant','Marketing Manager','Sales Representative','Teacher','Nurse','Lawyer','Engineer',
  'Chef','Writer','Analyst','Consultant','Architect','Photographer','Driver','Electrician',
}
local INDUSTRIES = {
  'Technology','Healthcare','Finance','Education','Retail','Manufacturing','Energy','Media',
  'Transportation','Real Estate','Consulting','Hospitality','Agriculture','Construction','Telecom',
}
local CAR_BRAND = { 'Toyota','Honda','Ford','Tesla','BMW','Mercedes-Benz','Audi','Volkswagen','Hyundai','Kia','Nissan','Subaru','Mazda','Lexus' }
reg('company.job_title', function(rng) return pick(rng, JOBS) end)
reg('company.industry', function(rng) return pick(rng, INDUSTRIES) end)
reg('car.brand', function(rng) return pick(rng, CAR_BRAND) end)
-- 中文补充
reg('text.sentence_cn', function(rng)
  local s = pick(rng, {'今天的数据','这个系统','新的方案','我们的产品','这次调研','数据库的性能','接口的设计'})
  local v = pick(rng, {'表现良好','需要优化','运行稳定','提升明显','有待改进','符合预期','超预期','仍有瓶颈'})
  return s .. v .. '。'
end)
-- 浮点区间
reg('number.float_range', function(rng, lo_s, hi_s, dp)
  return rf(rng, lo_s, hi_s, dp)
end)

-- 日期：默认区间 2001-01-01..2020-12-31（seed 稳定），可 kind 参数 'date.iso:lo,hi'
-- LuaJIT 5.1 无 // 整除运算符 → 手写 floor_div（仅日期 civil 换算用）
local function floor_div(a, b)
  return math.floor(a / b)
end
local function d2e(y, m, d)  -- date → epoch day（civil-from-days，Howard Hinnant）
  local yy = y - (m <= 2 and 1 or 0)
  local era = floor_div(yy, 400)
  local yoe = yy - era * 400
  local doy = floor_div(153 * (m + (m > 2 and -3 or 9)) + 2, 5) + d - 1
  local doe = yoe * 365 + floor_div(yoe, 4) - floor_div(yoe, 100) + doy
  return era * 146097 + doe - 719468
end
local function e2d(z)  -- epoch day → {y,m,d}
  local z = z + 719468
  local era = floor_div(z >= 0 and z or z - 146096, 146097)
  local doe = z - era * 146097
  local yoe = floor_div(doe - floor_div(doe, 1460) + floor_div(doe, 36524) - floor_div(doe, 146096), 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor_div(yoe, 4) - floor_div(yoe, 100))
  local mp = floor_div(5 * doy + 2, 153)
  local d = doy - floor_div(153 * mp + 2, 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  return y + (m <= 2 and 1 or 0), m, d
end
local EPOCH_DEFAULT_LO = d2e(2001, 1, 1)
local EPOCH_DEFAULT_HI = d2e(2020, 12, 31)
local function rand_epoch_day(rng, lo_s, hi_s)
  local lo, hi = EPOCH_DEFAULT_LO, EPOCH_DEFAULT_HI
  -- lo_s/hi_s 只认字符串日期界。行级/表函数调用会把实体 ctx（table）传进 lo_s 槽
  -- （date 系签名 (rng, lo_s, hi_s) 与实体系 (rng, ctx) 在第 2 参撞位），非字符串直接忽略
  -- → 走默认区间，否则会 table:match 抛错被表函数 pcall 吞成 0 行。
  if type(lo_s) == 'string' then
    local y, m, d = lo_s:match('(%d%d%d%d)-(%d%d)-(%d%d)')
    if y then lo = d2e(tonumber(y), tonumber(m), tonumber(d)) end
  end
  if type(hi_s) == 'string' then
    local y, m, d = hi_s:match('(%d%d%d%d)-(%d%d)-(%d%d)')
    if y then hi = d2e(tonumber(y), tonumber(m), tonumber(d)) end
  end
  return ri(rng, lo, hi)
end
local function fmt_date(z)
  local y, m, d = e2d(z)
  return string.format('%04d-%02d-%02d', y, m, d)
end
local function fmt_hm(rng)
  return string.format('%02d:%02d', ri(rng, 0, 23), ri(rng, 0, 59))
end
local function fmt_hms(rng)
  return string.format('%02d:%02d:%02d', ri(rng, 0, 23), ri(rng, 0, 59), ri(rng, 0, 59))
end
reg('date.iso', function(rng, lo_s, hi_s) return fmt_date(rand_epoch_day(rng, lo_s, hi_s)) end)
reg('date.datetime', function(rng, lo_s, hi_s) return fmt_date(rand_epoch_day(rng, lo_s, hi_s)) .. ' ' .. fmt_hms(rng) end)
reg('date.day', function(rng) return tostring(ri(rng, 1, 31)) end)
reg('time.hm', fmt_hm)
reg('time.date_cn', function(rng, lo_s, hi_s)
  local y, m, d = e2d(rand_epoch_day(rng, lo_s, hi_s))
  return string.format('%d年%d月%d日', y, m, d)
end)
-- 年龄 ↔ 生日吻合（ctx 缓存出生年份：同一行 age 与 dob 一致）
local BIRTH_YEAR_LO, BIRTH_YEAR_HI = 1961, 2008  -- 对应 2026 年 18..65 岁
reg('person.age', function(rng, ctx)
  if ctx then
    if not ctx._by then ctx._by = ri(rng, BIRTH_YEAR_LO, BIRTH_YEAR_HI) end
    return tostring(2026 - ctx._by)
  end
  return tostring(ri(rng, 18, 65))
end)
reg('person.dob', function(rng, ctx)
  local by
  if ctx then
    if not ctx._by then ctx._by = ri(rng, BIRTH_YEAR_LO, BIRTH_YEAR_HI) end
    by = ctx._by
  else
    by = ri(rng, BIRTH_YEAR_LO, BIRTH_YEAR_HI)
  end
  return fmt_date(d2e(by, ri(rng, 1, 12), ri(rng, 1, 28)))
end)

-- kind 解析：'name' 或 'name:arg1,arg2'；ctx=行级实体上下文（可选）
local function resolve_kind(rng, kind_str, ctx)
  local name, a1 = kind_str:match('^([%w_%.]+):?(.*)$')
  if not name then return nil, 'unknown kind: ' .. tostring(kind_str) end
  local fn = KINDS[name]
  if not fn then return nil, 'unknown kind: ' .. name end
  a1 = a1 or ''
  if a1 ~= '' then
    if name == 'number.int' or name == 'int' then
      local lo, hi = a1:match('^(-?%d+),(-?%d+)$')
      if not lo then return nil, name .. ':lo,hi parse failed: ' .. a1 end
      return tostring(ri(rng, tonumber(lo), tonumber(hi))), nil
    elseif name == 'number.float_range' then
      local lo, hi, dp = a1:match('^(-?[%d%.]+),(-?[%d%.]+),(%d+)$')
      if not lo then lo, hi = a1:match('^(-?[%d%.]+),(-?[%d%.]+)$') end
      if not lo then return nil, name .. ':lo,hi[,dp] parse failed: ' .. a1 end
      return fn(rng, tonumber(lo), tonumber(hi), dp and tonumber(dp) or 3), nil
    elseif name == 'date.iso' or name == 'date.datetime' or name == 'time.date_cn' then
      local lo_s, hi_s = a1:match('^(.-),(.+)$')
      return fn(rng, lo_s, hi_s), nil
    else
      return nil, 'kind ' .. name .. ' does not accept args'
    end
  end
  return fn(rng, ctx), nil
end

-- 模板展开：{a.b} 占位符 + #? 随机 hex（gofakeit generator 风格）
local function expand_template(rng, template)
  return (template:gsub('{([%w_%.]+)}', function(k)
    local v, err = resolve_kind(rng, k)
    if not v then return k end
    return v
  end)):gsub('#%?', function()
    return string.format('%x', ri(rng, 0, 15))
  end)
end

-- JSON 输出辅助（json.lua 编不了 table→?，手工 escape）
local function jsesc(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    local m = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return m[c] or string.format('\\u%04x', c:byte())
  end))
end

-- ======================================================================
-- 列名 → kind 自动推断（"列名自动判断调用"）
-- 规则：先查精确名表（覆盖最常见列名），再做后缀/包含模糊匹配，兜底
-- text.word。命中精确表 → 确定性；模糊匹配按序优先（更具体在前）。
-- ======================================================================
local EXACT_KIND = {
  id = 'uuid', name = 'person.full', full_name = 'person.full', full_name_cn = 'person.full_cn',
  first_name = 'person.first', last_name = 'person.last', name_cn = 'person.first_cn',
  user_name = 'person.username', username = 'person.username',
  gender = 'person.gender',
  email = 'contact.email', email_address = 'contact.email',
  phone = 'contact.phone', phone_number = 'contact.phone', mobile = 'contact.phone',
  tel = 'contact.phone_unformatted',
  company = 'company.name', company_name = 'company.name', employer = 'company.name',
  job = 'company.job_title', job_title = 'company.job_title', title = 'company.job_title',
  industry = 'company.industry',
  street = 'address.street', address = 'address.full', addr = 'address.full',
  full_address = 'address.full',
  city = 'address.city_us', city_cn = 'address.city_cn',
  state = 'address.state', region = 'address.state', province = 'address.city_cn',
  country = 'address.country',
  zip = 'address.zip', zip_code = 'address.zip', postal = 'address.zip', postal_code = 'address.zip',
  lat = 'address.lat', latitude = 'address.lat',
  lon = 'address.lon', lng = 'address.lon', longitude = 'address.lon',
  street_number = 'address.street_number',
  domain = 'internet.domain', website = 'internet.url', url = 'internet.url',
  web_site = 'internet.url', ip = 'internet.ip', ip_address = 'internet.ip',
  amount = 'finance.amount', price = 'finance.amount', salary = 'finance.salary',
  revenue = 'finance.amount', cost = 'finance.amount', fee = 'finance.amount',
  total = 'finance.amount',
  card = 'card.number', card_number = 'card.number', credit_card = 'card.number',
  cvv = 'card.cvv',
  car = 'car.brand', car_brand = 'car.brand',
  color = 'color.name', hex_color = 'color.hex', color_hex = 'color.hex',
  word = 'text.word', words = 'text.words', sentence = 'text.sentence',
  sentence_cn = 'text.sentence_cn', text = 'text.sentence', paragraph = 'text.sentence',
  slug = 'text.slug',
  note = 'text.sentence', comment = 'text.sentence', description = 'text.sentence',
  bio = 'text.sentence',
  is_active = 'bool.b', active = 'bool.b', is_deleted = 'bool.b', deleted = 'bool.b',
  flag = 'bool.b', is_admin = 'bool.b', admin = 'bool.b', verified = 'bool.b',
  date = 'date.iso', created_at = 'date.datetime', updated_at = 'date.datetime',
  created = 'date.datetime', updated = 'date.datetime',
  birth_date = 'person.dob', birthday = 'person.dob', dob = 'person.dob', age = 'person.age',
  date_cn = 'time.date_cn',
  time = 'time.hm',
  uuid = 'uuid',
}
-- 模糊规则：(子串, kind)，按序匹配（先精确后模糊，命中即停）
local FUZZY_RULES = {
  {'_at$', 'date.datetime'},
  {'email', 'contact.email'},
  {'phone', 'contact.phone'},
  {'name', 'person.full'},
  {'user', 'person.username'},
  {'lat', 'address.lat'},
  {'lon', 'address.lon'},
  {'zip', 'address.zip'},
  {'city', 'address.city_us'},
  {'country', 'address.country'},
  {'street', 'address.street'},
  {'address', 'address.full'},
  {'company', 'company.name'},
  {'job', 'company.job_title'},
  {'domain', 'internet.domain'},
  {'url', 'internet.url'},
  {'ip', 'internet.ip'},
  {'amount', 'finance.amount'},
  {'price', 'finance.amount'},
  {'card', 'card.number'},
  {'car', 'car.brand'},
  {'color', 'color.name'},
  {'bool', 'bool.b'},
  {'date', 'date.iso'},
  {'uuid', 'uuid'},
  {'word', 'text.word'},
  {'text', 'text.sentence'},
}
local function guess_kind(colname)
  local low = (colname or ''):lower():gsub('%s+', '_'):gsub('^_+|_+$', '')
  if low == '' then return 'text.word' end
  local exact = EXACT_KIND[low]
  if exact then return exact end
  for _, rule in ipairs(FUZZY_RULES) do
    local pat, kind = rule[1], rule[2]
    if low:find(pat) or (pat:sub(1, 1) == '_' and low:match(pat)) then return kind end
  end
  return 'text.word'  -- 兜底
end

-- ======================================================================
-- 行级生成（op='rows' / op='table' / 表函数共用）
-- spec = { cols={name=kind_str,...}, rows=N, seed=S, format='pipe'|'json',
--          date_lo=?, date_hi=? }
-- cols 值既可以是显式 kind（'person.first' / 'int:18,65'），也可以是列名本身
-- （此时自动推断：'name' → person.full）；显式 kind 优先，列名仅做推断兜底。
-- 返回 { rows = {每行字符串}, error = '...' }
-- ======================================================================
local function build_rows(spec)
  local err
  local function die(msg) err = msg end
  if type(spec) ~= 'table' then return { error = 'spec must be a table (JSON string or struct)' } end
  local cols = spec.cols
  if type(cols) ~= 'table' or next(cols) == nil then
    return { error = "spec.cols required: {col: 'kind', ...}" }
  end
  local names = {}
  for k in pairs(cols) do names[#names + 1] = k end
  table.sort(names)  -- 列序稳定（Lua table 遍历序不定 → 按名字排序保证可复现）
  local n = spec.rows and tonumber(spec.rows) or 10
  if n == nil or n < 1 or n > 100000 or n ~= math.floor(n) then
    return { error = 'spec.rows must be an integer in [1, 100000]' }
  end
  local fmt = spec.format == 'json' and 'json' or 'pipe'
  local rng = make_rng(spec.seed)
  -- 预解析每列的有效 kind：显式 kind 优先；值为空 / 等于列名 → 按列名推断
  local kind_of = {}
  for _, k in ipairs(names) do
    local raw = cols[k]
    local s = raw and tostring(raw) or ''
    if s == '' or s:lower() == k:lower() then
      kind_of[k] = guess_kind(k)
    else
      kind_of[k] = s
    end
  end
  local rows = {}
  for r = 1, n do
    -- 每行一个实体上下文：姓名/邮箱/电话/城市/州/邮编/年龄/生日 从同一实体派生，
    -- 保证跨列关联（邮箱名=人名、city→state/zip、age↔dob 吻合）。
    -- spec.entity=false 可关闭（回到逐列独立随机，旧行为）。
    local ctx = (spec.entity == false) and nil or new_person_ctx(rng)
    local cells = {}
    for _, k in ipairs(names) do
      local v, e = resolve_kind(rng, kind_of[k], ctx)
      if not v then die(e) break end
      cells[#cells + 1] = { k = k, v = v }
    end
    if err then break end
    if fmt == 'json' then
      local parts = {}
      for i = 1, #cells do
        parts[i] = '"' .. jsesc(cells[i].k) .. '":"' .. jsesc(cells[i].v) .. '"'
      end
      rows[r] = '{' .. table.concat(parts, ',') .. '}'
    else
      -- pipe 行：转义 \ → \x07、| → \x07p、\n → \x07n、\r → \x07r
      local parts = {}
      for i = 1, #cells do
        local v = cells[i].v:gsub('\\', '\x07')
        v = v:gsub('|', '\x07p'):gsub('\n', '\x07n'):gsub('\r', '\x07r')
        parts[i] = v
      end
      rows[r] = table.concat(parts, '|')
    end
  end
  if err then return { error = err } end
  return { rows = rows }
end

-- ======================================================================
-- 分发
-- ======================================================================
local function run(p)
  if type(p) == 'string' then
    if p == '' or p == 'kinds' then p = { op = p == '' and 'kinds' or 'kinds' }
    else
      local ok, t = pcall(json.decode, p)
      if ok and type(t) == 'table' then p = t else p = { template = p } end
    end
  end
  if type(p) ~= 'table' then
    return json.encode({ status = 'Error', message = 'args must be a struct or JSON string' })
  end
  local op = p.op or 'gen'
  if op == 'kinds' then
    return json.encode({ kinds = ALL_KINDS, count = #ALL_KINDS })
  elseif op == 'gen' then
    local kind = p.kind
    if not kind then return json.encode({ status = 'Error', message = "missing kind" }) end
    local rng = make_rng(p.seed)
    local v, e = resolve_kind(rng, tostring(kind))
    if not v then return json.encode({ status = 'Error', message = e }) end
    return tostring(v)  -- 裸值（VARCHAR 输出）；错误才走 JSON 对象
  elseif op == 'template' then
    local t = p.template
    if not t then return json.encode({ status = 'Error', message = 'missing template' }) end
    local rng = make_rng(p.seed)
    return expand_template(rng, t)  -- 裸值
  elseif op == 'rows' or op == 'table' then
    local spec = p.spec
    if type(spec) == 'string' then
      local ok, t = pcall(json.decode, spec)
      if not ok or type(t) ~= 'table' then
        return json.encode({ status = 'Error', message = 'spec must be a table or JSON string' })
      end
      spec = t
    end
    -- seed 容错：允许放在外层 op 结构（{op, spec, seed}），spec 内无 seed 时回填
    if type(spec) == 'table' and spec.seed == nil and p.seed ~= nil then spec.seed = p.seed end
    local res = build_rows(spec)
    if res.error then return json.encode({ status = 'Error', message = res.error }) end
    if op == 'table' then
      return table.concat(res.rows, '\n')  -- 表函数形态：裸行串
    end
    return json.encode(res.rows)
  end
  return json.encode({ status = 'Error', message = 'unknown op: ' .. tostring(op) })
end

-- ======================================================================
-- 单一顶层函数返回（quick_compile 契约：chunk 顶层 return function）
-- 按参数内容分派两种调用形态：
--   luajit_table('fake', list := <spec JSON 串>) → 表函数，返回行字符串数组
--   luajit_s('fake', <struct/标量 JSON 串/裸模板串>) → 标量，返回字符串
-- 判据（行级 spec 特征键：cols/rows/format，且非 op 驱动）：
--   解析后的表含 cols（或 rows/format 之一）且无 op → 表函数 spec；
--   含 op → 标量 run；裸串（{a.b} 模板 / 非 JSON）→ 标量 template。
-- ======================================================================
local function is_spec(t)
  if type(t) ~= 'table' then return false end
  if t.op then return false end  -- op 驱动 = 标量
  if t.cols then return true end
  if t.rows ~= nil or t.format ~= nil then return true end
  return false
end

return function(arg)
  if type(arg) == 'string' then
    local ok, t = pcall(json_decode, arg)
    if ok and type(t) == 'table' and is_spec(t) then
      -- 表函数 spec（cols/rows/format 特征键）
      local res = build_rows(t)
      if res.error then return { 'ERR: ' .. res.error } end
      return res.rows
    end
    -- 标量：struct JSON（含 op）/ 裸模板串 / 非 JSON 串
    return run(arg)
  end
  if type(arg) == 'table' and is_spec(arg) then
    -- struct 形式的 spec（DuckDB struct 字面量直接传）
    local res = build_rows(arg)
    if res.error then return { 'ERR: ' .. res.error } end
    return res.rows
  end
  return run(arg)  -- struct 入参（标量 op）
end
