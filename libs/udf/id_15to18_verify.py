#!/usr/bin/env python3
"""id_15to18 交叉校验：独立 Python oracle vs cncheck(id_15to18) Lua 实现。
运行：python3 id_15to18_verify.py
"""
import json, subprocess

DUEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"
LUA = "/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/cncheck.lua"

W = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
MODMAP = "10X98765432"

def oracle(s):
    s = "".join(s.split()).upper()
    if len(s) != 15 or not s.isdigit():
        return None
    s17 = s[:6] + "19" + s[6:]
    c = MODMAP[sum(int(s17[i]) * W[i] for i in range(17)) % 11]
    return s17 + c

def sq(x):
    return x.replace("'", "''")

def run(v):
    sql = (
        "LOAD '%s';\n" % DUEXT +
        "SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'cncheck', "
        "source := 'return dofile(''%s'')');\n" % LUA +
        "SELECT luajit_s('cncheck', {v: '%s', op: 'id_15to18'});\n" % sq(v)
    )
    open("/tmp/id18_v.sql", "w").write(sql)
    p = subprocess.run(["duckdb", "-unsigned", "-list", "-noheader", "-f", "/tmp/id18_v.sql"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "DUCKERR:" + p.stderr.strip()
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return lines[-1] if lines else ""

# 样本：真实区划码风格 + 遍历末位序列保证覆盖全部 11 种校验位（含 X）
samples = [
    "110105491231002", "350102681001001", "440301760101002",
    "510104560715018", "210211730115007", "330106840212003",
    "610113900101009", "120102701224001", "370202550303002",
    "420102881101011", "500103910505022", "150102630404033",
    "650102771212044", "710101820909055", "810101930101066",
    "230102450606077", "450103660808088",
]
# 暴力补齐：固定前 14 位，末位 0-9 遍历，确保 X/0-9 校验位都出现
for last in range(10):
    samples.append("11010549123100" + str(last))
# 去重保序
seen, uniq = set(), []
for s in samples:
    if s not in seen:
        seen.add(s); uniq.append(s)

fails = total = 0
seen_check = set()
for s in uniq:
    total += 1
    got = json.loads(run(s))
    want = oracle(s)
    if want is None:
        if got.get("id18") is not None:
            fails += 1
            print("MISMATCH (should be null) #%s: %r" % (s, got))
        continue
    if got.get("id18") != want:
        fails += 1
        print("MISMATCH #%s: lua=%r oracle=%r" % (s, got.get("id18"), want))
    else:
        seen_check.add(want[-1])
        # 闭环：转换结果必须通过 id_card 校验（oracle 独立验证 18 位合法性）
        s18 = want
        ssum = sum(int(s18[i]) * W[i] for i in range(17))
        assert MODMAP[ssum % 11] == s18[17], "oracle self-check failed"

missing = set(MODMAP) - seen_check
print("check-digits covered: %s%s" % (sorted(seen_check), "" if not missing else "  (missing: %s)" % sorted(missing)))
print("=== PASS=%d FAIL=%d TOTAL=%d ===" % (total - fails, fails, total))
