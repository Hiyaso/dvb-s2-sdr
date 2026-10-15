/*
 * dvbs2_demo.c -- bare-metal (Vitis "standalone") control program for the
 * DVB-S2 PL loopback (dvbs2_loopback_top).
 *
 *  - configures MODCOD / pilots / roll-off / symbol rate,
 *  - programs the channel emulator (Es/N0, carrier offset, clock offset),
 *  - prints receiver status and a BER / FER sweep over Es/N0 on the UART.
 *
 * Build: create a Vitis platform from build/dvbs2_z7020.xsa, an empty
 * "standalone" C application, add this file, link with -lm.
 */
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include "xil_io.h"
#include "sleep.h"

#ifndef DVBS2_BASE
#define DVBS2_BASE 0x43C00000u          /* address assigned in bd_system.tcl */
#endif
#define FCLK_HZ    100000000.0           /* FCLK_CLK0 */

/* ---- register offsets (z7020/doc/register_map.md) ---- */
#define R_ID        0x000
#define R_VERSION   0x004
#define R_CTRL      0x008
#define R_TXCFG     0x00C
#define R_DIV       0x010
#define R_CH_PPM    0x014
#define R_CH_DELAY  0x018
#define R_CH_CFO    0x01C
#define R_CH_PHASE  0x020
#define R_CH_NOISE  0x024
#define R_CH_GAIN   0x028
#define R_RX_AGC    0x030
#define R_RX_TIM    0x034
#define R_RX_FS     0x038
#define R_RX_FLL    0x03C
#define R_RX_FEC    0x040
#define S_STATUS    0x080
#define S_OMEGA     0x084
#define S_FRAMES    0x088
#define S_MISSES    0x08C
#define S_PLSFAIL   0x090
#define S_GAINS     0x094
#define S_LDPC_DEC  0x098
#define S_LDPC_DROP 0x09C
#define S_BCH_CORR  0x0A0
#define S_BCH_FAIL  0x0A4
#define S_BB_OK     0x0A8
#define S_BB_CRC    0x0AC
#define S_BB_BCHF   0x0B0
#define S_BB_INFO   0x0B4
#define S_BER_LO    0x0B8
#define S_BER_HI    0x0BC
#define S_BER_ERR   0x0C0
#define S_TX_ENC    0x0C4
#define S_TX_SENT   0x0C8
#define S_TX_DUMMY  0x0CC
#define S_TX_UF     0x0D0

#define CTRL_TX_EN      (1u << 0)
#define CTRL_RX_RST     (1u << 1)
#define CTRL_TX_RST     (1u << 2)
#define CTRL_CLR_STATS  (1u << 3)
#define CTRL_CH_BYPASS  (1u << 4)
#define CTRL_SRC_STREAM (1u << 5)
#define CTRL_PLL_EN     (1u << 6)
#define CTRL_AGC_EN     (1u << 7)
#define CTRL_EARLY_STOP (1u << 8)

static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(DVBS2_BASE + off, v); }
static inline uint32_t rd(uint32_t off) { return Xil_In32(DVBS2_BASE + off); }

static unsigned g_div = 10;

static const char *modcod_name(unsigned m)
{
    static const char *n[] = { "DUMMY", "QPSK 1/4", "QPSK 1/3", "QPSK 2/5", "QPSK 1/2", "QPSK 3/5",
        "QPSK 2/3", "QPSK 3/4", "QPSK 4/5", "QPSK 5/6", "QPSK 8/9", "QPSK 9/10(n/a)", "8PSK 3/5",
        "8PSK 2/3", "8PSK 3/4", "8PSK 5/6", "8PSK 8/9" };
    return m <= 16 ? n[m] : "?";
}

/* symbol rate = FCLK / (2 * div) */
static void set_symbol_rate_div(unsigned div)
{
    if (div < 8) div = 8;                        /* hardware minimum: 6.25 Msym/s */
    g_div = div;
    wr(R_DIV, div);
}

/* Es/N0 in dB at the matched-filter output (signal radius 16384 at sig_gain 1.0) */
static void set_esn0(double esn0_db)
{
    if (esn0_db >= 60.0) { wr(R_CH_NOISE, 0); return; }
    double sigma = 16384.0 / sqrt(2.0 * pow(10.0, esn0_db / 10.0));
    double amp = sigma / 0.8165;
    if (amp > 65535.0) amp = 65535.0;
    wr(R_CH_NOISE, (uint32_t)(amp + 0.5));
}

/* carrier frequency offset in units of the symbol rate (e.g. 0.01 = 1 % of Rs) */
static void set_cfo(double frac_of_rs)
{
    double per_sample = frac_of_rs / 2.0;            /* 2 samples per symbol */
    wr(R_CH_CFO, (uint32_t)(int32_t)llround(per_sample * 4294967296.0));
}

/* sampling clock offset in ppm */
static void set_clock_ppm(double ppm)
{
    wr(R_CH_PPM, (uint32_t)(int32_t)llround(ppm * 1e-6 * 4294967296.0));
}

static void configure(unsigned modcod, int pilots, unsigned rolloff)
{
    uint32_t ctrl = CTRL_PLL_EN | CTRL_AGC_EN | CTRL_EARLY_STOP;
    wr(R_CTRL, ctrl | CTRL_TX_RST | CTRL_RX_RST);    /* hold TX/RX in reset */
    wr(R_TXCFG, (modcod & 31) | ((pilots ? 1u : 0u) << 8) | ((rolloff & 3) << 12));
    wr(R_CTRL, ctrl | CTRL_TX_EN);                   /* release, transmit */
}

static void restart_rx(void)
{
    uint32_t c = rd(R_CTRL);
    wr(R_CTRL, c | CTRL_RX_RST);
    wr(R_CTRL, c & ~CTRL_RX_RST);
}

static void clear_stats(void)
{
    wr(R_CTRL, rd(R_CTRL) | CTRL_CLR_STATS);         /* self clearing */
}

static void print_status(void)
{
    uint32_t s = rd(S_STATUS);
    int32_t om = (int32_t)rd(S_OMEGA);
    double cfo_rs = (double)om / 4294967296.0;       /* cycles per symbol */
    uint64_t bits = ((uint64_t)rd(S_BER_HI) << 32) | rd(S_BER_LO);
    uint32_t errs = rd(S_BER_ERR);
    printf("RX: %s state=%lu modcod=%s pilots=%lu FLL-stage=%lu CFO=%+.5f Rs | "
           "frames=%lu miss=%lu | LDPC dec=%lu drop=%lu it=%lu | BCH corr=%lu fail=%lu | "
           "BB ok=%lu crc=%lu | BER %llu/%llu = %.3e\r\n",
           (s & 0x10) ? "LOCK" : "----", (unsigned long)(s & 0xF), modcod_name((s >> 5) & 31),
           (unsigned long)((s >> 10) & 1), (unsigned long)((s >> 12) & 3), cfo_rs,
           (unsigned long)rd(S_FRAMES), (unsigned long)rd(S_MISSES),
           (unsigned long)rd(S_LDPC_DEC), (unsigned long)rd(S_LDPC_DROP), (unsigned long)((s >> 16) & 63),
           (unsigned long)rd(S_BCH_CORR), (unsigned long)rd(S_BCH_FAIL),
           (unsigned long)rd(S_BB_OK), (unsigned long)rd(S_BB_CRC),
           (unsigned long long)errs, (unsigned long long)bits, bits ? (double)errs / (double)bits : 0.0);
}

/* measure for 'seconds' after locking; returns 0 if never locked */
static int measure(double esn0, int seconds)
{
    set_esn0(esn0);
    restart_rx();
    for (int t = 0; t < 20 && !(rd(S_STATUS) & 0x10); t++) usleep(100000);
    sleep(1);                                        /* let the FLL settle */
    uint32_t ok0 = rd(S_BB_OK), bf0 = rd(S_BB_BCHF), dr0 = rd(S_LDPC_DROP);
    clear_stats();
    sleep(seconds);
    uint64_t bits = ((uint64_t)rd(S_BER_HI) << 32) | rd(S_BER_LO);
    uint32_t errs = rd(S_BER_ERR);
    uint32_t ok = rd(S_BB_OK), bf = rd(S_BB_BCHF), dr = rd(S_LDPC_DROP);
    (void)ok0; (void)bf0; (void)dr0;
    printf("  Es/N0 %5.1f dB : frames ok %6lu  BCH fail %5lu  dropped %5lu  BER %.2e (%llu/%llu)\r\n",
           esn0, (unsigned long)ok, (unsigned long)bf, (unsigned long)(dr - dr0),
           bits ? (double)errs / (double)bits : 1.0, (unsigned long long)errs, (unsigned long long)bits);
    return (rd(S_STATUS) & 0x10) != 0;
}

int main(void)
{
    printf("\r\nDVB-S2 PL loopback demo\r\n");
    uint32_t id = rd(R_ID);
    if (id != 0x44564232) {
        printf("ERROR: core not found at 0x%08x (ID=0x%08lx)\r\n", DVBS2_BASE, (unsigned long)id);
        return 1;
    }
    printf("core version 0x%08lx\r\n", (unsigned long)rd(R_VERSION));

    set_symbol_rate_div(10);                         /* 100 MHz / 20 = 5 Msym/s */
    printf("symbol rate %.2f Msym/s\r\n", FCLK_HZ / (2.0 * g_div) / 1e6);
    set_cfo(0.01);                                   /* +1 % of Rs */
    set_clock_ppm(20.0);
    wr(R_CH_DELAY, 0x5000);

    /* 1) quick status at high SNR */
    configure(13, 1, 0);                             /* 8PSK 2/3, pilots, roll-off 0.35 */
    set_esn0(15.0);
    for (int i = 0; i < 5; i++) { sleep(1); print_status(); }

    /* 2) BER sweeps */
    static const struct { unsigned mc; double e0, e1; } sweep[] = {
        { 4, 0.5, 3.0 },        /* QPSK 1/2 */
        { 13, 6.0, 9.0 },       /* 8PSK 2/3 */
    };
    for (unsigned k = 0; k < sizeof(sweep) / sizeof(sweep[0]); k++) {
        printf("\r\nBER sweep %s (pilots on)\r\n", modcod_name(sweep[k].mc));
        configure(sweep[k].mc, 1, 0);
        for (double e = sweep[k].e0; e <= sweep[k].e1 + 1e-9; e += 0.5)
            measure(e, 3);
    }

    /* 3) live status */
    configure(4, 1, 0);
    set_esn0(8.0);
    printf("\r\nlive status (QPSK 1/2, Es/N0 8 dB)\r\n");
    for (;;) { sleep(2); print_status(); }
    return 0;
}
