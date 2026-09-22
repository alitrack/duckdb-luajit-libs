-- jev_ask.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_jev_ask.sql
--
-- ⚠️ 前置（本套件**非自包含**，这是唯一一个依赖外部服务的 udf 测试）：
--   1. 一个 jev 型决策服务在跑，默认 http://127.0.0.1:18090（本机实例 /mnt/d/wsl2/jev-clone）：
--        cd /mnt/d/wsl2/jev-clone
--        JEV_BASE_URL=<能吐 logprobs 的 OpenAI 兼容端点>/v1 JEV_MODEL=<模型> \
--        JEV_SLOT_CHECK=letters JEV_LISTEN=127.0.0.1:18090 setsid ./target/debug/jev-server
--      （后端必须支持 logprobs —— 硬拒 logprobs 的端点如 NInfer 不能当读出口径后端）
--   2. 首次调用会做槽位自检（letters），失败则拒绝启动（fail-fast）。
--   服务没起时本套件**会报错**——这是设计（失败必须显形），不是测试坏了。
--
-- 正确性证据（2026-09-21 实测，Mac llama.cpp Qwen3.5-4B-Q8_0 后端）：
--   * 8 条中文工单 × 3 问，`output_tokens` 恒为 3（三个问题各读一个 token ⇒ 不是「生成得短」，是不生成）
--   * 概率守恒 Σp = 1（±1e-6，见用例 5）
--   * choice 的 `choice` 字段 = 该题概率最大项（用例 2 断言）
--   * 阈值 0.80 门控：8 条里 4 条自动、4 条转人工（覆盖率 50%）
--   留档：~/research/duckdb-jev-20260921/demo-output.txt
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
.read /mnt/d/wsl2/duckdb-luajit-libs/libs/udf/jev_ask_macros.sql

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jev_ask',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/jev_ask.lua'')');

-- 0. 探活：批量跑之前先探一次（返回 {"service":"jev-clone","status":"ok"}）
SELECT luajit_s('jev_ask', {'op':'health'}) AS health;

-- 1. 一 state × 三问（choice / noul / score）＝ 一次调用拿全部答案
SET VARIABLE q = '{"team":{"type":"choice","instructions":"哪个团队该处理？","criteria":{"billing":"账单、发票、退款、价格","technical":"故障、报错、接口、崩溃","logistics":"发货、物流、到货时间"}},"urgent":{"type":"noul","instructions":"客户表达了紧迫性（催办、时限、威胁投诉）？"},"anger":{"type":"score","instructions":"客户情绪强度？","criteria":["平静","不满","非常愤怒"]}}';
CREATE OR REPLACE TABLE one AS
SELECT luajit_s('jev_ask', {'state': '发票金额和合同不一致，我已经催了三次了，再不解决就投诉到消协',
                            'questions': getvariable('q')}) AS raw;
-- 期望（2026-09-21 实测）：team=billing，p_billing≈0.968，conf≈0.856，urgent≈0.712，anger≈1.173
SELECT jev_choice(raw,'team') AS team,
       round(jev_p(raw,'team','billing'),   3) AS p_billing,
       round(jev_p(raw,'team','technical'), 3) AS p_technical,
       round(jev_conf(raw,'team'),          3) AS conf,
       round(jev_noul(raw,'urgent'),        3) AS p_urgent,
       round(jev_score(raw,'anger'),        3) AS anger,
       json_extract(raw,'$.usage.output_tokens') AS output_tokens
FROM one;

-- 2. choice 的答案必须是该题概率最大项（argmax 一致性）
SELECT jev_choice(raw,'team') = (
         SELECT p.key FROM json_each(json_extract(raw,'$.answers.team.probabilities')) AS p
         ORDER BY CAST(p.value AS DOUBLE) DESC LIMIT 1) AS choice_is_argmax
FROM one;

-- 3. 长表展开（一条决策一行 = 台账形态）
SELECT * FROM jev_long((SELECT raw FROM one));

-- 4. 概率覆盖全部声明选项（三选项题必须三行、且键集合等于 criteria 键集合）
SELECT (SELECT count(*) FROM json_each(json_extract(raw,'$.answers.team.probabilities'))) AS n_slots
FROM one;   -- 期望 3

-- 5. 概率守恒：Σp = 1（±1e-6）。服务端做归一化，SQL 侧只做复核，不重算。
SELECT round(jev_prob_sum(raw,'team'), 9) AS sum_team,
       abs(jev_prob_sum(raw,'team') - 1.0) <= 1e-6 AS conserved
FROM one;

-- 6. 负数路径 A：空 state / 空 questions / 未知 op / 服务不可达
--    ⇒ 一律返回 **`error: <msg>` 字符串**（不是 NULL、也不是抛错）。
--    ⚠️ 这是实测后改的设计：duckdb-luajit 扩展会把 Lua `error()` **吞成 NULL**，消息只落进
--       luajit_module(mode:='last_error')，而 NULL 与「本来没数据」不可区分 ⇒ 靠 error() 显形是假的。
SELECT luajit_s('jev_ask', {'op':'ask', 'state':'', 'questions': getvariable('q')})       AS empty_state,
       luajit_s('jev_ask', {'op':'ask', 'state':'x', 'questions': ''})                    AS empty_questions,
       luajit_s('jev_ask', {'op':'nope', 'state':'x'})                                    AS unknown_op;
-- 期望：三条都是 'error: ...' 开头，且 jev_ok = false
SELECT jev_ok(luajit_s('jev_ask', {'op':'ask', 'state':'', 'questions': getvariable('q')})) AS empty_state_ok;
SELECT jev_error(luajit_s('jev_ask', {'op':'ask', 'state':'', 'questions': getvariable('q')})) AS empty_state_msg;

-- 7. 负数路径 B：服务不可达 ⇒ 错误串里带端点与 HTTP 码（不是静默 NULL）
SELECT jev_error(luajit_s('jev_ask', {'op':'ask', 'state':'x', 'questions': getvariable('q'),
                                      'endpoint':'http://127.0.0.1:1'})) AS unreachable_msg;

-- 7b. 扩展的错误通道（供排查用）：如果哪天真抛了错，消息在这里
SELECT message FROM luajit_module(mode := 'last_error');

-- 8. 真实批量：8 条中文工单 + 失败计数 + 阈值门控
.bail on
CREATE OR REPLACE TABLE tickets AS SELECT * FROM (VALUES
  (1,'发票金额和合同不一致，我已经催了三次了，再不解决就投诉到消协'),
  (2,'系统登录一直提示 500，我们的运营全卡住了，麻烦尽快看下'),
  (3,'货还没到，物流信息三天没更新，客户那边要退货了'),
  (4,'这个价格比去年涨了 30%，能重新给个报价吗'),
  (5,'导出 Excel 的时候中文全变问号了，是不是编码问题'),
  (6,'你们这个破系统到底行不行？每次都要重启'),
  (7,'想申请发票，请问在哪填税号'),
  (8,'接口调用一直返回 429，我们的批处理任务全失败了')
) AS t(id, body);
CREATE OR REPLACE TABLE decisions AS
SELECT id, body, luajit_s('jev_ask', {'state': body, 'questions': getvariable('q')}) AS raw FROM tickets;

-- 8a. 失败行数必须先看（部分失败容忍口径）：期望 0
SELECT count(*) AS n, count(*) FILTER (WHERE NOT jev_ok(raw)) AS n_failed FROM decisions;

-- 8b. 阈值门控：覆盖率是硬指标，必须与覆盖内正确率一起报（本页无 gold，只演示机制）
SELECT count(*) FILTER (WHERE jev_conf(raw,'team') >= 0.80) AS auto_routed,
       round(100.0 * count(*) FILTER (WHERE jev_conf(raw,'team') >= 0.80) / count(*), 1) AS coverage_pct
FROM decisions;
-- 期望（2026-09-21 实测）：n=8，n_failed=0，auto_routed=4，coverage_pct=50.0

-- 8c. 概率守恒复核（服务端归一化、SQL 侧只核，不重算）：期望全部 conserved = true
SELECT count(*) FILTER (WHERE abs(jev_prob_sum(raw,'team') - 1.0) > 1e-6) AS n_violating FROM decisions;

-- 9. per-row 一行分类门面（jev_questions 表宏 + jev 纯标量宏，MotherDuck prompt_jev 本地等价）
--    断言：4 条各归入其主题（确定性语料，期望全对）、0 失败、4 个 conf 在 (0,1]
CREATE OR REPLACE TABLE facade_t AS SELECT * FROM (VALUES
  (1, 'Wall St. Bears Claw Back Into the Black, short-sellers seeing green again'),
  (2, 'The Reds win the cup final after extra time in a thrilling finish'),
  (3, 'NASA launches new probe to study the outer solar system'),
  (4, 'World leaders meet to discuss climate accord and international trade')
) AS t(id, body);
SET VARIABLE fq = (SELECT questions FROM jev_questions(
  'Classify the topic of this news article.', ['World','Sports','Business','Sci/Tech']));
CREATE OR REPLACE TABLE facade_r AS
SELECT id, jev_choice(r,'q') AS topic, jev_conf(r,'q') AS conf, jev_ok(r) AS ok
FROM (SELECT id, jev(body, getvariable('fq')) AS r FROM facade_t);
SELECT count(*) AS n,
       count(*) FILTER (WHERE NOT ok) AS n_failed,
       count(*) FILTER (WHERE conf IS NULL OR conf <= 0 OR conf > 1) AS n_bad_conf,
       count(*) FILTER (WHERE (id=1 AND topic='Business') OR (id=2 AND topic='Sports')
                          OR (id=3 AND topic='Sci/Tech') OR (id=4 AND topic='World')) AS n_correct
FROM facade_r;
-- 期望（2026-09-22 实测）：n=4 n_failed=0 n_bad_conf=0 n_correct=4

