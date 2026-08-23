#!/usr/bin/env python3
"""htmlx.lua 交叉校验：Python html.parser（stdlib）独立解析 HTML，
提取 title/links/tables，与 lua 的 hx() 比对。运行：python3 htmlx_verify.py
"""
import json, subprocess
from html.parser import HTMLParser

REPO = "/mnt/d/wsl2/duckdb-luajit-libs"
DUEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"
LUA = REPO + "/libs/parser/htmlx.lua"

class Extractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = None; self.in_title = False
        self.links = []; self._a = None
        self.tables = []; self._tbl = None; self._row = None; self._cell = None
        self._skip = 0; self._skip_tags = {'script','style','noscript','template'}
    def handle_starttag(self, tag, attrs):
        if tag == 'title': self.in_title = True
        if tag in self._skip_tags: self._skip += 1
        if tag == 'a':
            d = dict(attrs); self._a = d.get('href')
        if tag == 'table': self._tbl = {'rows': []}
        if tag == 'tr': self._row = []
        if tag in ('td','th'): self._cell = []
    def handle_endtag(self, tag):
        if tag == 'title': self.in_title = False
        if tag in self._skip_tags and self._skip > 0: self._skip -= 1
        if tag == 'a' and self._a is not None:
            self.links.append(self._a); self._a = None
        if tag == 'table' and self._tbl is not None:
            self.tables.append(self._tbl); self._tbl = None
        if tag == 'tr' and self._row is not None and self._tbl is not None:
            self._tbl['rows'].append(self._row); self._row = None
        if tag in ('td','th') and self._cell is not None and self._row is not None:
            self._row.append(' '.join(''.join(self._cell).split())); self._cell = None
    def handle_data(self, data):
        if self._skip: return
        if self.in_title:
            self.title = ('' if self.title is None else self.title + ' ') + data
        if self._a is not None and self._cell is None:
            pass  # 仅取 href，text 不在 oracle 比对范围
        if self._cell is not None:
            self._cell.append(data)

def oracle(text):
    e = Extractor(); e.feed(text); e.close()
    return {
        'title': ' '.join(e.title.split()) if e.title is not None else None,
        'link_hrefs': e.links,
        'tables': e.tables,
    }

def sq(s): return s.replace("'", "''")

def run_elf(v, op):
    sql = "LOAD '%s';\n" % DUEXT
    sql += "SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'hx', "
    sql += "source := 'return dofile(''%s'')');\n" % LUA
    sql += "SELECT hx({v:'%s', op:'%s'});\n" % (sq(v), op)
    open("/tmp/hx_v.sql", "w").write(sql)
    p = subprocess.run(["duckdb", "-unsigned", "-list", "-noheader", "-f", "/tmp/hx_v.sql"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "DUCKERR:" + p.stderr.strip()
    lines = [l for l in p.stdout.splitlines() if l.strip() != ""]
    return lines[-1] if lines else ""

CASES = [
    """<html><head><title>  T  </title><style>body{}</style></head>
    <body><h1>H</h1><p>hello   world</p>
    <a href="https://x.com/1">A One</a>
    <a href="https://x.com/2">A  Two</a>
    <a>nope</a>
    <table><tr><th>C1</th><th>C2</th></tr><tr><td>1</td><td>two words</td></tr></table>
    <a href="https://x.com/3">
      multi
      line
    </a>
    <!-- <a href="ghost">no</a> -->
    </body></html>""",
    """<div><A HREF="up.com">Up</a><P>Hi there</p></div>""",
    """<P>no title""",
    """<table><tr><td>a</td><td>b</td></tr></table>""",
    """<ul><li>one</li><li>two</li></ul>
    <a href="l.com">only link</a>""",
    """<h2>Sec</h2><a href="a">x</a><a href="b">y</a><a href="c">z</a>""",
]

fails = 0; total = 0
for i, text in enumerate(CASES):
    total += 1
    o = oracle(text)
    got_t = run_elf(text, 'title')
    got_l = run_elf(text, 'links')
    got_tb = run_elf(text, 'tables')
    try:
        gtitle = json.loads(got_t)
        gloss = json.loads(got_l)
        gtables = json.loads(got_tb)
    except Exception as ex:
        print("MISMATCH #%d parse: %s" % (i, ex)); fails += 1; continue

    ok = True
    # title
    if gtitle != o['title']:
        ok = False; print("MISMATCH #%d title: lua=%r oracle=%r" % (i, gtitle, o['title']))
    # link hrefs（顺序）
    ghrefs = [l.get('href') for l in gloss]
    if ghrefs != o['link_hrefs']:
        ok = False; print("MISMATCH #%d link hrefs: lua=%r oracle=%r" % (i, ghrefs, o['link_hrefs']))
    # tables（rows 矩阵）
    if gtables != o['tables']:
        ok = False; print("MISMATCH #%d tables:\n  lua  : %s\n  oracle: %s" % (i, gtables, o['tables']))
    if not ok:
        fails += 1
        print("  text: %r" % text[:120])

print("=== PASS=%d FAIL=%d TOTAL=%d ===" % (total-fails, fails, total))
