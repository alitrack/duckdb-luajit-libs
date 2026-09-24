#!/usr/bin/env python3
"""Generate SBOM.md (and sbom.cdx.json) for duckdb-luajit-libs.

Reviews headers (@lib/@category/@source/@requires/@license) of every lib
and emits a human-readable SBOM plus a CycloneDX-lite JSON. Run AFTER
add_license_headers.py. Idempotent. 2026-09-24 (review P1-4)."""
import hashlib, json, re, subprocess, sys
from pathlib import Path
from datetime import date

ROOT = Path(__file__).resolve().parent.parent
LIBS = ROOT / "libs"

# system dependencies (NOT distributed in this repo; interface-only FFI)
SYSTEM_DEPS = [
    ("OpenBLAS/LAPACK", "BSD-3-Clause (OpenBLAS)", "libs/linalg/linalg.lua links at runtime via FFI; not distributed here"),
    ("HiGHS", "MIT", "libs/optimize/highs.lua links at runtime via FFI; not distributed here"),
]

EMBEDDED_NOTE = ("duckdb-luajit (extension) embeds the Fennel compiler "
                 "(src/embedded/fennel_embedded.c, 1.9MB) — MIT, SPDX header "
                 "preserved. See that repo's SBOM section in README.")


def lib_files():
    return sorted(LIBS.rglob("*.lua"))


def parse_header(text: str):
    h = {}
    for ln in text.split("\n")[:25]:
        m = re.match(r"^--\s*@(\w+):\s*(.*)$", ln)
        if m and m.group(1) not in h:
            h[m.group(1)] = m.group(2).strip()
    return h


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def kind(source: str) -> str:
    if "vendored" in source or "移植" in source or "pinyin-data" in source:
        return "vendored"
    if "cdylib" in source or "usql-bridge" in source:
        return "companion-binary"
    return "original"


def main():
    rows = []
    for f in lib_files():
        h = parse_header(f.read_text(encoding="utf-8"))
        if "lib" not in h:            # helper/test scripts without @lib
            continue
        src = h.get("source", "")
        rows.append({
            "name": h["lib"],
            "category": h.get("category", ""),
            "path": str(f.relative_to(ROOT)),
            "sha256": sha256(f),
            "license": h.get("license", "MIT (duckdb-luajit-libs project)"),
            "source": src or "original (duckdb-luajit series)",
            "requires": h.get("requires", "none"),
            "kind": kind(src),
        })

    # ── SBOM.md ──
    lines = [
        "# SBOM — duckdb-luajit-libs",
        "",
        f"Generated {date.today().isoformat()} by `scripts/gen_sbom.py` (idempotent; regenerate after lib changes).",
        "",
        f"{len(rows)} distributable libraries. Project license: **MIT** (see LICENSE).",
        "",
        "## Vendored / third-party components",
        "",
        "| Component | Library | License | Origin |",
        "|---|---|---|---|",
    ]
    vend = [r for r in rows if r["kind"] != "original"]
    seen = set()
    for r in vend:
        key = (r["name"], r["license"])
        if key in seen:
            continue
        seen.add(key)
        lines.append(f"| `{r['name']}` | {r['path']} | {r['license']} | {r['source']} |")
    if not vend:
        lines.append("| — (none beyond original code) | | | |")

    lines += ["", "## System dependencies (interface-only, NOT distributed)", ""]
    lines += ["| Component | License | Note |", "|---|---|---|"]
    for n, l, note in SYSTEM_DEPS:
        lines.append(f"| {n} | {l} | {note} |")

    lines += ["", "## Full inventory", "",
              "| Lib | Category | Path | SHA-256 | License | Requires |",
              "|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| `{r['name']}` | {r['category']} | `{r['path']}` | `{r['sha256'][:16]}…` | {r['license']} | {r['requires']} |")

    lines += ["", "## Embedded in the companion extension (duckdb-luajit)", "",
              f"- {EMBEDDED_NOTE}", "",
              "## Companion binaries shipped in this repo", "",
              "| Binary | Library | License |", "|---|---|---|"]
    for r in rows:
        if r["kind"] == "companion-binary":
            lines.append(f"| — | `{r['path']}` | {r['license']} |")
    lines += ["| `libs/stats/librng_capi.so` | rng | MIT OR Apache-2.0 (Rust cdylib, sources in repo) |"]

    (ROOT / "SBOM.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    # ── CycloneDX-lite JSON ──
    cdx = {
        "bomFormat": "CycloneDX", "specVersion": "1.5",
        "version": 1,
        "metadata": {"component": {"type": "application",
                                    "name": "duckdb-luajit-libs", "license": {"id": "MIT"}}},
        "components": [
            {"type": "library", "name": r["name"], "purl": f"pkg:github/alitrack/duckdb-luajit-libs@{r['path']}",
             "licenses": [{"license": {"name": r["license"]}}],
             "hashes": [{"alg": "SHA-256", "content": r["sha256"]}]}
            for r in rows
        ] + [
            {"type": "library", "name": n, "licenses": [{"license": {"name": l}}], "scope": "excluded"}
            for n, l, _ in SYSTEM_DEPS
        ],
    }
    (ROOT / "sbom.cdx.json").write_text(json.dumps(cdx, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"SBOM.md + sbom.cdx.json: {len(rows)} components, {len(vend)} vendored/non-original")


if __name__ == "__main__":
    main()
