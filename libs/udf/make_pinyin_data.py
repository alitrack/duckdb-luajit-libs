#!/usr/bin/env python3
"""pinyin.lua 单文件生成器：引擎（pinyin_engine.lua 模板）+ pypinyin 0.55.0 词典数据
→ 单文件 pinyin.lua（符合仓库"单文件自包含"约定，install/init/dofile 直接可用）。
运行：/tmp/pinyinenv/bin/python make_pinyin_data.py
输出：libs/udf/pinyin.lua（引擎 ~7KB + 数据 ~4.8MB，共 ~4.8MB）
"""
import json

BASE = "/tmp/pinyinenv/lib/python3.14/site-packages/pypinyin"
ENGINE = "/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/pinyin_engine.lua"
OUT = "/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/pinyin.lua"

pinyin = json.load(open(f"{BASE}/pinyin_dict.json"))
phrases = json.load(open(f"{BASE}/phrases_dict.json"))

TONE = {
    "ā": "a", "á": "a", "ǎ": "a", "à": "a",
    "ē": "e", "é": "e", "ě": "e", "è": "e",
    "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
    "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
    "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
    "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v",
}

def strip_tone(s):
    return "".join(TONE.get(c, c) for c in s)

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

def lua_table(entries):
    lines = []
    for k, v in entries.items():
        if isinstance(k, int):
            lines.append(f"    [{k}] = \"{esc(v)}\",")
        else:
            lines.append(f"    [\"{esc(k)}\"] = \"{esc(v)}\",")
    return "    {\n" + "\n".join(lines) + "\n  }"

P = {int(k): v.split(",")[0] for k, v in pinyin.items()}
P0 = {cp: strip_tone(v) for cp, v in P.items()}
PH = {k: "".join(r[0] for r in v) for k, v in phrases.items()}
PH0 = {k: strip_tone(v) for k, v in PH.items()}

engine = open(ENGINE, encoding="utf-8").read()
# 引擎尾部是 "return build" → 替换为内嵌数据 + 调用
assert engine.rstrip().endswith("return build"), "engine must end with 'return build'"
engine_body = engine.rstrip()[: -len("return build")]

data = (
    "-- ===== 词典数据（自动生成：pypinyin 0.55.0 快照，勿手改；\n"
    "-- 重新生成：make_pinyin_data.py，源 make_pinyin_data.py 同目录）=====\n"
    "local DICT = {\n"
    f"  P   = {lua_table(P)},\n"
    f"  PH  = {lua_table(PH)},\n"
    f"  P0  = {lua_table(P0)},\n"
    f"  PH0 = {lua_table(PH0)},\n"
    "}\n"
    "-- ===== 词典数据结束 =====\n"
    "\n"
    "return build(DICT)\n"
)

open(OUT, "w", encoding="utf-8").write(engine_body + data)
import os
print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")
print(f"P={len(P)} chars, PH={len(PH)} phrases")
