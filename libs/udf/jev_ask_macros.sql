-- jev_ask 配套宏（SQL 侧展开层）——本文件是**配方文档，不进 INDEX**
-- （INDEX 只收能编译成 Lua chunk 的 .lua；本文件是 SQL）
--
-- 为什么展开放在 SQL 而不放进 Lua：
--   * `raw` 是本项目自己服务端返回的 JSON（契约已知、形状稳定），展开 = 按契约取字段，
--     一句 `json_extract` 的事，且**不重算、不归一化、不补缺**（重算 = 静默错位的根源）；
--   * 与既有分工一致：llm_extract 的注释原文就是「JSON 展开永远交给 DuckDB 原生 json_extract」；
--   * 宏是 catalog 对象，装一次随库存在，比每次在 SQL 里手写一长串 json_extract 可读得多。
--
-- 用法：
--   .read libs/udf/jev_ask_macros.sql
--   -- 宽表（一题一列）
--   SELECT id, jev_choice(raw,'team') AS team, jev_p(raw,'team','billing') AS p_billing,
--          jev_pmax(raw,'team') AS pmax, jev_conf(raw,'team') AS conf
--   FROM decisions;
--   -- 长表（一条决策一行，直接就是台账形态）
--   SELECT d.id, l.* FROM decisions d, jev_long(d.raw) l;

-- ── 宽表：按 (问题 id, 选项标签) 取数 ────────────────────────────────────
CREATE OR REPLACE MACRO jev_choice(raw, qid) AS
  json_extract_string(raw, '$.answers.' || qid || '.choice');

CREATE OR REPLACE MACRO jev_p(raw, qid, label) AS
  CAST(json_extract(raw, '$.answers.' || qid || '.probabilities.' || label) AS DOUBLE);

CREATE OR REPLACE MACRO jev_conf(raw, qid) AS
  CAST(json_extract(raw, '$.answers.' || qid || '.confidence') AS DOUBLE);

CREATE OR REPLACE MACRO jev_score(raw, qid) AS
  CAST(json_extract(raw, '$.answers.' || qid || '.score') AS DOUBLE);

CREATE OR REPLACE MACRO jev_noul(raw, qid) AS
  CAST(json_extract(raw, '$.answers.' || qid || '.noul') AS DOUBLE);

-- ⚠️ `pmax`（选项集上的最大概率）**不是**服务端的 confidence：前者是从分布算的读数，
--    后者是服务端按自己的公式导出的量。门控该用哪个必须各自量曲线，别混。取 max 需要
--    遍历选项键，故做成表宏（见下），宽表里用 greatest(jev_p(...), jev_p(...)) 手写。

-- ── 长表：一条决策一行（台账/审计形态）────────────────────────────────────
CREATE OR REPLACE MACRO jev_long(raw) AS TABLE
SELECT
  j.key                                                        AS question_id,
  json_extract_string(j.value, '$.type')                       AS qtype,
  CASE json_extract_string(j.value, '$.type')
    WHEN 'choice' THEN json_extract_string(j.value, '$.choice')
    WHEN 'score'  THEN CAST(json_extract(j.value, '$.score') AS VARCHAR)
    WHEN 'noul'   THEN CAST(json_extract(j.value, '$.noul') AS VARCHAR)
    ELSE NULL
  END                                                          AS answer,
  (SELECT max(CAST(p.value AS DOUBLE))
     FROM json_each(json_extract(j.value, '$.probabilities')) AS p) AS p_max,
  CAST(json_extract(j.value, '$.confidence') AS DOUBLE)        AS confidence,
  json_extract(j.value, '$.probabilities')                     AS probabilities
FROM json_each(json_extract(raw, '$.answers')) AS j;

-- ── 审计辅助 ─────────────────────────────────────────────────────────────
-- ⭐ 失败显形：失败时 lib 返回 `error: <msg>` 字符串（不是 NULL，也不是抛错——
--    扩展会把 Lua error() 吞成 NULL，NULL 与「本来没数据」不可区分）。任何批量管道
--    都应先断言：SELECT count(*) FILTER (WHERE NOT jev_ok(raw)) AS n_failed FROM ...;
CREATE OR REPLACE MACRO jev_ok(raw) AS
  (raw IS NOT NULL AND raw NOT LIKE 'error:%');

CREATE OR REPLACE MACRO jev_error(raw) AS
  CASE WHEN raw LIKE 'error:%' THEN substr(raw, 8) ELSE NULL END;

-- 概率守恒断言（服务端口径是 Σp=1±1e-6；这里给出可复核的 SQL）
CREATE OR REPLACE MACRO jev_prob_sum(raw, qid) AS (
  SELECT sum(CAST(p.value AS DOUBLE))
  FROM json_each(json_extract(raw, '$.answers.' || qid || '.probabilities')) AS p
);

-- ── per-row 一行分类（MotherDuck prompt_jev 风格的本地等价形态）─────────────
-- 为什么要拆两层（DuckDB 硬约束：scalar macro 的 body 里不能出现 table 子查询——
-- `struct_pack(...) FROM (...)` 会被当表展开、绑定错位）：
--   * jev_questions(instructions, choice) 是**表宏**——UNNEST + json_group_object
--     那个必须聚合的脏活只能放表宏里；
--   * jev(text, questions) 是**纯标量宏**——body 就是一句 luajit_s(...) 直接展开，
--     因此可以在 SELECT 列表里对每行调用（per-row 串行，服务端一次前向/行）。
-- 用法：questions 是常量，先组装一次存进变量，再扫表：
--   SET VARIABLE q = (SELECT questions FROM jev_questions(
--     'Classify the topic of this news article.', ['World','Sports','Business','Sci/Tech']));
--   SELECT id, jev_choice(r,'q') AS topic, round(jev_conf(r,'q'),3) AS conf
--   FROM (SELECT id, jev(body, getvariable('q')) AS r FROM t) ORDER BY id;
-- 多题：当前 jev_questions 固定单题（key='q'）；多题需手写 questions JSON
--       多 key 后直接喂 jev(text, questions_json)——jev 只负责透传，题目数不限。
CREATE OR REPLACE MACRO jev_questions(instructions, choice) AS TABLE
SELECT
  '{"q":{"type":"choice","instructions":' || to_json(instructions)
  || ',"criteria":' || (SELECT to_json(json_group_object(s, s))
                        FROM (SELECT UNNEST(choice) AS s)) || '}}' AS questions;

CREATE OR REPLACE MACRO jev(text, questions) AS
  luajit_s('jev_ask', {state: text, questions: questions});
