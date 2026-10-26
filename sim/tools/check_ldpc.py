#!/usr/bin/env python3
import sys
def load(fn):
    fr = {}
    with open(fn) as f:
        lines = [l.split() for l in f if l.strip()]
    i = 0
    while i < len(lines):
        h = lines[i]; assert h[0] == 'F'
        fr[int(h[1])] = (int(h[2]), [int(x) for x in lines[i + 1]])
        i += 2
    return fr
e = load('ldpc_exp.txt'); o = load('ldpc_out.txt')
ok = True
for k, (it, by) in e.items():
    if k not in o:
        print('frame', k, 'missing'); ok = False; continue
    oit, oby = o[k]
    if oit != it or oby != by:
        nd = sum(a != b for a, b in zip(by, oby))
        print(f'frame {k}: iters exp {it} got {oit}, byte diffs {nd}, len {len(by)} {len(oby)}'); ok = False
print('frames', len(e), 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
