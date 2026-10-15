#!/usr/bin/env python3
import sys
exp = {}
L = [l.split() for l in open('bch_exp.txt') if l.strip()]
for i in range(0, len(L), 2):
    exp[int(L[i][1])] = (int(L[i][2]), int(L[i][3]), L[i + 1])
got = {}
L = [l.split() for l in open('bch_out.txt') if l.strip()]
for i in range(0, len(L), 2):
    got[int(L[i][1])] = ([int(x) for x in L[i][2:]], int(L[i + 1][1]), int(L[i + 1][2]))
ok = True
for f, (fail, n, by) in exp.items():
    if f not in got: print('missing', f); ok = False; continue
    gb, gf, gn = got[f]
    if gf != fail: print(f'frame {f}: fail exp {fail} got {gf}'); ok = False; continue
    if not fail and (gn != n or gb != [int(x) for x in by]):
        print(f'frame {f}: ncorr exp {n} got {gn}, bytes equal {gb == [int(x) for x in by]}'); ok = False
print('frames', len(exp), 'PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)
