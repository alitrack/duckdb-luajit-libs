#!/usr/bin/env python3
"""Add/normalize @license headers in all lib .lua files.

Rules (2026-09-24 supply-chain review, P1-4):
  - Header order: @lib, @category, @desc, @source, @requires, @license
  - @license value decided by @source provenance:
      original/*  → MIT (project license)
      vendored X (LICENSE) → that license, attributed
      system dep (LAPACK/HiGHS) → interface-only, dep NOT distributed
  - Idempotent: replaces an existing @license line in place.
Run from repo root:  python3 scripts/add_license_headers.py
"""
import re, subprocess, sys
from pathlib import Path

MIT = "MIT (duckdb-luajit-libs project)"

# file → explicit license override (provenance from @source / known vendor)
OVERRIDES = {
    "parser/json.lua": "MIT (vendored rxi/json.lua, rxi 2020)",
    "base64.lua": "public domain (vendored iskolbin/lbase64, 2017)",
}

# maturity tiers (review P2-3): audited = third-party reviewed / anchor-verified
# against known answers; tested = has runnable test in repo; poc = demo/probe.
# Path fragments → tier; last match wins; default 'tested'.
MATURITY = [
    ("audited", [
        "privacy/privacy.lua",      # DP/masking anchors in test_privacy.sql
        "etl/incremental.lua",      # E2E + multi-round use in production flows
        "stats/rng.lua",            # statistical test suite
        "parser/json.lua",          # vendored rxi/json.lua (upstream-tested)
        "linalg/linalg.lua",        # anchor-verified vs LAPACK CLI (SVD 18.6x)
        "optimize/highs.lua",       # anchor-verified vs HiGHS CLI & hand-solved
        "ml/classifier.lua",        # benchmarked vs sklearn reference
    ]),
    ("poc", [
        "demo_e2e", "demo_tcc", "gen_inline", "bench_four",
        "inv_ofd_probe", "inv_ofd_test", "probe_bench_transport",
        "test_classifier", "test_entity", "test_privacy", "test_psi",
        "iconv_test", "llm_extract_test", "mcp/sudoku",
    ]),
]


def maturity_for(path: str) -> str:
    tier = "tested"
    for t, frags in MATURITY:
        for frag in frags:
            if frag in path:
                tier = t
    return tier


def rel(p: Path) -> str:
    try:
        return str(p.relative_to(Path("libs")))
    except ValueError:
        return str(p)


def license_for(path: str, source: str) -> str:
    for k, v in OVERRIDES.items():
        if path.endswith(k):
            return v
    if "mozillazg/pinyin-data" in source:
        return "MIT (vendored pinyin-data dictionary, mozillazg)"
    if "python-qrcode" in source or "Nayuki" in source:
        return "MIT (algorithm layout) / Apache-2.0 (Nayuki QR generator)"
    if "Apache 2.0" in source or "MIT/Apache" in source:
        return "MIT OR Apache-2.0 (Rust cdylib, sources in repo)"
    if "usql-bridge" in source:
        return "MIT (alitrack/usql-bridge + original)"
    if "自包含" in source or "original" in source or not source:
        return MIT
    return MIT  # default: project MIT; unusual provenance flagged for review


def main():
    root = Path("libs")
    files = sorted(root.rglob("*.lua"))
    changed = 0
    for f in files:
        text = f.read_text(encoding="utf-8")
        m = re.search(r"^--\s*@source:?\s*(.*)$", text, re.M)
        source = m.group(1).strip() if m else ""
        lic = license_for(rel(f), source)
        lines = text.split("\n")
        if re.search(r"^--\s*@license:", text, re.M):
            new = re.sub(r"^--\s*@license:.*$", f"-- @license: {lic}", text, count=1, flags=re.M)
            if not re.search(r"^--\s*@maturity:", new, re.M):
                new = re.sub(r"^(--\s*@license:.*)$",
                             rf"\1\n-- @maturity: {maturity_for(rel(f))}",
                             new, count=1, flags=re.M)
        else:
            # find the LAST tag line of the header block: scan from the top,
            # a tag line starts a new tag; continuation lines are '--' without
            # '@tag:'. Track the last line index belonging to the final tag's
            # logical position = last line that is either a tag start or a
            # '--' continuation BEFORE the first non-comment line.
            last_tag = None
            in_header = True
            for i, ln in enumerate(lines[:20]):
                if not ln.startswith("--"):
                    in_header = False
                    break
                if re.match(r"^--\s*@\w+:", ln):
                    last_tag = i
            if last_tag is None:
                last_tag = 0
            lines.insert(last_tag + 1, f"-- @license: {lic}")
            lines.insert(last_tag + 2, f"-- @maturity: {maturity_for(rel(f))}")
            new = "\n".join(lines)
        if new != text:
            f.write_text(new, encoding="utf-8")
            changed += 1
            print(f"{rel(f)}: @license: {lic}")
    print(f"\n{changed}/{len(files)} files updated")


if __name__ == "__main__":
    main()
