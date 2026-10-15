#!/usr/bin/env python3
"""ber_sweep.py -- BER/FER curves of the RTL FEC chain (ideal synchronisation).

For every MODCOD: a coarse scan (0.2 dB steps, ~2e5 bits/point) locates the
waterfall, then a fine sweep (0.1 dB steps) runs until a point shows no error
in MAXBITS bits.  Each fine point stops after MAXBITS bits or 50 frame errors
(at least 1e6 bits).  Results: results/ber_m<modcod>.txt
usage: ber_sweep.py [-j 2] [--maxbits 2e7] modcod ...
"""
import argparse, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(HERE, 'obj', 'Vber_dut')
START = {1: -2.6, 2: -1.8, 3: -1.0, 4: -0.4, 5: 1.4, 6: 2.2, 7: 3.0, 8: 3.6, 9: 4.0, 10: 5.2,
         12: 4.6, 13: 5.8, 14: 7.0, 15: 8.2, 16: 10.4}


def run(mc, e0, e1, step, maxbits, maxferr, seed):
    out = subprocess.run([EXE, str(mc), '%.2f' % e0, '%.2f' % e1, '%.2f' % step, '%g' % maxbits,
                          str(maxferr), str(seed), '25'], capture_output=True, text=True, check=True).stdout
    rows = [l.split() for l in out.splitlines() if l.strip() and not l.startswith('#')]
    return out, [(float(r[0]), float(r[7]), float(r[5])) for r in rows]     # EsN0, FER, BER


def sweep(mc, maxbits):
    _, rows = run(mc, START[mc], START[mc] + 4.0, 0.2, 2e5, 20, 700 + mc)
    e_start = next((e for e, fer, _ in rows if fer < 0.95), rows[-1][0]) - 0.1
    out, rows = run(mc, e_start, e_start + 3.0, 0.1, maxbits, 50, mc)
    with open(os.path.join(HERE, 'results', 'ber_m%d.txt' % mc), 'w') as f:
        f.write(out)
    print('modcod %2d done: %s' % (mc, ' '.join('%.1f:%.1e' % (e, b) for e, _, b in rows)), flush=True)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('-j', type=int, default=2)
    ap.add_argument('--maxbits', type=float, default=2e7)
    ap.add_argument('modcods', type=int, nargs='+')
    a = ap.parse_args()
    os.makedirs(os.path.join(HERE, 'results'), exist_ok=True)
    with ThreadPoolExecutor(a.j) as ex:
        list(ex.map(lambda m: sweep(m, a.maxbits), a.modcods))
