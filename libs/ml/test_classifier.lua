-- test_classifier.lua — Lua 级单测（luajit CLI 直跑，必须 cd 到 libs/ml/）
-- @license: MIT (duckdb-luajit-libs project)
-- @maturity: poc
-- 覆盖：train(含 auto cal split) / predict / evaluate / 模型持久化往返 /
--       错误分支。断言失败即非零退出。

local run = dofile('classifier.lua')

-- ---------- 构造中文工单数据：5 类 × 16 条（train 12 + cal 4 每类） ----------
local templates = {
    billing = {
        '我的账户被扣了两次款，请退款', '这个月账单多扣了钱', '重复扣费了，要求退回多收的费用',
        '发票金额和实际扣款不一致', '充值没有到账但是钱已经扣了', '为什么又扣了我的会员费',
        '退款申请提交一周了还没到账', '扣款短信收到了但订单显示未支付',
        '帮我查一下上次的双倍扣费', '月费扣多了，差额怎么退', '支付成功但余额没变',
        '退订了还继续扣费，这是第三次了', '银行卡被莫名扣款 99 元', '优惠券没有抵扣直接全款扣了',
        '自动续费没有提醒就扣钱了', '发票开错了金额需要重开',
    },
    shipping = {
        '包裹一周了还没送达', '物流信息三天没有更新了', '快递显示已签收但我没收到货',
        '发货地址填错了怎么改', '订单一直显示待发货', '快递员联系不上，包裹在哪',
        '想查询我的快递现在到哪里了', '运费怎么比上次贵了一倍', '两个包裹只收到了一个',
        '配送时间能不能改到周末', '包裹外包装破损严重', '物流单号查不到任何信息',
        '要求改派送到代收点', '发货太慢了，什么时候能发出', '商品寄丢了需要赔偿',
        '快递放门口被偷了怎么办',
    },
    technical = {
        'APP 打开就闪退，安卓 14', '登录一直转圈进不去', '验证码收不到，手机号没错',
        '页面白屏加载不出来', '搜索功能用不了，点了没反应', '上传图片一直失败',
        'App 耗电特别快，后台发热', '消息通知收不到', '二维码扫描没反应',
        '密码重置邮件收不到', '小程序里打不开链接', '版本更新后数据全丢了',
        '收藏夹内容不显示', '夜间模式切换无效', '语音输入没有声音', '绑定手机号时报系统错误',
    },
    account = {
        '怎么注销我的账户', '忘记密码了怎么找回', '手机号换人了要更换绑定',
        '注册时收不到验证码', '账号被锁定了怎么解除', '实名认证信息填错了',
        '怎么修改昵称和头像', '注销后数据会保留多久', '账号被盗了急需冻结',
        '邮箱换了怎么更新账户信息', '想解绑微信换绑手机', '账户被异常登录提醒',
        '双重验证的备用码丢了', '注销账户余额怎么提出来', '生日性别信息改不了',
        '一个手机号能注册几个账号',
    },
    product = {
        '这款有没有更大尺码的', '商品详情页图片看不清', '这个型号和上一代有什么区别',
        '什么时候会补货', '想要的功能你们计划上线吗', '套餐内容和价格明细在哪看',
        '和另一款对比哪个更适合我', '产品支持防水吗', '能用多少年，寿命多久',
        '有没有官方配件卖', '颜色选项里没有我要的', '质保期是多久，怎么算',
        '下次促销是什么时候', '支持以旧换新吗', '说明书能发电子版吗', '这个材质安不安全',
    },
}

local texts, labels = {}, {}
local cal_texts, cal_labels = {}, {}
local n = 0
for label, arr in pairs(templates) do
    for i, t in ipairs(arr) do
        n = n + 1
        if i <= 12 then
            texts[#texts + 1] = t; labels[#labels + 1] = label
        else
            cal_texts[#cal_texts + 1] = t; cal_labels[#cal_labels + 1] = label
        end
    end
end
assert(#texts == 60, 'train set should be 60, got ' .. #texts)
assert(#cal_texts == 20, 'cal set should be 20, got ' .. #cal_texts)

-- ---------- T1: train with explicit cal set ----------
local r1 = run({ op = 'train', texts = texts, labels = labels,
                 texts_cal = cal_texts, labels_cal = cal_labels, out = '/tmp/cl_model.json' })
assert(r1:find('"status":"ok"', 1, true) or r1:find('"status": "ok"'), 'T1 train failed: ' .. tostring(r1))
assert(r1:find('"n_classes":5'), 'T1 expected 5 classes: ' .. r1)
assert(r1:find('"n_cal":20'), 'T1 expected n_cal=20')
assert(r1:find('"n_train":60'), 'T1 expected n_train=60')
assert(r1:find('"temperature"'), 'T1 report missing temperature')
print('T1 train ok')

-- ---------- T2: model persists & round-trips through a file ----------
local f = io.open('/tmp/cl_model.json', 'r')
assert(f, 'T2 model file not written')
local esc = f:read('*a'); f:close()
assert(#esc > 1000, 'T2 model file suspiciously small: ' .. #esc)
assert(esc:find('"labels"'), 'T2 model file content invalid')
print('T2 model written: ' .. #esc .. ' bytes')

local r2 = run({ op = 'predict', model_path = '/tmp/cl_model.json',
                 texts = { '又被扣了两回钱，要求退款', '快递五天没动了', 'APP 一打开就闪退',
                           '我想注销账号', '这个有黑色款吗' } })
assert(r2:find('"status":"ok"'), 'T2 predict failed: ' .. r2)
assert(r2:find('billing'), 'T2 expected billing in predictions')
assert(r2:find('shipping'), 'T2 expected shipping')
assert(r2:find('technical'), 'T2 expected technical')
assert(r2:find('account'), 'T2 expected account')
assert(r2:find('product'), 'T2 expected product')
print('T2 predict ok')

-- ---------- T3: evaluate on the cal set ----------
local r3 = run({ op = 'evaluate', model_path = '/tmp/cl_model.json',
                 texts = cal_texts, labels = cal_labels })
assert(r3:find('"status":"ok"'), 'T3 evaluate failed: ' .. r3)
print('T3 evaluate ok: ' .. r3:sub(1, 200))

-- ---------- T4: English data sanity ----------
local en_t = {}
local en_l = {}
for i = 1, 15 do
    en_t[#en_t + 1] = 'I was charged twice for my order number ' .. i
    en_l[#en_l + 1] = 'billing'
    en_t[#en_t + 1] = 'my package has not arrived and tracking is stuck for ' .. i .. ' days'
    en_l[#en_l + 1] = 'shipping'
    en_t[#en_t + 1] = 'the app crashes on login every time ' .. i
    en_l[#en_l + 1] = 'technical'
end
local r4 = run({ op = 'train', texts = en_t, labels = en_l, out = '/tmp/cl_model_en.json' })
assert(r4:find('"status":"ok"'), 'T4 en train failed: ' .. r4)
local r4p = run({ op = 'predict', model_path = '/tmp/cl_model_en.json',
                  texts = { 'charged twice', 'package never arrived', 'app crashes' } })
assert(r4p:find('"label":"billing"'), 'T4 expected billing: ' .. r4p)
assert(r4p:find('"label":"shipping"'), 'T4 expected shipping')
assert(r4p:find('"label":"technical"'), 'T4 expected technical')
print('T4 english ok')

-- ---------- T5: error branches ----------
local e1 = run({ op = 'nope' })
assert(e1:find('unknown op'), 'T5.1 expected unknown op error')
local e2 = run({ op = 'predict', texts = { 'x' } })
assert(e2:find('missing model'), 'T5.2 expected missing model error')
local e3 = run({ op = 'train', texts = { 'a' }, labels = { 'x' } })
assert(e3:find('Error'), 'T5.3 expected error for single label: ' .. e3)
local e4 = run({ op = 'predict', model_path = '/nonexistent/model.json', texts = { 'x' } })
assert(e4:find('cannot open'), 'T5.4 expected cannot open: ' .. e4)
print('T5 error branches ok')

-- ---------- T6: train with out= writes model file ----------
local r6 = run({ op = 'train', texts = texts, labels = labels, out = '/tmp/cl_model2.json' })
assert(r6:find('"status":"ok"'), 'T6 train-out failed: ' .. r6)
assert(r6:find('"model_path":"/tmp/cl_model2.json"'), 'T6 model_path missing')
local f6 = io.open('/tmp/cl_model2.json')
assert(f6, 'T6 model file not written')
local c6 = f6:read('*a'); f6:close()
assert(c6:find('"labels"'), 'T6 model file content invalid')
local r6p = run({ op = 'predict', model_path = '/tmp/cl_model2.json', texts = { '我的账户被扣了两次款，要求退款' } })
assert(r6p:find('"label":"billing"'), 'T6 predict from out= model failed: ' .. r6p)
print('T6 out= ok')

print('ALL LUA TESTS PASSED')
