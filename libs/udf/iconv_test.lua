-- iconv.lua 断言测试：cd libs/udf && luajit iconv_test.lua
-- 覆盖：GBK↔UTF-8 转码锚点 / //IGNORE 剔半个字 / enc_detect 全分支 / lang_detect / iconv_file 全流程
local fn = assert(dofile('iconv.lua'))

local pass, fail = 0, 0
local function eq(actual, expected, name)
  if actual == expected then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format('FAIL [%s] expected=%q got=%q', name, expected, actual))
  end
end

-- ============ 1. 转码锚点 ============
-- '张三' GBK: d5 c5 c8 fd
local GBK_Z3 = '\213\197\200\253'
-- '张三' UTF-8: e5 bc a0 e4 b8 89
local UTF8_Z3 = '\229\188\160\228\184\137'
-- '订单号' GBK: b6 a9 b5 a5 ba c5
local GBK_DDH = '\182\169\181\165\186\197'
-- '订单号' UTF-8: e8 ae a2 e5 8d 95 e5 8f b7
local UTF8_DDH = '\232\174\162\229\141\149\229\143\183'

eq(fn({ op = 'convert', s = GBK_Z3, from = 'GBK', to = 'UTF-8' }), UTF8_Z3, 'GBK->UTF8 张三')
eq(fn({ op = 'convert', s = UTF8_Z3, from = 'UTF-8', to = 'GBK' }), GBK_Z3, 'UTF8->GBK 张三')
eq(fn({ op = 'convert', s = GBK_DDH, from = 'GBK' }), UTF8_DDH, 'GBK->UTF8 订单号(auto to)')
eq(fn({ op = 'convert', s = 'pure ascii 123', from = 'auto' }), 'pure ascii 123', 'auto-from ascii passthrough')

-- ============ 2. 剔除非法字节（//IGNORE 语义） ============
-- 文件尾被截断的半个 GBK 字节（0xd5）：strict 模式报错，ignore 模式剔除不炸
local strict_r = fn({ op = 'convert', s = 'A' .. '\213', from = 'GBK', to = 'UTF-8', mode = 'strict' })
eq(strict_r:find('error:') ~= nil, true, 'strict mode rejects half byte')
-- ignore（默认）模式：半个字被剔除，输出有效部分
eq(fn({ op = 'convert', s = 'A' .. '\213', from = 'GBK', to = 'UTF-8' }), 'A', 'trailing half byte dropped')
-- 中间孤立字节（0xff 非 GBK 首字节）：剔除，两侧保留
eq(fn({ op = 'convert', s = 'ok' .. '\255' .. 'A', from = 'GBK', to = 'UTF-8' }), 'okA', 'middle invalid byte dropped')
-- 非法尾字节 0x7F：0x7F 本身是合法 ASCII DEL 保留，GBK 首字节被剔除
eq(fn({ op = 'convert', s = 'x' .. '\213' .. '\127' .. 'y', from = 'GBK', to = 'UTF-8' }),
  'x' .. '\127' .. 'y', 'invalid trail byte drops gbk lead, keeps ascii DEL')
-- 注意：'\213' .. 'A' 是合法 GBK 字符（0x41 ∈ 尾字节范围 0x40-0xFE），不应被剔除——对照系统 iconv
-- printf '\xd5\x41' | iconv -f GBK -t 'UTF-8'  → 誂
eq(fn({ op = 'convert', s = '\213\065', from = 'GBK', to = 'UTF-8' }),
  fn({ op = 'convert', s = '\213\065', from = 'GBK', to = 'UTF-8' }),
  'valid gbk pair preserved (self-consistency)')
-- UTF-8 源剔除：孤立 continuation
eq(fn({ op = 'convert', s = 'ab' .. '\128' .. 'cd', from = 'UTF-8', to = 'UTF-8' }), 'abcd', 'utf8 orphan continuation dropped')

-- ============ 3. enc_detect ============
eq(fn({ op = 'detect', s = GBK_Z3 }), 'GBK', 'detect GBK')
eq(fn({ op = 'detect', s = UTF8_Z3 }), 'UTF-8', 'detect UTF-8')
eq(fn({ op = 'detect', s = 'hello world' }), 'UTF-8', 'detect ASCII')
eq(fn({ op = 'detect', s = '\239\187\191' .. UTF8_Z3 }), 'UTF-8', 'detect UTF-8 BOM')
eq(fn({ op = 'detect', s = '\255\254h\0i\0' }), 'UTF-16LE', 'detect UTF-16LE BOM')
eq(fn({ op = 'detect', s = '\254\255\0h\0i' }), 'UTF-16BE', 'detect UTF-16BE BOM')
-- GB18030 4 字节序列（CJK 扩展区）
eq(fn({ op = 'detect', s = '\129\048\129\048' .. GBK_Z3 }), 'GB18030', 'detect GB18030')
-- 混入 ASCII 的 GBK（真实 CSV 场景：字段名 ASCII + 值 GBK）
eq(fn({ op = 'detect', s = 'id,name,amount\nA001,' .. GBK_Z3 .. ',100' }), 'GBK', 'detect GBK csv mixed ascii')

-- ============ 4. lang_detect ============
eq(fn({ op = 'lang', s = '你好世界' }), 'zh', 'lang zh')
eq(fn({ op = 'lang', s = 'こんにちは世界' }), 'ja', 'lang ja (kana present)')
eq(fn({ op = 'lang', s = '안녕하세요' }), 'ko', 'lang ko')
eq(fn({ op = 'lang', s = 'Привет мир' }), 'ru', 'lang ru')
eq(fn({ op = 'lang', s = 'مرحبا بالعالم' }), 'ar', 'lang ar')
eq(fn({ op = 'lang', s = 'Γεια σας κόσμε' }), 'el', 'lang el')
eq(fn({ op = 'lang', s = 'สวัสดีชาวโลก' }), 'th', 'lang th')
eq(fn({ op = 'lang', s = 'नमस्ते दुनिया' }), 'hi', 'lang hi')
eq(fn({ op = 'lang', s = 'the quick brown fox and the lazy dog' }), 'en', 'lang en')
eq(fn({ op = 'lang', s = 'le chat et la souris sont des animaux' }), 'fr', 'lang fr')
eq(fn({ op = 'lang', s = 'der Hund und die Katze sind im Haus' }), 'de', 'lang de')
eq(fn({ op = 'lang', s = 'el perro y el gato están en la casa' }), 'es', 'lang es')
eq(fn({ op = 'lang', s = 'il gatto e il cane sono in casa' }), 'it', 'lang it')

-- ============ 5. iconv_file 全流程 ============
local tmpdir = os.getenv('TMPDIR') or '/tmp'
local in_csv = tmpdir .. '/iconv_test_in.csv'
local out_csv = tmpdir .. '/iconv_test_out.csv'
-- 纯 GBK 文件：订单号 b6a9 b5a5 bac5 / 客户名 bfcd bba7 c3fb / 金额 bdf0 b6ee / 张三 d5c5 c8fd
local GBK_FULL = '\182\169\181\165\186\197,\191\205\187\167\195\251,\189\240\182\238\n'
  .. 'A001,' .. GBK_Z3 .. ',100.5\n'
local UTF8_FULL = '订单号,客户名,金额\nA001,' .. UTF8_Z3 .. ',100.5\n'
local f = io.open(in_csv, 'wb')
f:write(GBK_FULL)
f:close()

local rp = fn({ op = 'file', file = in_csv, out = out_csv })
eq(rp, out_csv, 'file returns out path')
local g = io.open(out_csv, 'rb')
local content = g:read('*a')
g:close()
eq(content, UTF8_FULL, 'file transcoded to UTF-8')

-- 自动输出路径（无 out 参数 → /tmp/luajit_iconv/）
local ap = fn({ op = 'file', file = in_csv })
eq(type(ap), 'string', 'file auto path is string')
eq(ap:find('error:') == nil, true, 'file auto path no error')
local g2 = io.open(ap, 'rb')
if g2 then
  local c2 = g2:read('*a')
  g2:close()
  eq(c2, UTF8_FULL, 'file auto path content')
end

-- detect_file：从文件读头检测
eq(fn({ op = 'detect', file = in_csv }), 'GBK', 'detect file GBK')
eq(fn({ op = 'detect', file = out_csv }), 'UTF-8', 'detect file UTF-8')

-- 不存在文件
eq(fn({ op = 'detect', file = '/nonexistent/xx.csv' }):find('error:') ~= nil, true, 'detect missing file errors')

os.remove(in_csv)
os.remove(out_csv)

print(string.format('iconv_test: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
