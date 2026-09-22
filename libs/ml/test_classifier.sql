-- test_classifier.sql — DuckDB E2E（duckdb -unsigned < test_classifier.sql）
-- 覆盖：install 缓存加载 / train from SQL / predict / evaluate / 断言全 0

LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

-- 训练数据表（中文工单 5 类 × 12）
CREATE OR REPLACE TABLE tickets AS
SELECT * FROM (VALUES
  ('我的账户被扣了两次款，请退款','billing'),
  ('这个月账单多扣了钱','billing'),
  ('重复扣费了，要求退回多收的费用','billing'),
  ('退款申请提交一周了还没到账','billing'),
  ('充值没有到账但是钱已经扣了','billing'),
  ('为什么又扣了我的会员费','billing'),
  ('月费扣多了，差额怎么退','billing'),
  ('支付成功但余额没变','billing'),
  ('退订了还继续扣费','billing'),
  ('优惠券没有抵扣直接全款扣了','billing'),
  ('自动续费没有提醒就扣钱了','billing'),
  ('发票开错了金额需要重开','billing'),
  ('包裹一周了还没送达','shipping'),
  ('物流信息三天没有更新了','shipping'),
  ('快递显示已签收但我没收到货','shipping'),
  ('发货地址填错了怎么改','shipping'),
  ('订单一直显示待发货','shipping'),
  ('两个包裹只收到了一个','shipping'),
  ('商品寄丢了需要赔偿','shipping'),
  ('配送时间能不能改到周末','shipping'),
  ('包裹外包装破损严重','shipping'),
  ('快递放门口被偷了怎么办','shipping'),
  ('运费怎么比上次贵了一倍','shipping'),
  ('要求改派送到代收点','shipping'),
  ('APP 打开就闪退，安卓 14','technical'),
  ('登录一直转圈进不去','technical'),
  ('验证码收不到，手机号没错','technical'),
  ('页面白屏加载不出来','technical'),
  ('搜索功能用不了，点了没反应','technical'),
  ('上传图片一直失败','technical'),
  ('消息通知收不到','technical'),
  ('二维码扫描没反应','technical'),
  ('密码重置邮件收不到','technical'),
  ('版本更新后数据全丢了','technical'),
  ('收藏夹内容不显示','technical'),
  ('夜间模式切换无效','technical'),
  ('怎么注销我的账户','account'),
  ('忘记密码了怎么找回','account'),
  ('手机号换人了要更换绑定','account'),
  ('注册时收不到验证码','account'),
  ('账号被锁定了怎么解除','account'),
  ('实名认证信息填错了','account'),
  ('账号被盗了急需冻结','account'),
  ('邮箱换了怎么更新账户信息','account'),
  ('一个手机号能注册几个账号','account'),
  ('怎么修改昵称和头像','account'),
  ('双重验证的备用码丢了','account'),
  ('账户被异常登录提醒','account'),
  ('这款有没有更大尺码的','product'),
  ('商品详情页图片看不清','product'),
  ('这个型号和上一代有什么区别','product'),
  ('什么时候会补货','product'),
  ('套餐内容和价格明细在哪看','product'),
  ('产品支持防水吗','product'),
  ('质保期是多久，怎么算','product'),
  ('下次促销是什么时候','product'),
  ('支持以旧换新吗','product'),
  ('说明书能发电子版吗','product'),
  ('这个材质安不安全','product'),
  ('颜色选项里没有我要的','product')
) AS t(text, label);

-- 1) install（从本地缓存）
SELECT * FROM luajit_module(mode := 'install', sql_name := 'classifier');

-- 2) train from SQL table
SELECT luajit_s('classifier', {op:'train', sql:'SELECT text, label FROM tickets', out:'/tmp/e2e_model.json'}) AS train_result;

-- 3) predict 断言：三条强信号文本必须分类正确
CREATE OR REPLACE TABLE preds AS
SELECT unnest(['我被扣了两次款要求退款','快递三天没更新了','APP 闪退打不开']) AS text,
       unnest(['billing','shipping','technical']) AS expected;
CREATE OR REPLACE TABLE pred_out AS
SELECT p.text, p.expected,
       json_extract_string(luajit_s('classifier', {op:'predict', model_path:'/tmp/e2e_model.json', texts:[p.text]}), '$.predictions[0].label') AS got
FROM preds p;
SELECT count(*) AS predict_mismatch_must_be_0 FROM pred_out WHERE got != expected;

-- 4) evaluate on held-out cal-style texts
CREATE OR REPLACE TABLE tickets_eval AS
SELECT * FROM (VALUES
  ('银行卡被莫名扣款 99 元','billing'),
  ('退款什么时候能到账','billing'),
  ('想查询我的快递现在到哪里了','shipping'),
  ('发货太慢了，什么时候能发出','shipping'),
  ('App 耗电特别快，后台发热','technical'),
  ('语音输入没有声音','technical'),
  ('注销后数据会保留多久','account'),
  ('生日性别信息改不了','account'),
  ('有没有官方配件卖','product'),
  ('能用多少年，寿命多久','product')
) AS t(text, label);
SELECT luajit_s('classifier', {op:'evaluate', model_path:'/tmp/e2e_model.json', sql:'SELECT text, label FROM tickets_eval'}) AS eval_result;
