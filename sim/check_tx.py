#!/usr/bin/env python3
"""Compare tb_tx output with the Python reference transmitter."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'python'))
from dvbs2_ref import *

def main(modcod, pilots, ro_idx, d):
    rolloff = [0.35, 0.25, 0.20][ro_idx]
    syms = np.loadtxt(os.path.join(d, 'tx_syms.txt'), dtype=int)
    sof = np.where(syms[:, 0] == 1)[0]
    k = syms[:, 1]
    tx = Transmitter(modcod, pilots, rolloff)
    hdr_d, _ = plheader(0, False)
    ok = True
    nd = nf = 0
    for fi, st in enumerate(sof[:-1]):
        fr = k[st:sof[fi + 1]]
        z = np.exp(1j * np.pi / 4 * fr)
        # dummy?
        dummy_hdr = pi2bpsk(np.concatenate([SOF_BITS, pls_code(0, False, False)]))
        if len(fr) == 90 + 36 * 90 and np.allclose(z[:90], dummy_hdr):
            exp_body = np.full(3240, PILOT_SYM) * (1j ** pl_scrambler_rn(3240))
            if not np.allclose(z[90:], exp_body):
                print('dummy frame', fi, 'MISMATCH'); ok = False
            nd += 1
            continue
        ref = tx.next_frame()['plframe']
        if len(ref) != len(fr) or not np.allclose(ref, z):
            bad = np.where(~np.isclose(ref[:len(z)], z[:len(ref)]))[0]
            print('data frame', fi, 'MISMATCH len', len(fr), len(ref), 'first bad', bad[:10])
            ok = False
        nf += 1
    print(f'frames: data={nf} dummy={nd}')
    # samples: compare with float RRC of the captured symbols
    smp = np.loadtxt(os.path.join(d, 'tx_samples.txt'), dtype=int)
    x = (smp[:, 0] + 1j * smp[:, 1]) / 32768
    s = np.exp(1j * np.pi / 4 * k) * 0.5
    up = np.zeros(2 * len(s), complex); up[::2] = s
    h = rrc_taps(rolloff, 2, 16)
    y = np.convolve(up, h)
    # align: find lag maximizing correlation
    n = min(len(x), len(y)) - 100
    best = max(range(0, 200), key=lambda L: abs(np.vdot(y[:n - 200], x[L:L + n - 200])))
    e = x[best:best + n - 200] - y[:n - 200]
    err = 10 * np.log10(np.mean(np.abs(e[200:]) ** 2) / np.mean(np.abs(y[200:n - 200]) ** 2))
    print(f'sample lag {best}, shaping error {err:.1f} dB')
    if err > -60: ok = False
    print('PASS' if ok else 'FAIL')
    return ok

if __name__ == '__main__':
    mc, pil, ro = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    sys.exit(0 if main(mc, bool(pil), ro, sys.argv[4] if len(sys.argv) > 4 else '.') else 1)
