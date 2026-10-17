//
// dvbs2_adrv -- ARM (Linux) side of the DVB-S2 modem in the ADRV9364-Z7020 FPGA.
//
//   * modem registers and payload FIFOs over AXI-Lite (/dev/mem, 0x44A00000, see
//     adrv9364/rtl/dvbs2_adrv.v); spectrum from the FPGA snapshot (1024 ADC samples)
//   * AD9364 (ad9361-phy, sysfs + libad9361 for the sample rate): LO frequencies, gains,
//     analog bandwidth; one sample rate for TX and RX = 2 x symbol rate
//   * TX payload: PRBS-23 (FPGA), a file / stdin, or UDP datagrams (--udp-in, framed as in
//     udp_frame.hpp); RX payload: PRBS BER check, a file / stdout, or UDP (--udp-out)
//   * --web PORT: web page (status, spectrum, RF and modem settings, PRBS / UDP mode,
//     file loopback), settings can be saved to the configuration file
//
// Runs on the SOM (Kuiper Linux, as root).  Options come from the command line and
// from --config FILE (key = value, same names as the long options).
//
//   dvbs2_adrv --config /etc/dvbs2.conf            (service: web page + UDP link)
//   dvbs2_adrv --mode tx --freq 2.45e9 --rs 1e6 --udp-in 0.0.0.0:5000
//   dvbs2_adrv --mode rx --freq 2.45e9 --rs 1e6 --udp-out 192.168.30.255:5001
//
#include <arpa/inet.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include "udp_frame.hpp"

// ---------------------------------------------------------------- modem registers
enum : uint32_t {
    REG_CTRL = 0, REG_TXCFG = 1, REG_AGC = 2, REG_TIM = 3, REG_FS = 4, REG_FLL = 5, REG_FEC = 6, REG_CLR = 7,
    REG_CAP = 8
};
enum : uint32_t {
    CTRL_TX_EN = 1u << 0, CTRL_RX_EN = 1u << 1, CTRL_TX_DATA = 1u << 2, CTRL_RX_DATA = 1u << 3,
    CTRL_PLL = 1u << 6, CTRL_AGC = 1u << 7, CTRL_ES = 1u << 8
};
static const uint32_t MODEM_ID   = 0x44564232;   // "DVB2"
static const off_t MODEM_BASE    = 0x44A00000;   // AXI-Lite slave of dvbs2_adrv
static const off_t AD9361_DAC    = 0x79024000;   // axi_ad9361 DAC registers
static const int CAP_N           = 1024;         // spectrum snapshot length (samples)
static const double CLK_HZ       = 100e6;        // modem clock (sys_cpu_clk)
static const double FS_MIN       = 520834;       // AD9364 with 4x FIR decimation / interpolation
static const double FS_MAX       = CLK_HZ / 8;   // >= 8 modem clocks per sample
static const uint32_t TXW_DEPTH  = 4097;         // TX payload FIFO (words)

struct Mmio {
    volatile uint32_t* p = nullptr;
    size_t len = 0;
    bool open(off_t base, size_t n)
    {
        int fd = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (fd < 0) return false;
        void* m = mmap(nullptr, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
        ::close(fd);
        if (m == MAP_FAILED) return false;
        p   = (volatile uint32_t*)m;
        len = n;
        return true;
    }
    uint32_t rd(uint32_t off) const { return p[off / 4]; }
    void wr(uint32_t off, uint32_t v) { p[off / 4] = v; }
};

#ifdef DVBS2_MOCK
// Software model of the FPGA for testing the program on a PC (build.sh MOCK=1): the TX
// payload FIFO feeds BBFRAME data fields (DFL/8 bytes, at the frame rate of the MODCOD at
// Fs = 2 MS/s) straight into the RX frame FIFO, like an error-free radio link.
struct Modem {
    Mmio m;
    std::mutex mx;
    std::deque<uint8_t> txq;
    std::deque<std::vector<uint8_t>> rxf;
    std::vector<uint8_t> cur;
    size_t cur_pos = 0;
    uint32_t ctrl = 0, txcfg = 0, frames = 0;
    std::thread th;
    std::atomic<bool> quit{false};
    Modem()
    {
        // like tx_bbframe: the frame being built takes bytes from the FIFO at the byte rate
        // (DFL/8 bytes per frame time at Rs = 1 Msym/s) and stalls while the FIFO is empty
        th = std::thread([this] {
            std::vector<uint8_t> f;
            double budget = 0;
            while (!quit) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                int mc = txcfg & 31, kb = 0;
                static const int kq[] = {0, 3072, 5232, 6312, 7032, 9552, 10632, 11712, 12432, 13152, 14232, 0,
                    9552, 10632, 11712, 13152, 14232};
                if (mc >= 1 && mc <= 16) kb = kq[mc];
                const size_t dfl = kb > 80 ? size_t(kb - 80) / 8 : 0;
                const double tf  = (mc >= 12 ? 5598.0 : 8370.0) / 1e6;
                std::lock_guard<std::mutex> l(mx);
                if (!(ctrl & CTRL_TX_EN) || !(ctrl & CTRL_TX_DATA) || !dfl) {
                    f.clear();
                    budget = 0;
                    continue;
                }
                budget = std::min(budget + double(dfl) * 1e-3 / tf, double(dfl));
                while (budget >= 1 && !txq.empty()) {
                    f.push_back(txq.front());
                    txq.pop_front();
                    budget -= 1;
                    if (f.size() == dfl) {
                        frames++;
                        if ((ctrl & CTRL_RX_EN) && (ctrl & CTRL_RX_DATA) && rxf.size() < 9) rxf.push_back(f);
                        f.clear();
                    }
                }
            }
        });
    }
    ~Modem()
    {
        quit = true;
        th.join();
    }
    void wr(uint32_t reg, uint32_t v)
    {
        std::lock_guard<std::mutex> l(mx);
        if (reg == REG_CTRL) {
            if (!(v & CTRL_TX_EN)) txq.clear();
            if (!(v & CTRL_RX_EN)) rxf.clear(), cur.clear(), cur_pos = 0;
            ctrl = v;
        }
        if (reg == REG_TXCFG) txcfg = v;
    }
    std::vector<uint32_t> status()
    {
        std::lock_guard<std::mutex> l(mx);
        std::vector<uint32_t> s(64);
        s[0]  = ((ctrl & CTRL_RX_EN) ? 1u << 4 : 0u) | ((txcfg & 31) << 5) | ((txcfg >> 8 & 1) << 10) | (3u << 12);
        s[10] = s[18] = frames;
        s[13] = (txcfg & 31) ? 0 : 0;
        s[30] = MODEM_ID;
        s[31] = 0x00030000;
        s[29] = 1u << 31;
        return s;
    }
    uint32_t levels()
    {
        std::lock_guard<std::mutex> l(mx);
        const uint32_t used = uint32_t(txq.size() / 4);
        return ((ctrl & CTRL_TX_EN) ? (TXW_DEPTH - std::min(used, TXW_DEPTH)) << 16 : 0u);
    }
    void tx_word(uint32_t w)
    {
        std::lock_guard<std::mutex> l(mx);
        if (txq.size() / 4 >= TXW_DEPTH || !(ctrl & CTRL_TX_EN)) return;
        for (int b = 0; b < 4; b++) txq.push_back(uint8_t(w >> (8 * b)));
    }
    uint32_t rx_len()
    {
        std::lock_guard<std::mutex> l(mx);
        if (rxf.empty()) return 0;
        cur = rxf.front();
        rxf.pop_front();
        cur_pos = 0;
        return 0x80000000u | uint32_t(cur.size());
    }
    uint32_t rx_word()
    {
        std::lock_guard<std::mutex> l(mx);
        uint32_t w = 0;
        for (int b = 0; b < 4 && cur_pos < cur.size(); b++) w |= uint32_t(cur[cur_pos++]) << (8 * b);
        return w;
    }
    std::vector<std::complex<float>> snapshot()
    {
        std::vector<std::complex<float>> x(CAP_N);
        for (auto& v : x) v = std::complex<float>(float(rand() % 2001 - 1000), float(rand() % 2001 - 1000));
        return x;
    }
};
#else
struct Modem {
    Mmio m;
    void wr(uint32_t reg, uint32_t v) { m.wr(4 * reg, v); }
    // status words 0..63 (see adrv9364/rtl/dvbs2_adrv.v)
    std::vector<uint32_t> status()
    {
        std::vector<uint32_t> s(64);
        for (uint32_t k = 0; k < 64; k++) s[k] = m.rd(0x100 + 4 * k);
        return s;
    }
    uint32_t levels() { return m.rd(0x20C); }          // {TX free words, RX used words}
    void tx_word(uint32_t w) { m.wr(0x200, w); }
    uint32_t rx_len() { return m.rd(0x204); }          // {valid, bytes} of the next complete frame
    uint32_t rx_word() { return m.rd(0x208); }
    // 1024 consecutive ADC samples; empty if the capture did not finish
    std::vector<std::complex<float>> snapshot()
    {
        std::vector<std::complex<float>> x;
        wr(REG_CAP, 1);
        bool done = false;
        for (int t = 0; t < 100 && !done; t++) {
            done = (m.rd(0x100 + 4 * 29) >> 31) & 1;
            if (!done) std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
        if (!done) return x;
        x.reserve(CAP_N);
        for (int i = 0; i < CAP_N; i++) {
            uint32_t s = m.rd(0x1000 + 4 * i);
            x.emplace_back(float(int16_t(s >> 16)), float(int16_t(s & 0xFFFF)));
        }
        return x;
    }
};
#endif

// ---------------------------------------------------------------- AD9364 (ad9361-phy)
// sysfs attributes; the sample rate through libad9361 (ad9361_set_bb_rate loads the FIR
// filters needed below ~2.1 MS/s), loaded at run time so the program has no build dependencies
struct Phy {
    std::string dir;
    void* h_iio = nullptr;
    void* h_ad = nullptr;
    void* dev = nullptr;
    int (*set_bb_rate)(void*, unsigned long) = nullptr;

    bool find()
    {
#ifdef DVBS2_MOCK
        // attributes are plain files in a temporary directory
        dir = "/tmp/dvbs2_mock_phy";
        mkdir(dir.c_str(), 0755);
        std::ofstream(dir + "/name") << "ad9361-phy\n";
        return true;
#endif
        DIR* d = opendir("/sys/bus/iio/devices");
        if (!d) return false;
        while (dirent* e = readdir(d)) {
            std::string p = std::string("/sys/bus/iio/devices/") + e->d_name, n;
            std::ifstream f(p + "/name");
            if (f && std::getline(f, n) && n == "ad9361-phy") {
                dir = p;
                break;
            }
        }
        closedir(d);
        return !dir.empty();
    }
    void open_lib()
    {
        h_iio = dlopen("libiio.so.0", RTLD_NOW | RTLD_GLOBAL);
        h_ad  = dlopen("libad9361.so.0", RTLD_NOW);
        if (!h_iio || !h_ad) return;
        auto mk  = (void* (*)())dlsym(h_iio, "iio_create_local_context");
        auto fnd = (void* (*)(void*, const char*))dlsym(h_iio, "iio_context_find_device");
        set_bb_rate = (int (*)(void*, unsigned long))dlsym(h_ad, "ad9361_set_bb_rate");
        void* ctx = mk ? mk() : nullptr;
        dev = (ctx && fnd) ? fnd(ctx, "ad9361-phy") : nullptr;
        if (!dev) set_bb_rate = nullptr;
    }
    bool wr(const std::string& a, const std::string& v)
    {
        std::ofstream f(dir + "/" + a);
        if (!f) return false;
        f << v;
        f.flush();
        return bool(f);
    }
    bool wr(const std::string& a, double v)
    {
        char b[64];
        if (v == std::floor(v) && std::fabs(v) < 1e15) snprintf(b, sizeof b, "%lld", (long long)v);
        else snprintf(b, sizeof b, "%.6f", v);
        return wr(a, std::string(b));
    }
    std::string rd(const std::string& a)
    {
        std::ifstream f(dir + "/" + a);
        std::string s;
        if (f) std::getline(f, s);
        return s;
    }
    double num(const std::string& a)
    {
        std::string s = rd(a);
        return s.empty() ? NAN : strtod(s.c_str(), nullptr);    // "40.000000 dB" -> 40
    }
    void set_rate(double fs)
    {
        if (set_bb_rate) {
            int r = set_bb_rate(dev, (unsigned long)std::llround(fs));
            if (r < 0) fprintf(stderr, "ad9361_set_bb_rate(%.0f) failed (%d)\n", fs, r);
        } else if (!wr("in_voltage_sampling_frequency", std::round(fs))) {
            fprintf(stderr, "cannot set the sample rate %.0f (libad9361 not found)\n", fs);
        }
    }
};

// axi_ad9361 DAC channels I0/Q0: data source DMA (2), the modem multiplexes its samples
// into the DMA data path (the Linux driver selects the DDS when no TX buffer is open)
static void dac_select_dma(Mmio& dac)
{
    dac.wr(0x418, 2);
    dac.wr(0x458, 2);
}

// ---------------------------------------------------------------- DVB-S2 frame parameters
static const char* MODCOD_NAME[] = {"DUMMY", "QPSK 1/4", "QPSK 1/3", "QPSK 2/5", "QPSK 1/2", "QPSK 3/5",
    "QPSK 2/3", "QPSK 3/4", "QPSK 4/5", "QPSK 5/6", "QPSK 8/9", "?", "8PSK 3/5", "8PSK 2/3", "8PSK 3/4",
    "8PSK 5/6", "8PSK 8/9"};
static int kbch_of(int mc)
{
    static const int kq[] = {0, 3072, 5232, 6312, 7032, 9552, 10632, 11712, 12432, 13152, 14232, 0,
        9552, 10632, 11712, 13152, 14232};
    return (mc >= 1 && mc <= 16) ? kq[mc] : 0;
}
static int frame_symbols(int mc, bool pilots)
{
    bool is8 = mc >= 12;
    if (is8)
        return pilots ? 5598 : 5490;
    return pilots ? 8370 : 8190;
}
static double rolloff_of(int ro) { return ro == 1 ? 0.25 : ro == 2 ? 0.20 : 0.35; }
static int ro_of_percent(int p) { return p == 25 ? 1 : p == 20 ? 2 : 0; }

static std::atomic<bool> stop_signal{false};   // Ctrl-C / SIGTERM / end of program
static std::atomic<bool> sess_stop{false};     // end of the current session
static FILE* g_log = stdout;     // status output (stderr when the payload goes to stdout)
static void sig_handler(int) { stop_signal = true; }
static bool running() { return !stop_signal && !sess_stop; }

// ---------------------------------------------------------------- file framing
// The receiver can only lock after the transmitter has started, so the TX first sends
// a preamble of zero bytes, then a header (magic + length + ~length), then the file.
// The RX side discards everything before a valid header and stops after <length> bytes.
static const uint8_t FILE_MAGIC[8] = {0xA5, 'D', 'V', 'B', 'S', '2', 0x5A, 0xC3};
static const uint64_t LEN_UNKNOWN  = ~uint64_t(0);    // stdin: stream until stopped
static void put_u64(std::vector<uint8_t>& v, uint64_t x)
{
    for (int i = 0; i < 8; i++) v.push_back(uint8_t(x >> (8 * i)));
}
static uint64_t get_u64(const uint8_t* p)
{
    uint64_t x = 0;
    for (int i = 7; i >= 0; i--) x = (x << 8) | p[i];
    return x;
}
struct FileSink {
    bool raw = false;
    FILE* out = nullptr;
    int state = 0;                  // 0 = looking for the header, 1 = writing, 2 = done
    std::deque<uint8_t> win;
    uint64_t len = 0, written = 0;
    std::vector<uint8_t> wbuf;
    void byte(uint8_t b)
    {
        if (raw || state == 1) {
            if (state == 2) return;
            wbuf.push_back(b);
            ++written;
            if (!raw && len != LEN_UNKNOWN && written >= len) state = 2;
            return;
        }
        if (state == 2) return;
        win.push_back(b);
        if (win.size() > 24) win.pop_front();
        if (win.size() < 24) return;
        uint8_t h[24];
        std::copy(win.begin(), win.end(), h);
        if (!std::equal(FILE_MAGIC, FILE_MAGIC + 8, h)) return;
        uint64_t l = get_u64(h + 8), nl = get_u64(h + 16);
        if (l != ~nl) return;
        len     = l;
        written = 0;
        state   = (len == 0) ? 2 : 1;
        win.clear();
    }
    void flush()
    {
        if (!wbuf.empty() && out) {
            fwrite(wbuf.data(), 1, wbuf.size(), out);
            fflush(out);
        }
        wbuf.clear();
    }
};

struct InputQueue {
    std::mutex m;
    std::condition_variable cv;
    std::deque<uint8_t> q;
    bool eof = false;
    static const size_t CAP = 1 << 20;
};
static void reader_worker(FILE* in, InputQueue* iq, std::vector<uint8_t> prefix)
{
    {
        std::lock_guard<std::mutex> l(iq->m);
        iq->q.insert(iq->q.end(), prefix.begin(), prefix.end());
    }
    std::vector<uint8_t> b(4096);
    while (running()) {
        size_t got = fread(b.data(), 1, b.size(), in);
        std::unique_lock<std::mutex> l(iq->m);
        for (size_t i = 0; i < got; i++) {
            iq->cv.wait(l, [&] { return iq->q.size() < InputQueue::CAP || !running(); });
            if (!running()) return;
            iq->q.push_back(b[i]);
        }
        if (got == 0) {        // EOF or error
            iq->eof = true;
            return;
        }
    }
}

// ---------------------------------------------------------------- UDP
// "[host:]port" (host default def_host) -> IPv4 address
static sockaddr_in udp_addr(const std::string& s, const std::string& def_host)
{
    const size_t c         = s.rfind(':');
    const std::string host = c == std::string::npos ? def_host : s.substr(0, c);
    const std::string port = c == std::string::npos ? s : s.substr(c + 1);
    addrinfo hints{}, *res = nullptr;
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (host.empty() || port.empty() || getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0 || !res)
        throw std::runtime_error("bad UDP address '" + s + "' (expected [host:]port)");
    sockaddr_in a;
    std::memcpy(&a, res->ai_addr, sizeof(a));
    freeaddrinfo(res);
    return a;
}
static std::string addr_str(const sockaddr_in& a)
{
    char b[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &a.sin_addr, b, sizeof(b));
    return std::string(b) + ":" + std::to_string(ntohs(a.sin_port));
}

// TX: datagrams received on a UDP port, framed into the payload queue
struct UdpIn {
    int fd = -1;
    sockaddr_in addr{};
    size_t limit = 0;            // queue limit (bytes): a datagram that does not fit is dropped
    std::atomic<uint64_t> packets{0}, bytes{0}, drops{0};
    ~UdpIn()
    {
        if (fd >= 0) close(fd);
    }
};
static void udp_reader_worker(UdpIn* u, InputQueue* iq)
{
    std::vector<uint8_t> b(UDP_MAX_PAYLOAD), f;
    uint16_t seq = 0;
    while (running()) {
        const ssize_t got = recv(u->fd, b.data(), b.size(), 0);    // 0.1 s timeout (SO_RCVTIMEO)
        if (got < 0) continue;
        f.clear();
        udp_frame(b.data(), size_t(got), seq, f);
        std::lock_guard<std::mutex> l(iq->m);
        // a datagram is queued as a whole (the TX pads only at datagram boundaries);
        // when the radio link is slower than the input, datagrams are dropped, not delayed
        if (!iq->q.empty() && iq->q.size() + f.size() > u->limit) {
            u->drops++;
            continue;
        }
        iq->q.insert(iq->q.end(), f.begin(), f.end());
        seq++;
        u->packets++;
        u->bytes += size_t(got);
    }
}

// RX: recovered datagrams sent to a UDP address
struct UdpOut {
    int fd = -1;
    sockaddr_in dst{};
    UdpDeframer df;
    std::vector<uint8_t> pkt;
    std::atomic<uint64_t> packets{0}, bytes{0}, bad{0}, lost{0}, send_err{0};
    ~UdpOut()
    {
        if (fd >= 0) close(fd);
    }
    void flush()
    {
        while (df.next(pkt)) {
            if (sendto(fd, pkt.data(), pkt.size(), 0, (const sockaddr*)&dst, sizeof(dst)) < 0)
                send_err++;
            packets++;
            bytes += pkt.size();
        }
        bad  = df.bad;
        lost = df.lost;
    }
};

// ---------------------------------------------------------------- TX thread
struct TxStats {
    std::atomic<uint64_t> bytes{0}, pad{0}, fill{0}, written{0};
    std::atomic<bool> pad_done{false};
    uint64_t pad_bytes = 0;      // zero bytes appended after the end of the input (flushes the last frame)
    // fill: zero bytes that complete a BBFRAME while the (UDP) input is idle
};
// Keeps the FPGA payload FIFO (16 kB) filled from the input queue.  The FIFO gives the flow
// control: the modem takes the bytes at the frame rate, dummy PLFRAMEs go out when it is empty.
static void tx_worker(Modem* modem, InputQueue* iq, size_t fill_frame, TxStats* st)
{
    std::vector<uint8_t> buf;
    uint8_t part[4];
    size_t npart = 0;            // bytes of an incomplete word
    uint64_t sent = 0;           // bytes given to the FPGA: BBFRAMEs take exactly fill_frame bytes each
    auto put = [&](uint8_t b) {
        part[npart++] = b;
        if (npart == 4) {
            modem->tx_word(uint32_t(part[0]) | uint32_t(part[1]) << 8 | uint32_t(part[2]) << 16 | uint32_t(part[3]) << 24);
            npart = 0;
        }
        sent++;
    };
    while (running()) {
        const uint32_t free_w = modem->levels() >> 16;
        if (free_w < 2) {
            std::this_thread::sleep_for(std::chrono::microseconds(500));
            continue;
        }
        const size_t want = 4 * size_t(free_w - 1) - npart;
        buf.clear();
        bool eof = false;
        if (!st->pad_done) {
            std::lock_guard<std::mutex> l(iq->m);
            while (buf.size() < want && !iq->q.empty()) {
                buf.push_back(iq->q.front());
                iq->q.pop_front();
            }
            eof = iq->eof && iq->q.empty();
            iq->cv.notify_one();
        }
        if (!buf.empty()) {
            for (uint8_t b : buf) put(b);
            st->bytes += buf.size();
            st->written = sent;
            continue;
        }
        const uint32_t used_w = TXW_DEPTH - free_w;
        size_t zeros = 0;
        if (eof && !st->pad_done) {
            // input finished: pad with zeros so the last BBFRAME is completed and sent
            zeros = size_t(st->pad_bytes);
            st->pad += zeros;
            st->pad_done = true;
        } else if (fill_frame && (sent % fill_frame || npart) && used_w < 64) {
            // queue empty and the modem about to run dry: complete the BBFRAME with zero bytes so
            // the last datagram goes out now (the queue holds whole datagrams, so this is between two)
            zeros = (fill_frame - sent % fill_frame) % fill_frame;
            st->fill += zeros;
        }
        zeros += (4 - (npart + zeros) % 4) % 4;          // whole words only
        if (zeros) {
            for (size_t i = 0; i < zeros; i++) put(0);
            st->written = sent;
            continue;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

// ---------------------------------------------------------------- RX thread
struct RxStats {
    std::atomic<uint64_t> bytes{0}, frames_out{0};
    std::atomic<uint64_t> file_len{0}, file_written{0};
    std::atomic<int> file_state{0};
};
static void rx_worker(Modem* modem, FileSink* sink, UdpOut* usink, RxStats* st)
{
    std::vector<uint8_t> fr;
    while (running()) {
        const uint32_t l = modem->rx_len();
        if (!(l >> 31)) {
            sink->flush();
            if (usink) usink->flush();
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        const size_t len = l & 0xFFFF;
        fr.resize(len);
        for (size_t k = 0; k < (len + 3) / 4; k++) {
            const uint32_t w = modem->rx_word();
            for (size_t b = 0; b < 4 && 4 * k + b < len; b++) fr[4 * k + b] = uint8_t(w >> (8 * b));
        }
        for (uint8_t b : fr) {
            if (usink) usink->df.push(b);
            else sink->byte(b);
        }
        st->bytes += len;
        st->frames_out++;
        if (usink) usink->flush();
        st->file_state   = sink->state;
        st->file_len     = sink->len;
        st->file_written = sink->written;
    }
    sink->flush();
    st->file_state   = sink->state;
    st->file_written = sink->written;
}

// ---------------------------------------------------------------- status printing
static void print_rx(const std::vector<uint32_t>& s, double rs, const RxStats& rst, const std::string& dst,
    bool raw, const UdpOut* u)
{
    uint32_t w0   = s[0];
    bool lock     = (w0 >> 4) & 1;
    int mc        = (w0 >> 5) & 31;
    int typ       = (w0 >> 10) & 3;
    int stage     = (w0 >> 12) & 3;
    bool berlock  = (w0 >> 14) & 1;
    int iters     = (w0 >> 16) & 63;
    double cfo_hz = double(int32_t(s[1])) / 4294967296.0 * rs;
    uint64_t bits = (uint64_t(s[15] & 0xFFFF) << 32) | s[14];
    double ber    = bits ? double(s[16]) / double(bits) : 0.0;
    fprintf(g_log, "RX %s %-8s %s FLL%d CFO %+9.1f Hz | frames %u miss %u | LDPC it %2d drop %u | BCH corr %u fail %u | "
           "BB ok %u crc %u",
        lock ? "LOCK" : "----", MODCOD_NAME[mc <= 16 ? mc : 11], (typ & 1) ? "pil" : "   ", stage, cfo_hz,
        s[2], s[3], iters, s[7], s[8], s[9], s[10], s[11]);
    if (dst == "prbs")
        fprintf(g_log, " | BER %s %u/%llu = %.2e", berlock ? "lock" : "----", s[16], (unsigned long long)bits, ber);
    else {
        fprintf(g_log, " | payload %llu B", (unsigned long long)rst.bytes.load());
        int fs = rst.file_state;
        if (u)
            fprintf(g_log, " | udp out %llu pkt %llu B, lost %llu, bad CRC %llu%s", (unsigned long long)u->packets.load(),
                (unsigned long long)u->bytes.load(), (unsigned long long)u->lost.load(),
                (unsigned long long)u->bad.load(), u->send_err ? " (sendto errors)" : "");
        else if (raw)
            fprintf(g_log, " | raw: %llu B", (unsigned long long)rst.file_written.load());
        else if (fs == 0)
            fprintf(g_log, " | file: waiting for header");
        else if (rst.file_len == LEN_UNKNOWN)
            fprintf(g_log, " | stream: %llu B", (unsigned long long)rst.file_written.load());
        else
            fprintf(g_log, " | file: %llu/%llu B%s", (unsigned long long)rst.file_written.load(),
                (unsigned long long)rst.file_len.load(), fs == 2 ? " DONE" : "");
    }
    if (s[32]) fprintf(g_log, " | ADC overflow %u", s[32]);
    fprintf(g_log, "\n");
    fflush(g_log);
}
static void print_tx(const std::vector<uint32_t>& s, const TxStats& tst, const std::string& src, const UdpIn* u)
{
    fprintf(g_log, "TX frames encoded %u sent %u dummy %u | DAC underflow %u", s[17], s[18], s[19], s[26]);
    if (src != "prbs")
        fprintf(g_log, " | payload in %llu B (FPGA %u, buffered %u words)", (unsigned long long)tst.bytes.load(),
            s[23], (s[22] >> 16) & 0x1FFF);
    if (u)
        fprintf(g_log, " | udp in %llu pkt %llu B, dropped %llu, fill %llu B", (unsigned long long)u->packets.load(),
            (unsigned long long)u->bytes.load(), (unsigned long long)u->drops.load(),
            (unsigned long long)tst.fill.load());
    fprintf(g_log, "\n");
    fflush(g_log);
}

// ---------------------------------------------------------------- spectrum
static void fft(std::vector<std::complex<float>>& a)
{
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = -2.0 * M_PI / double(len);
        const std::complex<float> wl(float(std::cos(ang)), float(std::sin(ang)));
        for (size_t i = 0; i < n; i += len) {
            std::complex<float> w(1.0f, 0.0f);
            for (size_t k = 0; k < len / 2; k++) {
                std::complex<float> u = a[i + k], v = a[i + k + len / 2] * w;
                a[i + k]           = u + v;
                a[i + k + len / 2] = u - v;
                w *= wl;
            }
        }
    }
}
// power spectrum in dBFS (full scale = 32767), fftshifted, Hann window
static std::vector<float> power_spectrum(const std::vector<std::complex<float>>& x)
{
    const size_t n = x.size();
    std::vector<std::complex<float>> a(n);
    double wsum = 0.0;
    for (size_t i = 0; i < n; i++) {
        float w = 0.5f - 0.5f * float(std::cos(2.0 * M_PI * double(i) / double(n)));
        a[i]    = x[i] * w;
        wsum += w;
    }
    fft(a);
    std::vector<float> p(n);
    const double ref = 32767.0 * wsum;
    for (size_t i = 0; i < n; i++)
        p[i] = float(10.0 * std::log10(std::norm(a[(i + n / 2) % n]) / (ref * ref) + 1e-15));
    return p;
}
// root-raised-cosine impulse response, t in symbols
static double rrc(double t, double a)
{
    if (std::fabs(t) < 1e-9) return 1.0 - a + 4.0 * a / M_PI;
    if (std::fabs(std::fabs(t) - 0.25 / a) < 1e-9)
        return a / std::sqrt(2.0) * ((1 + 2 / M_PI) * std::sin(M_PI / (4 * a)) + (1 - 2 / M_PI) * std::cos(M_PI / (4 * a)));
    return (std::sin(M_PI * t * (1 - a)) + 4 * a * t * std::cos(M_PI * t * (1 + a)))
           / (M_PI * t * (1 - 16 * a * a * t * t));
}
// Blind SNR estimate (M2M4, constant-modulus PSK), see b210/host/dvbs2_b210.cpp.
// x: ADC samples at 2 samples/symbol; 16 timing phases of the RRC matched filter, the phase
// with the lowest kappa = M4 / M2^2 is used;  Es/N0 = s / (1 - s), s = sqrt(2 - kappa).
static double psk_kappa(const std::vector<std::complex<float>>& x, double alpha)
{
    const int span = 8;
    const int ns   = int(x.size()) / 2;
    if (ns <= 2 * span + 16) return NAN;
    double best = NAN;
    for (int p = 0; p < 16; p++) {
        double c[4 * span + 1];
        for (int m = -2 * span; m <= 2 * span; m++) c[m + 2 * span] = rrc(p / 16.0 - m / 2.0, alpha);
        double m2 = 0, m4 = 0;
        int cnt = 0;
        for (int k = span; k < ns - span; k++) {
            std::complex<double> y = 0;
            for (int m = -2 * span; m <= 2 * span; m++)
                y += std::complex<double>(x[2 * k + m].real(), x[2 * k + m].imag()) * c[m + 2 * span];
            const double e = std::norm(y);
            m2 += e;
            m4 += e * e;
            cnt++;
        }
        m2 /= cnt;
        m4 /= cnt;
        if (m2 > 0 && !(m4 / (m2 * m2) >= best)) best = m4 / (m2 * m2);
    }
    return best;
}
static double esn0_db_of_kappa(double kappa)
{
    if (!(kappa < 2.0)) return NAN;
    const double s = std::sqrt(2.0 - kappa);
    return s >= 0.9999 ? 40.0 : std::min(40.0, 10.0 * std::log10(s / (1.0 - s)));
}
static std::string jnum(double v, int digits = 2)
{
    if (!std::isfinite(v)) return "null";
    char b[32];
    snprintf(b, sizeof b, "%.*f", digits, v);
    return b;
}
static std::string jstr(const std::string& s)
{
    std::string o = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        if ((unsigned char)c >= 0x20) o += c;
    }
    return o + "\"";
}

// ---------------------------------------------------------------- options / configuration
// --key value on the command line, "key = value" lines in the configuration file
struct Options {
    std::map<std::string, std::string> v;
    static std::string trim(const std::string& s)
    {
        size_t a = s.find_first_not_of(" \t\r\n"), b = s.find_last_not_of(" \t\r\n");
        return a == std::string::npos ? "" : s.substr(a, b - a + 1);
    }
    bool load(const std::string& path)
    {
        std::ifstream f(path);
        if (!f) return false;
        std::string line;
        while (std::getline(f, line)) {
            line = trim(line.substr(0, line.find('#')));
            size_t e = line.find('=');
            if (line.empty() || e == std::string::npos) continue;
            std::string k = trim(line.substr(0, e));
            if (!v.count(k)) v[k] = trim(line.substr(e + 1));      // the command line wins
        }
        return true;
    }
    std::string s(const std::string& k, const std::string& d = "") const { auto it = v.find(k); return it == v.end() ? d : it->second; }
    double d(const std::string& k, double def) const
    {
        auto it = v.find(k);
        return it == v.end() || it->second.empty() ? def : std::stod(it->second);
    }
    bool b(const std::string& k, bool def) const
    {
        auto it = v.find(k);
        if (it == v.end() || it->second.empty()) return def;
        const std::string& x = it->second;
        return x == "1" || x == "true" || x == "yes" || x == "on";
    }
};
static const char* HELP =
    "dvbs2_adrv options (also as 'key = value' lines in --config FILE):\n"
    "  --config FILE      configuration file\n"
    "  --mode M           tx | rx | trx (default trx)\n"
    "  --freq HZ          RF frequency (default 2.45e9); --tx-freq / --rx-freq\n"
    "  --rs SYM/S         symbol rate (sets --bw = Rs (1 + roll-off)), 260e3 .. 6.25e6\n"
    "  --bw HZ            occupied bandwidth Rs (1 + roll-off), default 2e6 (TX and RX: one sample rate)\n"
    "  --modcod N         1..10 QPSK 1/4..8/9, 12..16 8PSK 3/5..8/9 (default 13)\n"
    "  --pilots 0|1       pilots (default 1)\n"
    "  --rolloff P        35 | 25 | 20 (default 35)\n"
    "  --tx-gain DB       TX gain 0..89.75 (= 89.75 - attenuation, default 60)\n"
    "  --rx-gain DB       RX gain (manual), default 40\n"
    "  --tx-on 0|1, --rx-on 0|1   TX / RX switched on at start (default 1)\n"
    "  --data M           prbs | udp: payload with --web (default udp when --udp-in / --udp-out are set)\n"
    "  --input FILE       TX payload file ('-' = stdin), not with --web\n"
    "  --output FILE      RX payload file ('-' = stdout), not with --web\n"
    "  --udp-in [A:]P     TX payload: UDP datagrams received on [addr:]port (addr default 0.0.0.0)\n"
    "  --udp-out H:P      RX payload: recovered datagrams sent to host:port (broadcast allowed)\n"
    "  --max-iter N       LDPC iterations 1..50 (default 25)\n"
    "  --preamble S       TX file: seconds of zero bytes before the file (default 1)\n"
    "  --raw 0|1          no file header\n"
    "  --duration S       seconds to run (0 = until stopped)\n"
    "  --web PORT         web page on this TCP port (0 = off); --web-bind ADDR (default 0.0.0.0)\n"
    "  --web-root DIR     directory with index.html (default <program>/../share/dvbs2/web)\n"
    "  --file-dir DIR     web: directory for sent / received files (default /var/lib/dvbs2)\n";

struct Config {
    double tx_freq = 0, rx_freq = 0, bw = 0, tx_gain = 0, rx_gain = 0;
    int modcod = 13, ro = 0, max_iter = 25;
    bool pilots = true;
    std::string udp_in, udp_out;
};
struct Actual {
    double fs = 0, tx_freq = 0, rx_freq = 0, tx_gain = 0, rx_gain = 0, tx_abw = 0, rx_abw = 0;
};
static Actual apply_rf(Phy& phy, const Config& c, bool do_tx, bool do_rx, bool tx_on)
{
    const double a  = rolloff_of(c.ro);
    const double fs = 2.0 * c.bw / (1.0 + a);
    if (fs < FS_MIN - 1 || fs > FS_MAX + 1)
        throw std::runtime_error("sample rate " + std::to_string(fs) + " out of range (bandwidth too small / large)");
    phy.wr("ensm_mode", std::string("fdd"));
    phy.set_rate(fs);
    Actual r;
    r.fs = phy.num("in_voltage_sampling_frequency");
    if (!(r.fs > 0)) r.fs = fs;
    if (do_rx) {
        phy.wr("out_altvoltage0_RX_LO_frequency", std::round(c.rx_freq));
        phy.wr("in_voltage_rf_bandwidth", std::round(std::min(56e6, std::max(200e3, c.bw))));
        phy.wr("in_voltage0_gain_control_mode", std::string("manual"));
        phy.wr("in_voltage0_hardwaregain", c.rx_gain);
        r.rx_freq = phy.num("out_altvoltage0_RX_LO_frequency");
        r.rx_gain = phy.num("in_voltage0_hardwaregain");
        r.rx_abw  = phy.num("in_voltage_rf_bandwidth");
    }
    if (do_tx) {
        phy.wr("out_altvoltage1_TX_LO_frequency", std::round(c.tx_freq));
        phy.wr("out_voltage_rf_bandwidth", std::round(std::min(40e6, std::max(200e3, c.bw))));
        phy.wr("out_voltage0_hardwaregain", std::round(4 * (c.tx_gain - 89.75)) / 4);
        r.tx_freq = phy.num("out_altvoltage1_TX_LO_frequency");
        r.tx_gain = phy.num("out_voltage0_hardwaregain") + 89.75;
        r.tx_abw  = phy.num("out_voltage_rf_bandwidth");
    }
    phy.wr("out_altvoltage1_TX_LO_powerdown", std::string(do_tx && tx_on ? "0" : "1"));
    return r;
}

// ---------------------------------------------------------------- minimal HTTP server (web mode)
struct WebState {
    std::mutex m;
    std::string status_json = "{}", spectrum_json = "{}";
    // requests from the web page, handled by the main loop
    std::map<std::string, std::string> pending;    // config key -> value
    bool req_send = false, req_save = false;
    std::string req_data;                          // "prbs" / "udp"
    std::string send_path, send_name;
    std::string rx_path;                           // last received file (download)
};
static WebState g_web;

static std::string url_decode(const std::string& s)
{
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '+') o += ' ';
        else if (s[i] == '%' && i + 2 < s.size()) {
            o += char(std::stoi(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else o += s[i];
    }
    return o;
}
static std::map<std::string, std::string> parse_query(const std::string& q)
{
    std::map<std::string, std::string> kv;
    std::stringstream ss(q);
    std::string item;
    while (std::getline(ss, item, '&')) {
        size_t e = item.find('=');
        if (e == std::string::npos) continue;
        kv[url_decode(item.substr(0, e))] = url_decode(item.substr(e + 1));
    }
    return kv;
}
static void send_all(int fd, const std::string& s)
{
    size_t off = 0;
    while (off < s.size()) {
        ssize_t w = ::send(fd, s.data() + off, s.size() - off, MSG_NOSIGNAL);
        if (w <= 0) return;
        off += size_t(w);
    }
}
static void reply(int fd, int code, const std::string& type, const std::string& body, const std::string& extra = "")
{
    const char* txt = code == 200 ? "OK" : code == 404 ? "Not Found" : code == 413 ? "Payload Too Large" : "Bad Request";
    std::string h = "HTTP/1.1 " + std::to_string(code) + " " + txt + "\r\nContent-Type: " + type
                    + "\r\nContent-Length: " + std::to_string(body.size()) + "\r\nCache-Control: no-store\r\n" + extra
                    + "Connection: close\r\n\r\n";
    send_all(fd, h + body);
}
static bool read_file(const std::string& path, std::string& out)
{
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}
static std::string safe_name(const std::string& n)
{
    std::string o;
    for (char c : n)
        o += (isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_') ? c : '_';
    if (o.empty() || o[0] == '.') o = "file" + o;
    return o.substr(0, 100);
}

static const size_t MAX_UPLOAD = size_t(1) << 30;     // 1 GB (SD card space)
static void handle_client(int fd, const std::string& web_root, const std::string& file_dir)
{
    std::string req;
    char b[65536];
    size_t hdr_end = std::string::npos;
    while (hdr_end == std::string::npos && req.size() < 65536) {
        ssize_t r = ::recv(fd, b, sizeof(b), 0);
        if (r <= 0) return;
        req.append(b, size_t(r));
        hdr_end = req.find("\r\n\r\n");
    }
    if (hdr_end == std::string::npos) return;
    std::string head = req.substr(0, hdr_end);
    std::string body = req.substr(hdr_end + 4);
    std::istringstream hs(head);
    std::string method, target, ver;
    hs >> method >> target >> ver;
    size_t clen = 0;
    {
        std::string lower = head;
        std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
        size_t p = lower.find("content-length:");
        if (p != std::string::npos) clen = size_t(std::stoull(head.substr(p + 15)));
    }
    std::string path = target, query;
    size_t qm = target.find('?');
    if (qm != std::string::npos) {
        path  = target.substr(0, qm);
        query = target.substr(qm + 1);
    }
    // file upload: streamed to disk (not held in memory)
    if (method == "POST" && path == "/api/send") {
        auto kv          = parse_query(query);
        std::string name = safe_name(kv.count("name") ? kv["name"] : "payload.bin");
        std::string p    = file_dir + "/tx_" + name;
        if (clen > MAX_UPLOAD) {
            reply(fd, 413, "application/json", "{\"ok\":false,\"error\":\"file too large (max 1 GB)\"}");
            return;
        }
        FILE* f = fopen(p.c_str(), "wb");
        if (!f) {
            reply(fd, 500, "application/json", "{\"ok\":false,\"error\":\"cannot write " + p + "\"}");
            return;
        }
        size_t got = std::min(body.size(), clen);
        bool ok    = fwrite(body.data(), 1, got, f) == got;
        while (ok && got < clen) {
            ssize_t r = ::recv(fd, b, sizeof(b), 0);
            if (r <= 0) break;
            ok = fwrite(b, 1, size_t(r), f) == size_t(r);
            got += size_t(r);
        }
        ok = (fclose(f) == 0) && ok;
        if (!ok || got < clen) {
            fprintf(stderr, "web: upload %s incomplete (%zu of %zu bytes)\n", name.c_str(), got, clen);
            reply(fd, 400, "application/json", "{\"ok\":false,\"error\":\"upload incomplete or disk full\"}");
            return;
        }
        fprintf(g_log, "web: received upload %s (%zu bytes)\n", name.c_str(), got);
        std::lock_guard<std::mutex> l(g_web.m);
        g_web.req_send  = true;
        g_web.send_path = p;
        g_web.send_name = name;
        reply(fd, 200, "application/json", "{\"ok\":true}");
        return;
    }
    if (clen > (1u << 20)) {
        reply(fd, 413, "text/plain", "request too large\n");
        return;
    }
    while (body.size() < clen) {
        ssize_t r = ::recv(fd, b, sizeof(b), 0);
        if (r <= 0) return;
        body.append(b, size_t(r));
    }
    if (method == "GET" && path == "/api/status") {
        std::lock_guard<std::mutex> l(g_web.m);
        reply(fd, 200, "application/json", g_web.status_json);
    } else if (method == "GET" && path == "/api/spectrum") {
        std::lock_guard<std::mutex> l(g_web.m);
        reply(fd, 200, "application/json", g_web.spectrum_json);
    } else if (method == "POST" && path == "/api/config") {
        auto kv = parse_query(body.empty() ? query : body);
        static const char* keys[] = {"tx_freq", "tx_bw", "tx_gain", "rx_freq", "rx_bw", "rx_gain", "tx_on", "rx_on",
            "modcod", "pilots", "rolloff", "max_iter", "udp_in", "udp_out"};
        std::lock_guard<std::mutex> l(g_web.m);
        int n = 0;
        for (const char* k : keys) {
            auto it = kv.find(k);
            if (it == kv.end() || it->second.empty()) continue;
            g_web.pending[k] = it->second;
            n++;
        }
        reply(fd, n ? 200 : 400, "application/json", n ? "{\"ok\":true}" : "{\"ok\":false}");
    } else if (method == "POST" && (path == "/api/prbs" || path == "/api/udp")) {
        std::lock_guard<std::mutex> l(g_web.m);
        g_web.req_data = path == "/api/prbs" ? "prbs" : "udp";
        reply(fd, 200, "application/json", "{\"ok\":true}");
    } else if (method == "POST" && path == "/api/save") {
        std::lock_guard<std::mutex> l(g_web.m);
        g_web.req_save = true;
        reply(fd, 200, "application/json", "{\"ok\":true}");
    } else if (method == "GET" && path == "/api/received") {
        std::string p, data;
        {
            std::lock_guard<std::mutex> l(g_web.m);
            p = g_web.rx_path;
        }
        if (p.empty() || !read_file(p, data)) {
            reply(fd, 404, "text/plain", "no received file\n");
            return;
        }
        std::string fn = p.substr(p.find_last_of('/') + 1);
        reply(fd, 200, "application/octet-stream", data, "Content-Disposition: attachment; filename=\"" + fn + "\"\r\n");
    } else if (method == "GET" && (path == "/" || path == "/index.html")) {
        std::string data;
        if (!read_file(web_root + "/index.html", data)) {
            reply(fd, 404, "text/plain", "index.html not found in " + web_root + " (use --web-root)\n");
            return;
        }
        reply(fd, 200, "text/html; charset=utf-8", data);
    } else {
        reply(fd, 404, "text/plain", "not found\n");
    }
}

static void web_server(int port, std::string bind_addr, std::string web_root, std::string file_dir)
{
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port   = htons(uint16_t(port));
    if (inet_pton(AF_INET, bind_addr.c_str(), &a.sin_addr) != 1 || ::bind(s, (sockaddr*)&a, sizeof(a)) != 0
        || ::listen(s, 16) != 0) {
        fprintf(stderr, "web: cannot listen on %s:%d (%s)\n", bind_addr.c_str(), port, strerror(errno));
        stop_signal = true;
        return;
    }
    timeval tv{0, 200000};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));   // accept() wakes up to check stop_signal
    fprintf(g_log, "web page: http://%s:%d/\n", bind_addr.c_str(), port);
    while (!stop_signal) {
        int c = ::accept(s, nullptr, nullptr);
        if (c < 0) continue;
        timeval ct{10, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &ct, sizeof(ct));
        try {
            handle_client(c, web_root, file_dir);
        } catch (const std::exception& e) {
            fprintf(stderr, "web: %s\n", e.what());
        }
        ::close(c);
    }
    ::close(s);
}

static std::string exe_dir()
{
    char p[4096];
    ssize_t n = readlink("/proc/self/exe", p, sizeof(p) - 1);
    if (n <= 0) return ".";
    p[n]          = 0;
    std::string s = p;
    return s.substr(0, s.find_last_of('/'));
}

// ---------------------------------------------------------------- one streaming session
// RF / rate setup, modem configuration and the TX/RX/reader threads.  A session is
// restarted when the bandwidth, the MODCOD / roll-off or the payload source changes.
struct Session {
    bool do_tx = false, do_rx = false, raw = false;
    std::string src = "prbs", dst = "prbs";        // TX: prbs | file | udp,  RX: prbs | file | udp
    double fs = 0, rs = 0;
    FILE* fin = nullptr;
    FILE* fout = nullptr;
    std::string in_name, in_path, out_path;
    std::unique_ptr<TxStats> tst;
    std::unique_ptr<RxStats> rst;
    std::unique_ptr<InputQueue> iq;
    std::unique_ptr<FileSink> sink;
    std::unique_ptr<UdpIn> uin;
    std::unique_ptr<UdpOut> uout;
    std::thread ttx, trx, trd;
    std::chrono::steady_clock::time_point t0;
    bool cleared = false, compared = false;
    std::string result;           // file comparison result / error (web mode)

    void stop(Modem& modem)
    {
        sess_stop = true;
        if (iq) {
            std::lock_guard<std::mutex> l(iq->m);
            iq->cv.notify_all();
        }
        if (ttx.joinable()) ttx.join();
        if (trx.joinable()) trx.join();
        if (trd.joinable()) {
            // a reader blocked in fread() on stdin cannot be interrupted: detach it
            if (fin == stdin) trd.detach(); else trd.join();
        }
        modem.wr(REG_CTRL, CTRL_PLL | CTRL_AGC | CTRL_ES);    // modem off (reset): DAC back to the DMA data
        if (fin && fin != stdin) fclose(fin);
        if (fout && fout != stdout) fclose(fout);
        fin = fout = nullptr;
        uin.reset();
        uout.reset();
        sess_stop = false;
    }
};

int main(int argc, char* argv[])
try {
    Options o;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help") {
            fputs(HELP, stdout);
            return EXIT_SUCCESS;
        }
        if (a.rfind("--", 0) != 0 || i + 1 >= argc) {
            fprintf(stderr, "bad argument '%s' (--help)\n", a.c_str());
            return EXIT_FAILURE;
        }
        o.v[a.substr(2)] = argv[++i];
    }
    const std::string conf_path = o.s("config");
    if (!conf_path.empty() && !o.load(conf_path))
        fprintf(stderr, "note: configuration file %s not found, using defaults\n", conf_path.c_str());

    const int web_port = int(o.d("web", 0));
    const bool web     = web_port > 0;
    const std::string mode = o.s("mode", "trx");
    const bool do_tx = (mode == "tx" || mode == "trx");
    const bool do_rx = (mode == "rx" || mode == "trx");
    if (!do_tx && !do_rx) throw std::runtime_error("--mode must be tx, rx or trx");
    bool tx_on = do_tx && o.b("tx-on", true), rx_on = do_rx && o.b("rx-on", true);
    const std::string input = o.s("input"), output = o.s("output");
    const bool raw          = o.b("raw", false);
    const double preamble   = o.d("preamble", 1.0), duration = o.d("duration", 0);
    std::string web_root    = o.s("web-root"), file_dir = o.s("file-dir", "/var/lib/dvbs2");
    const std::string web_bind = o.s("web-bind", "0.0.0.0");

    Config cfg;
    const double freq = o.d("freq", 2.45e9);
    cfg.tx_freq  = o.d("tx-freq", freq);
    cfg.rx_freq  = o.d("rx-freq", freq);
    cfg.modcod   = int(o.d("modcod", 13));
    cfg.pilots   = o.b("pilots", true);
    cfg.ro       = ro_of_percent(int(o.d("rolloff", 35)));
    cfg.max_iter = int(o.d("max-iter", 25));
    cfg.tx_gain  = o.d("tx-gain", 60);
    cfg.rx_gain  = o.d("rx-gain", 40);
    cfg.udp_in   = o.s("udp-in");
    cfg.udp_out  = o.s("udp-out");
    const double rs0 = o.d("rs", 0);
    cfg.bw = o.d("bw", rs0 ? rs0 * (1 + rolloff_of(cfg.ro)) : 2e6);
    const int rolloff_pct = int(o.d("rolloff", 35));
    if (kbch_of(cfg.modcod) == 0) throw std::runtime_error("unsupported --modcod");
    if (rolloff_pct != 35 && rolloff_pct != 25 && rolloff_pct != 20) throw std::runtime_error("--rolloff must be 35, 25 or 20");
    if (cfg.max_iter < 1 || cfg.max_iter > 50) throw std::runtime_error("--max-iter must be 1..50");
    if (web && (!input.empty() || !output.empty()))
        throw std::runtime_error("--web: send files from the web page instead of --input / --output");
    if (!cfg.udp_in.empty() && !input.empty()) throw std::runtime_error("--udp-in and --input cannot be used together");
    if (!cfg.udp_out.empty() && !output.empty()) throw std::runtime_error("--udp-out and --output cannot be used together");
    // web mode payload: prbs | udp (file loopback is started from the page)
    std::string data_mode = o.s("data", (!cfg.udp_in.empty() || !cfg.udp_out.empty()) ? "udp" : "prbs");
    if (output == "-") g_log = stderr;

    // ---- hardware
    Modem modem;
    Mmio dac;
#ifdef DVBS2_MOCK
    static uint32_t dac_mock[0x400];
    dac.p = dac_mock;
    fprintf(g_log, "MOCK build: FPGA and AD9364 are simulated\n");
#else
    if (!modem.m.open(MODEM_BASE, 0x2000) || !dac.open(AD9361_DAC, 0x1000))
        throw std::runtime_error("cannot map /dev/mem (run as root)");
#endif
    auto s0 = modem.status();
    if (s0[30] != MODEM_ID || (s0[31] >> 16) != 3) {
        fprintf(stderr, "DVB-S2 modem not found in the FPGA (ID 0x%08x, version 0x%08x): is BOOT.BIN the DVB-S2 image?\n",
            s0[30], s0[31]);
        return EXIT_FAILURE;
    }
    fprintf(g_log, "DVB-S2 modem found, version %u.%u\n", s0[31] >> 16, s0[31] & 0xFFFF);
    Phy phy;
    for (int t = 0; t < 60 && !phy.find(); t++) std::this_thread::sleep_for(std::chrono::milliseconds(500));
    if (phy.dir.empty()) throw std::runtime_error("ad9361-phy not found in /sys/bus/iio/devices");
    phy.open_lib();
    if (!phy.set_bb_rate) fprintf(g_log, "note: libad9361 not found, sample rates below 2.1 MS/s may fail\n");
    modem.wr(REG_CTRL, CTRL_PLL | CTRL_AGC | CTRL_ES);
    dac_select_dma(dac);

    if (web) mkdir(file_dir.c_str(), 0755);
    if (web_root.empty()) web_root = exe_dir() + "/../share/dvbs2/web";
    std::signal(SIGINT, &sig_handler);
    std::signal(SIGTERM, &sig_handler);
    std::thread tweb;
    if (web) tweb = std::thread(web_server, web_port, web_bind, web_root, file_dir);

    // ---- session start: RF, rate, modem registers, threads
    Session S;
    Actual act;
    auto start_session = [&](const std::string& in, const std::string& out, const std::string& name) {
        S        = Session();
        S.do_tx  = do_tx && tx_on;
        S.do_rx  = do_rx && rx_on;
        S.raw    = raw;
        S.in_path = in;
        S.in_name = name;
        S.out_path = out;
        // payload source / sink
        if (!in.empty()) S.src = "file";
        else if (!cfg.udp_in.empty() && (!web || data_mode == "udp")) S.src = "udp";
        if (!out.empty()) S.dst = "file";
        else if (!cfg.udp_out.empty() && (!web || data_mode == "udp")) S.dst = "udp";
        if (!S.do_tx) S.src = "prbs";
        if (!S.do_rx) S.dst = "prbs";
        dac_select_dma(dac);
        act  = apply_rf(phy, cfg, do_tx, do_rx, S.do_tx);
        S.fs = act.fs;
        S.rs = act.fs / 2;
        fprintf(g_log, "TX %s, RX %s | %.4f MS/s (%.1f clk/sample), Rs %.4f Msym/s", S.do_tx ? "on" : "off",
            S.do_rx ? "on" : "off", act.fs / 1e6, CLK_HZ / act.fs, S.rs / 1e6);
        if (do_tx) fprintf(g_log, " | TX %.3f MHz gain %.2f dB", act.tx_freq / 1e6, act.tx_gain);
        if (do_rx) fprintf(g_log, " | RX %.3f MHz gain %.1f dB", act.rx_freq / 1e6, act.rx_gain);
        fprintf(g_log, "\n");
        if (CLK_HZ / act.fs < 7.999) throw std::runtime_error("less than 8 modem clocks per sample");

        if (S.src == "file") {
            S.fin = (in == "-") ? stdin : fopen(in.c_str(), "rb");
            if (!S.fin) throw std::runtime_error("cannot open payload file " + in);
        }
        if (S.dst == "file") {
            S.fout = (out == "-") ? stdout : fopen(out.c_str(), "wb");
            if (!S.fout) throw std::runtime_error("cannot open payload file " + out);
        }
        if (S.src == "udp") {
            S.uin           = std::unique_ptr<UdpIn>(new UdpIn());
            S.uin->addr     = udp_addr(cfg.udp_in, "0.0.0.0");
            S.uin->fd       = socket(AF_INET, SOCK_DGRAM, 0);
            const int one   = 1, rcvbuf = 4 << 20;
            timeval tv{0, 100000};
            setsockopt(S.uin->fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            setsockopt(S.uin->fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
            setsockopt(S.uin->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            if (S.uin->fd < 0 || bind(S.uin->fd, (const sockaddr*)&S.uin->addr, sizeof(S.uin->addr)) < 0)
                throw std::runtime_error("cannot bind UDP " + addr_str(S.uin->addr) + ": " + strerror(errno));
            fprintf(g_log, "TX payload: UDP datagrams received on %s\n", addr_str(S.uin->addr).c_str());
        }
        if (S.dst == "udp") {
            S.uout      = std::unique_ptr<UdpOut>(new UdpOut());
            S.uout->dst = udp_addr(cfg.udp_out, "");
            S.uout->fd  = socket(AF_INET, SOCK_DGRAM, 0);
            const int one = 1;
            setsockopt(S.uout->fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
            if (S.uout->fd < 0) throw std::runtime_error("cannot open a UDP socket");
            fprintf(g_log, "RX payload: UDP datagrams sent to %s\n", addr_str(S.uout->dst).c_str());
        }

        // ---- configure the modem
        uint32_t ctrl = CTRL_PLL | CTRL_AGC | CTRL_ES;
        modem.wr(REG_CTRL, ctrl);                       // both parts held in reset
        modem.wr(REG_TXCFG, uint32_t(cfg.modcod & 31) | (cfg.pilots ? 1u << 8 : 0u) | (uint32_t(cfg.ro) << 12));
        modem.wr(REG_FEC, (uint32_t(cfg.max_iter & 63) << 16) | (16u << 8) | 24u);
        if (S.do_tx) ctrl |= CTRL_TX_EN | (S.src != "prbs" ? CTRL_TX_DATA : 0);
        if (S.do_rx) ctrl |= CTRL_RX_EN | (S.dst != "prbs" ? CTRL_RX_DATA : 0);
        modem.wr(REG_CTRL, ctrl);
        modem.wr(REG_CLR, 1);
        fprintf(g_log, "%s, %s, roll-off 0.%02d | TX payload %s | RX payload %s\n", MODCOD_NAME[cfg.modcod],
            cfg.pilots ? "pilots" : "no pilots", int(std::lround(100 * rolloff_of(cfg.ro))),
            S.do_tx ? S.src.c_str() : "-", S.do_rx ? S.dst.c_str() : "-");

        const size_t dfl_bytes = size_t(kbch_of(cfg.modcod) - 80) / 8;
        const double cap_Bps   = double(dfl_bytes) / frame_symbols(cfg.modcod, cfg.pilots) * S.rs;
        if (S.src != "prbs") fprintf(g_log, "payload capacity %.1f kB/s\n", cap_Bps / 1e3);
        S.tst            = std::unique_ptr<TxStats>(new TxStats());
        S.tst->pad_bytes = 2 * uint64_t(dfl_bytes);
        S.rst            = std::unique_ptr<RxStats>(new RxStats());
        S.iq             = std::unique_ptr<InputQueue>(new InputQueue());
        S.sink           = std::unique_ptr<FileSink>(new FileSink());
        std::vector<uint8_t> prefix;
        // UDP: queue at most ~0.2 s of air time (and at least one maximum-size datagram)
        if (S.uin) S.uin->limit = std::max(size_t(0.2 * cap_Bps), UDP_MAX_PAYLOAD + UDP_OVERHEAD);
        if (S.src == "file" && !raw) {
            // preamble (zero bytes while the receiver locks) + header
            prefix.assign(size_t(std::max(0.0, preamble) * cap_Bps), 0);
            uint64_t flen = LEN_UNKNOWN;
            if (S.fin != stdin && fseek(S.fin, 0, SEEK_END) == 0) {
                long sz = ftell(S.fin);
                if (sz >= 0) flen = uint64_t(sz);
                fseek(S.fin, 0, SEEK_SET);
            }
            prefix.insert(prefix.end(), FILE_MAGIC, FILE_MAGIC + 8);
            put_u64(prefix, flen);
            put_u64(prefix, ~flen);
            if (flen != LEN_UNKNOWN)
                fprintf(g_log, "file %s: %llu bytes, after %.1f s preamble\n", in.c_str(), (unsigned long long)flen, preamble);
        }
        S.sink->raw = raw;
        S.sink->out = S.fout;
        if (S.uin) S.trd = std::thread(udp_reader_worker, S.uin.get(), S.iq.get());
        else if (S.src == "file") S.trd = std::thread(reader_worker, S.fin, S.iq.get(), prefix);
        if (S.dst != "prbs") S.trx = std::thread(rx_worker, &modem, S.sink.get(), S.uout.get(), S.rst.get());
        if (S.src != "prbs")
            S.ttx = std::thread(tx_worker, &modem, S.iq.get(), S.uin ? dfl_bytes : 0, S.tst.get());
        S.t0 = std::chrono::steady_clock::now();
    };

    auto save_config = [&]() -> std::string {
        if (conf_path.empty()) return "no --config file given";
        std::ofstream f(conf_path);
        if (!f) return "cannot write " + conf_path;
        f.precision(12);
        f << "# dvbs2_adrv configuration (written by the web page)\n"
          << "mode = " << mode << "\nweb = " << web_port << "\n"
          << "tx-freq = " << cfg.tx_freq << "\nrx-freq = " << cfg.rx_freq << "\nbw = " << cfg.bw << "\n"
          << "tx-gain = " << cfg.tx_gain << "\nrx-gain = " << cfg.rx_gain << "\n"
          << "modcod = " << cfg.modcod << "\npilots = " << (cfg.pilots ? 1 : 0) << "\n"
          << "rolloff = " << int(std::lround(100 * rolloff_of(cfg.ro))) << "\nmax-iter = " << cfg.max_iter << "\n"
          << "tx-on = " << (tx_on ? 1 : 0) << "\nrx-on = " << (rx_on ? 1 : 0) << "\n"
          << "data = " << data_mode << "\nudp-in = " << cfg.udp_in << "\nudp-out = " << cfg.udp_out << "\n"
          << "file-dir = " << file_dir << "\n";
        f.close();
        return f ? "saved to " + conf_path : "cannot write " + conf_path;
    };

    try {
        start_session(input, output, input);
    } catch (const std::exception& e) {
        if (!web) throw;
        fprintf(stderr, "session start failed: %s\n", e.what());
        S.result = e.what();
    }

    // ---- web status / spectrum
    std::vector<float> spec_db;
    double spec_fs = 0, spec_fc = 0;
    const double RATE_INTERVAL = 0.5;
    struct RateSample {
        double t;
        uint64_t tx_frames, tx_bytes, rx_bb_ok, rx_written;
    };
    RateSample rate_mark{};
    std::chrono::steady_clock::time_point rate_t0;
    double tx_rate = 0, tx_host = 0, rx_rate = 0, rx_fps = 0, rx_file = 0, rate_dt = 0;
    double snr_t = 0, esn0_avg = NAN, level_avg = NAN, rssi_db = NAN;
    std::chrono::steady_clock::time_point snr_t0;
    double update_ms = 0;
    std::string save_msg;
    auto update_web = [&](const std::vector<uint32_t>& s) {
        const double a = rolloff_of(cfg.ro);
        if (!S.do_rx) spec_db.clear();
        if (S.do_rx) {
            std::vector<std::complex<float>> x = modem.snapshot();
            const double tnow = std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count();
            if (snr_t0 != S.t0) esn0_avg = level_avg = NAN, snr_t = tnow;
            snr_t0 = S.t0;
            if (x.size() == size_t(CAP_N)) {
                spec_db = power_spectrum(x);
                spec_fs = S.fs;
                spec_fc = act.rx_freq;
                const double e1 = esn0_db_of_kappa(psk_kappa(x, a));
                double pw = 0;
                for (const auto& v : x) pw += std::norm(v);
                pw /= double(x.size());
                const double w = 1.0 - std::exp(-std::max(0.0, tnow - snr_t) / 0.5);
                snr_t = tnow;
                if (std::isfinite(e1)) esn0_avg = std::isfinite(esn0_avg) ? esn0_avg + w * (e1 - esn0_avg) : e1;
                level_avg = std::isfinite(level_avg) ? level_avg + w * (pw - level_avg) : pw;
            }
            rssi_db = phy.num("in_voltage0_rssi");          // dB, relative (not dBm)
        }
        const uint32_t w0   = s[0];
        const bool lock     = (w0 >> 4) & 1;
        const int mc        = (w0 >> 5) & 31;
        const uint64_t bits = (uint64_t(s[15] & 0xFFFF) << 32) | s[14];
        const double tx_dfl = kbch_of(cfg.modcod) - 80;
        const int rx_dfl_hw = s[13] & 0xFFFF;
        const double rx_dfl = rx_dfl_hw ? rx_dfl_hw : std::max(0, kbch_of(mc) - 80);
        const double tx_cap = tx_dfl / frame_symbols(cfg.modcod, cfg.pilots) * S.rs;
        const double rx_cap = kbch_of(mc) ? (kbch_of(mc) - 80.0) / frame_symbols(mc, (w0 >> 10) & 1) * S.rs : 0;
        const uint64_t tx_bytes = S.tst ? S.tst->bytes.load() : 0, rx_written = S.rst ? S.rst->file_written.load() : 0;
        const RateSample cur{std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count(), s[18],
            tx_bytes, s[10], rx_written};
        if (rate_t0 != S.t0 || cur.tx_frames < rate_mark.tx_frames || cur.tx_bytes < rate_mark.tx_bytes
            || cur.rx_bb_ok < rate_mark.rx_bb_ok || cur.rx_written < rate_mark.rx_written) {
            rate_mark = cur;
            tx_rate = tx_host = rx_rate = rx_fps = rx_file = rate_dt = 0;
        } else if (cur.t - rate_mark.t >= RATE_INTERVAL) {
            const double dt = cur.t - rate_mark.t;
            tx_rate  = double(cur.tx_frames - rate_mark.tx_frames) * tx_dfl / dt;
            tx_host  = double(cur.tx_bytes - rate_mark.tx_bytes) * 8 / dt;
            rx_fps   = double(cur.rx_bb_ok - rate_mark.rx_bb_ok) / dt;
            rx_rate  = rx_fps * rx_dfl;
            rx_file  = double(cur.rx_written - rate_mark.rx_written) * 8 / dt;
            rate_dt  = dt;
            rate_mark = cur;
        }
        rate_t0 = S.t0;
        const double esn0 = S.do_rx ? esn0_avg : NAN;
        const double ebn0 = lock && rx_cap > 0 ? esn0 - 10.0 * std::log10(rx_cap / S.rs) : NAN;
        const double level_dbfs = S.do_rx && level_avg > 0 ? 10.0 * std::log10(level_avg / (32767.0 * 32767.0)) : NAN;
        const UdpIn* ui = S.uin.get();
        const UdpOut* uo = S.uout.get();
        std::ostringstream j;
        j.precision(10);
        j << "{\"board\":\"ADRV9364-Z7020\",\"fpga\":{\"version\":\"" << (s[31] >> 16) << "." << (s[31] & 0xFFFF)
          << "\",\"spectrum\":true},";
        j << "\"update_ms\":" << update_ms << ",";
        j << "\"uptime\":" << std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count() << ",";
        j << "\"config\":{\"tx_freq\":" << cfg.tx_freq << ",\"tx_bw\":" << cfg.bw << ",\"tx_gain\":" << cfg.tx_gain
          << ",\"rx_freq\":" << cfg.rx_freq << ",\"rx_bw\":" << cfg.bw << ",\"rx_gain\":" << cfg.rx_gain
          << ",\"rolloff\":" << a << ",\"modcod\":" << jstr(MODCOD_NAME[cfg.modcod]) << ",\"modcod_n\":" << cfg.modcod
          << ",\"pilots\":" << (cfg.pilots ? "true" : "false") << ",\"max_iter\":" << cfg.max_iter
          << ",\"data\":" << jstr(data_mode) << ",\"udp_in\":" << jstr(cfg.udp_in) << ",\"udp_out\":" << jstr(cfg.udp_out)
          << ",\"has_tx\":" << (do_tx ? "true" : "false") << ",\"has_rx\":" << (do_rx ? "true" : "false")
          << ",\"saved\":" << jstr(save_msg) << "},";
        j << "\"tx\":{\"on\":" << (S.do_tx ? "true" : "false") << ",\"freq\":" << act.tx_freq << ",\"rs\":" << S.rs
          << ",\"fs\":" << S.fs << ",\"gain\":" << act.tx_gain << ",\"analog_bw\":" << act.tx_abw
          << ",\"frames_encoded\":" << s[17] << ",\"frames_sent\":" << s[18]
          << ",\"dummy\":" << s[19] << ",\"duc_underflow\":" << s[26] << ",\"host_underflow\":" << s[24]
          << ",\"mode\":" << jstr(S.src) << ",\"file\":" << jstr(S.in_name)
          << ",\"bytes\":" << tx_bytes << ",\"done\":" << (S.tst && S.tst->pad_done ? "true" : "false")
          << ",\"capacity_bps\":" << tx_cap << ",\"rate_bps\":" << tx_rate << ",\"host_bps\":" << tx_host
          << ",\"udp_packets\":" << (ui ? ui->packets.load() : 0) << ",\"udp_bytes\":" << (ui ? ui->bytes.load() : 0)
          << ",\"udp_drops\":" << (ui ? ui->drops.load() : 0) << ",\"fill\":" << (S.tst ? S.tst->fill.load() : 0) << "},";
        j << "\"rx\":{\"on\":" << (S.do_rx ? "true" : "false") << ",\"freq\":" << act.rx_freq << ",\"rs\":" << S.rs
          << ",\"fs\":" << S.fs << ",\"gain\":" << act.rx_gain << ",\"analog_bw\":" << act.rx_abw
          << ",\"lock\":" << (lock ? "true" : "false") << ",\"modcod\":" << jstr(MODCOD_NAME[mc <= 16 ? mc : 11])
          << ",\"pilots\":" << (((w0 >> 10) & 1) ? "true" : "false") << ",\"fll_stage\":" << ((w0 >> 12) & 3)
          << ",\"cfo_hz\":" << double(int32_t(s[1])) / 4294967296.0 * S.rs << ",\"agc_gain\":" << (s[5] & 0xFFFF)
          << ",\"frames\":" << s[2] << ",\"misses\":" << s[3] << ",\"pls_fail\":" << s[4]
          << ",\"ldpc_iters\":" << ((w0 >> 16) & 63) << ",\"ldpc_drop\":" << s[7] << ",\"bch_corr\":" << s[8]
          << ",\"bch_fail\":" << s[9] << ",\"bb_ok\":" << s[10] << ",\"bb_crc\":" << s[11]
          << ",\"ber_lock\":" << (((w0 >> 14) & 1) ? "true" : "false") << ",\"ber_bits\":" << bits
          << ",\"ber_errors\":" << s[16] << ",\"host_overflow\":" << s[32]
          << ",\"mode\":" << jstr(S.dst) << ",\"file_state\":" << (S.rst ? S.rst->file_state.load() : 0)
          << ",\"file_len\":" << (!S.rst || S.rst->file_len == LEN_UNKNOWN ? 0 : S.rst->file_len.load())
          << ",\"file_written\":" << rx_written << ",\"seq_gaps\":0"
          << ",\"capacity_bps\":" << rx_cap << ",\"rate_bps\":" << rx_rate << ",\"frames_per_s\":" << rx_fps
          << ",\"file_bps\":" << rx_file << ",\"rate_interval\":" << rate_dt << ",\"rate_time\":" << rate_mark.t
          << ",\"rssi_db\":" << jnum(S.do_rx ? rssi_db : NAN) << ",\"level_dbfs\":" << jnum(level_dbfs)
          << ",\"esn0_db\":" << jnum(esn0) << ",\"ebn0_db\":" << jnum(ebn0)
          << ",\"udp_packets\":" << (uo ? uo->packets.load() : 0) << ",\"udp_bytes\":" << (uo ? uo->bytes.load() : 0)
          << ",\"udp_lost\":" << (uo ? uo->lost.load() : 0) << ",\"udp_bad\":" << (uo ? uo->bad.load() : 0)
          << ",\"result\":" << jstr(S.result) << "}}";
        std::ostringstream sp;
        sp.precision(10);
        sp << "{\"fc\":" << spec_fc << ",\"fs\":" << spec_fs << ",\"db\":[";
        for (size_t i = 0; i < spec_db.size(); i++) sp << (i ? "," : "") << std::round(spec_db[i] * 10) / 10;
        sp << "]}";
        std::lock_guard<std::mutex> l(g_web.m);
        g_web.status_json   = j.str();
        g_web.spectrum_json = sp.str();
    };

    auto compare_files = [&](const std::string& a, const std::string& b) -> std::string {
        FILE* fa = fopen(a.c_str(), "rb");
        FILE* fb = fopen(b.c_str(), "rb");
        if (!fa || !fb) {
            if (fa) fclose(fa);
            if (fb) fclose(fb);
            return "cannot read the files";
        }
        std::vector<char> x(1 << 20), y(1 << 20);
        uint64_t na = 0, nb = 0, diff = 0;
        for (;;) {
            size_t ra = fread(x.data(), 1, x.size(), fa), rb = fread(y.data(), 1, y.size(), fb);
            for (size_t i = 0; i < std::min(ra, rb); i++) diff += x[i] != y[i];
            na += ra;
            nb += rb;
            if (ra == 0 && rb == 0) break;
        }
        fclose(fa);
        fclose(fb);
        if (na == nb && diff == 0) return "identical (" + std::to_string(na) + " bytes)";
        return "DIFFERENT: sent " + std::to_string(na) + " B, received " + std::to_string(nb) + " B, "
               + std::to_string(diff) + " bytes differ";
    };

    auto t_poll  = std::chrono::steady_clock::now();
    auto t_print = t_poll;
    while (!stop_signal) {
        std::this_thread::sleep_for(std::chrono::milliseconds(web ? 10 : 200));
        // ---- requests from the web page
        if (web) {
            std::map<std::string, std::string> pend;
            bool rq_send = false, rq_save = false;
            std::string rq_data, spath, sname;
            {
                std::lock_guard<std::mutex> l(g_web.m);
                pend.swap(g_web.pending);
                rq_send = g_web.req_send;
                rq_save = g_web.req_save;
                rq_data = g_web.req_data;
                spath   = g_web.send_path;
                sname   = g_web.send_name;
                g_web.req_send = g_web.req_save = false;
                g_web.req_data.clear();
            }
            bool restart = rq_send || !rq_data.empty();
            if (!rq_data.empty()) data_mode = rq_data;
            try {
                for (auto& kv : pend) {
                    const std::string& k = kv.first;
                    const std::string& sv = kv.second;
                    double v = 0;
                    if (k != "udp_in" && k != "udp_out") {
                        try { v = std::stod(sv); } catch (...) { continue; }
                    }
                    if (k == "tx_freq" && do_tx) {
                        cfg.tx_freq = v;
                        phy.wr("out_altvoltage1_TX_LO_frequency", std::round(v));
                        act.tx_freq = phy.num("out_altvoltage1_TX_LO_frequency");
                    } else if (k == "rx_freq" && do_rx) {
                        cfg.rx_freq = v;
                        phy.wr("out_altvoltage0_RX_LO_frequency", std::round(v));
                        act.rx_freq = phy.num("out_altvoltage0_RX_LO_frequency");
                    } else if (k == "tx_gain" && do_tx) {
                        cfg.tx_gain = std::min(89.75, std::max(0.0, v));
                        phy.wr("out_voltage0_hardwaregain", std::round(4 * (cfg.tx_gain - 89.75)) / 4);
                        act.tx_gain = phy.num("out_voltage0_hardwaregain") + 89.75;
                    } else if (k == "rx_gain" && do_rx) {
                        cfg.rx_gain = v;
                        phy.wr("in_voltage0_hardwaregain", v);
                        act.rx_gain = phy.num("in_voltage0_hardwaregain");
                    } else if ((k == "tx_bw" || k == "rx_bw") && v != cfg.bw) {
                        const double fs = 2.0 * v / (1.0 + rolloff_of(cfg.ro));
                        if (fs >= FS_MIN && fs <= FS_MAX) {
                            cfg.bw  = v;
                            restart = true;
                        } else S.result = "bandwidth out of range";
                    } else if (k == "tx_on" && do_tx && (v != 0) != tx_on) {
                        tx_on   = v != 0;
                        restart = true;
                    } else if (k == "rx_on" && do_rx && (v != 0) != rx_on) {
                        rx_on   = v != 0;
                        restart = true;
                    } else if (k == "modcod" && kbch_of(int(v)) && int(v) != cfg.modcod) {
                        cfg.modcod = int(v);
                        restart    = true;
                    } else if (k == "pilots" && (v != 0) != cfg.pilots) {
                        cfg.pilots = v != 0;
                        restart    = true;
                    } else if (k == "rolloff" && (v == 35 || v == 25 || v == 20) && ro_of_percent(int(v)) != cfg.ro) {
                        cfg.ro  = ro_of_percent(int(v));
                        restart = true;
                    } else if (k == "max_iter" && v >= 1 && v <= 50 && int(v) != cfg.max_iter) {
                        cfg.max_iter = int(v);
                        restart      = true;
                    } else if (k == "udp_in" && sv != cfg.udp_in) {
                        try { udp_addr(sv, "0.0.0.0"); cfg.udp_in = sv; restart = true; }
                        catch (const std::exception& e) { S.result = e.what(); }
                    } else if (k == "udp_out" && sv != cfg.udp_out) {
                        try { udp_addr(sv, ""); cfg.udp_out = sv; restart = true; }
                        catch (const std::exception& e) { S.result = e.what(); }
                    }
                    fprintf(g_log, "web: %s = %s\n", k.c_str(), sv.c_str());
                }
                if (restart) {
                    // keep sending the current file unless another payload mode was requested
                    std::string in = S.in_path, name = S.in_name;
                    if (!rq_data.empty()) in.clear(), name.clear();
                    if (rq_send) in = spath, name = sname;
                    if (!(tx_on && rx_on)) in.clear(), name.clear();   // file loopback needs TX and RX on
                    S.stop(modem);
                    std::string out = in.empty() ? "" : file_dir + "/rx_" + name;
                    try {
                        start_session(in, out, name);
                    } catch (const std::exception& e) {
                        fprintf(stderr, "session start failed: %s\n", e.what());
                        S.result = e.what();
                    }
                    if (rq_send && !(tx_on && rx_on)) S.result = "TX and RX must be on to send a file";
                    std::lock_guard<std::mutex> l(g_web.m);
                    g_web.rx_path = out;
                }
                if (rq_save) {
                    save_msg = save_config();
                    fprintf(g_log, "web: %s\n", save_msg.c_str());
                }
            } catch (const std::exception& e) {
                fprintf(stderr, "web request failed: %s\n", e.what());
            }
        }
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration<double>(now - t_poll).count() < (web ? 0.1 : 0.999)) continue;     // web: 10 Hz
        t_poll = now;
        auto s = modem.status();
        if (web) {
            update_web(s);
            update_ms = 1e3 * std::chrono::duration<double>(std::chrono::steady_clock::now() - now).count();
        }
        if (std::chrono::duration<double>(now - t_print).count() >= (web ? 9.999 : 0.999)) {
            t_print = now;
            if (S.do_tx && S.tst) print_tx(s, *S.tst, S.src, S.uin.get());
            if (S.do_rx && S.rst) print_rx(s, S.rs, *S.rst, S.dst, S.raw, S.uout.get());
        }
        // restart the BER statistics once, after the receiver has settled
        if (S.do_rx && !S.cleared && ((s[0] >> 14) & 1) && s[10] >= 5) {
            modem.wr(REG_CLR, 1);
            S.cleared = true;
            fprintf(g_log, "(statistics cleared after lock)\n");
        }
        double el = std::chrono::duration<double>(now - S.t0).count();
        if (duration > 0 && el >= duration) stop_signal = true;
        if (S.dst == "file" && !S.raw && S.rst && S.rst->file_state == 2 && S.rst->file_len != LEN_UNKNOWN && !S.compared) {
            S.compared = true;
            if (S.fout && S.fout != stdout) fflush(S.fout);
            fprintf(g_log, "file received: %llu bytes\n", (unsigned long long)S.rst->file_written.load());
            if (web) {
                S.result = compare_files(S.in_path, S.out_path);
                fprintf(g_log, "file loopback: %s\n", S.result.c_str());
            } else if (!S.do_tx || S.src != "file" || S.tst->pad_done)
                stop_signal = true;
        }
        if (!web && S.src == "file" && S.tst && S.tst->pad_done && !S.do_rx) {
            // input sent and padded: let the FPGA FIFO (16 kB) and 2 frames drain, then stop
            const double frame_s = frame_symbols(cfg.modcod, cfg.pilots) / S.rs;
            const double cap_Bps = double(kbch_of(cfg.modcod) - 80) / 8 / frame_symbols(cfg.modcod, cfg.pilots) * S.rs;
            std::this_thread::sleep_for(std::chrono::duration<double>(16384.0 / cap_Bps + 3.0 * frame_s + 0.2));
            fprintf(g_log, "input sent (%llu bytes incl. preamble and header, + %llu padding bytes)\n",
                (unsigned long long)S.tst->bytes.load(), (unsigned long long)S.tst->pad.load());
            stop_signal = true;
        }
    }
    S.stop(modem);
    phy.wr("out_altvoltage1_TX_LO_powerdown", std::string("1"));    // stop transmitting
    if (tweb.joinable()) tweb.join();
    fprintf(g_log, "done\n");
    return EXIT_SUCCESS;
} catch (const std::exception& e) {
    fprintf(stderr, "error: %s\n", e.what());
    return EXIT_FAILURE;
}
