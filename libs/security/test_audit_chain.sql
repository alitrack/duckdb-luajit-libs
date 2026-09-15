-- audit_chain 回归（duckdb-luajit）——链式哈希审计：append / verify / 篡改即暴露
-- 运行：rm -f /tmp/audit_chain_poc.db && ~/.local/bin/duckdb -unsigned /tmp/audit_chain_poc.db -f libs/security/test_audit_chain.sql
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'audit_chain',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/security/audit_chain.lua'')');

-- 0. 契约快照
SELECT luajit_s('audit_chain', {op:'status'}) AS s0;

-- 1. 建表（幂等）
SELECT luajit_s('audit_chain', {op:'setup'}) AS s1;

-- 2. append 3 条：actor/action + 授权范围(scope) + 范围指纹(scope_hash) + 载荷 + 结果
SELECT luajit_s('audit_chain', {op:'append', actor:'agent:retail-e2e', action:'llm_prompt',
  scope:'workflow:revenue-growth-kpi', scope_hash: luajit_s('audit_chain', {op:'scope_hash', v:'node=1'}),
  payload:'{"node":1}', outcome:'ok'}) AS a1;
SELECT luajit_s('audit_chain', {op:'append', actor:'agent:retail-e2e', action:'duckdb_query',
  scope:'workflow:revenue-growth-kpi', scope_hash: luajit_s('audit_chain', {op:'scope_hash', v:'node=2'}),
  payload:'{"node":2,"rows":31}', outcome:'ok'}) AS a2;
SELECT luajit_s('audit_chain', {op:'append', actor:'agent:retail-e2e', action:'csv_write',
  scope:'workflow:revenue-growth-kpi', scope_hash: luajit_s('audit_chain', {op:'scope_hash', v:'node=3'}),
  payload:'{"node":3,"bytes":919}', outcome:'ok'}) AS a3;

-- 3. 链内容（hash 前 16 位便于目视）
SELECT seq, ts, substr(prev_hash,1,16) AS prev16, substr(hash,1,16) AS hash16, actor, action, outcome
FROM audit_chain ORDER BY seq;

-- 4. ⭐ 独立复算：不经过 Lua，纯 SQL 按文档口径重算 hash（证明「任何语言可验证」）
SELECT seq,
       hash AS stored,
       sha256(concat_ws('|', prev_hash, CAST(seq AS VARCHAR), ts, actor, action,
                        scope, scope_hash, payload, outcome)) AS recomputed_sql,
       hash = sha256(concat_ws('|', prev_hash, CAST(seq AS VARCHAR), ts, actor, action,
                        scope, scope_hash, payload, outcome)) AS match_sql
FROM audit_chain ORDER BY seq;

-- 5. verify → 全链通过
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_clean;

-- 5b. ⭐ 导出 → 回灌 → 复验（跨语言路径往返：外部写入方产出 JSONL，由本库装入并 verify）
--     ⚠️ load_jsonl 显式声明列类型；若改用 read_json_auto，ts 会被推成 TIMESTAMPTZ（'… 11:48:38+08'），
--     与写入方的 '…T03:48:38Z' 不一致 → 误报 hash_mismatch（实测踩过，非算法不一致）
COPY (SELECT seq, ts, prev_hash, hash, actor, action, scope, scope_hash, payload, outcome
      FROM audit_chain ORDER BY seq) TO '/tmp/ac_roundtrip.jsonl' (FORMAT JSON);
SELECT luajit_s('audit_chain', {op:'load_jsonl', f:'/tmp/ac_roundtrip.jsonl', tbl:'ac_rt'}) AS rt_load;
SELECT luajit_s('audit_chain', {op:'verify', tbl:'ac_rt'}) AS rt_verify;

-- 6. ⭐ 篡改 1：改一条历史记录的 payload（seq=2）→ verify 立刻暴露
UPDATE audit_chain SET payload = '{"node":2,"rows":9999}' WHERE seq = 2;
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_tamper_payload;

-- 7. 还原为原值 → 链自动恢复通过（说明失败是内容敏感的，不是状态的）
UPDATE audit_chain SET payload = '{"node":2,"rows":31}' WHERE seq = 2;
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_restored;

-- 8. ⭐ 篡改 2：只改前驱链指针（seq=3 的 prev_hash），内容一字不动 → 立刻暴露
CREATE TABLE snap AS SELECT prev_hash FROM audit_chain WHERE seq = 3;   -- 留原值用于还原
UPDATE audit_chain SET prev_hash = 'deadbeef' WHERE seq = 3;
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_tamper_chain;

-- 9. 还原链指针 → 恢复通过（对照 8：失败是内容敏感的）
UPDATE audit_chain SET prev_hash = (SELECT prev_hash FROM snap) WHERE seq = 3;
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_chain_restored;

-- 10. ⭐ ⭐ 删中间行（掩盖历史最典型的手段）→ prev_hash 与 lag(hash) 错位 = chain_break
DELETE FROM audit_chain WHERE seq = 2;
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_missing_middle;

-- 11. ⚠️ 诚实边界：删掉**尾部**行，链本身发现不了（末行无后继）→ ok=true，须把 n 与外部台账对账
DELETE FROM audit_chain WHERE seq = 3;
SELECT luajit_s('audit_chain', {op:'verify'}) AS v_tail_deleted;

-- 12. head / logs
SELECT luajit_s('audit_chain', {op:'head'}) AS hd;
SELECT luajit_s('audit_chain', {op:'logs', n:2}) AS lg;

-- 13. scope_hash 确定性（同入同出、异入异出）
SELECT luajit_s('audit_chain', {op:'scope_hash', v:'a=1'}) = luajit_s('audit_chain', {op:'scope_hash', v:'a=1'}) AS same_in,
       luajit_s('audit_chain', {op:'scope_hash', v:'a=1'}) = luajit_s('audit_chain', {op:'scope_hash', v:'a=2'}) AS diff_in,
       luajit_s('audit_chain', {op:'scope_hash', v:'a=1'}) AS h_a1;

-- 12. 入参校验
SELECT luajit_s('audit_chain', {op:'append', action:'x'}) AS err_no_actor,
       luajit_s('audit_chain', {op:'nope'}) AS err_bad_op;
