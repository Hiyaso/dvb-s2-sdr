"""
Bit-exact model of the RTL layered normalized-min-sum LDPC decoder.

Architecture modelled (see rtl/rx/ldpc_dec*.v):
  * P lanes, S = 360/P sub-layers per layer (layer = check group r, 360 checks).
  * Variable memory word (group g, sub-word u) holds positions u + k*S, k=0..P-1.
  * Check sub-layer (r, w) handles checks c = w + k*S of layer r.
  * Input phase per edge e=(g, s):   V2C = satV(Q - Rold),   mag clipped to MAXR
  * CNU: min1, min2, idx, sign product;  Rnew = sign * ((min * 3) >> 2)
  * Output phase per edge (in edge order): Q = satQ(Q + (Rnew - Rold))
    (delta update => duplicate circulants in one layer are handled exactly)
  * Sub-layers are processed strictly sequentially (the RTL enforces this with a
    per-word pending-write scoreboard).
  * Early stop: an iteration in which every check saw even parity of the hard
    decisions it read AND no hard decision changed.
"""
import numpy as np
from dvbs2_ref import CODES, NLDPC, ldpc_qc_structure

QW = 8          # APP (Q) width
RW = 7          # check-to-variable message width
CW = 7          # channel LLR width
QMAX = (1 << (QW - 1)) - 1
RMAX = (1 << (RW - 1)) - 1
CMAX = (1 << (CW - 1)) - 1
ALPHA_NUM, ALPHA_SHIFT = 7, 3   # normalisation factor alpha = ALPHA_NUM/8 (runtime register in RTL)
ALPHA_DEFAULT = {'1/4': 6, '1/3': 6, '2/5': 6}   # must match gen_rtl_roms.py


def sat(x, m):
    return np.clip(x, -m, m)


class Schedule:
    """Per-code processing schedule (what the RTL ROM + address logic produce)."""

    def __init__(self, rate, P=45):
        assert 360 % P == 0
        self.rate, self.P, self.S = rate, P, 360 // P
        S = self.S
        kbch, k, q = CODES[rate]
        self.k, self.q, self.G = k, q, k // 360
        layers = ldpc_qc_structure(rate)
        # order edges in each layer: as listed (info first, then parity)
        self.layers = []
        for r, lay in enumerate(layers):
            edges = []
            seen = {}
            for (g, s) in lay:
                b = s % S
                key = (g, b)
                dup = seen.get(key, 0)
                seen[key] = dup + 1
                special = (r == 0 and g == self.G + q - 1 and s == 1)
                edges.append(dict(g=g, s=s, a=s // S, b=b, dup=dup, special=special))
            self.layers.append(edges)
        self.max_dup = max(e['dup'] for lay in self.layers for e in lay)

    def sublayers(self):
        """Yields (r, w, [(word, rot, dup, mask_lane0)])"""
        S, P = self.S, self.P
        for r, lay in enumerate(self.layers):
            for w in range(S):
                ed = []
                for e in lay:
                    if w >= e['b']:
                        u, rot = w - e['b'], e['a']
                    else:
                        u, rot = w - e['b'] + S, e['a'] + 1
                    rot %= P
                    ed.append((e['g'] * S + u, rot, e['dup'], e['special'] and w == 0))
                yield r, w, ed

    def var_to_word_lane(self, i):
        """Codeword bit index -> (word, lane) in decoder memory."""
        S = self.S
        if i < self.k:
            g, m = divmod(i, 360)
        else:
            j = i - self.k
            r, c = j % self.q, j // self.q
            g, m = self.G + r, c
        return g * S + (m % S), m // S

    def word_lane_maps(self):
        idx = np.arange(NLDPC)
        words = np.zeros(NLDPC, np.int64)
        lanes = np.zeros(NLDPC, np.int64)
        for i in range(NLDPC):
            words[i], lanes[i] = self.var_to_word_lane(i)
        return words, lanes


def rot_read(vec, rot):
    """check lane k <- memory lane (k - rot) mod P"""
    return np.roll(vec, rot)


def rot_write(vec, rot):
    """memory lane j <- check lane (j + rot) mod P"""
    return np.roll(vec, -rot)


class Decoder:
    def __init__(self, rate, P=45):
        self.sch = Schedule(rate, P)
        self.subl = list(self.sch.sublayers())
        self.words, self.lanes = self.sch.word_lane_maps()
        self.nwords = NLDPC // P
        self.n_edges = sum(len(ed) for _, _, ed in self.subl)

    def load(self, llr):
        """llr: int array (codeword order), already saturated to CW bits."""
        P = self.sch.P
        Q = np.zeros((self.nwords, P), np.int64)
        Q[self.words, self.lanes] = llr
        return Q

    def decode(self, llr, max_iter=25, early_stop=True, trace=None, alpha=None):
        P = self.sch.P
        if alpha is None:
            alpha = ALPHA_DEFAULT.get(self.sch.rate, ALPHA_NUM)
        Q = self.load(sat(np.asarray(llr, np.int64), CMAX))
        R = np.zeros((self.n_edges, P), np.int64)
        it_done = 0
        for it in range(max_iter):
            all_ok = True
            changed = False
            ridx = 0
            for (r, w, ed) in self.subl:
                dc = len(ed)
                v2c = np.zeros((dc, P), np.int64)
                hard = np.zeros(P, np.int64)
                rold = R[ridx:ridx + dc]
                for i, (word, rot, dup, msk) in enumerate(ed):
                    q = rot_read(Q[word], rot)
                    x = sat(q - rold[i], QMAX)
                    if msk:
                        x = x.copy(); x[0] = RMAX
                    v2c[i] = x
                    hq = (q < 0).astype(np.int64)
                    if msk:
                        hq[0] = 0
                    hard ^= hq
                if hard.any():
                    all_ok = False
                mag = np.minimum(np.abs(v2c), RMAX)
                sgn = (v2c < 0).astype(np.int64)
                order = np.argsort(mag, axis=0, kind='stable')
                min1 = np.take_along_axis(mag, order[0:1], 0)[0]
                min2 = np.take_along_axis(mag, order[1:2], 0)[0]
                idx1 = order[0]
                # RTL tie rule: first index (lowest edge number) holding min1 wins
                stot = np.bitwise_xor.reduce(sgn, axis=0)
                for i, (word, rot, dup, msk) in enumerate(ed):
                    m = np.where(idx1 == i, min2, min1)
                    m = (m * alpha) >> ALPHA_SHIFT
                    s = stot ^ sgn[i]
                    rn = np.where(s == 1, -m, m)
                    if msk:
                        rn = rn.copy(); rn[0] = 0
                    delta = rn - rold[i]
                    if msk:
                        delta = delta.copy(); delta[0] = 0
                    old = Q[word].copy()
                    Q[word] = sat(Q[word] + rot_write(delta, rot), QMAX)
                    if ((old < 0) != (Q[word] < 0)).any():
                        changed = True
                    R[ridx + i] = rn
                ridx += dc
            it_done = it + 1
            if trace is not None:
                trace.append((it_done, all_ok, changed))
            if early_stop and all_ok and not changed:
                break
        hard = (Q[self.words, self.lanes] < 0).astype(np.uint8)
        return hard, it_done


def check_min_tie_rule():
    """argsort(kind=stable) picks the lowest index among equal minima -> matches RTL
    which updates min1 only on strictly-smaller input."""
    pass
