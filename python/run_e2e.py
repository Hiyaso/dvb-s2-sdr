#!/usr/bin/env python3
"""
run_e2e.py -- end-to-end DVB-S2 (short frame, QPSK/8PSK) simulation with the Python
reference models of this project.  Needs only numpy (matplotlib for --plot).

    TX (dvbs2_ref)  : PRBS -> BBFRAME -> BB scrambler -> BCH -> LDPC -> (8PSK interleaver)
                      -> mapping -> PLHEADER + pilots + PL scrambler -> RRC (2 sps)
    channel         : timing offset (ppm) + fractional delay, CFO, phase, AWGN
    RX (sync_model, frame_model)
                    : RRC matched filter -> Gardner/Farrow timing loop ->
                      header detection, PLS decoding, FLL (3 stages), phase tracking
    FEC             : demapper (bit-exact copy of rtl/rx/rx_demap.v) ->
                      LDPC (ldpc_fixed.py, bit-exact model of the RTL decoder) ->
                      BCH (bch_hw_model.py) -> BB descrambler, CRC-8 -> BER vs. PRBS

Examples
    python3 run_e2e.py                                   # 8PSK 2/3, 9 dB, 1 % CFO, 20 ppm, 30 frames
    python3 run_e2e.py --modcod 4 --esn0 2 --frames 30 --plot e2e.png
    python3 run_e2e.py --modcod 13 --no-pilots --esn0 9
    python3 run_e2e.py --ideal-sync --modcod 4 --sweep 0.2 0.4 0.6 --frames 50   # BER points

MODCOD: 1..10 = QPSK 1/4,1/3,2/5,1/2,3/5,2/3,3/4,4/5,5/6,8/9 ; 12..16 = 8PSK 3/5,2/3,3/4,5/6,8/9
"""
import argparse
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from dvbs2_ref import Transmitter, MODCODS, CODES, rrc_taps, bb_scrambler_seq, crc8  # noqa: E402
from sync_model import channel, TimingLoop                                             # noqa: E402
from frame_model import FrameProc                                                      # noqa: E402
import ldpc_fixed                                                                      # noqa: E402
import bch_hw_model                                                                    # noqa: E402

K8 = np.array([1, 0, 4, 5, 2, 7, 3, 6])          # 8PSK bit pattern -> phase index (pi/4)


# ---------------------------------------------------------------------------- demapper
def _sat7(v):
    return np.clip(v, -63, 63)


def demap_rtl(y, mod, rate, scale_qpsk=24, scale_8psk=16):
    """Soft demapper, bit-exact with rtl/rx/rx_demap.v.  y: data symbols with unit
    radius (as delivered by the frame synchroniser).  Returns 7-bit LLRs in codeword
    order (positive = bit 0)."""
    s = np.clip(np.round(y * 4096), -32767, 32767)
    si = s.real.astype(np.int64)
    sq = s.imag.astype(np.int64)
    if mod == 'QPSK':
        llr = np.empty(2 * len(y), np.int64)
        llr[0::2] = _sat7((si * scale_qpsk) >> 12)
        llr[1::2] = _sat7((sq * scale_qpsk) >> 12)
        return llr
    p1 = ((si + sq) * 23170) >> 15
    p7 = ((si - sq) * 23170) >> 15
    pr = np.stack([si, p1, sq, -p7, -si, -p1, -sq, p7], axis=1)      # Re{y e^{-j k pi/4}}
    n = len(y)
    col = [2, 1, 0] if rate == '3/5' else [0, 1, 2]
    llr = np.empty(3 * n, np.int64)
    for b in range(3):
        bit = (np.arange(8) >> (2 - b)) & 1
        mz = pr[:, K8[bit == 0]].max(axis=1)
        mo = pr[:, K8[bit == 1]].max(axis=1)
        llr[col[b] * n:(col[b] + 1) * n] = _sat7(((mz - mo) * scale_8psk) >> 12)
    return llr


# ---------------------------------------------------------------------------- FEC decoding
_DEC = {}


def fec_decode(y, modcod, max_iter=25, scale_qpsk=24, scale_8psk=16):
    """-> dict(data bits, ldpc iterations, bch corrections (-1 = failure), crc_ok)"""
    mod, rate = MODCODS[modcod]
    kbch, kldpc, _ = CODES[rate]
    llr = demap_rtl(y, mod, rate, scale_qpsk, scale_8psk)
    if rate not in _DEC:
        _DEC[rate] = ldpc_fixed.Decoder(rate)
    hard, it = _DEC[rate].decode(llr, max_iter=max_iter)
    bchcw = hard[:kldpc].astype(np.uint8)
    corr, ncorr = bch_hw_model.decode(bchcw)
    bb = corr[:kbch] ^ bb_scrambler_seq(kbch)
    crc_ok = bool((crc8(bb[:72]) == bb[72:80]).all())
    return dict(data=bb[80:], iters=it, bch=ncorr, crc_ok=crc_ok)


# ---------------------------------------------------------------------------- simulations
def full_chain(a, rng):
    mod, rate = MODCODS[a.modcod]
    tx = Transmitter(a.modcod, a.pilots, a.rolloff)
    frames = [tx.next_frame() for _ in range(a.frames)]
    sym = np.concatenate([f['plframe'] for f in frames])
    h = rrc_taps(a.rolloff, 2, 16)
    up = np.zeros(2 * len(sym), complex)
    up[::2] = sym
    x = np.convolve(up, h)[:len(up)]
    t0 = time.time()
    rx = channel(x, a.esn0, cfo=a.cfo / 2, phase=a.phase, delay=a.delay, ppm=a.ppm, rng=rng)
    z, _ = TimingLoop().run(np.convolve(rx, h))
    fp = FrameProc(n2=a.n2)
    out = fp.run(z)
    t_sync = time.time() - t0
    print('MODCOD %d (%s %s), pilots %s, roll-off %.2f, Es/N0 %.2f dB, CFO %+.4f Rs, %+.0f ppm, %d frames sent'
          % (a.modcod, mod, rate, 'on' if a.pilots else 'off', a.rolloff, a.esn0, a.cfo, a.ppm, a.frames))
    print('synchronisation: %d frames delivered (%.1f s)' % (len(out), t_sync))
    print(' rx#  tx#  FLL  EVM[dB]  LDPC it  BCH  CRC  bit errors')
    rows = []
    for i, fr in enumerate(out):
        if fr['modcod'] != a.modcod:
            print('%4d  wrong MODCOD %d' % (i, fr['modcod']))
            continue
        evm = [np.mean(np.abs(fr['data'] - f['xfec']) ** 2) for f in frames]
        k = int(np.argmin(evm))
        r = fec_decode(fr['data'], a.modcod, a.max_iter)
        nerr = int(np.sum(r['data'] != frames[k]['data']))
        rows.append(dict(rx=i, tx=k, stage=fr['stage'], evm=10 * np.log10(evm[k]), errors=nerr,
                         bits=len(r['data']), y=fr['data'], **{q: r[q] for q in ('iters', 'bch', 'crc_ok')}))
        print('%4d %4d   %d   %6.1f   %5d   %4s  %3s  %d' % (i, k, fr['stage'], rows[-1]['evm'], r['iters'],
              'fail' if r['bch'] < 0 else r['bch'], 'ok' if r['crc_ok'] else 'bad', nerr))
    settled = [r for r in rows if r['rx'] >= a.settle]
    nb = sum(r['bits'] for r in settled)
    ne = sum(r['errors'] for r in settled)
    nf = sum(1 for r in settled if r['errors'])
    true_w = 2 * np.pi * a.cfo
    om = [(l[1], l[4]) for l in fp.log if l[0] == 'frame']
    if om:
        print('frequency: true %+.5f rad/sym, NCO after last frame %+.5f rad/sym' % (true_w, om[-1][1]))
    if nb:
        print('after %d settling frames: %d frames, %d bit errors / %d bits  BER %.2e  FER %.2e'
              % (a.settle, len(settled), ne, nb, ne / nb, nf / max(1, len(settled))))
    return rows, om, true_w


def ideal_sync(a, rng, esn0):
    """Symbol-level AWGN, perfect synchronisation (fast BER points)."""
    mod, rate = MODCODS[a.modcod]
    tx = Transmitter(a.modcod, True, a.rolloff)
    sigma = np.sqrt(10 ** (-esn0 / 10) / 2)
    ne = nb = nf = 0
    its = []
    for _ in range(a.frames):
        f = tx.next_frame()
        y = f['xfec'] + sigma * (rng.standard_normal(len(f['xfec'])) + 1j * rng.standard_normal(len(f['xfec'])))
        r = fec_decode(y, a.modcod, a.max_iter)
        e = int(np.sum(r['data'] != f['data']))
        ne += e
        nb += len(r['data'])
        nf += e > 0
        its.append(r['iters'])
    print('Es/N0 %6.2f dB  frames %4d  bit errors %7d / %9d  BER %.2e  FER %.2e  avg LDPC it %.1f'
          % (esn0, a.frames, ne, nb, ne / nb, nf / a.frames, np.mean(its)))
    return esn0, ne / nb, nf / a.frames


# ---------------------------------------------------------------------------- plot
def plot(path, a, rows, om, true_w):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(2, 2, figsize=(11, 9))
    if rows:
        y = rows[-1]['y']
        ax[0, 0].plot(y.real, y.imag, '.', ms=1, alpha=0.4)
        ax[0, 0].set_aspect('equal')
        ax[0, 0].set_xlim(-1.8, 1.8)
        ax[0, 0].set_ylim(-1.8, 1.8)
    ax[0, 0].set_title('data symbols, last frame (EVM %.1f dB)' % (rows[-1]['evm'] if rows else 0))
    ax[0, 0].grid(alpha=0.3)
    if om:
        ax[0, 1].plot(np.arange(len(om)), [w for _, w in om], 'o-', ms=3, label='NCO')
        ax[0, 1].axhline(true_w, color='k', ls='--', lw=0.8, label='true CFO')
        ax[0, 1].legend()
    ax[0, 1].set_title('frequency estimate (rad/symbol) per frame')
    ax[0, 1].set_xlabel('frame')
    ax[0, 1].grid(alpha=0.3)
    ax[1, 0].plot([r['rx'] for r in rows], [r['evm'] for r in rows], 'o-', ms=3)
    ax[1, 0].set_title('EVM per frame (dB)')
    ax[1, 0].set_xlabel('frame')
    ax[1, 0].grid(alpha=0.3)
    ax[1, 1].bar([r['rx'] for r in rows], [r['iters'] for r in rows], color='tab:gray', label='LDPC iterations')
    bad = [r for r in rows if r['errors']]
    ax[1, 1].plot([r['rx'] for r in bad], [a.max_iter + 1] * len(bad), 'rx', label='frame with bit errors')
    ax[1, 1].set_title('LDPC iterations per frame')
    ax[1, 1].set_xlabel('frame')
    ax[1, 1].legend()
    mod, rate = MODCODS[a.modcod]
    fig.suptitle('DVB-S2 %s %s, Es/N0 %.1f dB, CFO %+.3f Rs, %+.0f ppm' % (mod, rate, a.esn0, a.cfo, a.ppm))
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    print('plot ->', path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--modcod', type=int, default=13)
    ap.add_argument('--no-pilots', dest='pilots', action='store_false')
    ap.add_argument('--rolloff', type=float, default=0.35, choices=[0.35, 0.25, 0.20])
    ap.add_argument('--esn0', type=float, default=9.0, help='Es/N0 in dB')
    ap.add_argument('--cfo', type=float, default=0.01, help='carrier offset as a fraction of Rs')
    ap.add_argument('--ppm', type=float, default=20.0, help='sample clock offset (ppm)')
    ap.add_argument('--phase', type=float, default=1.0, help='carrier phase (rad)')
    ap.add_argument('--delay', type=float, default=0.37, help='fractional delay (samples)')
    ap.add_argument('--frames', type=int, default=30)
    ap.add_argument('--settle', type=int, default=18, help='frames ignored for the BER (FLL settling)')
    ap.add_argument('--n2', type=int, default=12,
                    help='frames in FLL stage 2 before the pilot-aided stage 3 (RTL register default 32)')
    ap.add_argument('--max-iter', type=int, default=25)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--ideal-sync', action='store_true', help='symbol-level AWGN, no synchronisation')
    ap.add_argument('--sweep', type=float, nargs='+', help='Es/N0 list (with --ideal-sync)')
    ap.add_argument('--plot', help='PNG file for constellation / FLL / EVM plots')
    a = ap.parse_args()
    if a.modcod not in MODCODS:
        ap.error('unsupported MODCOD %d' % a.modcod)
    rng = np.random.default_rng(a.seed)
    if a.ideal_sync:
        for e in (a.sweep or [a.esn0]):
            ideal_sync(a, rng, e)
        return
    rows, om, true_w = full_chain(a, rng)
    if a.plot:
        plot(a.plot, a, rows, om, true_w)


if __name__ == '__main__':
    main()
