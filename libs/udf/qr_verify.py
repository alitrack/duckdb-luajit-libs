#!/usr/bin/env python3
"""
qr_verify.py — 独立交叉校验 duckdb-luajit `qr` 库的正确性。

原理：从 GitHub 拉取 python-qrcode（lincolnloop/python-qrcode，MIT，业界通用参考实现），
对若干样例**强制 byte 模式**，与 `qr` 库的 `codewords` 算子（数据 + Reed-Solomon 纠错码字，
与 mask 选择无关）逐字节比对。码字一致即证明：模式编码 / 版本选择 / 分块 / RS 纠错 / 交织
全部正确（QR 里最易错的几处）。矩阵层面参考实现还可能因 mask 选择不同而有差异，两种 mask
均为规格合法且可解码，故不以矩阵逐模块相等为判据（PoC 里附矩阵层面 5/7 逐模块相同的旁证）。

运行（WSL，需网络 + 系统 duckdb）：
    python3 libs/udf/qr_verify.py
"""
import os, sys, time, subprocess, json, shutil

EXT = "/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension"
LIB = "/mnt/d/wsl2/duckdb-luajit-libs/libs/udf/qr.lua"
D = "/tmp/qrverify"
PKG = D + "/qrcode"

def fetch(url, dest):
    for _ in range(5):
        r = subprocess.run(["curl", "-sSL", "--max-time", "30", url, "-o", dest],
                           capture_output=True, text=True)
        if r.returncode == 0 and os.path.getsize(dest) > 0:
            return True
        time.sleep(3)
    return False

def setup_reference():
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(PKG + "/image", exist_ok=True)
    base = "https://raw.githubusercontent.com/lincolnloop/python-qrcode/main/qrcode"
    for f in ["__init__.py", "base.py", "constants.py", "main.py", "util.py",
              "LUT.py", "release.py", "exceptions.py"]:
        if not fetch(f"{base}/{f}", f"{PKG}/{f}"):
            print("FAILED to fetch", f); sys.exit(2)
    for f in ["__init__.py", "base.py", "factories.py", "pil_image.py", "svg.py", "png.py"]:
        fetch(f"{base}/image/{f}", f"{PKG}/image/{f}")
    open(PKG + "/image/__init__.py", "w").write("")
    # 屏蔽 main.py 顶部 image 渲染相关 import（get_matrix/codewords 不需要），并补占位类
    import re
    mp = PKG + "/main.py"
    src = open(mp).read()
    src = re.sub(r"from qrcode\.image\.\w+ import .*", "", src)
    dummies = "class BaseImage: pass\nclass PyPNGImage: pass\nclass SvgPath: pass\n"
    anchor = "from __future__ import annotations"
    src = src.replace(anchor, anchor + "\n" + dummies, 1) if anchor in src else dummies + src
    open(mp, "w").write(src)
    sys.path.insert(0, D)
    from qrcode.main import QRCode
    from qrcode.util import create_data, QRData, MODE_8BIT_BYTE
    from qrcode import constants
    return QRCode, create_data, QRData, MODE_8BIT_BYTE, constants

ECMAP = None  # 在 setup 后填充

def lua_op(text, op, ec):
    esc = text.replace("'", "''")
    sql = (
        "LOAD '%s';\n" % EXT +
        "SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'qr',\n"
        "  source := 'return dofile(''%s'')');\n" % LIB +
        "SELECT luajit_s('qr', {v: '%s', op: '%s', ec: '%s'});\n" % (esc, op, ec)
    )
    tmp = "/tmp/qrverify_q.sql"
    open(tmp, "w").write(sql)
    r = subprocess.run(["duckdb", "-unsigned", "-list", "-noheader", "-f", tmp],
                       capture_output=True, text=True)
    for l in r.stdout.splitlines():
        s = l.strip()
        if s.startswith("[") or s.startswith("{"):
            return s
    raise RuntimeError("no result: " + r.stdout[:100] + r.stderr[:200])

def main():
    QRCode, create_data, QRData, MODE_8BIT_BYTE, constants = setup_reference()
    ecm = {"L": constants.ERROR_CORRECT_L, "M": constants.ERROR_CORRECT_M,
           "Q": constants.ERROR_CORRECT_Q, "H": constants.ERROR_CORRECT_H}

    def ref_codewords(text, ec):
        q = QRCode(error_correction=ecm[ec])
        q.add_data(text); q.make(fit=True)
        dlist = [QRData(text.encode(), mode=MODE_8BIT_BYTE)]
        cw = create_data(q.version, ecm[ec], dlist)
        return [f"{b:02X}" for b in cw], q.version

    TESTS = [("https://example.com/duckdb-luajit?x=1", "M"),
             ("hello world", "M"), ("abc", "L"), ("short", "Q"),
             ("0123456789", "M"), ("中文测试QR码", "M"),
             ("a longer payload that should push version 2 for sure 0123456789", "M")]

    print("=== QR codeword cross-check vs python-qrcode (byte mode) ===")
    allok = True
    for text, ec in TESTS:
        rcw, rv = ref_codewords(text, ec)
        lcw = [h.upper() for h in json.loads(lua_op(text, "codewords", ec))]
        if rcw == lcw:
            print(f"  {text[:24]!r} ec={ec} v={rv}: CODEWORDS IDENTICAL ({len(rcw)}B)")
        else:
            allok = False
            di = next((i for i in range(max(len(rcw), len(lcw)))
                       if (rcw[i] if i < len(rcw) else '?') != (lcw[i] if i < len(lcw) else '?')), -1)
            print(f"  {text[:24]!r} ec={ec} v={rv}: CODEWORDS DIFF @ {di} "
                  f"(ref {len(rcw)}B vs lua {len(lcw)}B)")
    print("RESULT:", "ALL CODEWORDS IDENTICAL" if allok else "MISMATCH — investigate")
    sys.exit(0 if allok else 1)

if __name__ == "__main__":
    main()
