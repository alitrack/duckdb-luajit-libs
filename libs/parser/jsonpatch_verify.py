#!/usr/bin/env python3
# jsonpatch.lua 独立交叉校验 —— 内置一个最小 RFC 6901/6902 参考实现（独立于 Lua 代码），
# 把一批 (doc, patch) 与若干 diff 闭环用例打包进一次 duckdb 运行，逐条比对。
import json, subprocess, sys

LUA = "/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/jsonpatch.lua"
DVEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"

# ---------- 最小 RFC 6901/6902 参考实现 ----------
def split(ptr):
    if ptr == "": return []
    assert ptr.startswith("/")
    return [t.replace("~1","/").replace("~0","~") for t in ptr[1:].split("/")]

def _parent(doc, toks):
    """返回 (parent_container, last_key)。toks 非空。"""
    cur = doc
    for t in toks[:-1]:
        if isinstance(cur, list):
            cur = cur[int(t)]
        else:
            cur = cur.get(t)
        if cur is None: raise ValueError("missing parent")
    return cur, toks[-1]

def apply(doc, patch):
    for o in patch:
        op = o["op"]
        if op == "add":
            toks = split(o["path"])
            if not toks: doc = o["value"]; continue
            parent, key = _parent(doc, toks)
            if isinstance(parent, list):
                if key == "-": parent.append(o["value"])
                else: parent.insert(int(key), o["value"])
            else: parent[key] = o["value"]
        elif op == "remove":
            toks = split(o["path"]); parent, key = _parent(doc, toks)
            if isinstance(parent, list): del parent[int(key)]
            else: parent.pop(key)
        elif op == "replace":
            toks = split(o["path"])
            if not toks: doc = o["value"]; continue
            parent, key = _parent(doc, toks)
            if isinstance(parent, list): parent[int(key)] = o["value"]
            else: parent[key] = o["value"]
        elif op == "test":
            toks = split(o["path"]); cur = doc
            for t in toks: cur = cur[int(t)] if isinstance(cur, list) else cur.get(t)
            assert cur == o["value"], "test fail"
        elif op == "move":
            v = apply_get(doc, split(o["from"]))
            apply(doc, [{"op":"remove","path":o["from"]}])
            apply(doc, [{"op":"add","path":o["to"],"value":v}])
        elif op == "copy":
            v = apply_get(doc, split(o["from"]))
            apply(doc, [{"op":"add","path":o["to"],"value":v}])
    return doc

def apply_get(doc, toks):
    cur = doc
    for t in toks:
        cur = cur[int(t)] if isinstance(cur, list) else cur.get(t)
    return cur

def jdump(x): return json.dumps(x, ensure_ascii=False)

# ---------- 用例 ----------
cases = []  # (label, duckdb_op, kwargs, expected_json)
def add_case(label, op, **kw):
    cases.append((label, op, kw))

# apply 系列（期望值由参考实现算出，直接嵌入比对）
apply_pairs = [
    ('{"a":1}', '[{"op":"add","path":"/b","value":2},{"op":"test","path":"/a","value":1}]'),
    ('[1,2,4]', '[{"op":"add","path":"/1","value":3}]'),
    ('{"a":1,"b":2,"c":3}', '[{"op":"replace","path":"/a","value":9},{"op":"remove","path":"/b"}]'),
    ('{"a":1,"b":2}', '[{"op":"move","from":"/a","to":"/c"}]'),
    ('{"a":1,"b":2}', '[{"op":"copy","from":"/a","to":"/d"}]'),
    ('{"a/b":{"c~d":5}}', '[{"op":"add","path":"/x","value":{"y":[1,2]}}]'),
    ('{"list":[{"id":1},{"id":2}]}', '[{"op":"remove","path":"/list/0"}]'),
    ('{"list":[1,2,3,4]}', '[{"op":"replace","path":"/list/2","value":99}]'),
    ('{"s":"hi"}', '[{"op":"test","path":"/s","value":"hi"},{"op":"add","path":"/n","value":null}]'),
    ('{"a":{"b":1}}', '[{"op":"add","path":"/a/c","value":true}]'),
]
# 预计算期望
apply_expected = [jdump(apply(json.loads(d), json.loads(p))) for d, p in apply_pairs]

# get 系列
get_pairs = [
    ('[{"x":7},"y"]', '/0/x'),
    ('{"a/b":{"c~d":5}}', '/a~1b/c~0d'),
    ('{"a":[10,20,30]}', '/a/2'),
    ('[1,2,3]', '/1'),
]
get_expected = []
for doc, path in get_pairs:
    toks = split(path)
    cur = json.loads(doc)
    for t in toks: cur = cur[int(t)] if isinstance(cur, list) else cur.get(t)
    get_expected.append(jdump(cur) if cur is not None else "null")

# diff 闭环：patch = diff(a,b)；apply(a, patch) == b
diff_pairs = [
    ('{"a":1,"b":[1,2],"c":"x"}', '{"a":9,"b":[1,3],"d":true}'),
    ('[1,2,3]', '[1,2,3,4]'),
    ('{"a":{"b":[1,2]}}', '{"a":{"b":[1,9],"c":0}}'),
    ('{"x":null}', '{"x":5}'),
    ('{"k":"v"}', '{}'),
]
diff_expected_b = [json.loads(b) for _, b in diff_pairs]

# 组装 duckdb SQL
def sq(s):
    """嵌入 SQL 单引号字符串：单引号翻倍即可（反斜杠/双引号在单引号串里是字面量）。"""
    return s.replace("'", "''")
rows = []
def mk(op, **kw):
    parts = ["op: '%s'" % op]
    for k, v in kw.items():
        parts.append("%s: '%s'" % (k, sq(v)))
    return "SELECT json('{' || '\"l\":' || (SELECT json('%s')) || ',\"r\":' || luajit_s('jp', {%s}) || '}') AS out;" % (sq(rows_label), ", ".join(parts))

# 顺序执行，收集 label
queries = []
labels = []
for i, (doc, patch) in enumerate(apply_pairs):
    labels.append("apply%d" % i)
for i, (doc, path) in enumerate(get_pairs):
    labels.append("get%d" % i)
for i, (a, b) in enumerate(diff_pairs):
    labels.append("diff%d" % i)

sql_body = []
# apply
for i, (doc, patch) in enumerate(apply_pairs):
    L = "apply%d" % i
    sql_body.append("SELECT json('{' || '\"l\":\"%s\",\"r\":' || luajit_s('jp', {op:'apply', doc:'%s', patch:'%s'}) || '}') AS out;" % (L, sq(doc), sq(patch)))
# get
for i, (doc, path) in enumerate(get_pairs):
    L = "get%d" % i
    sql_body.append("SELECT json('{' || '\"l\":\"%s\",\"r\":' || luajit_s('jp', {op:'get', doc:'%s', path:'%s'}) || '}') AS out;" % (L, sq(doc), sq(path)))
# diff → apply 闭环（两步：先 diff，再 apply 回 a）
for i, (a, b) in enumerate(diff_pairs):
    L = "diff%d" % i
    sql_body.append("WITH d AS (SELECT luajit_s('jp', {op:'diff', a:'%s', b:'%s'}) AS patch) "
                    "SELECT json('{' || '\"l\":\"%s\",\"r\":' || luajit_s('jp', {op:'apply', doc:'%s', patch:(SELECT patch FROM d)}) || '}') AS out;" % (sq(a), sq(b), L, sq(a)))

sql = "LOAD '%s';\nSELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jp', source := 'return dofile(''%s'')');\n" % (DVEXT, LUA)
sql += "\n".join(sql_body)
open("/tmp/jp_verify.sql","w").write(sql)
p = subprocess.run(["duckdb","-unsigned","-list","-noheader","-f","/tmp/jp_verify.sql"], capture_output=True, text=True)
if p.returncode != 0:
    print("duckdb failed:", p.stderr[-800:]); sys.exit(2)
res = {}
for line in p.stdout.splitlines():
    line = line.strip()
    if line.startswith("{") and line.endswith("}"):
        try:
            o = json.loads(line); res[o["l"]] = o["r"]
        except Exception: pass

fails = 0; total = 0
def as_val(s):
    """把 duckdb 返回的字符串结果解析回 JSON 值（数字/对象/数组/字符串/bool）。"""
    if s is None: return None
    try: return json.loads(s)
    except Exception: return s
def ck(desc, got_raw, want):
    global fails, total
    total += 1
    got = as_val(got_raw)
    if got != want:
        fails += 1
        print("MISMATCH %s\n  lua : %r\n  ref : %r" % (desc, got, want))

# apply
for i, (doc, patch) in enumerate(apply_pairs):
    ck("apply%d" % i, res.get("apply%d" % i), json.loads(apply_expected[i]))
# get
for i, (doc, path) in enumerate(get_pairs):
    ck("get%d" % i, res.get("get%d" % i), json.loads(get_expected[i]))
# diff roundtrip: apply(a, diff(a,b)) == b
for i, (a, b) in enumerate(diff_pairs):
    got = res.get("diff%d" % i)
    want = diff_expected_b[i]
    total += 1
    if as_val(got) != want:
        fails += 1
        print("MISMATCH diff%d roundtrip\n  lua : %r\n  b   : %r" % (i, as_val(got), want))

print("\n=== jsonpatch.lua vs RFC6902 reference: %d checks, %d mismatches ===" % (total, fails))
sys.exit(1 if fails else 0)
