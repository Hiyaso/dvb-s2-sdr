"""
Algorithm model of rtl/rx/rx_frame.v: frame synchronisation, PLS decoding and
pilot/header-aided carrier recovery on the symbol stream (after timing recovery).

Processing (same structure as the RTL):
  * every incoming symbol is derotated by an NCO (phi += omega); omega only
    changes at frame starts, so it is constant inside a frame,
  * a differential SOF/PLSC correlator detects headers (CFO tolerant) and gives a
    coarse residual frequency (lag-1),
  * PLS decoding is coherent: the header is derotated by the coarse residual plus
    a small grid of frequency hypotheses; phase from the SOF; ML over 128 codes,
  * when the NEXT header of a frame is confirmed the frame is processed:
      - reference blocks (header, pilot blocks, next header) -> phases,
      - FLL: stage 1 lag-1 correlator, stage 2 Luise-Reggiannini (16 lags) on the
        known header, stage 3 phase difference across the frame (pilots on),
      - data symbols: phase linearly interpolated between reference blocks
        (pilots) or header phase + decision-directed PLL (pilots off),
      - PL descrambling and amplitude normalisation.
"""
import numpy as np
from dvbs2_ref import (SOF_BITS, PLS_SCR, pls_code, pi2bpsk, pl_scrambler_rn,
                       MODCODS, PILOT_SYM, QPSK_PTS, PSK8_PTS)

HDR_SOF = pi2bpsk(SOF_BITS)
SOF_DIFF = HDR_SOF[1:] * np.conj(HDR_SOF[:-1])
PLSC_PAIR = np.array([1j * (1 - 2 * (int(PLS_SCR[2 * i]) ^ int(PLS_SCR[2 * i + 1])))
                      for i in range(32)])
GOLD = pl_scrambler_rn(8370)
PLS_TABLE = np.array([pls_code(c >> 2, bool(c & 2), bool(c & 1)) for c in range(128)])
BASE64 = pi2bpsk(np.zeros(64, np.uint8), start=26)
FGRID = 0.02 * np.arange(-4, 5)          # PLS decoding frequency hypotheses (rad/symbol)


def frame_info(modcod, typ):
    """-> (length incl. header, data symbols, pilot block starts, mod) or None"""
    pilots = bool(typ & 1)
    if modcod == 0:
        return 3330, 0, [], None
    if modcod not in MODCODS or not (typ & 2):
        return None
    mod, rate = MODCODS[modcod]
    slots = 90 if mod == 'QPSK' else 60
    pb, n = [], 90
    for s in range(slots):
        n += 90
        if pilots and (s + 1) % 16 == 0 and s < slots - 1:
            pb.append(n)
            n += 36
    return n, slots * 90, pb, mod


def known_header(mc, typ):
    return pi2bpsk(np.concatenate([SOF_BITS, pls_code(mc, bool(typ & 2), bool(typ & 1))]))


class FrameProc:
    def __init__(self, thr_acq=0.55, thr_trk=0.35, n1=2, n2=32, k_acq=0.5, k1=0.5,
                 k2_sched=((4, 0.5), (4, 0.25), (8, 0.125), (16, 1 / 16.)), k3=0.5,
                 pll_k1=2 ** -6, pll_k2=2 ** -12):
        self.thr_acq, self.thr_trk = thr_acq, thr_trk
        self.n1, self.n2 = n1, n2
        self.k_acq, self.k1, self.k3 = k_acq, k1, k3
        self.k2_sched = k2_sched
        self.pll_k1, self.pll_k2 = pll_k1, pll_k2
        self.log = []

    # ------------------------------------------------------------------ helpers
    def ratio(self, A, B, P):
        return max(abs(A + B), abs(A - B)) / max(P, 1e-12)

    def coarse(self, A, B):
        Dp, Dm = A + B, A - B
        return np.angle(Dp if abs(Dp) >= abs(Dm) else Dm)

    def decode_header(self, zp, h, res):
        best = None
        kk = np.arange(90) - 44.5
        for g in FGRID:
            hz = zp[h:h + 90] * np.exp(-1j * (res + g) * kk)
            th = np.angle(np.sum(hz[:26] * np.conj(HDR_SOF)))
            soft = np.real(hz[26:] * np.exp(-1j * th) * np.conj(BASE64))
            corr = PLS_TABLE.astype(float) @ (-2 * soft) + soft.sum()
            b = int(np.argmax(corr))
            q = corr[b] / max(np.abs(soft).sum(), 1e-12)
            if best is None or corr[b] > best[0]:
                best = (corr[b], b, q)
        _, code, q = best
        if q < 0.5:
            return None
        mc, typ = code >> 2, code & 3
        fi = frame_info(mc, typ)
        if fi is None:
            return None
        return mc, typ, fi

    # ------------------------------------------------------------------ main loop
    def run(self, z):
        n = len(z)
        omega, phi = 0.0, 0.0
        self._ld, self._la = 0.0, -1      # last FLL increment and the symbol where it applies
        zp = np.zeros(n, complex)
        d = np.zeros(n, complex)
        A = np.zeros(n, complex); B = np.zeros(n, complex); P = np.zeros(n)
        R = np.zeros(n)
        out = []
        state, H, info, expect, misses, nlock, pending = 'SEARCH', None, None, None, 0, 0, None
        self.pll = [0.0, 0.0]
        for k in range(n):
            if pending is not None and k == pending[0]:
                omega = pending[1]; pending = None
            zp[k] = z[k] * np.exp(-1j * phi)
            phi += omega
            if k >= 1:
                d[k] = zp[k] * np.conj(zp[k - 1])
            if k < 89:
                continue
            h0 = k - 89
            A[k] = np.sum(d[h0 + 1:h0 + 26] * np.conj(SOF_DIFF))
            B[k] = np.sum(d[h0 + 27:h0 + 90:2] * np.conj(PLSC_PAIR))
            P[k] = np.sum(np.abs(d[h0 + 1:h0 + 90])) * 57 / 89
            R[k] = self.ratio(A[k], B[k], P[k])
            if state == 'SEARCH':
                kc = k - 4                       # peak decision delayed by 4 symbols
                if kc >= 93 and R[kc] > self.thr_acq and R[kc] == R[kc - 4:k + 1].max():
                    res = self.coarse(A[kc], B[kc])
                    hdr = self.decode_header(zp, kc - 89, res)
                    omega += self.k_acq * res
                    self._ld, self._la = 0.0, -1
                    if hdr is not None:
                        H, info = kc - 89, hdr
                        expect, state, nlock, misses = H + hdr[2][0] + 89, 'TRACK', 0, 0
                        self.log.append(('acq', kc, hdr[0], hdr[1], res))
            else:
                if k == expect + 2:
                    # best of expect-2 .. expect+2 (tolerates timing slips)
                    cand = int(np.argmax(R[expect - 2:expect + 3])) + expect - 2
                    if R[cand] > self.thr_trk:
                        res = self.coarse(A[cand], B[cand])
                        # tracking: residual is small, search around zero
                        hdr = self.decode_header(zp, cand - 89, 0.0)
                        if hdr is None:
                            hdr = self.decode_header(zp, cand - 89, res)
                        if hdr is None:
                            misses += 1
                            self.log.append(('plsfail', cand, R[cand], res))
                        else:
                            misses = 0
                            Hn = cand - 89
                            fr, new_omega = self.process_frame(zp, H, info, Hn, hdr, res, omega, nlock)
                            if fr is not None:
                                out.append(fr)
                            nlock += 1
                            pending = (Hn + hdr[2][0], new_omega)
                            self._ld, self._la = new_omega - omega, Hn + hdr[2][0]
                            H, info = Hn, hdr
                            expect = Hn + hdr[2][0] + 89
                            continue
                    else:
                        misses += 1
                        self.log.append(('lowcorr', expect, R[expect - 2:expect + 3].max()))
                    self.log.append(('miss', k))
                    if misses >= 3:
                        state = 'SEARCH'
                    else:
                        H = H + info[2][0]
                        expect = H + info[2][0] + 89
        return out

    # ------------------------------------------------------------------ frame
    def process_frame(self, zp, H, info, Hn, ninfo, nres, omega, nlock):
        mc, typ, fi = info
        L, ndata, pblocks, mod = fi
        hk = known_header(mc, typ)
        u = zp[H:H + 90] * np.conj(hk)                    # modulation removed
        blocks = [(H + 44.5, np.sum(u))]
        for pbs in pblocks:
            gi = pbs - 90
            known = PILOT_SYM * (1j ** GOLD[gi:gi + 36])
            blocks.append((H + pbs + 17.5, np.sum(zp[H + pbs:H + pbs + 36] * np.conj(known))))
        hk2 = known_header(ninfo[0], ninfo[1])
        blocks.append((Hn + 44.5, np.sum(zp[Hn:Hn + 90] * np.conj(hk2))))
        th = [np.angle(blocks[0][1])]
        for b in range(1, len(blocks)):
            th.append(th[-1] + np.angle(blocks[b][1] * np.conj(blocks[b - 1][1])))
        # FLL
        lr = sum(np.sum(u[m:] * np.conj(u[:-m])) for m in range(1, 17))
        e2 = np.angle(lr) / 8.5                     # Luise-Reggiannini, N = 16
        e3 = (th[-1] - th[0]) / (blocks[-1][0] - blocks[0][0])
        pilots = len(pblocks) > 0
        # loop-delay compensation: header/body of this frame were derotated before
        # the previous update took effect
        sub = self._ld if H < self._la else 0.0
        if nlock < self.n1:
            new_omega, stage = omega + self.k1 * nres, 1
        elif nlock < self.n1 + self.n2 or not pilots:
            j = nlock - self.n1
            k2 = self.k2_sched[-1][1]
            acc = 0
            for cnt, kk in self.k2_sched:
                if j < acc + cnt:
                    k2 = kk
                    break
                acc += cnt
            new_omega, stage = omega + k2 * (e2 - sub), 2
        else:
            new_omega, stage = omega + self.k3 * (e3 - sub), 3
        self.log.append(('frame', H, mc, stage, omega, e2, e3, nres))
        if mc == 0:
            return None, new_omega
        amp = abs(blocks[0][1]) / 90
        # data symbols
        pos = []
        kpos = 90
        while kpos < L:
            if kpos in pblocks:
                kpos += 36
                continue
            pos.append(kpos)
            kpos += 1
        pos = np.array(pos)
        absn = H + pos
        gidx = pos - 90
        if pilots:
            centers = np.array([bl[0] for bl in blocks])
            thi = np.interp(absn, centers, th)
            y = zp[absn] * np.exp(-1j * thi) * (1j ** (-GOLD[gidx].astype(int))) / amp
        else:
            # header phase + decision-directed PLL
            pts = QPSK_PTS if mod == 'QPSK' else PSK8_PTS
            y = np.zeros(len(pos), complex)
            thp, nu = th[0], 0.0
            for i, an in enumerate(absn):
                v = zp[an] * np.exp(-1j * thp) * (1j ** (-int(GOLD[gidx[i]]))) / amp
                y[i] = v
                dec = pts[np.argmin(np.abs(pts - v))]
                e = np.imag(v * np.conj(dec))
                nu += self.pll_k2 * e
                thp += self.pll_k1 * e + nu
        return dict(modcod=mc, typ=typ, data=y, H=H, stage=stage), new_omega
