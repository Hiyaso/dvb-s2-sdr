#!/usr/bin/env python3
"""BCH decoder vectors: random BCH codewords with 0..15 bit errors.
usage: gen_bch_vec.py outdir nframes seed"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'python'))
from dvbs2_ref import CODES, CODE_ID, bch_encode
import bch_hw_model as H
out, nfr, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rng = np.random.default_rng(seed)
fi = open(os.path.join(out, 'bch_in.txt'), 'w')
fe = open(os.path.join(out, 'bch_exp.txt'), 'w')
rates = list(CODES)
for f in range(nfr):
    rate = rates[f % len(rates)]
    kbch, k, q = CODES[rate]
    ne = [0, 1, 3, 7, 12, 13, 0, 5, 12, 2, 16, 9][f % 12]
    m = rng.integers(0, 2, kbch).astype(np.uint8)
    c = bch_encode(m)
    r = c.copy()
    if ne:
        r[rng.choice(k, ne, replace=False)] ^= 1
    d, n = H.decode(r)
    fail = 1 if n < 0 else 0
    by = np.packbits(r)
    fi.write(f'F {CODE_ID[rate]} {f} {len(by)}\n' + ' '.join(map(str, by)) + '\n')
    ob = np.packbits(d[:kbch]) if not fail else None
    fe.write(f'F {f} {fail} {0 if fail else n}\n')
    fe.write((' '.join(map(str, ob)) if ob is not None else '-') + '\n')
fi.write('E\n')
