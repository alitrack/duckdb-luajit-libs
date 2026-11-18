#!/usr/bin/env python3
"""Emit all NIST vectors + random cases as JSON for the Lua cross-check."""
import json, sys
sys.path.insert(0, '/mnt/d/wsl2/duckdb-luajit-libs/libs/privacy')
import importlib.util
spec = importlib.util.spec_from_file_location("ref", "/mnt/d/wsl2/duckdb-luajit-libs/libs/privacy/ff31_ref.py")
ref = importlib.util.module_from_spec(spec)
# prevent __main__ side effects
import types
src = open("/mnt/d/wsl2/duckdb-luajit-libs/libs/privacy/ff31_ref.py").read()
src = src.replace('if __name__ == "__main__":', 'if False:')
exec(compile(src, "ref", "exec"), ref.__dict__)

out = {"vectors": [], "aes": []}
for k, p, c in ref.AES_VECTORS:
    out["aes"].append({"key": k, "pt": p, "ct": c})
for i, (radix, alph, k, t, pt, ct) in enumerate(ref.FF3_VECTORS):
    out["vectors"].append({"kind": "ff3", "i": i, "alphabet": alph, "key": k,
                           "tweak": t, "pt": str(pt), "ct": str(ct)})
for i, (radix, alph, k, t, pt, ct) in enumerate(ref.FF31_VECTORS):
    out["vectors"].append({"kind": "ff31", "i": i, "alphabet": alph, "key": k,
                           "tweak": t, "pt": str(pt), "ct": str(ct)})

# random cross-check cases (oracle-computed, round-trip verified)
import random, math
rng = random.Random(99)
keylens = (16, 24, 32)
alphas = ["0123456789", "abcdefghijklmnopqrstuvwxyz",
          "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"]
randoms = []
for _ in range(400):
    kind = "ff31" if rng.random() < 0.6 else "ff3"
    klen = rng.choice(keylens)
    alphabet = rng.choice(alphas)
    radix = len(alphabet)
    max_len = 2 * int(math.floor(96 / math.log2(radix)))
    min_len = 2
    if kind == "ff31":
        min_len = max(min_len, math.ceil(math.log(1_000_000) / math.log(radix)))
    n_len = rng.randint(min_len, max_len)
    pt = "".join(rng.choice(alphabet) for _ in range(n_len))
    key = rng.getrandbits(klen * 8).to_bytes(klen, "big").hex().upper()
    tweak = (rng.getrandbits(56).to_bytes(7, "big").hex().upper() if kind == "ff31"
             else rng.getrandbits(64).to_bytes(8, "big").hex().upper())
    ct = ref.ff3_ff31(bytes.fromhex(key), bytes.fromhex(tweak), pt, alphabet, True,
                      kind == "ff31")
    back = ref.ff3_ff31(bytes.fromhex(key), bytes.fromhex(tweak), ct, alphabet, False,
                        kind == "ff31")
    assert back == pt, f"oracle round-trip failed: {pt} -> {ct} -> {back}"
    randoms.append({"kind": kind, "alphabet": alphabet, "key": key,
                    "tweak": tweak, "pt": pt, "ct": ct})
out["randoms"] = randoms

with open("/mnt/d/wsl2/win/fpe_cases.json", "w") as f:
    json.dump(out, f)
print(f"vectors={len(out['vectors'])} aes={len(out['aes'])} randoms={len(randoms)}")
