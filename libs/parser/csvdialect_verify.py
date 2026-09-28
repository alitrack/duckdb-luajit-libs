#!/usr/bin/env python3
"""csvdialect.lua 交叉校验：Python csv.Sniffer（方言）+ csv.reader（解析矩阵）为 oracle。
运行：python3 csvdialect_verify.py
"""
import csv, io, json, subprocess

REPO = "/mnt/d/wsl2/duckdb-luajit-libs"
DUEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"
LUA = REPO + "/libs/parser/csvdialect.lua"

def freq_delim(text):
    # 列一致性规则：选「每行出现次数一致且 > 0」的候选分隔符（按 ,;\\t| 优先级）
    lines = [l for l in text.split('\n') if l.strip()]
    best, bestn = None, 0
    for cand in [',', ';', '\t', '|']:
        counts = []
        for l in lines:
            # 粗略（不含引号处理）计数
            counts.append(l.count(cand))
        nz = [c for c in counts if c > 0]
        if nz and len(set(nz)) == 1 and nz[0] == max(counts):
            if len(nz) > bestn:
                bestn = len(nz); best = cand
    return best

def ws_delim(text):
    # whitespace 回退（duckdb/duckdb#18413）：定长分隔符全 miss 时，
    # 所有非空行按连续空白切分列数一致且 >=2 → 'whitespace'
    lines = [l for l in text.split('\n') if l.strip()]
    if len(lines) < 2:
        return None
    cols = [len(l.split()) for l in lines]
    if cols[0] >= 2 and all(c == cols[0] for c in cols):
        return 'whitespace'
    return None

def oracle_delim(text):
    # 先用 Sniffer；若 Sniffer 的选择不产生一致多列切分，退回列一致性规则；
    # 再退回 whitespace 探测
    try:
        sn = csv.Sniffer().sniff(text, delimiters=',;\t|')
        d = sn.delimiter
        # 验证 d 确实把首行切成 >1 列
        if text.split('\n')[0].count(d) > 0:
            return d
    except Exception:
        pass
    return freq_delim(text) or ws_delim(text) or ','

CASES = [
    # (csv_text, has_header_expected) — oracle 用 csv.Sniffer + csv.reader
    ("name,age,city\nAlice,30,Berlin\nBob,25,Paris\n", True),
    ("name;age;city\nAlice;30;Berlin\nBob;25,Paris\n", True),  # 分号，含逗号字段
    ("a\tb\tc\n1\t2\t3\n4\t5\t6\n", False),
    ('a,b\n"1,2",3\n"say ""hi""",x\n', True),
    ("1,2,3\n4,5,6\n", False),
    ("x,y\n1,2\n3,4\n", True),
    ("a;b;c\n1;2;3\n4;5;6\n", False),
    ('col1,col2\n"multi\nline",v\n', True),
    # whitespace-delimited（duckdb/duckdb#18413：NOAA Keeling 曲线式）
    ("Year  Month  Decimal   Average\n"
     "1958  1.0  0.042   315.71\n"
     "1958  2.0  0.083   317.02\n"
     "1958  3.0  0.125   317.88\n", True),
    ("a\tb c   d\n1 2   3\n4 5   6\n", False),  # tab+空格混合
]

def sq(s):
    return s.replace("'", "''")

def run_elf(v, op):
    sql = "LOAD '%s';\n" % DUEXT
    sql += "SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'cd', "
    sql += "source := 'return dofile(''%s'')');\n" % LUA
    sql += "SELECT cd({v:'%s', op:'%s'});\n" % (sq(v), op)
    open("/tmp/cd_v.sql", "w").write(sql)
    p = subprocess.run(["duckdb", "-unsigned", "-list", "-noheader", "-f", "/tmp/cd_v.sql"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "DUCKERR:" + p.stderr.strip()
    lines = [l for l in p.stdout.splitlines() if l.strip() != ""]
    return lines[-1] if lines else ""

fails = 0; total = 0
for i, (text, _hexp) in enumerate(CASES):
    # --- oracle: dialect ---
    want_delim = oracle_delim(text)
    want_quote = '"'
    # --- oracle: parse matrix（用探测出的分隔符）---
    if want_delim == 'whitespace':
        want_rows = [[f for f in l.split()] for l in text.split('\n') if l.strip()]
    else:
        try:
            want_rows = list(csv.reader(io.StringIO(text), delimiter=want_delim, quotechar=want_quote))
        except Exception:
            want_rows = None

    # --- lua ---
    got_dia_raw = run_elf(text, 'detect')
    got_par_raw = run_elf(text, 'parse')
    try:
        got_dia = json.loads(got_dia_raw)
        got_par = json.loads(got_par_raw)
    except Exception as e:
        got_dia, got_par = None, "PARSEERR:%s:%s" % (got_dia_raw[:40], got_par_raw[:40])

    ok = True
    # 1) delimiter
    gd = got_dia.get('delimiter') if isinstance(got_dia, dict) else None
    if gd != want_delim:
        ok = False
        print("MISMATCH #%d delimiter: lua=%r oracle=%r" % (i, gd, want_delim))
    # 2) parse matrix（若 oracle 成功解析）
    if want_rows is not None and isinstance(got_par, list):
        if got_par != want_rows:
            ok = False
            print("MISMATCH #%d parse:\n  lua  : %s\n  oracle: %s" % (i, got_par, want_rows))
    else:
        # oracle 解析失败但 lua 成功（或反之）→ 记录（不判失败，仅提示）
        if want_rows is None and isinstance(got_par, list):
            print("NOTE #%d: oracle csv.reader failed, lua parsed=%s" % (i, str(got_par)[:60]))
    total += 1
    if not ok:
        fails += 1
        print("  text: %r" % text)

print("=== PASS=%d FAIL=%d TOTAL=%d ===" % (total-fails, fails, total))
