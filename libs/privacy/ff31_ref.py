#!/usr/bin/env python3
"""FF3 / FF3-1 reference oracle (pure Python, zero deps).

Implements NIST SP 800-38G FF3 (64-bit tweak) and FF3-1 (56-bit tweak)
following mysto/python-fpe (Apache-2.0) semantics, with a pure-python AES.

Validates against:
  - 3 FIPS-197 AES ECB vectors
  - 15 NIST official FF3 test vectors (SP 800-38G samples, via 0NG repo, MIT)
  - 18 NIST ACVP FF3-1 test vectors (56-bit tweaks, via mysto/python-fpe)

Usage:
  python3 ff31_ref.py              # run all vector checks (exit 1 on any fail)
  python3 ff31_ref.py gen N        # emit N random cases as JSON lines:
                                   # {kind:ff3|ff31, radix, alphabet, key,
                                   #  tweak, pt, ct} for the Lua cross-check
"""
import json
import math
import random
import string
import sys

# ---------------- AES (FIPS-197, pure python) ----------------
def _gf_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xff
        if hi:
            a ^= 0x1b
        b >>= 1
    return p


def _rotl8(v):
    return ((v << 1) | (v >> 7)) & 0xff


def _gen_sbox():
    # multiplicative inverse in GF(2^8) (inv(0)=0), then AES affine transform
    inv = [0] * 256
    for i in range(1, 256):
        x = 1
        for _ in range(254):  # i^254 = i^-1
            x = _gf_mul(x, i)
        inv[i] = x
    out = []
    for i in range(256):
        v = inv[i]
        # FIPS-197: b'_i = b_i ^ b_{i+4} ^ b_{i+5} ^ b_{i+6} ^ b_{i+7} ^ c_i (c=0x63)
        # bit i of rotl_k(v) = bit i-k of v, so b_{i+4..i+7} = rotl4, rotl3, rotl2, rotl1
        acc = v ^ _rotl8(v) ^ _rotl8(_rotl8(v)) \
            ^ _rotl8(_rotl8(_rotl8(v))) ^ _rotl8(_rotl8(_rotl8(_rotl8(v))))
        out.append(acc ^ 0x63)
    return bytes(out)


SBOX = _gen_sbox()
assert SBOX[0] == 0x63 and SBOX[1] == 0x7c and SBOX[0x53] == 0xed, "sbox self-check"
RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else (a << 1) & 0xFF


def _key_expansion(key: bytes):
    nks = {4: 10, 6: 12, 8: 14}
    nk = len(key) // 4
    nr = nks[nk]
    w = [key[4 * i:4 * i + 4] for i in range(nk)]
    for i in range(nk, 4 * (nr + 1)):
        t = bytearray(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = bytearray(SBOX[b] for b in t)
            t[0] ^= RCON[i // nk - 1]
        elif nk == 8 and i % nk == 4:
            t = bytearray(SBOX[b] for b in t)
        w.append(bytes(w[i - nk][j] ^ t[j] for j in range(4)))
    rk = []
    for r in range(nr + 1):
        blk = b"".join(w[r * 4:(r + 1) * 4])
        rk.append(list(blk))
    return rk, nr


def _add_key(st, rk):
    return [st[i] ^ rk[i] for i in range(16)]


def aes_block(key: bytes, block: bytes) -> bytes:
    rk, nr = _key_expansion(key)
    st = _add_key(list(block), rk[0])
    for r in range(1, nr):
        st = [SBOX[b] for b in st]
        st[1], st[5], st[9], st[13] = st[5], st[9], st[13], st[1]
        st[2], st[6], st[10], st[14] = st[10], st[14], st[2], st[6]
        st[3], st[7], st[11], st[15] = st[15], st[3], st[7], st[11]
        for c in range(4):
            a = st[4 * c:4 * c + 4]
            st[4 * c:4 * c + 4] = [
                _xtime(a[0]) ^ _xtime(a[1]) ^ a[1] ^ a[2] ^ a[3],
                a[0] ^ _xtime(a[1]) ^ _xtime(a[2]) ^ a[2] ^ a[3],
                a[0] ^ a[1] ^ _xtime(a[2]) ^ _xtime(a[3]) ^ a[3],
                a[0] ^ a[1] ^ a[2] ^ _xtime(a[0]) ^ _xtime(a[3]),
            ]
        st = _add_key(st, rk[r])
    st = [SBOX[b] for b in st]
    st[1], st[5], st[9], st[13] = st[5], st[9], st[13], st[1]
    st[2], st[6], st[10], st[14] = st[10], st[14], st[2], st[6]
    st[3], st[7], st[11], st[15] = st[15], st[3], st[7], st[11]
    st = _add_key(st, rk[nr])
    return bytes(st)


# ---------------- FF3 / FF3-1 ----------------
BASE62 = string.digits + string.ascii_lowercase + string.ascii_uppercase


# NOTE: the spec uses NUM_radix(Rev(X)) / REV(STR_radix^m(c)) — i.e. the digit
# order is REVERSED relative to the on-wire string. Both helpers below implement
# that convention (mirroring mysto/python-fpe decode_int_r/encode_int_r):
#   _decode(s) = value of s read RIGHT-TO-LEFT  (== standard decode of s[::-1])
#   _encode(n, l) = standard zero-padded numeral of n, then REVERSED
# They are exact inverses on length-l strings.
def _decode(s, alphabet):
    base = len(alphabet)
    n = 0
    for ch in reversed(s):
        n = n * base + alphabet.index(ch)
    return n


def _encode(n, alphabet, length):
    base = len(alphabet)
    digits = []
    while n >= base:
        n, r = divmod(n, base)
        digits.append(r)
    digits.append(n)
    s = "".join(alphabet[d] for d in reversed(digits))  # standard order
    if len(s) < length:
        s = alphabet[0] * (length - len(s)) + s
    return s[::-1]


def _rev(s):
    return s[::-1]


def _calc_p(i, alphabet, W, other):
    P = bytearray(16)
    P[0:4] = W
    P[3] ^= i
    val = _decode(other, alphabet)
    B = val.to_bytes(12, "big")
    P[4:16] = B
    return bytes(P)


def _tweak_expand_56_to_64(t):
    o = bytearray(8)
    o[0:3] = t[0:3]
    o[3] = t[3] & 0xF0
    o[4:7] = t[4:7]
    o[7] = (t[3] & 0x0F) << 4
    return bytes(o)


def ff3_block(key: bytes, tweak: bytes, i: int, m_side, other, enc):
    """Return y for round i. tweak is 8 bytes (already expanded for ff31).
    m_side: 'even' (m=u, use T_R) or 'odd' (m=v, use T_L). enc not needed for y."""
    W = tweak[4:8] if m_side == "even" else tweak[0:4]
    P = _calc_p(i, _ALPH, W, other)
    S = aes_block(key[::-1], P[::-1])[::-1]
    return int.from_bytes(S, "big")


def ff3_ff31(key: bytes, tweak: bytes, s: str, alphabet, enc: bool, ff31: bool):
    global _ALPH
    _ALPH = alphabet
    base = len(alphabet)
    n = len(s)
    u = (n + 1) // 2
    v = n - u
    if ff31:
        assert len(tweak) == 7
        tw = _tweak_expand_56_to_64(tweak)
    else:
        assert len(tweak) == 8
        tw = tweak
    # domain-size / length bounds (FF3-1: base^n >= 1e6; FF3 rev0: same check used here)
    max_len = 2 * int(math.floor(96 / math.log2(base)))
    assert 2 <= n <= max_len, f"length {n} out of [2,{max_len}] for radix {base}"
    mod_u = base ** u
    mod_v = base ** v
    A, B = s[:u], s[u:]
    if enc:
        rng = range(8)
    else:
        rng = range(7, -1, -1)
    for i in rng:
        side = "even" if i % 2 == 0 else "odd"
        mod = mod_u if side == "even" else mod_v
        if enc:
            y = ff3_block(key, tw, i, side, B, True)
            c = (_decode(A, alphabet) + y) % mod
            A, B = B, _encode(c, alphabet, v if side == "odd" else u)
        else:
            # decrypt: y from A (length m), c = dec(B) - y, then A_new = c, B_new = A
            y = ff3_block(key, tw, i, side, A, False)
            c = (_decode(B, alphabet) - y) % mod
            A, B = _encode(c, alphabet, v if side == "odd" else u), A
    return A + B


# ---------------- Test vectors ----------------
AES_VECTORS = [
    # FIPS-197 appendix vectors (key, pt, ct)
    ("2b7e151628aed2a6abf7158809cf4f3c",
     "6bc1bee22e409f96e93d7e117393172a",
     "3ad77bb40d7a3660a89ecaf32466ef97"),
    ("000102030405060708090a0b0c0d0e0f",
     "00112233445566778899aabbccddeeff",
     "69c4e0d86a7b0430d8cdb78070b4c55a"),
    ("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4",
     "00112233445566778899aabbccddeeff",
     "d83414223d20a0c928b136c884d07ea2"),
]

FF3_VECTORS = [
    # NIST SP 800-38G official samples (64-bit tweak)
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A94", "D8E7920AFA330A73",
     "890121234567890000", "750918814058654607"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A94", "9A768A92F60E12D8",
     "890121234567890000", "018989839189395384"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A94", "D8E7920AFA330A73",
     "89012123456789000000789000000", "48598367162252569629397416226"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A94", "0000000000000000",
     "89012123456789000000789000000", "34695224821734535122613701434"),
    (26, "0123456789abcdefghijklmnop", "EF4359D8D580AA4F7F036D6F04FC6A94",
     "9A768A92F60E12D8", "0123456789abcdefghi", "g2pk40i992fn20cjakb"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6",
     "D8E7920AFA330A73", "890121234567890000", "646965393875028755"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6",
     "9A768A92F60E12D8", "890121234567890000", "961610514491424446"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6",
     "D8E7920AFA330A73", "89012123456789000000789000000",
     "53048884065350204541786380807"),
    (10, "0123456789", "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6",
     "0000000000000000", "89012123456789000000789000000",
     "98083802678820389295041483512"),
    (26, "0123456789abcdefghijklmnop",
     "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6", "9A768A92F60E12D8",
     "0123456789abcdefghi", "i0ihe2jfj7a9opf9p88"),
    (10, "0123456789",
     "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6ABF7158809CF4F3C",
     "D8E7920AFA330A73", "890121234567890000", "922011205562777495"),
    (10, "0123456789",
     "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6ABF7158809CF4F3C",
     "9A768A92F60E12D8", "890121234567890000", "504149865578056140"),
    (10, "0123456789",
     "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6ABF7158809CF4F3C",
     "D8E7920AFA330A73", "89012123456789000000789000000",
     "04344343235792599165734622699"),
    (10, "0123456789",
     "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6ABF7158809CF4F3C",
     "0000000000000000", "89012123456789000000789000000",
     "30859239999374053872365555822"),
    (26, "0123456789abcdefghijklmnop",
     "EF4359D8D580AA4F7F036D6F04FC6A942B7E151628AED2A6ABF7158809CF4F3C",
     "9A768A92F60E12D8", "0123456789abcdefghi", "p0b2godfja9bhb7bk38"),
]

A64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
FF31_VECTORS = [
    # NIST ACVP AES-FF3-1 vectors (56-bit tweaks, via mysto/python-fpe, Apache-2.0)
    (10, "0123456789", "2DE79D232DF5585D68CE47882AE256D6", "CBD09280979564",
     "3992520240", "8901801106"),
    (10, "0123456789", "01C63017111438F7FC8E24EB16C71AB5", "C4E822DCD09F27",
     "60761757463116869318437658042297305934914824457484538562",
     "35637144092473838892796702739628394376915177448290847293"),
    (26, "abcdefghijklmnopqrstuvwxyz", "718385E6542534604419E83CE387A437",
     "B6F35084FA90E1", "wfmwlrorcd", "ywowehycyd"),
    (26, "abcdefghijklmnopqrstuvwxyz", "DB602DFF22ED7E84C8D8C865A941A238",
     "EBEFD63BCC2083", "kkuomenbzqvggfbteqdyanwpmhzdmoicekiihkrm",
     "belcfahcwwytwrckieymthabgjjfkxtxauipmjja"),
    (64, A64, "AEE87D0D485B3AFD12BD1E0B9D03D50D", "5F9140601D224B",
     "ixvuuIHr0e", "GR90R1q838"),
    (64, A64, "7B6C88324732F7F4AD435DA9AD77F917", "3F42102C0BAB39",
     "21q1kbbIVSrAFtdFWzdMeIDpRqpo", "cvQ/4aGUV4wRnyO3CHmgEKW5hk8H"),
    (10, "0123456789", "F62EDB777A671075D47563F3A1E9AC797AA706A2D8E02FC8",
     "493B8451BF6716", "4406616808", "1807744762"),
    (10, "0123456789", "0951B475D1A327C52756F2624AF224C80E9BE85F09B2D44F",
     "D679E2EA3054E1",
     "99980459818278359406199791971849884432821321826358606310",
     "84359031857952748660483617398396641079558152339419110919"),
    (26, "abcdefghijklmnopqrstuvwxyz",
     "49CCB8F62D941E5684599ECA0300937B5C766D053E109777", "0BFCF75CDC2FC1",
     "jaxlrchjjx", "kjdbfqyahd"),
    (26, "abcdefghijklmnopqrstuvwxyz",
     "03D253674A9309FF07ED0E71B24CBFE769025E09FCE544D7", "B33176B1DA0F6C",
     "tafzrybuvhiqvcyztuxfnwfprmqlwpayphxbawpl",
     "loaemzbgqkywkdhmncrijzildzleoqibtthdiliv"),
    (64, A64, "1C24B74B7C1B9969314CB53E92F98EFD620D5520017FB076",
     "0380341C425A6F", "6np8r2t8zo", "HgpCXoA1Rt"),
    (64, A64, "C0ABADFC071379824A070E8C3FD40DD9BFD7A3C99A0D5FE3",
     "6C2926C705DDAF", "GKB6sa9g56BSJ09iJ4dsaxRdsMvo",
     "gC0tTSdDPxM79QOWi+z+SNL9C4V+"),
    (10, "0123456789",
     "1FAA03EFF55A06F8FAB3F1DC57127D493E2F8F5C365540467A3A055BDBE6481D",
     "4D67130C030445", "3679409436", "1735794859"),
    (10, "0123456789",
     "9CE16E125BD422A011408EB083355E7089E70A4CD2F59E141D0B94A74BCC5967",
     "4684635BD2C821",
     "85783290820098255530464619643265070052870796363685134012",
     "75104723514036464144839960480545848044718729603261409917"),
    (26, "abcdefghijklmnopqrstuvwxyz",
     "6187F8BDE99F7DAF9E3EE8A8654308E7E51D31FA88AFFAEB5592041C033B736B",
     "5820812B3D5DD1", "mkblaoiyfd", "ifpyiihvvq"),
    (26, "abcdefghijklmnopqrstuvwxyz",
     "F6807FB9688937E4D4956006C8F0CB2394148A5F4B14666CF353F4941428FFD7",
     "30C87B99890096", "wrammvhudopmaazlsxevzwzwpezzmghwfnmkitnk",
     "nzftnfkliuctlmtdfrxfhwgevrbcbgljurnytxkj"),
    (64, A64,
     "9C2B69F7DDF181C54398E345BE04C2F6B00B9DD1679200E1E04C4FF961AE0F09",
     "103C238B4B1E44", "H2/c6FblSA", "EOg4H1bE+8"),
    (64, A64,
     "C58BCBD08B90006CEC7E82B2D987D79F6A21111DEF0CEBB273CBAEB2D6CD4044",
     "7036604882667B", "bz5TcS1krnD8IOLdrQeKzXkLAa6h",
     "Z6x3/9LPW8SZunRezRM8J68Q4J03"),
]

_ALPH = "0123456789"


def run_vectors():
    fail = 0
    print("AES (FIPS-197):")
    for i, (k, p, c) in enumerate(AES_VECTORS):
        got = aes_block(bytes.fromhex(k), bytes.fromhex(p)).hex()
        ok = got == c
        fail += 0 if ok else 1
        print(f"  {'OK ' if ok else 'FAIL'} aes{i} {p[:8]}.. -> {got}")
    print("FF3 (NIST SP 800-38G, 64-bit tweak):")
    for i, (radix, alph, k, t, pt, ct) in enumerate(FF3_VECTORS):
        got = ff3_ff31(bytes.fromhex(k), bytes.fromhex(t), pt, alph, True, False)
        ok = got == ct
        fail += 0 if ok else 1
        print(f"  {'OK ' if ok else 'FAIL'} ff3{i:2d} r={radix} {pt} -> {got}"
              + ("" if ok else f" expect {ct}"))
    print("FF3-1 (NIST ACVP, 56-bit tweak):")
    for i, (radix, alph, k, t, pt, ct) in enumerate(FF31_VECTORS):
        got = ff3_ff31(bytes.fromhex(k), bytes.fromhex(t), pt, alph, True, True)
        ok = got == ct
        fail += 0 if ok else 1
        print(f"  {'OK ' if ok else 'FAIL'} ff31{i:2d} r={radix} {pt} -> {got}"
              + ("" if ok else f" expect {ct}"))
    # decrypt round-trips
    for i, (radix, alph, k, t, pt, ct) in enumerate(FF3_VECTORS):
        got = ff3_ff31(bytes.fromhex(k), bytes.fromhex(t), ct, alph, False, False)
        if got != pt:
            fail += 1
            print(f"  FAIL ff3-decrypt{i} {ct} -> {got} expect {pt}")
    for i, (radix, alph, k, t, pt, ct) in enumerate(FF31_VECTORS):
        got = ff3_ff31(bytes.fromhex(k), bytes.fromhex(t), ct, alph, False, True)
        if got != pt:
            fail += 1
            print(f"  FAIL ff31-decrypt{i} {ct} -> {got} expect {pt}")
    total = 3 + len(FF3_VECTORS) + len(FF31_VECTORS) * 2 + 2 * 0
    print(f"vectors: {total - fail}/{total} pass")
    return fail


def gen_cases(n, seed=20261118):
    rng = random.Random(seed)
    keylens = (32, 48, 64)
    alphas = ["0123456789", "abcdefghijklmnopqrstuvwxyz", A64]
    for _ in range(n):
        kind = "ff31" if rng.random() < 0.6 else "ff3"
        klen = rng.choice(keylens)
        alphabet = rng.choice(alphas)
        radix = len(alphabet)
        # length: within [ceil(log_radix(1e6)), 2*floor(96/log2(radix))] for ff31;
        # ff3 rev0 also requires 2*ceil(u*log2(radix))<=464 etc. — keep both safe:
        max_len = 2 * int(math.floor(96 / math.log2(radix)))
        min_len = 2
        if kind == "ff31":
            min_len = max(min_len, math.ceil(math.log(1_000_000) / math.log(radix)))
        n_len = rng.randint(min_len, max_len)
        pt = "".join(rng.choice(alphabet) for _ in range(n_len))
        key = rng.getrandbits(klen * 8).to_bytes(klen, "big").hex().upper()
        tweak = rng.getrandbits(56).to_bytes(7, "big").hex().upper() if kind == "ff31" \
            else rng.getrandbits(64).to_bytes(8, "big").hex().upper()
        ct = ff3_ff31(bytes.fromhex(key), bytes.fromhex(tweak), pt, alphabet, True,
                      kind == "ff31")
        # verify round-trip in the oracle before emitting
        back = ff3_ff31(bytes.fromhex(key), bytes.fromhex(tweak), ct, alphabet,
                        False, kind == "ff31")
        assert back == pt, f"oracle round-trip failed: {pt} -> {ct} -> {back}"
        print(json.dumps({"kind": kind, "radix": radix, "alphabet": alphabet,
                          "key": key, "tweak": tweak, "pt": pt, "ct": ct}))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "gen":
        gen_cases(int(sys.argv[2]) if len(sys.argv) > 2 else 200)
    else:
        sys.exit(1 if run_vectors() else 0)
