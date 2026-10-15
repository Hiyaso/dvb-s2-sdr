"""
dvbs2_pynq.py -- PYNQ (PYNQ-Z2) driver and demo for the DVB-S2 PL loopback.

Copy build/dvbs2_z7020.bit and build/dvbs2_z7020.hwh to the board, then:

    from dvbs2_pynq import DVBS2
    d = DVBS2('dvbs2_z7020.bit')
    d.configure(modcod=13, pilots=True)       # 8PSK 2/3
    d.set_channel(esn0_db=9.0, cfo_rs=0.01, ppm=20)
    d.status()
    d.ber_sweep(13, [6.0, 6.5, 7.0, 7.5, 8.0])
"""
import math
import time

REG = dict(ID=0x000, VERSION=0x004, CTRL=0x008, TXCFG=0x00C, DIV=0x010, CH_PPM=0x014,
           CH_DELAY=0x018, CH_CFO=0x01C, CH_PHASE=0x020, CH_NOISE=0x024, CH_GAIN=0x028,
           RX_AGC=0x030, RX_TIM=0x034, RX_FS=0x038, RX_FLL=0x03C, RX_FEC=0x040)
STAT = dict(STATUS=0x080, OMEGA=0x084, FRAMES=0x088, MISSES=0x08C, PLSFAIL=0x090, GAINS=0x094,
            LDPC_DEC=0x098, LDPC_DROP=0x09C, BCH_CORR=0x0A0, BCH_FAIL=0x0A4, BB_OK=0x0A8,
            BB_CRC=0x0AC, BB_BCHFAIL=0x0B0, BB_INFO=0x0B4, BER_LO=0x0B8, BER_HI=0x0BC,
            BER_ERR=0x0C0, TX_ENC=0x0C4, TX_SENT=0x0C8, TX_DUMMY=0x0CC, TX_UF=0x0D0, PLSQ=0x0D4)
CTRL_TX_EN, CTRL_RX_RST, CTRL_TX_RST, CTRL_CLR, CTRL_BYPASS, CTRL_STREAM, CTRL_PLL, CTRL_AGC, CTRL_ES = \
    [1 << i for i in range(9)]
MODCODS = {1: 'QPSK 1/4', 2: 'QPSK 1/3', 3: 'QPSK 2/5', 4: 'QPSK 1/2', 5: 'QPSK 3/5', 6: 'QPSK 2/3',
           7: 'QPSK 3/4', 8: 'QPSK 4/5', 9: 'QPSK 5/6', 10: 'QPSK 8/9', 12: '8PSK 3/5', 13: '8PSK 2/3',
           14: '8PSK 3/4', 15: '8PSK 5/6', 16: '8PSK 8/9', 0: 'DUMMY'}
FCLK = 100e6


class DVBS2:
    def __init__(self, bitfile=None, base=0x43C00000, mmio=None):
        if mmio is None:
            from pynq import Overlay, MMIO
            if bitfile:
                self.ol = Overlay(bitfile)
            mmio = MMIO(base, 0x1000)
        self.m = mmio
        assert self.rd(REG['ID']) == 0x44564232, 'DVB-S2 core not found'
        self.div = self.rd(REG['DIV'])

    def rd(self, off):
        return self.m.read(off) & 0xFFFFFFFF

    def wr(self, off, v):
        self.m.write(off, int(v) & 0xFFFFFFFF)

    # ------------------------------------------------------------ configuration
    def set_symbol_rate(self, rs_hz):
        """Symbol rate = FCLK / (2*div), div >= 8 (max 6.25 Msym/s).  Returns the actual rate."""
        self.div = max(8, int(round(FCLK / (2 * rs_hz))))
        self.wr(REG['DIV'], self.div)
        return FCLK / (2 * self.div)

    def configure(self, modcod=4, pilots=True, rolloff=0):
        ctrl = CTRL_PLL | CTRL_AGC | CTRL_ES
        self.wr(REG['CTRL'], ctrl | CTRL_TX_RST | CTRL_RX_RST)
        self.wr(REG['TXCFG'], (modcod & 31) | (int(pilots) << 8) | ((rolloff & 3) << 12))
        self.wr(REG['CTRL'], ctrl | CTRL_TX_EN)

    def set_channel(self, esn0_db=None, cfo_rs=0.0, ppm=0.0, delay=0.3, phase=0.0, bypass=False):
        """esn0_db None = no noise; cfo_rs = carrier offset as a fraction of Rs."""
        if esn0_db is None:
            self.wr(REG['CH_NOISE'], 0)
        else:
            sigma = 16384.0 / math.sqrt(2 * 10 ** (esn0_db / 10))
            self.wr(REG['CH_NOISE'], min(65535, int(round(sigma / 0.8165))))
        self.wr(REG['CH_CFO'], int(round(cfo_rs / 2 * 2 ** 32)))
        self.wr(REG['CH_PPM'], int(round(ppm * 1e-6 * 2 ** 32)))
        self.wr(REG['CH_DELAY'], int(delay * 65536) & 0xFFFF)
        self.wr(REG['CH_PHASE'], int(phase / (2 * math.pi) * 65536) & 0xFFFF)
        c = self.rd(REG['CTRL'])
        self.wr(REG['CTRL'], (c | CTRL_BYPASS) if bypass else (c & ~CTRL_BYPASS))

    def restart_rx(self):
        c = self.rd(REG['CTRL'])
        self.wr(REG['CTRL'], c | CTRL_RX_RST)
        self.wr(REG['CTRL'], c & ~CTRL_RX_RST)

    def clear_stats(self):
        self.wr(REG['CTRL'], self.rd(REG['CTRL']) | CTRL_CLR)

    # ------------------------------------------------------------ status
    def status(self, show=True):
        s = self.rd(STAT['STATUS'])
        om = self.rd(STAT['OMEGA'])
        om = om - (1 << 32) if om & (1 << 31) else om
        bits = (self.rd(STAT['BER_HI']) << 32) | self.rd(STAT['BER_LO'])
        st = dict(
            locked=bool(s & 0x10), fs_state=s & 0xF, modcod=MODCODS.get((s >> 5) & 31, '?'),
            pilots=bool((s >> 10) & 1), fll_stage=(s >> 12) & 3, ber_lock=bool((s >> 14) & 1),
            ldpc_iters=(s >> 16) & 63, cfo_rs=om / 2 ** 32,
            frames=self.rd(STAT['FRAMES']), misses=self.rd(STAT['MISSES']),
            ldpc_dec=self.rd(STAT['LDPC_DEC']), ldpc_drop=self.rd(STAT['LDPC_DROP']),
            bch_corr=self.rd(STAT['BCH_CORR']), bch_fail=self.rd(STAT['BCH_FAIL']),
            bb_ok=self.rd(STAT['BB_OK']), bb_crc=self.rd(STAT['BB_CRC']),
            ber_bits=bits, ber_errors=self.rd(STAT['BER_ERR']),
            tx_sent=self.rd(STAT['TX_SENT']), tx_dummy=self.rd(STAT['TX_DUMMY']))
        st['ber'] = st['ber_errors'] / bits if bits else None
        if show:
            print(('LOCK' if st['locked'] else '----'),
                  '{modcod} stage={fll_stage} CFO={cfo_rs:+.5f}Rs frames={frames} '
                  'ldpc dec={ldpc_dec} drop={ldpc_drop} it={ldpc_iters} bch fail={bch_fail} '
                  'bb ok={bb_ok} crc={bb_crc} BER={ber_errors}/{ber_bits}'.format(**st))
        return st

    def ber_sweep(self, modcod, esn0_list, seconds=3, pilots=True, cfo_rs=0.01, ppm=20):
        self.configure(modcod, pilots)
        rows = []
        for e in esn0_list:
            self.set_channel(e, cfo_rs, ppm)
            self.restart_rx()
            t0 = time.time()
            while not (self.rd(STAT['STATUS']) & 0x10) and time.time() - t0 < 2:
                time.sleep(0.05)
            time.sleep(1.0)
            self.clear_stats()
            time.sleep(seconds)
            st = self.status(show=False)
            fer = st['bb_ok'] and (self.rd(STAT['BB_BCHFAIL']) / max(1, st['bb_ok'] + self.rd(STAT['BB_BCHFAIL'])))
            rows.append((e, st['bb_ok'], fer, st['ber']))
            print(f"Es/N0 {e:5.1f} dB  frames ok {st['bb_ok']:6d}  FER {fer:.2e}  BER "
                  f"{st['ber'] if st['ber'] is not None else float('nan'):.2e}")
        return rows


if __name__ == '__main__':
    d = DVBS2('dvbs2_z7020.bit')
    print('symbol rate %.2f Msym/s' % (d.set_symbol_rate(5e6) / 1e6))
    d.configure(13, True)
    d.set_channel(10.0, cfo_rs=0.01, ppm=20)
    for _ in range(5):
        time.sleep(1)
        d.status()
    d.ber_sweep(4, [0.5, 1.0, 1.5, 2.0, 3.0])
