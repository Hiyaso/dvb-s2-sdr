"""
DVB-S2 (ETSI EN 302 307-1) bit-exact reference model -- short FECFRAME, QPSK/8PSK.

This module is the golden model for the Z7020 RTL. Every TX function here is
mirrored by an RTL block and the RTL testbenches compare against it bit by bit.

Conventions
-----------
* Bits are numpy uint8 arrays, element 0 is the first bit transmitted (MSB first).
* Symbols are complex128, unit average energy.
"""
import numpy as np
from dvbs2_ldpc_tables import LDPC_SHORT

NLDPC = 16200
BCH_T = 12
BCH_PARITY = 168        # 14 * t for short frames

# code rate -> (Kbch, Kldpc, q)
CODES = {
    '1/4': (3072, 3240, 36),
    '1/3': (5232, 5400, 30),
    '2/5': (6312, 6480, 27),
    '1/2': (7032, 7200, 25),
    '3/5': (9552, 9720, 18),
    '2/3': (10632, 10800, 15),
    '3/4': (11712, 11880, 12),
    '4/5': (12432, 12600, 10),
    '5/6': (13152, 13320, 8),
    '8/9': (14232, 14400, 5),
}
# Index used by RTL (4-bit code id)
CODE_ID = {r: i for i, r in enumerate(CODES)}
CODE_BY_ID = {i: r for r, i in CODE_ID.items()}

# DVB-S2 MODCOD numbers (Table 12) that we support (short frames)
MODCODS = {
    1: ('QPSK', '1/4'), 2: ('QPSK', '1/3'), 3: ('QPSK', '2/5'), 4: ('QPSK', '1/2'),
    5: ('QPSK', '3/5'), 6: ('QPSK', '2/3'), 7: ('QPSK', '3/4'), 8: ('QPSK', '4/5'),
    9: ('QPSK', '5/6'), 10: ('QPSK', '8/9'),
    12: ('8PSK', '3/5'), 13: ('8PSK', '2/3'), 14: ('8PSK', '3/4'), 15: ('8PSK', '5/6'),
    16: ('8PSK', '8/9'),
}

# ---------------------------------------------------------------------------
# Mode / stream adaptation
# ---------------------------------------------------------------------------

def crc8(bits):
    """CRC-8, g(x)=x^8+x^7+x^6+x^4+x^2+1, init 0, MSB first (EN 302 307 5.1.4)."""
    c = 0
    for b in bits:
        fb = ((c >> 7) & 1) ^ int(b)
        c = (c << 1) & 0xFF
        if fb:
            c ^= 0xD5
    return np.array([(c >> (7 - i)) & 1 for i in range(8)], np.uint8)


def int_to_bits(v, n):
    return np.array([(v >> (n - 1 - i)) & 1 for i in range(n)], np.uint8)


def bits_to_int(b):
    v = 0
    for x in b:
        v = (v << 1) | int(x)
    return v


def bbheader(dfl, rolloff=0.35, matype2=0):
    """80-bit BBHEADER for a Generic Continuous single input stream, CCM."""
    ro = {0.35: 0, 0.25: 1, 0.20: 2}[rolloff]
    # TS/GS=01 (generic continuous), SIS=1, CCM=1, ISSYI=0, NPD=0, RO
    matype1 = (0b01 << 6) | (1 << 5) | (1 << 4) | (0 << 3) | (0 << 2) | ro
    hdr = np.concatenate([int_to_bits(matype1, 8), int_to_bits(matype2, 8),
                          int_to_bits(0, 16),          # UPL (0 for continuous)
                          int_to_bits(dfl, 16),        # DFL
                          int_to_bits(0, 8),           # SYNC
                          int_to_bits(0, 16)])         # SYNCD
    return np.concatenate([hdr, crc8(hdr)])


def bb_scrambler_seq(n):
    """PRBS 1+X^14+X^15, init 100101010000000 (EN 302 307 5.2.2)."""
    sr = 0x4A80
    out = np.zeros(n, np.uint8)
    for i in range(n):
        b = (sr ^ (sr >> 1)) & 1
        out[i] = b
        sr >>= 1
        if b:
            sr |= 0x4000
    return out


def prbs23(n, state=0x7FFFFF):
    """Test-data PRBS x^23+x^18+1 (ITU-T O.151), returns (bits, new_state)."""
    out = np.zeros(n, np.uint8)
    s = state
    for i in range(n):
        b = ((s >> 22) ^ (s >> 17)) & 1
        out[i] = b
        s = ((s << 1) | b) & 0x7FFFFF
    return out, s


def build_bbframe(data_bits, kbch, rolloff=0.35):
    dfl = kbch - 80
    assert len(data_bits) == dfl
    return np.concatenate([bbheader(dfl, rolloff), data_bits]).astype(np.uint8)

# ---------------------------------------------------------------------------
# BCH (short frames: GF(2^14), t=12)
# ---------------------------------------------------------------------------

BCH_SHORT_POLYS = [  # coefficients of x^0..x^14, EN 302 307 Table 6b
    [1, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1],
    [1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 1],
    [1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1],
    [1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 1],
    [1, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1],
    [1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1],
    [1, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1],
    [1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1],
    [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1],
    [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1],
    [1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 0, 0, 1, 1],
]


def _pmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a <<= 1
        b >>= 1
    return r


def _plist_to_int(p):
    return sum(c << i for i, c in enumerate(p))


BCH_GEN_SHORT = 1
for _p in BCH_SHORT_POLYS:
    BCH_GEN_SHORT = _pmul(BCH_GEN_SHORT, _plist_to_int(_p))
assert BCH_GEN_SHORT.bit_length() - 1 == BCH_PARITY


def bch_encode(msg):
    """Systematic BCH: codeword = msg followed by 168 parity bits."""
    g = BCH_GEN_SHORT
    reg = 0  # 168-bit remainder, bit 167 = x^167
    top = 1 << (BCH_PARITY - 1)
    mask = (1 << BCH_PARITY) - 1
    gl = g & mask
    for b in msg:
        fb = ((reg >> (BCH_PARITY - 1)) & 1) ^ int(b)
        reg = (reg << 1) & mask
        if fb:
            reg ^= gl
    par = int_to_bits(reg, BCH_PARITY)
    return np.concatenate([np.asarray(msg, np.uint8), par])

# GF(2^14) with p(x) = 1 + x + x^3 + x^5 + x^14 (the first minimal polynomial)
GF_M = 14
GF_N = (1 << GF_M) - 1
GF_POLY = _plist_to_int(BCH_SHORT_POLYS[0])
GF_EXP = np.zeros(2 * GF_N, np.int64)
GF_LOG = np.zeros(GF_N + 1, np.int64)
_x = 1
for _i in range(GF_N):
    GF_EXP[_i] = _x
    GF_LOG[_x] = _i
    _x <<= 1
    if _x >> GF_M:
        _x ^= GF_POLY
GF_EXP[GF_N:] = GF_EXP[:GF_N]


def gf_mul(a, b):
    if a == 0 or b == 0:
        return 0
    return int(GF_EXP[(GF_LOG[a] + GF_LOG[b]) % GF_N])


def gf_inv(a):
    return int(GF_EXP[(GF_N - GF_LOG[a]) % GF_N])


def bch_syndromes(r):
    """S_j = r(alpha^j), j=1..2t; r[0] is the coefficient of x^(n-1)."""
    S = []
    for j in range(1, 2 * BCH_T + 1):
        s = 0
        aj = int(GF_EXP[j % GF_N])
        for b in r:
            s = gf_mul(s, aj) ^ int(b)
        S.append(s)
    return S


def bch_decode(r):
    """Returns (corrected codeword, n_errors or -1 on failure)."""
    r = np.array(r, np.uint8)
    n = len(r)
    S = bch_syndromes(r)
    if not any(S):
        return r, 0
    # Berlekamp-Massey
    C = [1] + [0] * (2 * BCH_T)
    B = [1] + [0] * (2 * BCH_T)
    L, m, b = 0, 1, 1
    for k in range(2 * BCH_T):
        d = S[k]
        for i in range(1, L + 1):
            d ^= gf_mul(C[i], S[k - i])
        if d == 0:
            m += 1
        elif 2 * L <= k:
            T = C[:]
            coef = gf_mul(d, gf_inv(b))
            for i in range(m, len(C)):
                C[i] ^= gf_mul(coef, B[i - m])
            L, B, b, m = k + 1 - L, T, d, 1
        else:
            coef = gf_mul(d, gf_inv(b))
            for i in range(m, len(C)):
                C[i] ^= gf_mul(coef, B[i - m])
            m += 1
    if L > BCH_T:
        return r, -1
    # Chien search: bit index i (0 = first transmitted) has power p = n-1-i
    roots = []
    for i in range(n):
        p = n - 1 - i
        xinv = int(GF_EXP[(GF_N - p) % GF_N])
        v = 0
        xp = 1
        for c in C[:L + 1]:
            v ^= gf_mul(c, xp)
            xp = gf_mul(xp, xinv)
        if v == 0:
            roots.append(i)
    if len(roots) != L:
        return r, -1
    r[roots] ^= 1
    return r, L

# ---------------------------------------------------------------------------
# LDPC
# ---------------------------------------------------------------------------

def ldpc_params(rate):
    kbch, k, q = CODES[rate]
    return k, NLDPC - k, q


def ldpc_encode(info, rate):
    """EN 302 307 5.3.2: accumulate parity addresses then p_i ^= p_{i-1}."""
    k, m, q = ldpc_params(rate)
    tab = LDPC_SHORT[rate]
    assert len(info) == k and len(tab) * 360 == k
    p = np.zeros(m, np.uint8)
    info = np.asarray(info, np.uint8)
    for g, row in enumerate(tab):
        bits = info[g * 360:(g + 1) * 360]
        mm = np.arange(360)
        for x in row:
            idx = (x + mm * q) % m
            np.bitwise_xor.at(p, idx, bits)
    p = np.bitwise_xor.accumulate(p)
    return np.concatenate([info, p])


def ldpc_edges(rate):
    """Edges (check, var) in natural indexing (var<K info, var>=K parity)."""
    k, m, q = ldpc_params(rate)
    chk, var = [], []
    for g, row in enumerate(LDPC_SHORT[rate]):
        for x in row:
            mm = np.arange(360)
            chk.append((x + mm * q) % m)
            var.append(g * 360 + mm)
    i = np.arange(m)
    chk += [i, i[1:]]
    var += [k + i, k + i[1:] - 1]
    return np.concatenate(chk), np.concatenate(var)


def ldpc_syndrome_ok(cw, rate):
    k, m, q = ldpc_params(rate)
    c, v = ldpc_edges(rate)
    s = np.zeros(m, np.uint8)
    np.bitwise_xor.at(s, c, cw[v])
    return not s.any()


def ldpc_qc_structure(rate):
    """Quasi-cyclic view used by the RTL decoder.

    Variable groups: 0..K/360-1 info, K/360..K/360+q-1 parity groups where parity
    group r holds p_{r+q*c} at position c.  Check layer r holds checks r+q*c at
    position c.  Returns list over layers of [(var_group, shift)] meaning check
    position c connects to variable position (c - shift) mod 360.  The single
    edge from check 0 to the non-existent p_{-1} (layer 0, group G+q-1, shift 1,
    position c=0) is flagged by the caller.
    """
    k, m, q = ldpc_params(rate)
    G = k // 360
    layers = [[] for _ in range(q)]
    for g, row in enumerate(LDPC_SHORT[rate]):
        for x in row:
            layers[x % q].append((g, x // q))
    for r in range(q):
        layers[r].append((G + r, 0))
        if r > 0:
            layers[r].append((G + r - 1, 0))
        else:
            layers[r].append((G + q - 1, 1))
    return layers

# ---------------------------------------------------------------------------
# Bit interleaver + mapping
# ---------------------------------------------------------------------------

def interleave_8psk(cw, rate):
    rows = NLDPC // 3
    cols = cw.reshape(3, rows)        # column c = bits c*rows .. c*rows+rows-1
    order = [2, 1, 0] if rate == '3/5' else [0, 1, 2]
    return np.stack([cols[order[0]], cols[order[1]], cols[order[2]]], axis=1)  # rows x 3


QPSK_PTS = np.exp(1j * np.pi / 4 * np.array([1, 7, 3, 5]))
PSK8_PTS = np.exp(1j * np.pi / 4 * np.array([1, 0, 4, 5, 2, 7, 3, 6]))


def map_symbols(cw, mod, rate):
    if mod == 'QPSK':
        idx = cw[0::2] * 2 + cw[1::2]
        return QPSK_PTS[idx]
    tri = interleave_8psk(cw, rate)
    idx = tri[:, 0] * 4 + tri[:, 1] * 2 + tri[:, 2]
    return PSK8_PTS[idx]

# ---------------------------------------------------------------------------
# PL framing
# ---------------------------------------------------------------------------

SOF_BITS = int_to_bits(0x18D2E82, 26)
PLS_G = [0x55555555, 0x33333333, 0x0F0F0F0F, 0x00FF00FF, 0x0000FFFF, 0xFFFFFFFF]
PLS_SCR = int_to_bits(0x719D83C953422DFA, 64)


def pls_code(modcod, short=True, pilots=True):
    """64-bit PLS code for the 7 bits (MODCOD[4:0], TYPE[1:0])."""
    plsc = (modcod << 2) | ((1 if short else 0) << 1) | (1 if pilots else 0)
    w = 0
    for i in range(6):                       # bits 6..1 -> rows 0..5
        if (plsc >> (6 - i)) & 1:
            w ^= PLS_G[i]
    out = np.zeros(64, np.uint8)
    for mm in range(32):
        out[2 * mm] = (w >> (31 - mm)) & 1
        out[2 * mm + 1] = out[2 * mm] ^ (plsc & 1)
    return out ^ PLS_SCR


def pi2bpsk(bits, start=0):
    """pi/2-BPSK of the PLHEADER: even index e^{j pi/4}, odd e^{j 3pi/4}, bit 1 negates."""
    n = np.arange(len(bits)) + start
    base = np.where(n % 2 == 0, np.exp(1j * np.pi / 4), np.exp(3j * np.pi / 4))
    return base * (1 - 2 * bits.astype(float))


def plheader(modcod, pilots=True):
    bits = np.concatenate([SOF_BITS, pls_code(modcod, True, pilots)])
    return pi2bpsk(bits), bits


def pl_scrambler_rn(n, gold=0):
    """Complex scrambling sequence R_n in {0,1,2,3} (EN 302 307 5.5.4)."""
    x = 1
    y = 0x3FFFF
    for _ in range(gold):
        xb = bin(x & 0x0081).count('1') & 1
        x = (x >> 1) | (xb << 17)
    out = np.zeros(n, np.uint8)
    for i in range(n):
        xa = bin(x & 0x8050).count('1') & 1
        xb = bin(x & 0x0081).count('1') & 1
        xc = x & 1
        ya = bin(y & 0x04A1).count('1') & 1
        yb = bin(y & 0xFF60).count('1') & 1
        yc = y & 1
        x = (x >> 1) | (xb << 17)
        y = (y >> 1) | (ya << 17)
        out[i] = ((xa ^ yb) << 1) | (xc ^ yc)
    return out


PILOT_SYM = np.exp(1j * np.pi / 4)


def frame_layout(mod, pilots):
    """Returns (slots, total symbols incl. header, list of pilot block starts (in
    payload+pilot index space after header))."""
    slots = 90 if mod == 'QPSK' else 60
    pblocks = []
    if pilots:
        n = 0
        for s in range(slots):
            n += 90
            if (s + 1) % 16 == 0 and s < slots - 1:
                pblocks.append(n)
                n += 36
        total = 90 + n
    else:
        total = 90 + slots * 90
    return slots, total, pblocks


def pl_frame(xfec_syms, modcod, pilots=True, gold=0):
    mod, rate = MODCODS[modcod]
    slots, total, _ = frame_layout(mod, pilots)
    hdr, _ = plheader(modcod, pilots)
    body = []
    k = 0
    for s in range(slots):
        body.append(xfec_syms[k:k + 90])
        k += 90
        if pilots and (s + 1) % 16 == 0 and s < slots - 1:
            body.append(np.full(36, PILOT_SYM))
    body = np.concatenate(body)
    rn = pl_scrambler_rn(len(body), gold)
    body = body * (1j ** rn)
    frame = np.concatenate([hdr, body])
    assert len(frame) == total
    return frame

# ---------------------------------------------------------------------------
# Full transmitter (bit level -> PL frame symbols)
# ---------------------------------------------------------------------------

class Transmitter:
    def __init__(self, modcod, pilots=True, rolloff=0.35):
        self.modcod = modcod
        self.mod, self.rate = MODCODS[modcod]
        self.pilots = pilots
        self.rolloff = rolloff
        self.kbch, self.kldpc, self.q = CODES[self.rate]
        self.prbs_state = 0x7FFFFF

    def next_frame(self):
        dfl = self.kbch - 80
        data, self.prbs_state = prbs23(dfl, self.prbs_state)
        bb = build_bbframe(data, self.kbch, self.rolloff)
        bbs = bb ^ bb_scrambler_seq(self.kbch)
        bchcw = bch_encode(bbs)
        cw = ldpc_encode(bchcw, self.rate)
        syms = map_symbols(cw, self.mod, self.rate)
        frame = pl_frame(syms, self.modcod, self.pilots)
        return dict(data=data, bbframe=bb, bbscr=bbs, bch=bchcw, cw=cw,
                    xfec=syms, plframe=frame)

# ---------------------------------------------------------------------------
# RRC
# ---------------------------------------------------------------------------

def rrc_taps(beta, sps=2, span=16):
    n = np.arange(-span * sps // 2, span * sps // 2 + 1) / sps
    h = np.zeros(len(n))
    for i, t in enumerate(n):
        if abs(t) < 1e-12:
            h[i] = 1 - beta + 4 * beta / np.pi
        elif abs(abs(t) - 1 / (4 * beta)) < 1e-9:
            h[i] = beta / np.sqrt(2) * ((1 + 2 / np.pi) * np.sin(np.pi / (4 * beta)) +
                                        (1 - 2 / np.pi) * np.cos(np.pi / (4 * beta)))
        else:
            h[i] = (np.sin(np.pi * t * (1 - beta)) + 4 * beta * t * np.cos(np.pi * t * (1 + beta))) / \
                   (np.pi * t * (1 - (4 * beta * t) ** 2))
    return h / np.sqrt(np.sum(h ** 2))
