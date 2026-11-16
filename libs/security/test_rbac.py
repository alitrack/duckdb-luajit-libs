#!/usr/bin/env python3
"""rbac 回归（duckdb-luajit-libs，v4 引擎）—— 跑法: .venv/bin/python libs/security/test_rbac.lua

覆盖:
  - default-deny 全目录(未列名表对任何已认证用户拒读)
  - 视图→传递基表展开(包受控表的视图不是免费通道;授权用户可读)
  - 文件/外部读取函数拒(read_parquet/read_csv/st_read/sqlite_scan/httpfs/...)
  - sqlite 元数据恒拒 / RBAC 元数据恒拒
  - 大小写+引号+CTE 变体
  - 合法读不被误杀
  - authn 会话不覆盖(sid 劫持防护)
运行环境: python + duckdb + luajit 社区扩展(与 quackhole-rbac/tests/verify_rbac_adversarial.py 同源断言)
"""
import duckdb

con = duckdb.connect()
con.execute("INSTALL luajit FROM community; LOAD luajit;")
import os, sys
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "rbac.lua"), encoding="utf-8-sig").read()
con.execute("SELECT * FROM luajit_module(mode := 'compile', sql_name := 'rbac', source := $1)", [src])
con.execute("SELECT luajit_s('rbac', {op:'setup'})")

def ab(b):
    return bool(b) if isinstance(b, bool) else (b == "true")

con.execute("CREATE TABLE secret_data(id INT) VALUES (1)")
con.execute("CREATE TABLE public_data(id INT) VALUES (1)")
con.execute("CREATE TABLE other_data(id INT) VALUES (1)")
con.execute("CREATE TABLE sneaky_table(id INT) VALUES (1)")           # NOT protected-listed
con.execute("CREATE VIEW v_secret AS SELECT * FROM secret_data")
con.execute("CREATE VIEW v_of_v AS SELECT * FROM v_secret")
con.execute("CREATE VIEW v_pub AS SELECT * FROM public_data")
con.execute("INSERT INTO quack_tokens VALUES ('alice-tok','alice'),('bob-tok','bob'),('tunnel','tunnel')")
con.execute("INSERT INTO user_roles VALUES ('alice','analyst'),('bob','viewer'),('tunnel','tunnel_role')")
con.execute("INSERT INTO role_perms VALUES "
            "('analyst','secret_data',true,false),('analyst','public_data',true,false),('analyst','other_data',true,false),"
            "('viewer','public_data',true,false),('tunnel_role','public_data',true,false)")
con.execute("INSERT INTO quack_sessions VALUES ('sid-alice','alice'),('sid-bob','bob')")

CASES = [
    ("sid-bob",   "SELECT * FROM sneaky_table",         False, "default-deny: unlisted table"),
    ("sid-alice", "SELECT * FROM sneaky_table",         False, "default-deny: unlisted (not granted)"),
    ("sid-bob",   "SELECT * FROM v_secret",             False, "view wraps protected"),
    ("sid-bob",   "SELECT * FROM v_of_v",               False, "transitive view"),
    ("sid-alice", "SELECT * FROM v_secret",             True,  "granted reads via view"),
    ("sid-alice", "SELECT * FROM v_of_v",               True,  "granted reads transitive view"),
    ("sid-alice", "SELECT * FROM v_pub",                True,  "granted reads view over public"),
    ("sid-bob",   "SELECT * FROM read_parquet('/x/s.parquet')", False, "file fn read_parquet"),
    ("sid-bob",   "SELECT * FROM read_csv('/x/s.csv')",  False, "file fn read_csv"),
    ("sid-bob",   "SELECT * FROM read_text('/x/s.txt')", False, "file fn read_text"),
    ("sid-bob",   "SELECT * FROM st_read('/x/s.duckdb')", False, "file fn st_read"),
    ("sid-bob",   "SELECT * FROM sqlite_scan('/x/s.duckdb')", False, "file fn sqlite_scan"),
    ("sid-bob",   "SELECT * FROM iceberg_scan('p','t')", False, "file fn iceberg_scan"),
    ("sid-bob",   "SELECT * FROM httpfs('http://x/s.parquet')", False, "file fn httpfs"),
    ("sid-bob",   "SELECT * FROM READ_PARQUET('/x/s.parquet')", False, "file fn (UPPER)"),
    ("sid-bob",   "SELECT * FROM sqlite_master",        False, "sqlite metadata dump"),
    ("sid-bob",   "SELECT name FROM sqlite_schema WHERE type='table'", False, "sqlite_schema dump"),
    ("sid-bob",   "SELECT * FROM quack_tokens",         False, "RBAC meta: tokens"),
    ("sid-bob",   "SELECT * FROM role_perms",           False, "RBAC meta: perms"),
    ("sid-bob",   "SELECT * FROM SECRET_DATA",          False, "protected (UPPER case)"),
    ("sid-bob",   "SELECT * FROM \"secret_data\"",      False, "protected (quoted)"),
    ("sid-alice", "SELECT * FROM r.secret_data",        True,  "schema-qualified granted"),
    ("sid-bob",   "WITH x AS (SELECT * FROM secret_data) SELECT * FROM x", False, "CTE over ungranted"),
    ("sid-alice", "WITH x AS (SELECT * FROM secret_data) SELECT * FROM x", True,  "CTE over granted"),
    ("sid-bob",   "SELECT * FROM public_data",          True,  "viewer legit read"),
    ("sid-bob",   "SELECT count(*) FROM public_data",   True,  "viewer aggregate"),
    ("sid-alice", "SELECT * FROM secret_data",          True,  "analyst direct read"),
]

passed = 0
for sid, sql, want, label in CASES:
    raw = con.execute("SELECT luajit_s('rbac', {op:'authz', sid:?, q:?})", [sid, sql]).fetchone()[0]
    got = ab(raw)
    ok = got == want
    passed += ok
    print(f"  [{'OK ' if ok else 'BAD'}] {'ALLOW' if got else 'DENY':>5} (want {'ALLOW' if want else 'DENY':<5}) {label}")

# authn: an existing session mapping must NOT be overwritten (SID-takeover guard)
con.execute("INSERT INTO quack_sessions VALUES ('sid-bob','bob')")
r1 = con.execute("SELECT luajit_s('rbac', {op:'authn', sid:'sid-bob', client_token:'alice-tok', server_token:'x'})").fetchone()[0]
r2 = con.execute("SELECT user_name FROM quack_sessions WHERE sid='sid-bob'").fetchone()[0]
ok = ab(r1) and r2 == 'bob'
passed += ok
print(f"  [{'OK ' if ok else 'BAD'}] authn no-overwrite (sid stays 'bob' after alice-token reuse)")

total = len(CASES) + 1
print(f"\nRESULT: {passed}/{total} checks passed, {total-passed} failed")
sys.exit(0 if passed == total else 1)
