// ber_main.cpp -- BER / FER measurement of the RTL FEC chain (ldpc_dec + bch_dec)
// with Verilator.  The transmitter side (BCH + LDPC encoding, 8PSK interleaving,
// mapping), the AWGN channel and the soft demapper (bit-exact copy of
// rtl/rx/rx_demap.v) are modelled in C++.  Ideal synchronisation is assumed.
//
// usage: Vber_dut modcod esn0_start esn0_stop esn0_step [max_bits] [max_ferr] [seed] [max_iter] [alpha]
#include <verilated.h>
#include "Vber_dut.h"
#include "ber_tables.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <deque>
#include <map>
#include <random>
#include <bitset>

static int modcod_to_code(int mc, bool &is8) {
    is8 = mc >= 12;
    static const int q[] = {-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, 4, 5, 6, 8, 9};
    return (mc >= 1 && mc <= 16) ? q[mc] : -1;
}

struct Frame {
    std::vector<uint8_t> info;          // Kbch bits (what bch_dec outputs)
    std::vector<int8_t>  llr;           // LLR stream in loader order
    std::vector<uint8_t> stream;
};

static std::mt19937_64 rng;

static void bch_encode(const std::vector<uint8_t> &m, std::vector<uint8_t> &cw) {
    std::bitset<168> reg;
    for (uint8_t b : m) {
        int fb = reg[167] ^ b;
        reg <<= 1;
        if (fb) for (int i = 0; i < 168; i++) if (BCH_G[i]) reg.flip(i);
    }
    cw = m;
    for (int i = 167; i >= 0; i--) cw.push_back(reg[i]);
}

static void ldpc_encode(int code, const std::vector<uint8_t> &info, std::vector<uint8_t> &cw) {
    const CodeInfo &ci = CODE_INFO[code];
    int M = 16200 - ci.kldpc;
    std::vector<uint8_t> p(M, 0);
    for (int g = 0; g < ci.ngroups; g++) {
        int r = ci.row_off + g;
        for (int m = 0; m < 360; m++) {
            if (!info[g * 360 + m]) continue;
            for (int j = 0; j < ROW_COUNT[r]; j++) {
                int a = (XTAB[ROW_START[r] + j] + m * ci.q) % M;
                p[a] ^= 1;
            }
        }
    }
    for (int i = 1; i < M; i++) p[i] ^= p[i - 1];
    cw = info;
    cw.insert(cw.end(), p.begin(), p.end());
}

static inline int16_t q16(double v) {
    double s = std::round(v * 4096.0);
    if (s > 32767) s = 32767;
    if (s < -32767) s = -32767;
    return (int16_t)s;
}
static inline int8_t sat7(long v) { return v > 63 ? 63 : (v < -63 ? -63 : (int8_t)v); }
static inline long asr(long v, int s) { return v >= 0 ? (v >> s) : -((-v + (1L << s) - 1) >> s); }

static void make_frame(int code, bool is8, double sigma, Frame &f) {
    const CodeInfo &ci = CODE_INFO[code];
    std::uniform_int_distribution<int> bit(0, 1);
    std::normal_distribution<double> nd(0.0, sigma);
    f.info.resize(ci.kbch);
    for (auto &b : f.info) b = bit(rng);
    std::vector<uint8_t> bch, cw;
    bch_encode(f.info, bch);
    ldpc_encode(code, bch, cw);
    f.llr.clear(); f.stream.clear();
    if (!is8) {
        f.llr.reserve(16200); f.stream.reserve(16200);
        for (int j = 0; j < 8100; j++) {
            double I = (cw[2 * j] ? -1.0 : 1.0) / std::sqrt(2.0) + nd(rng);
            double Q = (cw[2 * j + 1] ? -1.0 : 1.0) / std::sqrt(2.0) + nd(rng);
            long si = q16(I), sq = q16(Q);
            f.llr.push_back(sat7(asr(si * 24, 12))); f.stream.push_back(0);
            f.llr.push_back(sat7(asr(sq * 24, 12))); f.stream.push_back(0);
        }
    } else {
        static const int K8[8] = {1, 0, 4, 5, 2, 7, 3, 6};    // index -> phase k (pi/4)
        bool r35 = (code == 4);
        int col[3] = {r35 ? 2 : 0, 1, r35 ? 0 : 2};
        f.llr.reserve(16200); f.stream.reserve(16200);
        for (int j = 0; j < 5400; j++) {
            int b0 = cw[col[0] * 5400 + j], b1 = cw[col[1] * 5400 + j], b2 = cw[col[2] * 5400 + j];
            int k = K8[(b0 << 2) | (b1 << 1) | b2];
            double I = std::cos(M_PI / 4 * k) + nd(rng), Q = std::sin(M_PI / 4 * k) + nd(rng);
            long si = q16(I), sq = q16(Q);
            // --- bit-exact copy of rx_demap.v (8PSK)
            long sIQ = si + sq, dIQ = si - sq;
            long p1 = asr(sIQ * 23170, 15), p7 = asr(dIQ * 23170, 15);
            long pr[8] = {si, p1, sq, -p7, -si, -p1, -sq, p7};
            for (int b = 0; b < 3; b++) {
                long mz = -131071, mo = -131071;
                for (int x = 0; x < 8; x++) {
                    long v = pr[K8[x]];
                    if (((x >> (2 - b)) & 1) == 0) { if (v > mz) mz = v; }
                    else { if (v > mo) mo = v; }
                }
                f.llr.push_back(sat7(asr((mz - mo) * 16, 12)));
                f.stream.push_back(col[b]);
            }
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s modcod esn0_start esn0_stop esn0_step [max_bits] [max_ferr] [seed] [max_iter]\n", argv[0]);
        return 1;
    }
    int mc = atoi(argv[1]);
    double e0 = atof(argv[2]), e1 = atof(argv[3]), es = atof(argv[4]);
    double max_bits = argc > 5 ? atof(argv[5]) : 2e7;
    int max_ferr = argc > 6 ? atoi(argv[6]) : 50;
    uint64_t seed = argc > 7 ? strtoull(argv[7], 0, 10) : 1;
    int max_iter = argc > 8 ? atoi(argv[8]) : 25;
    int alpha = argc > 9 ? atoi(argv[9]) : 0;          // min-sum alpha numerator /8, 0 = default
    bool is8;
    int code = modcod_to_code(mc, is8);
    if (code < 0) { fprintf(stderr, "unsupported modcod\n"); return 1; }
    const CodeInfo &ci = CODE_INFO[code];
    rng.seed(seed);

    Verilated::commandArgs(argc, argv);
    Vber_dut *d = new Vber_dut;
    auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
    d->rst = 1; d->max_iter = max_iter; d->alpha_ovr = alpha; d->ld_start = 0; d->ld_valid = 0; d->ld_end = 0;
    for (int i = 0; i < 10; i++) tick();
    d->rst = 0;
    for (int i = 0; i < 5; i++) tick();

    printf("# %s %s short frame, Kbch=%d, RTL ldpc_dec(P=45, max_iter=%d, alpha=%d/8%s)+bch_dec, ideal sync\n",
           is8 ? "8PSK" : "QPSK", RATE_NAME[code], ci.kbch, max_iter, alpha, alpha ? "" : " default");
    printf("# EsN0_dB  EbN0_dB  frames  bit_err      bits        BER        frame_err  FER        bch_fail  avg_iter\n");
    fflush(stdout);
    double bits_per_sym = (is8 ? 3.0 : 2.0) * ci.kbch / 16200.0;
    for (double esn0 = e0; esn0 <= e1 + 1e-9; esn0 += es) {
        double sigma = std::sqrt(1.0 / (2.0 * std::pow(10.0, esn0 / 10.0)));
        std::map<int, std::vector<uint8_t>> pend;
        uint64_t nbits = 0, nerr = 0, nfr = 0, nferr = 0, nfail = 0, iters = 0;
        int next_id = 0;
        Frame f;
        bool feeding = false; size_t fi = 0; int phase = 0;
        std::vector<uint8_t> rx; int rx_id = -1;
        bool stop_gen = false;
        uint64_t cyc = 0;
        while (true) {
            // ---- feeder
            d->ld_start = 0; d->ld_valid = 0; d->ld_end = 0;
            if (!feeding && !stop_gen && pend.size() < 3 && d->ld_can_start) {
                make_frame(code, is8, sigma, f);
                pend[next_id & 0xFFFF] = f.info;
                d->ld_start = 1; d->ld_code = code; d->ld_meta = next_id & 0xFFFF;
                next_id++;
                feeding = true; fi = 0; phase = 1;
            } else if (feeding && phase == 1) {
                d->ld_valid = 1; d->ld_stream = f.stream[fi]; d->ld_llr = (uint8_t)(f.llr[fi] & 0x7F);
                if (++fi == f.llr.size()) phase = 2;
            } else if (feeding && phase == 2) {
                d->ld_end = 1; feeding = false; phase = 0;
            }
            tick(); cyc++;
            // ---- collector (outputs after the edge)
            if (d->b_valid) {
                if (d->b_first) { rx.clear(); rx_id = d->b_meta & 0xFFFF; iters += (d->b_meta >> 16) & 63; }
                rx.push_back(d->b_data);
                if (d->b_last) {
                    auto it = pend.find(rx_id);
                    if (it != pend.end()) {
                        const auto &ref = it->second;
                        uint64_t e = 0;
                        for (int i = 0; i < ci.kbch; i++) {
                            int b = (rx[i >> 3] >> (7 - (i & 7))) & 1;
                            e += (b != ref[i]);
                        }
                        nbits += ci.kbch; nerr += e; nfr++; if (e) nferr++;
                        if (d->b_fail) nfail++;
                        pend.erase(it);
                    }
                    if ((nbits >= max_bits) || (nferr >= (uint64_t)max_ferr && nbits >= 1e6)) stop_gen = true;
                    if (stop_gen && pend.empty() && !feeding) break;
                }
            }
            if (stop_gen && pend.empty() && !feeding) break;
        }
        double ber = nbits ? (double)nerr / nbits : 0, fer = nfr ? (double)nferr / nfr : 0;
        printf("%7.2f  %7.2f  %6llu  %9llu  %11llu  %.3e  %6llu     %.3e  %6llu    %.1f\n",
               esn0, esn0 - 10 * std::log10(bits_per_sym), (unsigned long long)nfr, (unsigned long long)nerr,
               (unsigned long long)nbits, ber, (unsigned long long)nferr, fer, (unsigned long long)nfail,
               nfr ? (double)iters / nfr : 0.0);
        fflush(stdout);
        if (nerr == 0 && nbits >= max_bits) break;    // reached the floor of measurability
    }
    delete d;
    return 0;
}
