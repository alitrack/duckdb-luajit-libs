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
