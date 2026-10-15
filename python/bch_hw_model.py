"""Model of the RTL BCH decoder algorithm (bch_dec.v): odd syndromes by Horner,
even syndromes by squaring, simplified inversionless Berlekamp-Massey (t steps),
Chien search over all Nbch positions."""
import numpy as np
from dvbs2_ref import GF_EXP, GF_LOG, GF_N, gf_mul, BCH_T, CODES

T = BCH_T


def gf_pow_alpha(e):
    return int(GF_EXP[e % GF_N])


def syndromes(bits):
    S = [0] * (2 * T + 1)           # S[1..2t]
    for j in range(1, 2 * T, 2):
        aj = gf_pow_alpha(j)
        s = 0
        for b in bits:
            s = gf_mul(s, aj) ^ int(b)
        S[j] = s
    for j in range(2, 2 * T + 1, 2):
        S[j] = gf_mul(S[j // 2], S[j // 2])
    return S


def sibm(S):
    """Simplified inversionless BM for binary BCH: returns (lambda[0..t], L)."""
    lam = [1] + [0] * T
    b = [1] + [0] * T
    gamma = 1
    L = 0
    for r in range(0, 2 * T, 2):
        delta = 0
        for j in range(0, T + 1):
            if r + 1 - j >= 1:
                delta ^= gf_mul(lam[j], S[r + 1 - j])
        xb = [0] + b[:T]
        new = [gf_mul(gamma, lam[j]) ^ gf_mul(delta, xb[j]) for j in range(T + 1)]
        if delta != 0 and 2 * L <= r:
            b = [0] + lam[:T]            # x * lambda_old
            L = r + 1 - L
            gamma = delta
        else:
            b = [0, 0] + b[:T - 1]       # x^2 * B
        lam = new
    return lam, L


def chien(lam, n):
    """Returns list of bit indices (0 = first transmitted) where lambda has a root."""
    terms = [gf_mul(lam[j], gf_pow_alpha(-j * (n - 1))) for j in range(T + 1)]
    pos = []
    for i in range(n):
        s = 0
        for t_ in terms:
            s ^= t_
        if s == 0:
            pos.append(i)
        terms = [gf_mul(terms[j], gf_pow_alpha(j)) for j in range(T + 1)]
    return pos


def decode(bits):
    bits = np.array(bits, np.uint8)
    S = syndromes(bits)
    if not any(S[1:]):
        return bits, 0
    lam, L = sibm(S)
    deg = max(j for j in range(T + 1) if lam[j] != 0)
    pos = chien(lam, len(bits))
    if len(pos) != deg or deg > T:
        return bits, -1
    bits[pos] ^= 1
    return bits, deg


if __name__ == '__main__':
    from dvbs2_ref import bch_encode
    rng = np.random.default_rng(1)
    for rate in ['1/4', '8/9', '1/2']:
        kbch, k, q = CODES[rate]
        for ne in [0, 1, 2, 5, 11, 12, 13, 14, 20]:
            for trial in range(2):
                m = rng.integers(0, 2, kbch).astype(np.uint8)
                c = bch_encode(m)
                r = c.copy()
                pos = rng.choice(k, ne, replace=False)
                r[pos] ^= 1
                d, n = decode(r)
                ok = (d == c).all()
                print(rate, ne, 'ret', n, 'correct' if ok else 'wrong')
