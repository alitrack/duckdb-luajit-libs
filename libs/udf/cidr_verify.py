#!/usr/bin/env python3
# cidr.lua 独立交叉校验 —— Python ipaddress 为权威 oracle。
# 所有查询打包进一次 duckdb 运行（-list -noheader，每行 "label\tjson"），再逐条比对。
import ipaddress, json, subprocess, sys

LUA = "/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/cidr.lua"
DVEXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"

v4_ips = ["8.8.8.8","192.168.1.5","10.0.0.5","172.16.0.1","172.31.255.254",
          "127.0.0.1","169.254.10.20","224.0.0.5","255.255.255.255","1.2.3.4",
          "100.64.0.1","0.0.0.0","192.168.0.255","239.255.255.255","240.0.0.1"]
v6_ips = ["::","::1","fe80::1","fd12:3456::7","2001:db8::1","2001:4860:4860::8888",
          "ff02::1","2001:db8:abcd:1234::abcd","1:2:3:4:5:6:7:8"]
v4_cidrs = ["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12","192.168.5.0/24",
            "100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","8.8.8.0/24","9.9.9.0/24"]
v6_cidrs = ["2001:db8::/32","fe80::/10","fc00::/7","::1/128","ff00::/8","2001:4860:4860::8888/128","2606:4700:4700::1111/128"]

q = []   # (label, sql_select_expr)
def jesc(s):
    return s.replace("\\","\\\\").replace('"','\\"')
def add(label, op, v, cidr=None):
    struct = "op: '%s', v: '%s'" % (op, v)
    if cidr: struct += ", cidr: '%s'" % cidr
    q.append((label, "SELECT json('{' || '\"l\":\"%s\",\"r\":' || luajit_s('cidr', {%s}) || '}') AS out;" % (jesc(label), struct)))

# in_cidr
for net in v4_cidrs + v6_cidrs:
    try: netobj = ipaddress.ip_network(net)
    except ValueError: continue
    ip = str(netobj.network_address + 1) if netobj.num_addresses > 1 else str(netobj.network_address)
    add("in|%s|%s" % (ip, net), "in_cidr", ip, net)
    outside = "9.9.9.9" if netobj.version==4 else "2001:db9::1"
    add("inout|%s|%s" % (outside, net), "in_cidr", outside, net)
# cidr_info
for net in v4_cidrs + v6_cidrs:
    try: netobj = ipaddress.ip_network(net)
    except ValueError: continue
    add("info|%s" % net, "cidr_info", net)
# classify
for ip in v4_ips + v6_ips:
    add("cls|%s" % ip, "classify", ip)
# ip2int v4
for ip in v4_ips:
    add("ip2int|%s" % ip, "ip2int", ip)
# version
for ip in v4_ips[:3] + v6_ips[:3]:
    add("ver|%s" % ip, "version", ip)

sql = "LOAD '%s';\nSELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'cidr', source := 'return dofile(''%s'')');\n" % (DVEXT, LUA)
sql += "\n".join(s for _, s in q)

p = subprocess.run(["duckdb","-unsigned","-list","-noheader","-c",sql], capture_output=True, text=True)
open("/tmp/cidr_dbg.sql","w").write(sql)
open("/tmp/cidr_dbg.out","w").write("RC=%s\nSTDOUT:\n%s\nSTDERR:\n%s" % (p.returncode, p.stdout[:2000], p.stderr[:2000]))
if p.returncode != 0:
    print("duckdb failed:", p.stderr[-800:]); sys.exit(2)
res = {}
for line in p.stdout.splitlines():
    line = line.strip()
    if line.startswith("{") and line.endswith("}"):
        try:
            obj = json.loads(line)
            res[obj["l"]] = obj["r"]
        except Exception:
            pass

def py_classify(a):
    if a.is_unspecified: return "unspecified"
    if a.is_loopback: return "loopback"
    if a.is_multicast: return "multicast"
    if a.is_link_local: return "link-local"
    if a.is_private: return "private"
    if a.is_reserved: return "reserved"
    return "public"

fails=0; total=0
def check(desc, lua, want):
    global fails, total
    total += 1
    if lua != want:
        fails += 1
        print("MISMATCH %s\n  lua  : %s\n  python: %s" % (desc, lua, want))

for net in v4_cidrs + v6_cidrs:
    try: netobj = ipaddress.ip_network(net)
    except ValueError: continue
    ip = str(netobj.network_address + 1) if netobj.num_addresses > 1 else str(netobj.network_address)
    raw = res.get("in|%s|%s" % (ip, net))
    if not isinstance(raw, dict) or "in" not in raw:
        print("MISSING/BAD in label=%s|%s raw=%r" % (ip, net, raw)); fails+=1; total+=1; continue
    got = raw["in"]
    check("in %s in %s" % (ip, net), got, ipaddress.ip_address(ip) in netobj)
    outside = "9.9.9.9" if netobj.version==4 else "2001:db9::1"
    raw2 = res.get("inout|%s|%s" % (outside, net))
    if not isinstance(raw2, dict) or "in" not in raw2:
        print("MISSING/BAD inout label raw=%r" % raw2); fails+=1; total+=1; continue
    g2 = raw2["in"]
    check("in %s in %s (out)" % (outside, net), g2, ipaddress.ip_address(outside) in netobj)

for net in v4_cidrs + v6_cidrs:
    try: netobj = ipaddress.ip_network(net)
    except ValueError: continue
    got = res.get("info|%s" % net, {})
    if not isinstance(got, dict) or "network" not in got:
        print("MISSING/BAD info %s raw=%r" % (net, got)); fails+=1; total+=1; continue
    check("net %s" % net, got.get("network"), str(netobj.network_address))
    check("mask %s" % net, got.get("mask"), str(netobj.netmask))
    bcast = str(netobj.broadcast_address) if netobj.num_addresses>1 else str(netobj.network_address)
    check("bcast %s" % net, got.get("broadcast"), bcast)
    exp_size = netobj.num_addresses
    gs = got.get("size")
    if isinstance(gs, str) and gs.startswith("2^"): gs = 2 ** int(gs[2:])
    check("size %s" % net, gs, exp_size)

for ip in v4_ips + v6_ips:
    a = ipaddress.ip_address(ip)
    got = res.get("cls|%s" % ip, {})
    check("classify %s" % ip, got.get("class") if isinstance(got,dict) else None, py_classify(a))

for ip in v4_ips:
    got = res.get("ip2int|%s" % ip, {})
    check("ip2int %s" % ip, got.get("value") if isinstance(got,dict) else None, int(ipaddress.ip_address(ip)))

for ip in v4_ips[:3] + v6_ips[:3]:
    got = res.get("ver|%s" % ip, {})
    check("version %s" % ip, got.get("version") if isinstance(got,dict) else None, ipaddress.ip_address(ip).version)

print("\n=== cidr.lua vs Python ipaddress: %d checks, %d mismatches ===" % (total, fails))
sys.exit(1 if fails else 0)
