-- privacy.lua 端到端回归（duckdb-luajit）——mask_cn（CN 合规脱敏）+ dateshift（临床日期平移）
-- 运行：cp libs/privacy/privacy.lua ~/.duckdb/luajit-libs/ && duckdb -unsigned < test_privacy.sql
-- 断言查询全部"应为 0"（除显式标注的对照/展示查询），任一行非 0 即回归失败。

LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'install', sql_name := 'privacy');

-- ============================================================
-- 一、mask_cn：CN 合规脱敏（格式保持 + 不泄漏 + 外键可连接）
-- ============================================================
CREATE OR REPLACE TABLE pii AS SELECT * FROM (VALUES
  (1, '110101199003071234', '13800138000', '6222021234567890',  '张三',   'zhangsan@example.com'),
  (2, '310101198512150002', '13911112222', '6228480402564890018', '欧阳锋', 'ouyang@test.cn')
) t(id, idcard, mobile, bankcard, name, email);

CREATE OR REPLACE TABLE pii_masked AS SELECT
  id,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'idcard',   'v':idcard})   AS idcard,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'mobile',   'v':mobile})   AS mobile,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'bankcard', 'v':bankcard}) AS bankcard,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'name',     'v':name})     AS name,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'email',    'v':email})    AS email,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'idcard', 'mode':'birth', 'v':idcard}) AS idcard_birth,
  luajit_s('privacy', {'op':'mask_cn', 'kind':'idcard', 'mode':'hash', 'salt':'proj1', 'v':idcard}) AS idcard_hash
FROM pii;

SELECT * FROM pii_masked;

-- 断言 1：零泄漏（掩码结果不得等于原文）
SELECT COUNT(*) AS leakage_must_be_0 FROM pii p JOIN pii_masked m USING (id)
WHERE m.idcard = p.idcard OR m.mobile = p.mobile OR m.bankcard = p.bankcard
   OR m.name = p.name OR m.email = p.email;

-- 断言 2：格式保持（位数不变 → 下游长度校验/落库不炸）
SELECT COUNT(*) AS length_mismatch_must_be_0 FROM pii p JOIN pii_masked m USING (id)
WHERE length(m.idcard) <> length(p.idcard) OR length(m.mobile) <> length(p.mobile)
   OR length(m.bankcard) <> length(p.bankcard);

-- 断言 3：birth 模式只把出生日期归到年（其余位逐字保留）
SELECT COUNT(*) AS birth_mode_mismatch_must_be_0 FROM pii p JOIN pii_masked m USING (id)
WHERE m.idcard_birth <> substr(p.idcard, 1, 6) || substr(p.idcard, 7, 4) || '0101' || substr(p.idcard, 15, 4);

-- 断言 4：外键保持——哈希后连接的行数 == 明文连接的行数（同盐 → 同输入同输出）
CREATE OR REPLACE TABLE orders AS SELECT * FROM (VALUES
  ('110101199003071234', 100.0), ('310101198512150002', 200.0), ('110101199003071234', 50.0)
) o(idcard, amt);
SELECT (SELECT COUNT(*) FROM orders o JOIN pii p ON o.idcard = p.idcard) AS plaintext_join,
       (SELECT COUNT(*) FROM
          (SELECT luajit_s('privacy', {'op':'mask_cn','kind':'idcard','mode':'hash','salt':'proj1','v':idcard}) AS k, amt FROM orders) oh
          JOIN (SELECT idcard_hash AS k, id FROM pii_masked) ph USING (k)) AS hashed_join;

-- 断言 5：fail-closed——长度不符的值退通用 star，绝不原样透出
SELECT luajit_s('privacy', {'op':'mask_cn', 'kind':'idcard', 'v':'12345'}) AS failclosed_len,
       luajit_s('privacy', {'op':'mask_cn', 'kind':'idcard', 'v':'110101991230711234'}) AS unknown;

-- ============================================================
-- 二、dateshift：MIMIC 式临床日期平移（三条可证伪断言）
-- ============================================================
CREATE OR REPLACE TABLE enc AS SELECT * FROM (VALUES
  (101, 1, DATE '2150-03-01', DATE '2150-03-08'),
  (102, 1, DATE '2150-04-20', DATE '2150-04-25'),   -- 同 subject 第二次住院
  (103, 2, DATE '2149-11-30', DATE '2149-12-03'),
  (104, 3, DATE '2150-01-15', DATE '2150-01-20'),
  (105, 4, DATE '2150-06-01', DATE '2150-06-02')
) t(enc_id, subject_id, admittime, dischtime);

CREATE OR REPLACE TABLE enc_deid AS SELECT
  enc_id, subject_id,
  CAST(split_part(luajit_s('privacy', {'op':'dateshift', 'v':CAST(admittime AS VARCHAR),
       'key':CAST(subject_id AS VARCHAR), 'days':180, 'with_delta':true}), '|', 1) AS DATE) AS admittime,
  CAST(split_part(luajit_s('privacy', {'op':'dateshift', 'v':CAST(dischtime AS VARCHAR),
       'key':CAST(subject_id AS VARCHAR), 'days':180, 'with_delta':true}), '|', 1) AS DATE) AS dischtime,
  CAST(luajit_s('privacy', {'op':'dateoffset', 'key':CAST(subject_id AS VARCHAR), 'days':180}) AS INTEGER) AS delta
FROM enc;

SELECT * FROM enc_deid ORDER BY enc_id;

-- 断言 6（① 同 subject 恒同偏移）：每个 subject 的 delta 只有 1 个取值
SELECT COUNT(*) AS subject_drift_must_be_0 FROM (
  SELECT subject_id FROM enc_deid GROUP BY 1 HAVING COUNT(DISTINCT delta) <> 1);

-- 断言 7（② |delta| ≤ days=180）
SELECT COUNT(*) AS delta_oob_must_be_0 FROM enc_deid WHERE abs(delta) > 180;

-- 断言 8：平移量精确（DuckDB 自身日期引擎独立复算：shifted == original + delta）
SELECT COUNT(*) AS shift_math_mismatch_must_be_0
FROM enc e JOIN enc_deid d USING (enc_id)
WHERE d.admittime <> e.admittime + d.delta OR d.dischtime <> e.dischtime + d.delta;

-- 断言 9（③ 相对时间逐位不变）：住院时长（两事件间隔）多重集平移前后完全相同
SELECT COUNT(*) AS interval_mismatch_must_be_0 FROM (
  (SELECT enc_id, subject_id, dischtime - admittime AS los FROM enc
   EXCEPT SELECT enc_id, subject_id, dischtime - admittime AS los FROM enc_deid)
  UNION ALL
  (SELECT enc_id, subject_id, dischtime - admittime AS los FROM enc_deid
   EXCEPT SELECT enc_id, subject_id, dischtime - admittime AS los FROM enc)
);

-- 断言 10（③ 相对窗口）：每 subject 各次住院相对首次住院的天数，平移前后集合相等
SELECT COUNT(*) AS rel_window_mismatch_must_be_0 FROM (
  (SELECT subject_id, admittime - MIN(admittime) OVER (PARTITION BY subject_id) AS d FROM enc
   EXCEPT SELECT subject_id, admittime - MIN(admittime) OVER (PARTITION BY subject_id) AS d FROM enc_deid)
  UNION ALL
  (SELECT subject_id, admittime - MIN(admittime) OVER (PARTITION BY subject_id) AS d FROM enc_deid
   EXCEPT SELECT subject_id, admittime - MIN(admittime) OVER (PARTITION BY subject_id) AS d FROM enc)
);

-- 断言 11（反退化证据）：偏移确实按 subject 变化（不是全局常数平移），且绝对日期确已改变
SELECT COUNT(DISTINCT delta) AS distinct_deltas, MIN(delta) AS min_delta, MAX(delta) AS max_delta,
       COUNT(*) FILTER (WHERE d.admittime = e.admittime) AS unchanged_rows
FROM enc_deid d JOIN enc e USING (enc_id);

-- 断言 12：去标识后绝对日期范围与原始不同（不可反推原始日期）
SELECT MIN(admittime) AS orig_min, MAX(dischtime) AS orig_max FROM enc;
SELECT MIN(admittime) AS deid_min, MAX(dischtime) AS deid_max FROM enc_deid;

-- ============================================================
-- 三、kanon_report：k/l/t 去标识化效果评估（GB/T 42460 要素）
-- ============================================================
CREATE OR REPLACE TABLE pts AS SELECT * FROM (VALUES
  (1, 25, '310', 'A'), (2, 26, '310', 'B'), (3, 27, '310', 'A'), (4, 28, '310', 'C'),
  (5, 60, '110', 'A'), (6, 61, '110', 'B'), (7, 62, '110', 'B'), (8, 63, '110', 'C')
) t(id, age, zip, disease);

-- 把整表聚合成并行数组后送进 lib（SQL 侧真实调用形态）
CREATE OR REPLACE TABLE pts_args AS
SELECT list(age) AS age, list(zip) AS zip, list(disease) AS disease FROM pts;

SELECT luajit_s('privacy', {'op':'kanon_report', 'age':age, 'zip':zip, 'disease':disease,
  'k':2, 'l':2, 't':0.4, 'sensitive_field':'disease'}) AS report_loose FROM pts_args;

SELECT luajit_s('privacy', {'op':'kanon_report', 'age':age, 'zip':zip, 'disease':disease,
  'k':2, 'l':2, 't':0.2, 'sensitive_field':'disease'}) AS report_tight FROM pts_args;

-- 断言 13：t=0.4 通过、t=0.2 不通过（同一数据仅改阈值 → 判据真的在起作用，非恒定输出）
SELECT COUNT(*) AS threshold_gate_broken_must_be_0 FROM pts_args
WHERE json_extract_string(luajit_s('privacy', {'op':'kanon_report','age':age,'zip':zip,'disease':disease,
        'k':2,'l':2,'t':0.4,'sensitive_field':'disease'}), '$.report.verdict') <> 'pass'
   OR json_extract_string(luajit_s('privacy', {'op':'kanon_report','age':age,'zip':zip,'disease':disease,
        'k':2,'l':2,'t':0.2,'sensitive_field':'disease'}), '$.report.verdict') <> 'fail';

-- 断言 14：l 从 2 收紧到 3 → 必然违 l（每类只有 2 个病种）
SELECT COUNT(*) AS l_gate_broken_must_be_0 FROM pts_args
WHERE json_extract_string(luajit_s('privacy', {'op':'kanon_report','age':age,'zip':zip,'disease':disease,
        'k':2,'l':3,'t':0.9,'sensitive_field':'disease'}), '$.report.l_ok') <> 'false'
   OR json_extract_string(luajit_s('privacy', {'op':'kanon_report','age':age,'zip':zip,'disease':disease,
        'k':2,'l':3,'t':0.9,'sensitive_field':'disease'}), '$.report.verdict') <> 'fail';

-- 断言 15（跨层一致性）：report 的聚合字段必须等于其自带 groups 明细的再聚合
--   （明细由同一次调用产出，但聚合走的是独立代码路径 → 能抓出累加器与明细不一致）
WITH r AS (
  SELECT luajit_s('privacy', {'op':'kanon_report','age':age,'zip':zip,'disease':disease,
    'k':2,'l':2,'t':0.4,'sensitive_field':'disease'}) AS j FROM pts_args
), g AS (
  SELECT CAST(json_extract(j, '$.groups[*].size') AS BIGINT[])      AS sizes,
         CAST(json_extract(j, '$.groups[*].distinct_l') AS BIGINT[]) AS dls,
         CAST(json_extract(j, '$.groups[*].entropy_l') AS DOUBLE[])  AS ents,
         CAST(json_extract(j, '$.groups[*].t') AS DOUBLE[])          AS ts,
         json_extract(j, '$.report') AS rep
  FROM r
)
SELECT COUNT(*) AS report_aggregate_mismatch_must_be_0 FROM g
WHERE list_min(sizes) <> CAST(json_extract(rep, '$.min_class_size') AS BIGINT)
   OR list_min(dls)   <> CAST(json_extract(rep, '$.min_distinct_l') AS BIGINT)
   OR abs(list_min(ents) - CAST(json_extract(rep, '$.min_entropy_l') AS DOUBLE)) > 1e-9
   OR abs(list_max(ts)   - CAST(json_extract(rep, '$.max_t') AS DOUBLE)) > 1e-9
   OR list_sum(sizes) <> CAST(json_extract(rep, '$.n') AS BIGINT);

-- 断言 16：等价类规模与抑制（k=3、仅 2 条 → 全部抑制，抑制率 1）
SELECT luajit_s('privacy', {'op':'kanon_report', 'age':[25,26], 'zip':['310','310'],
  'disease':['A','B'], 'k':3, 'l':1, 't':0.9, 'sensitive_field':'disease'}) AS small_case;

SELECT COUNT(*) AS suppression_mismatch_must_be_0 FROM (SELECT 1)
WHERE (SELECT json_extract_string(luajit_s('privacy', {'op':'kanon_report','age':[25,26],
          'zip':['310','310'],'disease':['A','B'],'k':3,'l':1,'t':0.9,'sensitive_field':'disease'}),
          '$.report.suppression_rate')) <> '1'
   OR (SELECT json_extract_string(luajit_s('privacy', {'op':'kanon_report','age':[25,26],
          'zip':['310','310'],'disease':['A','B'],'k':3,'l':1,'t':0.9,'sensitive_field':'disease'}),
          '$.report.verdict')) <> 'fail';

-- ============================================================
-- 四、ε 预算台账：dp_compose / dp_alloc / dp_budget
-- ============================================================
-- 断言 17：强组合界必须严于 basic（n=100、ε=0.01 → 0.4899 vs 1.0）
SELECT json_extract_string(luajit_s('privacy', {'op':'dp_compose','epsilon':0.01,'count':100,'delta':1e-5}),
  '$.advanced_total') AS adv, json_extract_string(luajit_s('privacy',
  {'op':'dp_compose','epsilon':0.01,'count':100,'delta':1e-5}), '$.basic_total') AS bas;

SELECT COUNT(*) AS compose_bound_broken_must_be_0 FROM (SELECT 1)
WHERE (SELECT CAST(json_extract_string(luajit_s('privacy', {'op':'dp_compose','epsilon':0.01,
          'count':100,'delta':1e-5}), '$.advanced_total') AS DOUBLE))
    >= (SELECT CAST(json_extract_string(luajit_s('privacy', {'op':'dp_compose','epsilon':0.01,
          'count':100,'delta':1e-5}), '$.basic_total') AS DOUBLE));

-- 断言 18：同样预算下高级组合给出更大单查询 ε（记账的价值）
SELECT COUNT(*) AS alloc_gain_broken_must_be_0 FROM (SELECT 1)
WHERE (SELECT CAST(json_extract_string(luajit_s('privacy', {'op':'dp_alloc','budget':1.0,
          'n':100,'delta':1e-5}), '$.recommended_per_query') AS DOUBLE))
   <= (SELECT CAST(json_extract_string(luajit_s('privacy', {'op':'dp_alloc','budget':1.0,
          'n':100,'delta':1e-5}), '$.basic_per') AS DOUBLE));

-- 断言 19：ledger 数组（SQL list() → 嵌套 struct）穿透桥接后求和正确
--   5 笔共 0.80（0.1+0.2+0.05+0.15+0.3），申请 0.20 → 恰好用尽 1.0：allow=true、remaining_after=0
WITH led AS (
  SELECT list({'epsilon': eps}) AS arr, sum(eps) AS total
  FROM (VALUES (0.1),(0.2),(0.05),(0.15),(0.3)) t(eps)
), r AS (
  SELECT luajit_s('privacy', {'op':'dp_budget','budget':1.0,'request':0.2,'ledger':arr}) AS j,
         total FROM led
)
SELECT COUNT(*) AS ledger_bridge_mismatch_must_be_0 FROM r
WHERE abs(CAST(json_extract_string(j, '$.spent_before') AS DOUBLE) - total) > 1e-9
   OR json_extract_string(j, '$.allow') <> 'true'
   OR abs(CAST(json_extract_string(j, '$.remaining_after') AS DOUBLE)) > 1e-9;

-- 断言 20：超预算必拒批（同账本申请 0.3 → 1.10 > 1.0）
WITH led AS (
  SELECT list({'epsilon': eps}) AS arr FROM (VALUES (0.1),(0.2),(0.05),(0.15),(0.3)) t(eps)
)
SELECT COUNT(*) AS overbudget_not_denied_must_be_0 FROM led
WHERE json_extract_string(luajit_s('privacy', {'op':'dp_budget','budget':1.0,'request':0.3,'ledger':arr}),
        '$.allow') <> 'false'
   OR json_extract_string(luajit_s('privacy', {'op':'dp_budget','budget':1.0,'request':0.3,'ledger':arr}),
        '$.reason') <> 'budget_exceeded';

-- ============================================================
-- P2：redact_text 自由文本 PHI 脱敏（占位符式）
-- ============================================================

-- 断言 21：综合 —— 文本逐字 + total + 分类计数 + 模式标记
WITH r AS (
  SELECT luajit_s('privacy', {'op':'redact_text','v':'患者张三，电话13800138000，入院2026-03-04','dict':['张三']}) AS j
)
SELECT COUNT(*) AS p2_basic_must_be_0 FROM r
WHERE json_extract_string(j, '$.text') <> '患者[**Name1**]，电话[**PHONE**]，入院[**DATE**]'
   OR CAST(json_extract_string(j, '$.total') AS INT) <> 3
   OR CAST(json_extract_string(j, '$.counts.name') AS INT) <> 1
   OR CAST(json_extract_string(j, '$.counts.mobile') AS INT) <> 1
   OR CAST(json_extract_string(j, '$.counts.date') AS INT) <> 1
   OR json_extract_string(j, '$.date_mode') <> 'placeholder';

-- 断言 22：零明文残留（原值一个都不许出现在输出里）
WITH r AS (
  SELECT luajit_s('privacy', {'op':'redact_text',
    'v':'张三 13800138000 110101199003071234 zhang.san@hospital.org 10.0.0.7 2026-03-04','dict':['张三']}) AS j
)
SELECT COUNT(*) AS p2_no_residue_must_be_0 FROM r
WHERE json_extract_string(j, '$.text') LIKE '%张三%'
   OR json_extract_string(j, '$.text') LIKE '%13800138000%'
   OR json_extract_string(j, '$.text') LIKE '%110101199003071234%'
   OR json_extract_string(j, '$.text') LIKE '%hospital.org%'
   OR json_extract_string(j, '$.text') LIKE '%10.0.0.7%'
   OR json_extract_string(j, '$.text') LIKE '%2026-03-04%';

-- 断言 23：字典编号按「字典顺序」⇒ 跨行稳定假名（张三缺席时李四仍是 Name2）
SELECT COUNT(*) AS p2_dict_order_stable_must_be_0
FROM (SELECT luajit_s('privacy', {'op':'redact_text','v':'只有李四在','dict':['张三','李四']}) AS j)
WHERE json_extract_string(j, '$.text') <> '只有[**Name2**]在';

-- 断言 24：幂等 —— 对已脱敏文本再跑一次，输出不变
WITH a AS (
  SELECT json_extract_string(luajit_s('privacy', {'op':'redact_text','v':'张三13800138000','dict':['张三']}), '$.text') AS t
)
SELECT COUNT(*) AS p2_idempotent_must_be_0 FROM a
WHERE json_extract_string(luajit_s('privacy', {'op':'redact_text','v':t,'dict':['张三']}), '$.text') <> t;

-- 断言 25：跨 op 一致性 —— redact_text 的日期平移 == dateshift（同一 key 同一时间轴）
WITH x AS (
  SELECT luajit_s('privacy', {'op':'redact_text','v':'入院2026-03-04','key':'10001','days':180}) AS j,
         luajit_s('privacy', {'op':'dateshift','v':'2026-03-04','key':'10001','days':180}) AS d
)
SELECT COUNT(*) AS p2_shift_consistency_must_be_0 FROM x
WHERE json_extract_string(j, '$.text') <> '入院' || d
   OR json_extract_string(j, '$.date_mode') <> 'shift';

-- 断言 26：长数字串阈值 + 短数字不动（num_min 默认 9）
SELECT COUNT(*) AS p2_nummin_must_be_0
FROM (SELECT json_extract_string(
        luajit_s('privacy', {'op':'redact_text','v':'单号123456789 体温38 心率90'}), '$.text') AS t)
WHERE t <> '单号[**NUM**] 体温38 心率90';

-- 断言 27：非法日期/非法 IPv4 不误判（月 13、八位组 256 原样保留）
SELECT COUNT(*) AS p2_false_positive_must_be_0
FROM (SELECT json_extract_string(
        luajit_s('privacy', {'op':'redact_text','v':'2026-13-04 与 256.0.0.1'}), '$.text') AS t)
WHERE t <> '2026-13-04 与 256.0.0.1';

-- 断言 28：诚实声明字段存在（规则驱动不假装全覆盖）
SELECT COUNT(*) AS p2_note_missing_must_be_0
FROM (SELECT luajit_s('privacy', {'op':'redact_text','v':'任意文本'}) AS j)
WHERE json_extract_string(j, '$.note') IS NULL
   OR json_extract_string(j, '$.note') NOT LIKE '%not guaranteed%';
