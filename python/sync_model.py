"""
Floating-point algorithm model of the receiver synchronisation chain.

It mirrors the structure of the RTL (rtl/rx/*) so the loop constants and the
frame-sync / carrier-recovery state machines can be designed and checked here:

  samples(2 sps) -> RRC MF -> Farrow + Gardner timing loop -> symbols
  symbols -> differential SOF/PLSC correlator -> frame lock + PLS decode
  symbols -> NCO derotation -> reference blocks (header / pilots) ->
             frequency loop (3 stages) + linear phase interpolation -> LLRs
"""
import numpy as np
from dvbs2_ref import SOF_BITS, PLS_SCR, pls_code, pi2bpsk

# ---------------------------------------------------------------------------
# Channel
# ---------------------------------------------------------------------------

def channel(x, esn0_db, cfo=0.0, phase=0.0, delay=0.0, ppm=0.0, rng=None, sps=2):
    """cfo in cycles/sample, delay in samples (fractional), ppm sample clock offset."""
    rng = rng or np.random.default_rng()
    n = np.arange(len(x))
    if delay or ppm:
        t = n * (1 + ppm * 1e-6) - delay
        # windowed-sinc interpolation
        y = np.zeros(len(x), complex)
        L = 16
        ti = np.floor(t).astype(int)
        fr = t - ti
        for k in range(-L + 1, L + 1):
            idx = ti + k
            ok = (idx >= 0) & (idx < len(x))
            w = np.sinc(fr - k) * (0.54 + 0.46 * np.cos(np.pi * (fr - k) / L))
            y[ok] += x[idx[ok]] * w[ok]
        x = y
    x = x * np.exp(1j * (2 * np.pi * cfo * n + phase))
    # Es = 1 per symbol; with unit-energy RRC and sps samples per symbol the
    # per-sample signal power is 1/sps; noise per sample N0 (MF has unit energy)
    n0 = 10 ** (-esn0_db / 10)
    noise = np.sqrt(n0 / 2) * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
    return x + noise

# ---------------------------------------------------------------------------
# Timing recovery (Gardner + piecewise-parabolic Farrow, 2 sps)
# ---------------------------------------------------------------------------

def farrow_pp(x0, x1, x2, x3, mu, alpha=0.5):
    """Interpolate between x2 (older) and x1 at fraction mu; x0 newest."""
    v2 = alpha * (x0 - x1 - x2 + x3)
    v1 = -alpha * x0 + (1 + alpha) * x1 - (1 - alpha) * x2 - alpha * x3
    return (v2 * mu + v1) * mu + x2


class TimingLoop:
    def __init__(self, bn=None, zeta=0.707, kp=None, k1=-2.0**-7, k2=-2.0**-16):
        # Gardner TED gain for RRC 0.35 at unit symbol energy ~ 2*... measured
        if bn is not None:
            kp = kp if kp is not None else 1.0
            theta = bn / (zeta + 1 / (4 * zeta))
            d = 1 + 2 * zeta * theta + theta ** 2
            k1 = -4 * zeta * theta / d / kp
            k2 = -4 * theta ** 2 / d / kp
        self.k1, self.k2 = k1, k2      # RTL defaults: -2^-7, -2^-16
        self.reset()

    def reset(self):
        self.eta = 0.0
        self.w = 0.5
        self.mu = 0.0
        self.integ = 0.0
        self.hist = [0j, 0j, 0j]
        self.prev_interp = 0j
        self.prev_sym = 0j
        self.mid = 0j

    def run(self, x):
        """Rice, 'Digital Communications: A Discrete-Time Approach', sec. 8.4.4."""
        out = []
        mus = []
        strobe = False
        for s in x:
            x3, x2, x1 = self.hist
            interp = farrow_pp(s, x1, x2, x3, self.mu)
            self.hist = [x2, x1, s]
            if strobe:
                sym = interp
                e = np.real(np.conj(self.prev_interp) * (self.prev_sym - sym))
                self.integ += self.k2 * e
                v = self.k1 * e + self.integ
                self.w = 0.5 + v
                self.prev_sym = sym
                out.append(sym)
                mus.append(self.mu)
            nxt = self.eta - self.w
            if nxt < 0:
                nxt += 1.0
                strobe = True
                self.mu = self.eta / self.w
            else:
                strobe = False
            self.eta = nxt
            self.prev_interp = interp
        return np.array(out), np.array(mus)


# ---------------------------------------------------------------------------
# Frame synchronisation
# ---------------------------------------------------------------------------

HDR_SOF = pi2bpsk(SOF_BITS)
SOF_DIFF = HDR_SOF[1:] * np.conj(HDR_SOF[:-1])                   # 25 values (+-j)
PLSC_PAIR = np.array([1j * (1 - 2 * (int(PLS_SCR[2 * i]) ^ int(PLS_SCR[2 * i + 1])))
                      for i in range(32)])


def header_correlator(z):
    """Returns per-symbol metric arrays computed at the LAST header symbol index."""
    d = np.zeros(len(z), complex)
    d[1:] = z[1:] * np.conj(z[:-1])
    n = len(z)
    A = np.zeros(n, complex)
    B = np.zeros(n, complex)
    for k in range(89, n):
        h0 = k - 89
        A[k] = np.sum(d[h0 + 1:h0 + 26] * np.conj(SOF_DIFF))
        B[k] = np.sum(d[h0 + 27:h0 + 90:2] * np.conj(PLSC_PAIR))
    return A, B, d


class FrameSync:
    """Search -> lock state machine operating on a whole symbol array."""

    def __init__(self, thr=0.4):
        self.thr = thr

    def find(self, z):
        A, B, d = header_correlator(z)
        M = np.maximum(np.abs(A + B), np.abs(A - B))
        P = np.convolve(np.abs(d), np.ones(89), 'full')[:len(z)]
        ratio = M / np.maximum(P * 57 / 89, 1e-9)
        return ratio, A, B

# ---------------------------------------------------------------------------
# Carrier recovery on known frame positions
# ---------------------------------------------------------------------------

def known_header(modcod, pilots):
    sym = pi2bpsk(np.concatenate([SOF_BITS, pls_code(modcod, True, pilots)]))
    return sym
