#!/usr/bin/env python3
"""plot_ber.py -- BER curves (results/ber_m*.txt) -> ber_curves.png + summary table.

Points with no bit error are drawn at the 95 % upper bound 3/bits (hollow marker).
"""
import glob, os, re
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
# EN 302 307-1 Table 13: ideal Es/N0 (dB) for QEF, AWGN, *normal* FECFRAME (64800)
ETSI = {1: -2.35, 2: -1.24, 3: -0.30, 4: 1.00, 5: 2.23, 6: 3.10, 7: 4.03, 8: 4.68, 9: 5.18, 10: 6.20,
        12: 5.50, 13: 6.62, 14: 7.91, 15: 9.35, 16: 10.69}
NAME = {1: 'QPSK 1/4', 2: 'QPSK 1/3', 3: 'QPSK 2/5', 4: 'QPSK 1/2', 5: 'QPSK 3/5', 6: 'QPSK 2/3',
        7: 'QPSK 3/4', 8: 'QPSK 4/5', 9: 'QPSK 5/6', 10: 'QPSK 8/9', 12: '8PSK 3/5', 13: '8PSK 2/3',
        14: '8PSK 3/4', 15: '8PSK 5/6', 16: '8PSK 8/9'}


def load(path):
    rows = [l.split() for l in open(path) if l.strip() and not l.startswith('#')]
    a = np.array([[float(r[0]), float(r[1]), float(r[3]), float(r[4]), float(r[6]), float(r[2]), float(r[9])]
                  for r in rows])
    return dict(es=a[:, 0], eb=a[:, 1], err=a[:, 2], bits=a[:, 3], ferr=a[:, 4], fr=a[:, 5], it=a[:, 6])


def summary(mc, d):
    zero = np.where(d['err'] == 0)[0]
    qef = d['es'][zero[0]] if len(zero) else None
    fer = d['ferr'] / d['fr']
    k = np.where((fer[:-1] >= 1e-2) & (fer[1:] < 1e-2))[0]
    f2 = None
    if len(k):
        i = k[0]
        x0, x1 = d['es'][i], d['es'][i + 1]
        y0, y1 = np.log10(fer[i]), np.log10(max(fer[i + 1], 1e-4))
        f2 = x0 + (x1 - x0) * (y0 + 2) / (y0 - y1)
    return dict(mc=mc, name=NAME[mc], fer2=f2, qef=qef, bits=d['bits'][zero[0]] if len(zero) else None,
                etsi=ETSI[mc], it=d['it'][zero[0]] if len(zero) else None)


def main():
    files = sorted(glob.glob(os.path.join(HERE, 'results', 'ber_m*.txt')),
                   key=lambda p: int(re.findall(r'm(\d+)', p)[-1]))
    data = {int(re.findall(r'm(\d+)', p)[-1]): load(p) for p in files}
    fig, ax = plt.subplots(1, 2, figsize=(13, 5.5), sharey=True)
    cm = plt.get_cmap('tab10')
    cnt = {0: 0, 1: 0}
    for mc, d in sorted(data.items()):
        ber = np.where(d['err'] > 0, d['err'] / d['bits'], 3.0 / d['bits'])
        a = ax[0] if mc <= 10 else ax[1]
        c = cm(cnt[mc > 10] % 10)
        cnt[mc > 10] += 1
        a.semilogy(d['es'], ber, '-', color=c, label=NAME[mc])
        nz = d['err'] > 0
        a.semilogy(d['es'][nz], ber[nz], 'o', color=c, ms=4)
        a.semilogy(d['es'][~nz], ber[~nz], 'v', mfc='none', color=c, ms=6)
    for a, t in zip(ax, ('QPSK', '8PSK')):
        a.axhline(1e-6, color='k', ls='--', lw=0.8)
        a.set_xlabel('Es/N0 (dB)')
        a.set_title('DVB-S2 short frame, %s - RTL LDPC (25 it) + BCH' % t)
        a.grid(True, which='both', alpha=0.3)
        a.legend(fontsize=8)
    ax[0].set_ylabel('BER after BCH')
    ax[0].set_ylim(1e-8, 0.2)
    fig.text(0.5, 0.005, 'hollow triangles: no error in N bits (plotted at 3/N, 95% upper bound)',
             ha='center', fontsize=8)
    fig.tight_layout(rect=(0, 0.02, 1, 1))
    fig.savefig(os.path.join(HERE, 'ber_curves.png'), dpi=130)

    lines = ['| MODCOD | FER = 1e-2 (Es/N0 dB) | 0 errors in N bits at (dB) | N bits | avg. iterations | ETSI normal frame QEF (dB) |',
             '|---|---|---|---|---|---|']
    for mc in sorted(data):
        s = summary(mc, data[mc])
        lines.append('| %s | %s | %s | %s | %s | %.2f |' % (
            s['name'], '%.2f' % s['fer2'] if s['fer2'] is not None else '-',
            '%.1f' % s['qef'] if s['qef'] is not None else '-',
            '%.1e' % s['bits'] if s['bits'] is not None else '-',
            '%.1f' % s['it'] if s['it'] is not None else '-', s['etsi']))
    open(os.path.join(HERE, 'ber_summary.md'), 'w').write('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
