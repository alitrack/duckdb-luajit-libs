#!/usr/bin/env python3
"""jsonpath.lua 独立交叉校验：内置最小 RFC 9535 参考实现（Python），
批量与 duckdb 的 jp() 输出比对（json.loads 语义比较，列表保序、对象无序）。
运行：python3 jsonpath_verify.py
"""
import json, re, subprocess, os

REPO = "/mnt/d/wsl2/duckdb-luajit-libs"
DUEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"
LUA = REPO + "/libs/parser/jsonpath.lua"

# ---------------- 最小 JSONPath 参考实现（Python）----------------
def parse_member_path(p):
    keys = []
    i = 0; n = len(p)
    def read_name():
        nonlocal i
        j = i
        while j < n and p[j] not in '.[':
            j += 1
        name = p[i:j]
        if name:
            keys.append(name)
        i = j
        return j
    while i < n:
        c = p[i]
        if c == '.':
            i += 1
            i = read_name()
        elif c == '[':
            close = p.find(']', i)
            if close < 0:
                break
            inner = p[i+1:close]
            m = re.match(r'^"(.*)"$', inner) or re.match(r"^'(.*)'$", inner)
            if m:
                inner = m.group(1)
            keys.append(inner)
            i = close + 1
        else:
            i = read_name()
    return keys

def get_path(node, keys):
    cur = node
    for k in keys:
        if isinstance(cur, list):
            if re.match(r'^-?\d+$', k):
                idx = int(k)
                idx = idx if idx >= 0 else len(cur) + idx
                if 0 <= idx < len(cur):
                    cur = cur[idx]
                else:
                    return None
            else:
                return None
        elif isinstance(cur, dict):
            if k not in cur:
                return None
            cur = cur[k]
        else:
            return None
    return cur

def parse_path(expr):
    assert expr.startswith('$'), "must start with $"
    steps = []
    i = 1; n = len(expr)
    while i < n:
        c = expr[i]
        if c == '.':
            if i + 1 < n and expr[i+1] == '.':
                i += 2
                j = i
                while j < n and expr[j] not in '.[':
                    j += 1
                name = expr[i:j]
                if name:
                    steps.append(('rec', name))
                i = j
            else:
                i += 1
                if i < n and expr[i] == '*':
                    steps.append(('wild', None)); i += 1
                else:
                    j = i
                    while j < n and expr[j] not in '.[':
                        j += 1
                    steps.append(('mem', expr[i:j]))
                    i = j
        elif c == '*':
            steps.append(('wild', None)); i += 1
        elif c == '[':
            j = i + 1; inq = None
            while j < n:
                ch = expr[j]
                if inq:
                    if ch == inq: inq = None
                else:
                    if ch in '"\'': inq = ch
                    elif ch == ']': break
                j += 1
            inner = expr[i+1:j]
            i = j + 1
            if re.match(r'^-?\d+$', inner):
                steps.append(('idx', int(inner)))
            elif inner.startswith('?'):
                steps.append(('filt', inner))
            elif inner[0] in '"\'':
                steps.append(('mem', inner[1:-1]))
            elif inner == '*':
                steps.append(('wild', None))
            else:
                steps.append(('mem', inner))
        else:
            raise ValueError('unexpected %r @%d' % (c, i))
    return steps

def find_op(clause):
    i = 0; n = len(clause); inq = None
    while i < n:
        c = clause[i]
        if inq:
            if c == inq: inq = None
            i += 1
        else:
            if c in '"\'':
                inq = c; i += 1
            else:
                two = clause[i:i+2]
                if two in ('<=', '>=', '!='):
                    return two, clause[:i].rstrip(), clause[i+2:].strip()
                if c in '<>=':
                    return c, clause[:i].rstrip(), clause[i+1:].strip()
                i += 1
    return None

def num(x):
    if isinstance(x, bool): return None
    if isinstance(x, (int, float)): return float(x)
    if isinstance(x, str):
        try: return float(x)
        except ValueError: return None
    return None

def eq_val(a, b):
    if isinstance(a, bool) != isinstance(b, bool):
        return False
    return a == b

def eval_clause(node, clause):
    clause = clause.strip()
    fo = find_op(clause)
    if fo is None:
        rel = re.sub(r'^@\.', '', clause)
        rel = re.sub(r'^@', '', rel)
        lkeys = parse_member_path(rel)
        lval = get_path(node, lkeys) if lkeys else node
        return lval is not None
    op, left, right = fo
    rel = re.sub(r'^@\.', '', left)
    rel = re.sub(r'^@', '', rel)
    lkeys = parse_member_path(rel)
    lval = get_path(node, lkeys) if lkeys else node
    if right == 'true': rval = True
    elif right == 'false': rval = False
    elif right in ('null', 'nil'): rval = None
    elif re.match(r'^-?\d+\.?\d*$', right): rval = float(right)
    else:
        m = re.match(r'^"(.*)"$', right) or re.match(r"^'(.*)'$", right)
        rval = m.group(1) if m else right
    if op == '=': return eq_val(lval, rval)
    if op == '!=': return not eq_val(lval, rval)
    a, b = num(lval), num(rval)
    if a is None or b is None: return False
    if op == '<': return a < b
    if op == '<=': return a <= b
    if op == '>': return a > b
    return a >= b

def eval_filter(node, expr):
    m = re.match(r'^\?\((.*)\)\s*$', expr)
    body = m.group(1) if m else expr
    body = body.strip()
    for cl in re.split(r'\s+and\s+', body):
        if not eval_clause(node, cl.strip()):
            return False
    return True

def find_all(node, name, out):
    if isinstance(node, list):
        for x in node:
            find_all(x, name, out)
        return
    if not isinstance(node, dict):
        return
    for k in node:
        if node[k] is None: continue
        if k == name:
            out.append(node[k])
        find_all(node[k], name, out)

def ref_query(root, expr):
    steps = parse_path(expr)
    current = [root]
    for kind, arg in steps:
        nxt = []
        if kind == 'mem':
            for node in current:
                if isinstance(node, dict) and arg in node and node[arg] is not None:
                    nxt.append(node[arg])
        elif kind == 'idx':
            for node in current:
                if isinstance(node, list):
                    i = arg if arg >= 0 else len(node) + arg
                    if 0 <= i < len(node):
                        nxt.append(node[i])
        elif kind == 'wild':
            for node in current:
                if isinstance(node, list):
                    nxt.extend(node)
                elif isinstance(node, dict):
                    for k in node:
                        if node[k] is not None:
                            nxt.append(node[k])
        elif kind == 'rec':
            for node in current:
                find_all(node, arg, nxt)
        elif kind == 'filt':
            for node in current:
                if isinstance(node, list):
                    for x in node:
                        if eval_filter(x, arg):
                            nxt.append(x)
                else:
                    if eval_filter(node, arg):
                        nxt.append(node)
        current = nxt
    return current

# ---------------- 测试用例（doc, expr, op）----------------
CASES = [
    ('{"a":{"b":[10,20,30]}}', '$.a.b[1]', 'query'),
    ('{"a":{"b":[10,20,30]}}', '$.a.b[-1]', 'query'),
    ('{"a":{"b":[10,20,30]}}', '$.a.b', 'query'),
    ('{"a":{"b":[10,20,30]}}', '$.a.b[*]', 'query'),
    ('{"x":1,"y":2,"z":3}', '$.*', 'query'),
    ('{"a":{"b":{"name":"n1"}},"name":"top"}', '$..name', 'query'),
    ('{"a":{"b":{"cat":"ref"}},"cat":"novel"}', '$..cat', 'query'),
    ('{"a":{"a":{"a":{"v":1}},"v":2},"v":3}', '$..v', 'query'),
    ('{"book":[{"title":"A","price":8.95},{"title":"B","price":12.99}]}', '$.book[?(@.price>10)]', 'query'),
    ('{"book":[{"title":"A","price":8.95},{"title":"B","price":12.99}]}', '$.book[?(@.price<10)]', 'query'),
    ('{"book":[{"title":"A","price":8.95},{"title":"B","price":12.99}]}', '$.book[?(@.price<=8.95)]', 'query'),
    ('{"p":[{"cat":"ref","n":1},{"cat":"novel","n":2},{"cat":"ref","n":3}]}', '$.p[?(@.cat="ref")]', 'query'),
    ('{"p":[{"cat":"ref","n":1},{"cat":"novel","n":2},{"cat":"ref","n":3}]}', '$.p[?(@.cat="ref" and @.n>2)]', 'query'),
    ('{"p":[{"cat":"ref","n":1},{"cat":"novel","n":2}]}', '$.p[?(@.cat!="ref")]', 'query'),
    ('{"p":[{"a":1,"b":2},{"b":3}]}', '$.p[?(@.a)]', 'query'),
    ('{"p":[{"a":1,"b":2},{"b":3}]}', '$.p[?(@.c)]', 'query'),
    ('{"x":42}', '$', 'query'),
    ('{"p":[{"n":1},{"n":2},{"n":3}]}', '$.p[*]', 'count'),
    ('{"a":{"b":1}}', '$.a.c', 'exists'),
    ('{"book":[{"price":1},{"price":2}]}', '$.book[?(@.price>1)]', 'first'),
    ('{"book":[{"price":1},{"price":2}]}', '$.book[?(@.price>9)]', 'first'),
    ('{"arr":[[1,2],[3,4],[5,6]]}', '$.arr[1][0]', 'query'),
    ('{"arr":[[1,2],[3,4],[5,6]]}', '$.arr[*][1]', 'query'),
    ('{"store":{"book":[{"cat":"a"},{"cat":"b"}]}}', '$..book[*].cat', 'query'),
    ('{"people":[{"name":"a","age":30},{"name":"b","age":20},{"name":"c","age":25}]}', '$.people[?(@.age>24)]', 'query'),

    ('{"people":[{"name":"a","age":30},{"name":"b","age":20}]}', '$.people[?(@.age>24)]', 'query'),
    ('{"s":{"a":1,"b":{"c":2}}}', '$.s.b.c', 'query'),
    ('{"s":{"a":1,"b":{"c":2}}}', '$.s.nonexistent', 'query'),
    ('{"t":{"x":[{"y":1,"z":2},{"y":3,"z":4}]}}', '$.t.x[?(@.y=2)]', 'query'),
]

def sq(s):
    """嵌入 SQL 单引号串：只翻倍单引号（双引号/反斜杠在单引号串里是字面量）。"""
    return s.replace("'", "''")

def run_elf(doc, expr, op):
    # 走 duckdb 的 jp()，-list -noheader 让输出每行一个值
    sql = "LOAD '%s';\n" % DUEXT
    sql += "SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'jp', "
    sql += "source := 'return dofile(''%s'')');\n" % LUA
    sql += "SELECT jp({v:'%s', e:'%s', op:'%s'});\n" % (sq(doc), sq(expr), op)
    open("/tmp/jp_v.sql", "w").write(sql)
    p = subprocess.run(["duckdb", "-unsigned", "-list", "-noheader", "-f", "/tmp/jp_v.sql"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "DUCKERR:" + p.stderr.strip()
    lines = [l for l in p.stdout.splitlines() if l.strip() != ""]
    return lines[-1] if lines else ""

def norm(s):
    try:
        return json.loads(s)
    except Exception:
        return s

fails = 0; total = 0
for i, (doc, expr, op) in enumerate(CASES):
    total += 1
    try:
        want = ref_query(json.loads(doc), expr)
        if op == 'count':
            want = len(want)
        elif op == 'exists':
            want = len(want) > 0
        elif op == 'first':
            want = want[0] if want else None
    except Exception as e:
        want = "REFERR:%s" % e
    got_raw = run_elf(doc, expr, op)
    got = norm(got_raw)
    if isinstance(got, dict) and "error" in got:
        got = "LUAERR:" + str(got.get("error"))
    ok = (got == want)
    if not ok:
        fails += 1
        print("MISMATCH #%d %s op=%s" % (i, expr, op))
        print("  doc : %s" % doc)
        print("  lua : %s" % (got,))
        print("  ref : %s" % (want,))
print("=== PASS=%d FAIL=%d TOTAL=%d ===" % (total-fails, fails, total))
