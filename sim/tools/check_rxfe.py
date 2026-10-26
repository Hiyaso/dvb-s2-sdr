#!/usr/bin/env python3
"""Align the timing-recovery output with the reference PL frames, check for symbol slips and report EVM.
usage: check_rxfe.py modcod pilots [cfo_cycles_per_sym] [max_evm_db]
PASS: >= 3 PLHEADERs found, every header exactly one PLFRAME after the previous one (no symbols lost or
added by the timing loop) and EVM <= max_evm_db (default -30)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'python'))
from dvbs2_ref import *
mc, pil = int(sys.argv[1]), bool(int(sys.argv[2]))
cfo = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
max_evm = float(sys.argv[4]) if len(sys.argv) > 4 else -30.0
d = np.loadtxt('rx_syms.txt')
z = d[:, 0] + 1j * d[:, 1]
z = z * np.exp(-2j * np.pi * cfo * np.arange(len(z)))
print('mean |z| %.0f, final gain %d, mu range %d..%d' % (np.mean(np.abs(z[-5000:])), d[-1, 3], d[-5000:, 2].min(), d[-5000:, 2].max()))
tx = Transmitter(mc, pil, 0.35)
ref = [tx.next_frame()['plframe'] for _ in range(6)]
L = len(ref[0])
# PLHEADER search: correlation normalised by the received energy (the AGC start-up transient must not
# set the scale), two halves added non-coherently to tolerate residual CFO
hdr = ref[0][:90]
en = np.convolve(np.abs(z) ** 2, np.ones(90), 'valid')
c = np.abs(np.correlate(z, hdr[:45], 'valid')[:len(en)]) + np.abs(np.correlate(z[45:], hdr[45:], 'valid')[:len(en)])
c = c[:len(en)] / np.sqrt(90 * en[:len(c)] + 1e-9)
pk, k = [], 1000
while k < len(c):
    if c[k] > 0.45:
        k = k + int(np.argmax(c[k:k + 50])); pk.append(k); k += L // 2
    else:
        k += 1
sp = np.diff(pk).tolist()
print('headers at', pk, 'spacing', sp)
# EVM per complete frame against the best-matching reference frame, piecewise gain/phase (blocks of 500)
e = []
for j, h in enumerate(pk):
    if h + L > len(z):
        break
    zz = z[h:h + L]
    err = None
    for rr in ref:
        y = np.zeros(L, complex)
        for b in range(0, L, 500):
            s = slice(b, min(L, b + 500))
            y[s] = zz[s] / (np.vdot(rr[s], zz[s]) / np.vdot(rr[s], rr[s]))
        ei = np.abs(y - rr) ** 2
        if err is None or ei.mean() < err.mean():
            err = ei
    e.append(err[2000:] if j == 0 else err)       # skip the start of the first frame (loops settling)
evm = 10 * np.log10(np.mean(np.concatenate(e))) if e else float('inf')
slips = sum(abs(s - L) for s in sp)
ok = len(pk) >= 3 and slips == 0 and evm <= max_evm
print('frames compared %d, symbols slipped %d, EVM dB %.1f (limit %.1f) %s' % (len(e), slips, evm, max_evm, 'PASS' if ok else 'FAIL'))
