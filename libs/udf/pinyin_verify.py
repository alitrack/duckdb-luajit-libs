#!/usr/bin/env python3
"""pinyin.lua 交叉校验：pypinyin（独立 Python oracle）vs Lua 词库实现。
本库词典 = pypinyin 0.55.0 词典快照（多音取首读）+ 同款最大词组匹配，
故无词库语境下两者应逐字一致。无映射非 ASCII 字符：本库→'?'（keep→原字符），
oracle 侧按字符映射集归一化为 '?' 再比较。
运行：python3 pinyin_verify.py
"""
import json, subprocess
from pypinyin import pinyin, Style

DUEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"
LUA = "/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/pinyin.lua"

def sq(s):
    return s.replace("'", "''")

def run(v, style=None, unknown=None):
    fields = ["v:'%s'" % sq(v), "op:'join'"]
    if style:
        fields.append("style:'%s'" % style)
    if unknown:
        fields.append("unknown:'%s'" % unknown)
    sql = (
        "LOAD '%s';\n" % DUEXT +
        "SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'pinyin', "
        "source := 'return dofile(''%s'')');\n" % (LUA) +
        "SELECT luajit_s('pinyin', {%s});\n" % ", ".join(fields)
    )
    open("/tmp/ply_v.sql", "w").write(sql)
    p = subprocess.run(["duckdb", "-unsigned", "-list", "-noheader", "-f", "/tmp/ply_v.sql"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "DUCKERR:" + p.stderr.strip()
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return json.loads(lines[-1]) if lines else ""

def oracle(v, notones=False, keep=False):
    """pypinyin 逐字符对齐（返回每个输入字一个元素）。
    keep=False（默认）：无映射非 ASCII 字符 → '?'（对齐本库默认行为）
    keep=True ：无映射字符原样保留（对齐本库 unknown='keep'）"""
    style = Style.NORMAL if notones else Style.TONE
    parts = pinyin(v, style=style)
    out = []
    for c, part in zip(v, parts):
        s = part[0]
        unmapped = (not c.isascii()) and s == c
        if unmapped and not keep:
            out.append("?")
        else:
            out.append(s)
    return "".join(out)

def has_mapping(c):
    return c.isascii() or (lambda r: bool(r) and r[0][0] != c)(
        pinyin(c, style=Style.TONE))

CASES = [
    "中", "重庆", "中国", "北京", "天气", "一丁不识", "今天天气怎么样",
    "重庆一中欢迎你", "你好", "学习", "领导", "行长", "ab中国cd123", "中国123号",
    "你好世界", "长江三角洲", "厦门", "长沙", "蚌埠", "六安", "单县", "东莞",
    "调虎离山", "勉强", "重庆人民广播电台", "ㄐ",
]

fails = total = 0
for v in CASES:
    total += 1
    # tones
    got = run(v)
    want = oracle(v)
    if got != want:
        fails += 1
        print("MISMATCH(tones) %r:\n  lua   : %r\n  oracle: %r" % (v, got, want))
    # notones
    got0 = run(v, style="notones")
    want0 = oracle(v, notones=True)
    if got0 != want0:
        fails += 1
        print("MISMATCH(notones) %r:\n  lua   : %r\n  oracle: %r" % (v, got0, want0))
    # keep 模式（仅含无映射字符的样本）
    if any(not c.isascii() and not has_mapping(c) for c in v):
        gotk = run(v, unknown="keep")
        wantk = oracle(v, keep=True)  # keep：双方都保留原字符
        if gotk != wantk:
            fails += 1
            print("MISMATCH(keep) %r:\n  lua   : %r\n  oracle: %r" % (v, gotk, wantk))

print("=== PASS=%d FAIL=%d TOTAL=%d (每样本 tones+notones 双检，keep 额外) ===" % (total - fails, fails, total))
