//
// dvbs2_b210 -- PC side of the DVB-S2 modem running inside the USRP B210 FPGA.
//
//   * loads the custom FPGA image (usrp_b210_dvbs2_fpga.bin) when the device is opened
//   * sets RF (frequency, gain, antenna), master clock and sample rate (2 x symbol rate)
//   * configures the modem through the UHD user-settings registers
//   * TX: keeps the TX stream running; optional payload bytes from a file / stdin
//   * RX: reports lock / MODCOD / CFO / FEC / BER once per second; optional payload
//         bytes to a file / stdout
//
// Two PCs:   PC1:  dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6
//            PC2:  dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6
// One B210: dvbs2_b210 --mode trx ...   (TX on TX/RX A, RX on RX2 A, cable + attenuator)
//
#include <uhd/types/wb_iface.hpp>
#include <uhd/usrp/multi_usrp.hpp>
#include <uhd/utils/safe_main.hpp>
#include <uhd/utils/thread.hpp>
#include <boost/program_options.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <deque>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace po = boost::program_options;

// ---------------------------------------------------------------- modem registers
enum : uint32_t {
    REG_CTRL = 0, REG_TXCFG = 1, REG_AGC = 2, REG_TIM = 3, REG_FS = 4, REG_FLL = 5, REG_FEC = 6, REG_CLR = 7
};
enum : uint32_t {
    CTRL_TX_EN = 1u << 0, CTRL_RX_EN = 1u << 1, CTRL_TX_DATA = 1u << 2, CTRL_RX_DATA = 1u << 3,
    CTRL_PLL = 1u << 6, CTRL_AGC = 1u << 7, CTRL_ES = 1u << 8
};
static const uint32_t MODEM_ID = 0x44564232;   // "DVB2"

struct Modem {
    uhd::wb_iface::sptr regs;
    std::mutex m;
    void wr(uint32_t reg, uint32_t v)
    {
        std::lock_guard<std::mutex> l(m);
        regs->poke32(4 * reg, v);
    }
    // status words 0..31 (see rtl/b210/dvbs2_b210.v)
    std::vector<uint32_t> status()
    {
        std::lock_guard<std::mutex> l(m);
        std::vector<uint32_t> s(32);
        for (uint32_t k = 0; k < 16; k++) {
            uint64_t v = regs->peek64(8 * k);
            s[2 * k]     = uint32_t(v);
            s[2 * k + 1] = uint32_t(v >> 32);
        }
        return s;
    }
};

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

static std::atomic<bool> stop_signal{false};
static FILE* g_log = stdout;     // status output (stderr when the payload goes to stdout)
static void sig_int_handler(int) { stop_signal = true; }

// ---------------------------------------------------------------- TX thread
struct TxStats {
    std::atomic<uint64_t> samples{0}, bytes{0}, pad{0}, underflows{0};
    std::atomic<bool> pad_done{false};
    uint64_t pad_bytes = 0;      // zero bytes appended after the end of the input (flushes the last frame)
};

// Input reader: a separate thread reads the file / stdin into a bounded queue, so the
// TX stream never blocks on a slow pipe (it sends empty samples instead -> dummy frames)
// ---------------------------------------------------------------- file framing
// The receiver can only lock after the transmitter has started, so the TX first sends
// a preamble of zero bytes, then a header (magic + length + ~length), then the file.
// The RX side discards everything before a valid header and stops after <length> bytes,
// so preamble and end padding never reach the output file.
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
            if (!raw && len != LEN_UNKNOWN && ++written >= len) state = 2;
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
    while (!stop_signal) {
        size_t got = fread(b.data(), 1, b.size(), in);
        std::unique_lock<std::mutex> l(iq->m);
        for (size_t i = 0; i < got; i++) {
            iq->cv.wait(l, [&] { return iq->q.size() < InputQueue::CAP || stop_signal; });
            if (stop_signal) return;
            iq->q.push_back(b[i]);
        }
        if (got == 0) {        // EOF or error
            iq->eof = true;
            return;
        }
    }
}

static void tx_worker(uhd::usrp::multi_usrp::sptr usrp, InputQueue* iq, double bytes_per_sample, TxStats* st)
try {
    uhd::set_thread_priority_safe();
    uhd::stream_args_t sa("sc16", "sc16");
    sa.channels = {0};
    auto tx            = usrp->get_tx_stream(sa);
    const size_t n     = tx->get_max_num_samps();
    std::vector<std::complex<int16_t>> buf(n);
    uhd::tx_metadata_t md;
    md.start_of_burst = true;
    md.end_of_burst   = false;
    md.has_time_spec  = false;
    // async messages (underflow) from the device
    std::thread async([&] {
        uhd::async_metadata_t am;
        while (!stop_signal) {
            if (!tx->recv_async_msg(am, 0.2)) continue;
            if (am.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW
                || am.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW_IN_PACKET)
                st->underflows++;
        }
    });
    double acc = 0.0;
    std::vector<uint8_t> chunk;
    while (!stop_signal) {
        // take at most the bytes needed for this buffer from the input queue
        size_t want = iq ? size_t(std::ceil(bytes_per_sample * n)) + 1 : 0;
        chunk.clear();
        bool eof = false;
        if (iq && !st->pad_done) {
            std::lock_guard<std::mutex> l(iq->m);
            while (chunk.size() < want && !iq->q.empty()) {
                chunk.push_back(iq->q.front());
                iq->q.pop_front();
            }
            eof = iq->eof && iq->q.empty();
            iq->cv.notify_one();
        }
        size_t ci = 0;
        for (size_t i = 0; i < n; i++) {
            int16_t I = 0;
            if (iq && !st->pad_done) {
                acc += bytes_per_sample;
                if (acc >= 1.0) {
                    if (ci < chunk.size()) {
                        I = int16_t(0x100 | chunk[ci++]);      // valid flag + payload byte
                        st->bytes++;
                        acc -= 1.0;
                    } else if (eof) {
                        // input finished: pad with zeros so the last BBFRAME is completed and sent
                        I = int16_t(0x100);
                        acc -= 1.0;
                        if (++st->pad >= st->pad_bytes) st->pad_done = true;
                    } else {
                        acc = 0.0;          // input not ready (slow pipe): no byte, TX sends dummy frames
                    }
                }
            }
            buf[i] = std::complex<int16_t>(I, 0);
        }
        // bytes taken but not used go back to the front of the queue
        if (ci < chunk.size()) {
            std::lock_guard<std::mutex> l(iq->m);
            for (size_t k = chunk.size(); k > ci; k--) iq->q.push_front(chunk[k - 1]);
        }
        tx->send(&buf.front(), n, md, 1.0);
        md.start_of_burst = false;
        st->samples += n;
    }
    md.end_of_burst = true;
    tx->send("", 0, md);
    async.join();
} catch (const std::exception& e) {
    fprintf(stderr, "TX thread error: %s\n", e.what());
    stop_signal = true;
}

// ---------------------------------------------------------------- RX thread
struct RxStats {
    std::atomic<uint64_t> samples{0}, bytes{0}, seq_gaps{0}, file_gaps{0}, frames_out{0}, overflows{0};
    std::atomic<uint64_t> file_len{0}, file_written{0};
    std::atomic<int> file_state{0};
};
static void rx_worker(uhd::usrp::multi_usrp::sptr usrp, FileSink* sink, bool data_mode, RxStats* st)
try {
    uhd::set_thread_priority_safe();
    uhd::stream_args_t sa("sc16", "sc16");
    sa.channels = {0};
    auto rx        = usrp->get_rx_stream(sa);
    const size_t n = rx->get_max_num_samps();
    std::vector<std::complex<int16_t>> buf(n);
    uhd::rx_metadata_t md;
    uhd::stream_cmd_t cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
    cmd.stream_now = true;
    rx->issue_stream_cmd(cmd);
    uint16_t last_seq = 0;
    bool have_seq     = false;
    while (!stop_signal) {
        size_t got = rx->recv(&buf.front(), n, md, 1.0);
        if (md.error_code == uhd::rx_metadata_t::ERROR_CODE_OVERFLOW) {
            st->overflows++;
            continue;
        }
        if (md.error_code != uhd::rx_metadata_t::ERROR_CODE_NONE
            && md.error_code != uhd::rx_metadata_t::ERROR_CODE_TIMEOUT) {
            std::cerr << "RX error: " << md.strerror() << std::endl;
            continue;
        }
        st->samples += got;
        if (!data_mode)
            continue;
        for (size_t i = 0; i < got; i++) {
            uint16_t I = uint16_t(buf[i].real());
            if (!(I & 0x100))
                continue;
            uint16_t seq = uint16_t(buf[i].imag());
            if (have_seq && seq != uint16_t(last_seq + 1)) {
                st->seq_gaps++;
                if (sink->state == 1) st->file_gaps++;
            }
            last_seq = seq;
            have_seq = true;
            st->bytes++;
            sink->byte(uint8_t(I & 0xFF));
            if (I & 0x200)
                st->frames_out++;
        }
        sink->flush();
        st->file_state   = sink->state;
        st->file_len     = sink->len;
        st->file_written = sink->written;
    }
    rx->issue_stream_cmd(uhd::stream_cmd_t(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS));
} catch (const std::exception& e) {
    fprintf(stderr, "RX thread error: %s\n", e.what());
    stop_signal = true;
}

// ---------------------------------------------------------------- status printing
static void print_rx(const std::vector<uint32_t>& s, double rs, const RxStats& rst, bool data_mode)
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
    if (data_mode) {
        fprintf(g_log, " | payload %llu B, seq gaps %llu", (unsigned long long)rst.bytes.load(),
            (unsigned long long)rst.seq_gaps.load());
        int fs = rst.file_state;
        if (fs == 0)
            fprintf(g_log, " | file: waiting for header");
        else if (rst.file_len == LEN_UNKNOWN)
            fprintf(g_log, " | stream: %llu B", (unsigned long long)rst.file_written.load());
        else
            fprintf(g_log, " | file: %llu/%llu B%s", (unsigned long long)rst.file_written.load(),
                (unsigned long long)rst.file_len.load(), fs == 2 ? " DONE" : "");
    }
    else
        fprintf(g_log, " | BER %s %u/%llu = %.2e", berlock ? "lock" : "----", s[16], (unsigned long long)bits, ber);
    if (rst.overflows)
        fprintf(g_log, " | host O %llu", (unsigned long long)rst.overflows.load());
    fprintf(g_log, "\n");
    fflush(g_log);
}
static void print_tx(const std::vector<uint32_t>& s, const TxStats& tst, bool data_mode)
{
    fprintf(g_log, "TX frames encoded %u sent %u dummy %u | DUC underflow %u | samples %llu", s[17], s[18], s[19],
        s[26], (unsigned long long)tst.samples.load());
    if (tst.underflows)
        fprintf(g_log, " | host U %llu (USB too slow: lower --rs)", (unsigned long long)tst.underflows.load());
    if (data_mode)
        fprintf(g_log, " | payload in %llu B (FPGA %u, overflow %u, buffered %u)", (unsigned long long)tst.bytes.load(),
            s[23], s[24], s[22] >> 20);
    fprintf(g_log, "\n");
    fflush(g_log);
}

int UHD_SAFE_MAIN(int argc, char* argv[])
{
    std::string args, fpga, mode, input, output, tx_ant, rx_ant, ref;
    double freq, tx_freq, rx_freq, rs, mcr, tx_gain, rx_gain, duration, preamble;
    int modcod, rolloff_i, max_iter;
    bool no_pilots, raw;
    po::options_description desc("dvbs2_b210 options");
    // clang-format off
    desc.add_options()
        ("help,h", "help")
        ("args", po::value<std::string>(&args)->default_value(""), "UHD device args, e.g. serial=3xxxxxx")
        ("fpga", po::value<std::string>(&fpga)->default_value("usrp_b210_dvbs2_fpga.bin"), "DVB-S2 FPGA image")
        ("mode", po::value<std::string>(&mode)->default_value("rx"), "tx | rx | trx")
        ("freq", po::value<double>(&freq)->default_value(2.45e9), "RF frequency (Hz)")
        ("tx-freq", po::value<double>(&tx_freq)->default_value(0), "TX frequency (default --freq)")
        ("rx-freq", po::value<double>(&rx_freq)->default_value(0), "RX frequency (default --freq)")
        ("rs", po::value<double>(&rs)->default_value(1e6), "symbol rate (sym/s), max 3.84e6")
        ("mcr", po::value<double>(&mcr)->default_value(0), "master clock rate (0 = automatic)")
        ("modcod", po::value<int>(&modcod)->default_value(13), "1..10 QPSK 1/4..8/9, 12..16 8PSK 3/5..8/9")
        ("no-pilots", po::bool_switch(&no_pilots), "transmit without pilots")
        ("rolloff", po::value<int>(&rolloff_i)->default_value(35), "35 | 25 | 20")
        ("tx-gain", po::value<double>(&tx_gain)->default_value(60), "TX gain (dB)")
        ("rx-gain", po::value<double>(&rx_gain)->default_value(40), "RX gain (dB)")
        ("tx-ant", po::value<std::string>(&tx_ant)->default_value("TX/RX"), "TX antenna")
        ("rx-ant", po::value<std::string>(&rx_ant)->default_value("RX2"), "RX antenna")
        ("ref", po::value<std::string>(&ref)->default_value("internal"), "clock reference: internal | external (10 MHz REF IN) | gpsdo")
        ("input", po::value<std::string>(&input)->default_value(""), "TX payload file ('-' = stdin); none = PRBS")
        ("output", po::value<std::string>(&output)->default_value(""), "RX payload file ('-' = stdout); none = PRBS BER check")
        ("max-iter", po::value<int>(&max_iter)->default_value(25), "LDPC iterations")
        ("preamble", po::value<double>(&preamble)->default_value(1.0), "TX: seconds of zero bytes before the file (RX lock time)")
        ("raw", po::bool_switch(&raw), "no file header: TX sends the bytes as they are, RX writes every byte")
        ("duration", po::value<double>(&duration)->default_value(0), "seconds to run (0 = until Ctrl-C)");
    // clang-format on
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if (vm.count("help")) {
        std::cout << desc << std::endl;
        return EXIT_SUCCESS;
    }
    const bool do_tx = (mode == "tx" || mode == "trx");
    const bool do_rx = (mode == "rx" || mode == "trx");
    if (!do_tx && !do_rx)
        throw std::runtime_error("--mode must be tx, rx or trx");
    if (kbch_of(modcod) == 0)
        throw std::runtime_error("unsupported --modcod");
    const int ro       = rolloff_i == 25 ? 1 : rolloff_i == 20 ? 2 : 0;
    const bool pilots  = !no_pilots;
    const bool tx_data = do_tx && !input.empty();
    const bool rx_data = do_rx && !output.empty();
    if (output == "-") g_log = stderr;
    if (tx_freq == 0) tx_freq = freq;
    if (rx_freq == 0) rx_freq = freq;

    // sample rate = 2 Rs; >= 8 radio clocks per sample
    const double fs = 2.0 * rs;
    if (mcr == 0) {
        // interpolation / decimation d = MCR / fs: >= 8, multiple of 4 (CIC + halfbands),
        // MCR around 16 MHz or more
        int d = int(std::ceil(16e6 / fs));
        d     = std::max(8, (d + 3) / 4 * 4);
        if (fs * d > 61.44e6) d = 8;
        mcr = fs * d;
    }
    if (mcr / fs < 8.0 - 1e-9 || mcr > 61.44e6)
        throw std::runtime_error("need master clock >= 8 x sample rate and <= 61.44 MHz: lower --rs");

    FILE* fin  = nullptr;
    FILE* fout = nullptr;
    if (tx_data) fin = (input == "-") ? stdin : fopen(input.c_str(), "rb");
    if (rx_data) fout = (output == "-") ? stdout : fopen(output.c_str(), "wb");
    if ((tx_data && !fin) || (rx_data && !fout))
        throw std::runtime_error("cannot open payload file " + (tx_data && !fin ? input : output));

    // ---- open the device with the DVB-S2 FPGA image
    std::string dev_args = args;
    if (!dev_args.empty()) dev_args += ",";
    dev_args += "fpga=" + fpga + ",enable_user_regs,master_clock_rate=" + std::to_string(mcr);
    fprintf(g_log, "Opening B210 with %s\n", dev_args.c_str());
    auto usrp = uhd::usrp::multi_usrp::make(dev_args);
    if (ref != "internal") {
        usrp->set_clock_source(ref);
        std::this_thread::sleep_for(std::chrono::milliseconds(500));   // let the reference PLL lock
        auto sn = usrp->get_mboard_sensor_names(0);
        if (std::find(sn.begin(), sn.end(), "ref_locked") != sn.end())
            fprintf(g_log, "reference %s: %s\n", ref.c_str(),
                usrp->get_mboard_sensor("ref_locked", 0).to_bool() ? "locked" : "NOT locked");
    }
    usrp->set_rx_subdev_spec(std::string("A:A"));
    usrp->set_tx_subdev_spec(std::string("A:A"));
    if (do_rx) {
        usrp->set_rx_rate(fs, 0);
        usrp->set_rx_freq(uhd::tune_request_t(rx_freq), 0);
        usrp->set_rx_gain(rx_gain, 0);
        usrp->set_rx_antenna(rx_ant, 0);
    }
    if (do_tx) {
        usrp->set_tx_rate(fs, 0);
        usrp->set_tx_freq(uhd::tune_request_t(tx_freq), 0);
        usrp->set_tx_gain(tx_gain, 0);
        usrp->set_tx_antenna(tx_ant, 0);
    }
    const double mcr_act = usrp->get_master_clock_rate();
    const double fs_act  = do_rx ? usrp->get_rx_rate(0) : usrp->get_tx_rate(0);
    fprintf(g_log, "master clock %.3f MHz, sample rate %.4f MS/s (%.1f clocks/sample), symbol rate %.4f Msym/s\n",
        mcr_act / 1e6, fs_act / 1e6, mcr_act / fs_act, fs_act / 2e6);
    if (mcr_act / fs_act < 7.999)
        throw std::runtime_error("less than 8 radio clocks per sample");

    Modem modem;
    modem.regs = usrp->get_user_settings_iface(0);
    if (!modem.regs)
        throw std::runtime_error("no user settings interface (UHD too old?)");
    auto s0 = modem.status();
    if (s0[30] != MODEM_ID) {
        fprintf(stderr, "DVB-S2 modem not found in the FPGA (ID word 0x%08x). Is --fpga the DVB-S2 image?\n", s0[30]);
        return EXIT_FAILURE;
    }
    fprintf(g_log, "DVB-S2 modem found, version %u.%u\n", s0[31] >> 16, s0[31] & 0xFFFF);

    // ---- configure
    uint32_t ctrl = CTRL_PLL | CTRL_AGC | CTRL_ES;
    modem.wr(REG_CTRL, ctrl);                       // both parts held in reset
    modem.wr(REG_TXCFG, uint32_t(modcod & 31) | (pilots ? 1u << 8 : 0u) | (uint32_t(ro) << 12));
    modem.wr(REG_FEC, (uint32_t(max_iter & 63) << 16) | (16u << 8) | 24u);
    if (do_tx) ctrl |= CTRL_TX_EN | (tx_data ? CTRL_TX_DATA : 0);
    if (do_rx) ctrl |= CTRL_RX_EN | (rx_data ? CTRL_RX_DATA : 0);
    modem.wr(REG_CTRL, ctrl);
    modem.wr(REG_CLR, 1);
    fprintf(g_log, "%s, %s, roll-off 0.%02d, %s%s\n", MODCOD_NAME[modcod], pilots ? "pilots" : "no pilots", rolloff_i,
        do_tx ? (tx_data ? "TX payload from file " : "TX PRBS ") : "", do_rx ? (rx_data ? "RX payload to file" : "RX PRBS check") : "");

    // payload rate: 90 % of the frame capacity, in bytes per sample (2 samples / symbol)
    const double bps = 0.9 * double((kbch_of(modcod) - 80) / 8) / (2.0 * frame_symbols(modcod, pilots));
    if (tx_data)
        fprintf(g_log, "payload capacity %.1f kB/s, sending at %.1f kB/s\n", bps / 0.9 * fs_act / 1e3, bps * fs_act / 1e3);

    std::signal(SIGINT, &sig_int_handler);
    TxStats tst;
    tst.pad_bytes = 2 * uint64_t((kbch_of(modcod) - 80) / 8);
    RxStats rst;
    InputQueue iq;
    std::thread ttx, trx, trd;
    std::vector<uint8_t> prefix;
    if (tx_data && !raw) {
        // preamble (zero bytes while the receiver locks) + header
        prefix.assign(size_t(std::max(0.0, preamble) * bps * fs_act), 0);
        uint64_t flen = LEN_UNKNOWN;
        if (fin != stdin && fseek(fin, 0, SEEK_END) == 0) {
            long sz = ftell(fin);
            if (sz >= 0) flen = uint64_t(sz);
            fseek(fin, 0, SEEK_SET);
        }
        prefix.insert(prefix.end(), FILE_MAGIC, FILE_MAGIC + 8);
        put_u64(prefix, flen);
        put_u64(prefix, ~flen);
        if (flen != LEN_UNKNOWN)
            fprintf(g_log, "file %s: %llu bytes, after %.1f s preamble\n", input.c_str(), (unsigned long long)flen, preamble);
    }
    FileSink sink;
    sink.raw = raw;
    sink.out = fout;
    if (tx_data) trd = std::thread(reader_worker, fin, &iq, prefix);
    if (do_rx) trx = std::thread(rx_worker, usrp, &sink, rx_data, &rst);
    if (do_tx) ttx = std::thread(tx_worker, usrp, tx_data ? &iq : nullptr, bps, &tst);
    // time for the FPGA buffers to drain after the last byte: payload FIFO (2 KB) + 2 frames
    const double frame_s = frame_symbols(modcod, pilots) / (fs_act / 2);
    const double drain_s = 2048.0 / (bps * fs_act) + 3.0 * frame_s + 0.2;

    auto t0       = std::chrono::steady_clock::now();
    bool cleared  = false;
    while (!stop_signal) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        auto s = modem.status();
        if (do_tx) print_tx(s, tst, tx_data);
        if (do_rx) {
            print_rx(s, fs_act / 2, rst, rx_data);
            // restart the BER statistics once, after the receiver has settled
            if (!cleared && ((s[0] >> 14) & 1) && s[10] >= 5) {
                modem.wr(REG_CLR, 1);
                cleared = true;
                fprintf(g_log, "(statistics cleared after lock)\n");
            }
        }
        double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        if (duration > 0 && el >= duration) stop_signal = true;
        if (rx_data && !raw && rst.file_state == 2 && rst.file_len != LEN_UNKNOWN) {
            fprintf(g_log, "file received: %llu bytes, seq gaps inside the file %llu%s\n",
                (unsigned long long)rst.file_written.load(), (unsigned long long)rst.file_gaps.load(),
                rst.file_gaps ? "  (bytes were lost: the file is incomplete)" : "");
            if (!do_tx || !tx_data || tst.pad_done) stop_signal = true;
        }
        if (tx_data && tst.pad_done && !do_rx) {
            // input sent and padded: let the FPGA buffers drain, then stop
            std::this_thread::sleep_for(std::chrono::duration<double>(drain_s));
            fprintf(g_log, "input sent (%llu bytes incl. preamble and header, + %llu padding bytes)\n",
                (unsigned long long)tst.bytes.load(), (unsigned long long)tst.pad.load());
            stop_signal = true;
        }
    }
    if (ttx.joinable()) ttx.join();
    if (trx.joinable()) trx.join();
    {
        std::lock_guard<std::mutex> l(iq.m);
        iq.cv.notify_all();
    }
    if (trd.joinable()) {
        // a reader blocked in fread() on stdin cannot be interrupted: detach it
        if (input == "-") trd.detach(); else trd.join();
    }
    modem.wr(REG_CTRL, CTRL_PLL | CTRL_AGC | CTRL_ES);    // modem off: radio back to normal
    if (fin && fin != stdin) fclose(fin);
    if (fout && fout != stdout) fclose(fout);
    fprintf(g_log, "done\n");
    return EXIT_SUCCESS;
}
