#!/usr/bin/env python3
"""Regenerate INDEX.v2 (name|path|sha256|version) for all libs in INDEX.

Run from the repo root after adding/changing any lib:

    python3 scripts/gen_index_v2.py

- sha256: of the lib file as-is on disk (bytes)
- version: short sha of the last commit touching the lib file
  (uncommitted changes get the previous commit's sha — commit first!)

Consumed by duckdb-luajit install/upgrade modes (integrity gate).
Legacy 2-column INDEX must be updated separately (it stays authoritative
for old extension versions and the SwanFlow node scanner).
"""
import hashlib
import subprocess
import sys
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    index = root / "INDEX"
    if not index.exists():
        print("INDEX not found — run from repo root", file=sys.stderr)
        return 1

    rows = []
    for line in index.read_text().splitlines():
        if not line.strip():
            continue
        name, path = line.split("|", 1)
        f = root / path
        if not f.exists():
            print(f"SKIP {name}: {path} missing", file=sys.stderr)
            continue
        h = hashlib.sha256(f.read_bytes()).hexdigest()
        ver = subprocess.run(
            ["git", "log", "-1", "--format=%h", "--", path],
            cwd=root, capture_output=True, text=True,
        ).stdout.strip() or "uncommitted"
        rows.append(f"{name}|{path}|{h}|{ver}")

    out = root / "INDEX.v2"
    out.write_text("\n".join(rows) + "\n")
    print(f"{len(rows)} libs -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
