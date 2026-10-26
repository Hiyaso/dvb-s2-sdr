#!/usr/bin/env python3
"""Generate LLR frames + bit-exact expected decoder output for tb_ldpc.
usage: gen_ldpc_vec.py outdir modcod esn0 nframes [max_iter] [seed]"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'python'))
from dvbs2_ref import *
import ldpc_fixed as L

def make(outdir, modcod, es, nfr, max_iter=25, seed=1):
    rng = np.random.default_rng(seed)
    mod, rate = MODCODS[modcod]
    kbch, k, q = CODES[rate]
    dec = L.Decoder(rate, 45)
    fin = open(os.path.join(outdir, 'ldpc_in.txt'), 'w')
    fexp = open(os.path.join(outdir, 'ldpc_exp.txt'), 'w')
    for f in range(nfr):
        msg = rng.integers(0, 2, k).astype(np.uint8)
        cw = ldpc_encode(msg, rate)
        s = map_symbols(cw, mod, rate)
        sig2 = 1 / 10 ** (es / 10)
        y = s + np.sqrt(sig2 / 2) * (rng.standard_normal(len(s)) + 1j * rng.standard_normal(len(s)))
        if mod == 'QPSK':
            llr = np.empty(NLDPC); llr[0::2] = y.real; llr[1::2] = y.imag
            llr = np.clip(np.round(llr * 24), -63, 63).astype(int)
            streams = [(0, v) for v in llr]
        else:
            d = np.abs(y[:, None] - PSK8_PTS[None, :]) ** 2
            l3 = np.zeros((len(y), 3))
            for b in range(3):
                mm = ((np.arange(8) >> (2 - b)) & 1)
                l3[:, b] = d[:, mm == 1].min(1) - d[:, mm == 0].min(1)
            l3 = np.clip(np.round(l3 * 8), -63, 63).astype(int)
            order = [2, 1, 0] if rate == '3/5' else [0, 1, 2]
            rows = NLDPC // 3
            llr = np.empty(NLDPC, int)
            streams = []
            for j in range(rows):
                for b in range(3):
                    llr[order[b] * rows + j] = l3[j, b]
                    streams.append((order[b], l3[j, b]))
        hard, it = dec.decode(llr, max_iter=max_iter)
        tr = []
        fin.write(f'F {CODE_ID[rate]} {f} {len(streams)}\n')
        for st, v in streams:
            fin.write(f'{st} {v}\n')
        # expected: info bits as bytes, iterations
        info = hard[:k]
        by = np.packbits(info)
        fexp.write(f'F {f} {it} {int((info != cw[:k]).sum())}\n')
        fexp.write(' '.join(str(int(b)) for b in by) + '\n')
    fin.write('E\n')
    fin.close(); fexp.close()

if __name__ == '__main__':
    a = sys.argv
    make(a[1], int(a[2]), float(a[3]), int(a[4]), int(a[5]) if len(a) > 5 else 25,
         int(a[6]) if len(a) > 6 else 1)
