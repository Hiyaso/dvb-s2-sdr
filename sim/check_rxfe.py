#!/usr/bin/env python3
"""Align the timing-recovery output with the reference PL frames and report EVM.
usage: check_rxfe.py modcod pilots [cfo_rad_per_sym]"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'python'))
from dvbs2_ref import *
mc, pil = int(sys.argv[1]), bool(int(sys.argv[2]))
d = np.loadtxt('rx_syms.txt')
z = d[:, 0] + 1j * d[:, 1]
cfo = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0   # cycles per symbol
z = z * np.exp(-2j * np.pi * cfo * np.arange(len(z)))
print('mean |z| %.0f, final gain %d, mu range %d..%d' % (np.mean(np.abs(z[-5000:])), d[-1, 3], d[-5000:, 2].min(), d[-5000:, 2].max()))
tx = Transmitter(mc, pil, 0.35)
ref = np.concatenate([tx.next_frame()['plframe'] for _ in range(6)])
# find the first data frame header by correlating with its PLHEADER
hdr = ref[:90]
c = np.array([abs(np.vdot(hdr, z[k:k + 90])) if k > 3000 else 0 for k in range(len(z) - 90)])
k0 = int(np.argmax(c > 0.7 * c.max()))
n = min(len(z) - k0, len(ref))
zz = z[k0:k0 + n]; rr = ref[:n]
# piecewise phase removal (blocks of 500) to tolerate CFO / drift
y = np.zeros(n, complex)
for b in range(0, n, 500):
    s = slice(b, min(n, b + 500))
    g = np.vdot(rr[s], zz[s]) / np.vdot(rr[s], rr[s])
    y[s] = zz[s] / g
e = np.abs(y - rr) ** 2
print('header at', k0, 'symbols compared', n, 'EVM dB (after 2000) %.1f' % (10 * np.log10(np.mean(e[2000:]))))
