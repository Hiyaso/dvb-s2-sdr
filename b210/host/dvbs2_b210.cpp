//
// dvbs2_b210 -- PC side of the DVB-S2 modem running inside the USRP B210 FPGA.
//
//   * loads the custom FPGA image (usrp_b210_dvbs2_fpga.bin) when the device is opened
//   * sets RF (frequency, gain, analog bandwidth, antenna), master clock and sample rate
//     (2 x symbol rate; symbol rate = bandwidth / (1 + roll-off) or --rs)
//   * configures the modem through the UHD user-settings registers
//   * TX: keeps the TX stream running; optional payload bytes from a file / stdin,
//         or UDP datagrams (--udp-in, framed as in udp_frame.hpp)
//   * RX: reports lock / MODCOD / CFO / FEC / BER once per second; optional payload
//         bytes to a file / stdout, or the recovered UDP datagrams (--udp-out)
//   * --web PORT: web page with TX/RX status, received spectrum, constellation and file loopback;
//         TX/RX frequency, bandwidth and gain can be changed while running
//
// Two PCs:   PC1:  dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6
//            PC2:  dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6
// One B210: dvbs2_b210 --mode trx ...   (TX on TX/RX A, RX on RX2 A, cable + attenuator)
//           dvbs2_b210 --web 8080       (trx, 1 GHz, 2 MHz, browser at http://localhost:8080)
//
#include <uhd/types/wb_iface.hpp>
#include <uhd/usrp/multi_usrp.hpp>
#include <uhd/utils/safe_main.hpp>
#include <uhd/utils/thread.hpp>
#include <boost/program_options.hpp>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
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
#include "dsp_util.hpp"
#include "dvbs2_common.hpp"
#include "file_xfer.hpp"
#include "mini_http.hpp"
#include "net_udp.hpp"

namespace po = boost::program_options;

// ---------------------------------------------------------------- modem registers
enum : uint32_t {
    REG_CTRL = 0, REG_TXCFG = 1, REG_AGC = 2, REG_TIM = 3, REG_FS = 4, REG_FLL = 5, REG_FEC = 6, REG_CLR = 7,
    REG_CAP = 8
};
enum : uint32_t {
    CTRL_TX_EN = 1u << 0, CTRL_RX_EN = 1u << 1, CTRL_TX_DATA = 1u << 2, CTRL_RX_DATA = 1u << 3,
    CTRL_PLL = 1u << 6, CTRL_AGC = 1u << 7, CTRL_ES = 1u << 8
};
static const uint32_t MODEM_ID = 0x44564232;   // "DVB2"
static const int CAP_N         = 1024;         // spectrum snapshot length (samples)
static const int CONST_N       = 512;          // constellation points read per snapshot (of the 1024 captured)

struct Modem {
    uhd::wb_iface::sptr regs;
    std::mutex m;
    void wr(uint32_t reg, uint32_t v)
    {
        std::lock_guard<std::mutex> l(m);
        regs->poke32(4 * reg, v);
    }
    // status words 0..31 (see b210/rtl/dvbs2_b210.v)
    std::atomic<int> prio{0};                  // status() waiting: snapshot reads step aside
    std::vector<uint32_t> status()
    {
        prio++;
        std::lock_guard<std::mutex> l(m);
        prio--;
        std::vector<uint32_t> s(32);
        for (uint32_t k = 0; k < 16; k++) {
            uint64_t v = regs->peek64(8 * k);
            s[2 * k]     = uint32_t(v);
            s[2 * k + 1] = uint32_t(v >> 32);
        }
        return s;
    }
    // 1024 consecutive DDC samples (FPGA version >= 2.1); empty if the capture did not finish
    // (512 register reads, ~0.3 s over USB; locked per access so status() can run in between)
    uint64_t rd(uint32_t addr)
    {
        while (prio) std::this_thread::yield();
        std::lock_guard<std::mutex> l(m);
        return regs->peek64(addr);
    }
    std::vector<std::complex<float>> snapshot()
    {
        std::vector<std::complex<float>> x;
        wr(REG_CAP, 1);
        bool done = false;
        for (int t = 0; t < 50 && !done; t++) {
            done = (uint32_t(rd(8 * 14) >> 32) >> 31) & 1;    // status word 29 bit 31
            if (!done) std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        if (!done) return x;
        x.reserve(CAP_N);
        for (uint32_t page = 0; page < 4; page++) {
            wr(REG_CAP, page << 8);
            for (uint32_t w = 0; w < 128; w++) {
                uint64_t v = rd(8 * (128 + w));
                for (int h = 0; h < 2; h++) {
                    uint32_t s = uint32_t(v >> (32 * h));
                    x.emplace_back(float(int16_t(s >> 16)), float(int16_t(s & 0xFFFF)));
                }
            }
        }
        return x;
    }
    // CONST_N data symbols after carrier recovery (FPGA version >= 2.2), scaled to radius 1;
    // empty if the capture did not finish (receiver not locked, only dummy frames)
    std::vector<std::complex<float>> constellation()
    {
        std::vector<std::complex<float>> x;
        wr(REG_CAP, 3);
        bool done = false;
        for (int t = 0; t < 50 && !done; t++) {
            const uint32_t w29 = uint32_t(rd(8 * 14) >> 32);
            done = (w29 >> 31) & (w29 >> 29) & 1;              // done, source = symbols
            if (!done) std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        if (!done) return x;
        x.reserve(CONST_N);
        for (uint32_t page = 0; page < uint32_t(CONST_N / 256); page++) {
            wr(REG_CAP, page << 8);
            for (uint32_t w = 0; w < 128; w++) {
                uint64_t v = rd(8 * (128 + w));
                for (int h = 0; h < 2; h++) {
                    uint32_t s = uint32_t(v >> (32 * h));
                    x.emplace_back(float(int16_t(s >> 16)) / 4096.0f, float(int16_t(s & 0xFFFF)) / 4096.0f);
                }
            }
        }
        return x;
    }
};

static void sig_int_handler(int) { stop_signal = true; }

// ---------------------------------------------------------------- TX thread
struct TxStats {
    std::atomic<uint64_t> samples{0}, bytes{0}, pad{0}, fill{0}, underflows{0};
    std::atomic<bool> pad_done{false};
    uint64_t pad_bytes = 0;      // zero bytes appended after the end of the input (flushes the last frame)
    // fill: zero bytes that complete a BBFRAME while the (UDP) input is idle
};

static void tx_worker(uhd::usrp::multi_usrp::sptr usrp, InputQueue* iq, double bytes_per_sample, size_t fill_frame,
    TxStats* st)
{
    std::atomic<bool> async_stop{false};
    std::thread async;
    try {
        uhd::set_thread_priority_safe();
        uhd::stream_args_t sa("sc16", "sc16");
        sa.channels = {0};
        auto tx        = usrp->get_tx_stream(sa);
        const size_t n = tx->get_max_num_samps();
        std::vector<std::complex<int16_t>> buf(n);
        uhd::tx_metadata_t md;
        md.start_of_burst = true;
        md.end_of_burst   = false;
        md.has_time_spec  = false;
        // async messages (underflow) from the device
        async = std::thread([&] {
            uhd::async_metadata_t am;
            while (!async_stop) {
                if (!tx->recv_async_msg(am, 0.2)) continue;
                if (am.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW
                    || am.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW_IN_PACKET)
                    st->underflows++;
            }
        });
        double acc = 0.0;
        uint64_t sent = 0;       // bytes given to the FPGA: BBFRAMEs take exactly fill_frame bytes each
        std::vector<uint8_t> chunk;
        while (running()) {
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
            // queue empty: fill_frame > 0 (UDP) completes the BBFRAME with zero bytes so the last
            // datagram goes out now (the queue holds whole datagrams, so this is between two of them)
            const bool fill = fill_frame && chunk.size() < want;
            size_t ci = 0;
            for (size_t i = 0; i < n; i++) {
                int16_t I = 0;
                if (iq && !st->pad_done) {
                    acc += bytes_per_sample;
                    if (acc >= 1.0) {
                        if (ci < chunk.size()) {
                            I = int16_t(0x100 | chunk[ci++]);      // valid flag + payload byte
                            st->bytes++;
                            sent++;
                            acc -= 1.0;
                        } else if (fill && sent % fill_frame) {
                            I = int16_t(0x100);
                            st->fill++;
                            sent++;
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
    } catch (const std::exception& e) {
        fprintf(stderr, "TX thread error: %s\n", e.what());
        stop_signal = true;
    }
    async_stop = true;
    if (async.joinable()) async.join();
}

// ---------------------------------------------------------------- RX thread
struct RxStats {
    std::atomic<uint64_t> samples{0}, bytes{0}, seq_gaps{0}, file_gaps{0}, frames_out{0}, overflows{0};
    std::atomic<uint64_t> file_len{0}, file_written{0};
    std::atomic<int> file_state{0};
    // spectrum tap (PRBS mode: the RX stream carries the raw DDC samples): the main loop sets
    // tap_req, rx_worker fills tap with CAP_N consecutive samples and sets tap_ready
    std::atomic<bool> tap_req{false}, tap_ready{false};
    std::vector<std::complex<float>> tap;
};
static void rx_worker(uhd::usrp::multi_usrp::sptr usrp, FileSink* sink, UdpOut* usink, bool data_mode, RxStats* st)
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
    while (running()) {
        size_t got = rx->recv(&buf.front(), n, md, 1.0);
        if (md.error_code == uhd::rx_metadata_t::ERROR_CODE_OVERFLOW) {
            st->overflows++;
            if (!st->tap_ready) st->tap.clear();
            continue;
        }
        if (md.error_code != uhd::rx_metadata_t::ERROR_CODE_NONE
            && md.error_code != uhd::rx_metadata_t::ERROR_CODE_TIMEOUT) {
            std::cerr << "RX error: " << md.strerror() << std::endl;
            continue;
        }
        st->samples += got;
        if (!data_mode) {
            if (st->tap_req && !st->tap_ready) {
                for (size_t i = 0; i < got && st->tap.size() < size_t(CAP_N); i++)
                    st->tap.emplace_back(float(buf[i].real()), float(buf[i].imag()));
                if (st->tap.size() == size_t(CAP_N)) {
                    st->tap_req   = false;
                    st->tap_ready = true;
                }
            }
            continue;
        }
        for (size_t i = 0; i < got; i++) {
            uint16_t I = uint16_t(buf[i].real());
            if (!(I & 0x100))
                continue;
            uint16_t seq = uint16_t(buf[i].imag());
            if (have_seq && seq != uint16_t(last_seq + 1)) {
                st->seq_gaps++;
                if (sink->state == 1) st->file_gaps++;
                if (usink) usink->df.gap();
            }
            last_seq = seq;
            have_seq = true;
            st->bytes++;
            if (usink)
                usink->df.push(uint8_t(I & 0xFF));
            else
                sink->byte(uint8_t(I & 0xFF));
            if (I & 0x200)
                st->frames_out++;
        }
        sink->flush();
        if (usink) usink->flush();
        st->file_state   = sink->state;
        st->file_len     = sink->len;
        st->file_written = sink->written;
    }
    rx->issue_stream_cmd(uhd::stream_cmd_t(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS));
    // drain what is still in flight so the next session starts clean
    while (rx->recv(&buf.front(), n, md, 0.1) > 0) {}
} catch (const std::exception& e) {
    fprintf(stderr, "RX thread error: %s\n", e.what());
    stop_signal = true;
}

// ---------------------------------------------------------------- status printing
static void print_rx(const std::vector<uint32_t>& s, double rs, const RxStats& rst, bool data_mode, bool raw,
    const UdpOut* u)
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
    else
        fprintf(g_log, " | BER %s %u/%llu = %.2e", berlock ? "lock" : "----", s[16], (unsigned long long)bits, ber);
    if (rst.overflows)
        fprintf(g_log, " | host O %llu", (unsigned long long)rst.overflows.load());
    fprintf(g_log, "\n");
    fflush(g_log);
}
static void print_tx(const std::vector<uint32_t>& s, const TxStats& tst, bool data_mode, const UdpIn* u)
{
    fprintf(g_log, "TX frames encoded %u sent %u dummy %u | DUC underflow %u | samples %llu", s[17], s[18], s[19],
        s[26], (unsigned long long)tst.samples.load());
    if (tst.underflows)
        fprintf(g_log, " | host U %llu (USB too slow: lower --rs)", (unsigned long long)tst.underflows.load());
    if (data_mode)
        fprintf(g_log, " | payload in %llu B (FPGA %u, overflow %u, buffered %u)", (unsigned long long)tst.bytes.load(),
            s[23], s[24], s[22] >> 20);
    if (u)
        fprintf(g_log, " | udp in %llu pkt %llu B, dropped %llu, fill %llu B", (unsigned long long)u->packets.load(),
            (unsigned long long)u->bytes.load(), (unsigned long long)u->drops.load(),
            (unsigned long long)tst.fill.load());
    fprintf(g_log, "\n");
    fflush(g_log);
}

// ---------------------------------------------------------------- run-time configuration
struct Config {
    double tx_freq = 0, rx_freq = 0;
    double tx_bw = 0, rx_bw = 0;        // occupied bandwidth = Rs (1 + roll-off); also the AD9361 filter
    double tx_gain = 0, rx_gain = 0;
    int modcod = 13, ro = 0, max_iter = 25;
    bool pilots = true;
    std::string tx_ant, rx_ant;
};
struct Actual {
    double mcr = 0, fs_tx = 0, fs_rx = 0;
    double tx_freq = 0, rx_freq = 0, tx_gain = 0, rx_gain = 0, tx_abw = 0, rx_abw = 0;
};

// master clock: >= 8 radio clocks per sample at the higher of the two rates,
// interpolation/decimation a multiple of 4 (CIC + halfbands), MCR around 16 MHz or more
static double choose_mcr(double fs)
{
    int d = int(std::ceil(16e6 / fs));
    d     = std::max(8, (d + 3) / 4 * 4);
    while (fs * d > 61.44e6 && d > 8) d -= 4;
    return fs * d;
}

// ---------------------------------------------------------------- minimal HTTP server (web mode)
struct WebState {
    std::mutex m;
    std::string status_json = "{}", spectrum_json = "{}";
    // requests from the web page, handled by the main loop
    std::map<std::string, double> pending;     // tx_freq, tx_bw, ... -> value
    bool req_send = false, req_prbs = false;
    std::string send_path, send_name;
    std::string rx_path;                       // last received file (download)
};
static WebState g_web;

static const size_t MAX_UPLOAD = size_t(2) << 30;     // 2 GB (at ~300 kB/s that is ~2 h of air time)
static const double BW_MIN = 100e3, BW_MAX = 5.2e6;  // occupied bandwidth range (web page / API)
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
            reply(fd, 413, "application/json", "{\"ok\":false,\"error\":\"file too large (max 2 GB)\"}");
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
        static const char* keys[] = {"tx_freq", "tx_bw", "tx_gain", "rx_freq", "rx_bw", "rx_gain", "tx_on", "rx_on"};
        std::lock_guard<std::mutex> l(g_web.m);
        int n = 0;
        for (const char* k : keys) {
            auto it = kv.find(k);
            if (it == kv.end() || it->second.empty()) continue;
            try {
                g_web.pending[k] = std::stod(it->second);
                n++;
            } catch (...) {
            }
        }
        reply(fd, n ? 200 : 400, "application/json", n ? "{\"ok\":true}" : "{\"ok\":false}");
    } else if (method == "POST" && path == "/api/prbs") {
        std::lock_guard<std::mutex> l(g_web.m);
        g_web.req_prbs = true;
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

// ---------------------------------------------------------------- one streaming session
// RF / rate setup, modem configuration and the TX/RX/reader threads.  A session is
// restarted when the bandwidth (sample rate) or the TX payload source changes.
struct Session {
    bool do_tx = false, do_rx = false, tx_data = false, rx_data = false, raw = false;
    double bps = 0;               // payload bytes per sample (tx_data)
    double fs_act = 0, rs_tx = 0, rs_rx = 0;
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
    std::string result;           // file comparison result (web mode)

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
        modem.wr(REG_CTRL, CTRL_PLL | CTRL_AGC | CTRL_ES);    // modem off (reset): radio back to normal
        if (fin && fin != stdin) fclose(fin);
        if (fout && fout != stdout) fclose(fout);
        fin = fout = nullptr;
        uin.reset();
        uout.reset();
        sess_stop  = false;
    }
};

static Actual apply_rf(uhd::usrp::multi_usrp::sptr usrp, const Config& c, bool do_tx, bool do_rx)
{
    const double a  = rolloff_of(c.ro);
    const double fs_tx = 2.0 * c.tx_bw / (1.0 + a), fs_rx = 2.0 * c.rx_bw / (1.0 + a);
    const double fsmax = std::max(do_tx ? fs_tx : 0.0, do_rx ? fs_rx : 0.0);
    const double mcr   = choose_mcr(fsmax);
    if (mcr / fsmax < 8.0 - 1e-9 || mcr > 61.44e6)
        throw std::runtime_error("need master clock >= 8 x sample rate and <= 61.44 MHz: lower the bandwidth / --rs");
    usrp->set_master_clock_rate(mcr);
    Actual r;
    r.mcr = usrp->get_master_clock_rate();
    if (do_rx) {
        usrp->set_rx_rate(fs_rx, 0);
        usrp->set_rx_freq(uhd::tune_request_t(c.rx_freq), 0);
        usrp->set_rx_gain(c.rx_gain, 0);
        usrp->set_rx_antenna(c.rx_ant, 0);
        usrp->set_rx_bandwidth(c.rx_bw, 0);
        r.fs_rx   = usrp->get_rx_rate(0);
        r.rx_freq = usrp->get_rx_freq(0);
        r.rx_gain = usrp->get_rx_gain(0);
        r.rx_abw  = usrp->get_rx_bandwidth(0);
    }
    if (do_tx) {
        usrp->set_tx_rate(fs_tx, 0);
        usrp->set_tx_freq(uhd::tune_request_t(c.tx_freq), 0);
        usrp->set_tx_gain(c.tx_gain, 0);
        usrp->set_tx_antenna(c.tx_ant, 0);
        usrp->set_tx_bandwidth(c.tx_bw, 0);
        r.fs_tx   = usrp->get_tx_rate(0);
        r.tx_freq = usrp->get_tx_freq(0);
        r.tx_gain = usrp->get_tx_gain(0);
        r.tx_abw  = usrp->get_tx_bandwidth(0);
    }
    return r;
}

int UHD_SAFE_MAIN(int argc, char* argv[])
{
    std::string args, fpga, mode, input, output, udp_in, udp_out, tx_ant, rx_ant, ref, web_bind, web_root, file_dir;
    double freq, tx_freq, rx_freq, rs, bw, tx_bw, rx_bw, tx_gain, rx_gain, duration, preamble;
    int modcod, rolloff_i, max_iter, web_port;
    bool no_pilots, raw;
    po::options_description desc("dvbs2_b210 options");
    // clang-format off
    desc.add_options()
        ("help,h", "help")
        ("args", po::value<std::string>(&args)->default_value(""), "UHD device args, e.g. serial=3xxxxxx")
        ("fpga", po::value<std::string>(&fpga)->default_value("usrp_b210_dvbs2_fpga.bin"), "DVB-S2 FPGA image")
        ("mode", po::value<std::string>(&mode)->default_value(""), "tx | rx | trx (default rx, with --web trx)")
        ("freq", po::value<double>(&freq)->default_value(0), "RF frequency (Hz) (default 2.45e9, with --web 1e9)")
        ("tx-freq", po::value<double>(&tx_freq)->default_value(0), "TX frequency (default --freq)")
        ("rx-freq", po::value<double>(&rx_freq)->default_value(0), "RX frequency (default --freq)")
        ("rs", po::value<double>(&rs)->default_value(0), "symbol rate (sym/s), max 3.84e6 (default 1e6, or from --bw)")
        ("bw", po::value<double>(&bw)->default_value(0), "occupied bandwidth Rs*(1+roll-off) in Hz, sets Rs (with --web default 2e6)")
        ("tx-bw", po::value<double>(&tx_bw)->default_value(0), "TX bandwidth (default --bw)")
        ("rx-bw", po::value<double>(&rx_bw)->default_value(0), "RX bandwidth (default --bw)")
        ("modcod", po::value<int>(&modcod)->default_value(13), "1..10 QPSK 1/4..8/9, 12..16 8PSK 3/5..8/9")
        ("no-pilots", po::bool_switch(&no_pilots), "transmit without pilots")
        ("rolloff", po::value<int>(&rolloff_i)->default_value(35), "35 | 25 | 20")
        ("tx-gain", po::value<double>(&tx_gain)->default_value(-1), "TX gain (dB) (default 60, with --web 40)")
        ("rx-gain", po::value<double>(&rx_gain)->default_value(40), "RX gain (dB)")
        ("tx-ant", po::value<std::string>(&tx_ant)->default_value("TX/RX"), "TX antenna")
        ("rx-ant", po::value<std::string>(&rx_ant)->default_value("RX2"), "RX antenna")
        ("ref", po::value<std::string>(&ref)->default_value("internal"), "clock reference: internal | external (10 MHz REF IN) | gpsdo")
        ("input", po::value<std::string>(&input)->default_value(""), "TX payload file ('-' = stdin); none = PRBS")
        ("output", po::value<std::string>(&output)->default_value(""), "RX payload file ('-' = stdout); none = PRBS BER check")
        ("udp-in", po::value<std::string>(&udp_in)->default_value(""), "TX payload: UDP datagrams received on [addr:]port (addr default 127.0.0.1, 0.0.0.0 = all)")
        ("udp-out", po::value<std::string>(&udp_out)->default_value(""), "RX payload: send the received UDP datagrams to host:port")
        ("max-iter", po::value<int>(&max_iter)->default_value(25), "LDPC iterations (1..50)")
        ("preamble", po::value<double>(&preamble)->default_value(1.0), "TX: seconds of zero bytes before the file (RX lock time)")
        ("raw", po::bool_switch(&raw), "no file header: TX sends the bytes as they are, RX writes every byte")
        ("duration", po::value<double>(&duration)->default_value(0), "seconds to run (0 = until Ctrl-C)")
        ("web", po::value<int>(&web_port)->default_value(0), "web page on this TCP port (0 = off)")
        ("web-bind", po::value<std::string>(&web_bind)->default_value("127.0.0.1"), "web: address to listen on (0.0.0.0 = all)")
        ("web-root", po::value<std::string>(&web_root)->default_value(""), "web: directory with index.html (default <program>/../web, else host_common/web of the source tree)")
        ("file-dir", po::value<std::string>(&file_dir)->default_value("dvbs2_files"), "web: directory for sent / received files");
    // clang-format on
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if (vm.count("help")) {
        std::cout << desc << std::endl;
        return EXIT_SUCCESS;
    }
    const bool web = web_port > 0;
    if (mode.empty()) mode = web ? "trx" : "rx";
    const bool do_tx = (mode == "tx" || mode == "trx");
    const bool do_rx = (mode == "rx" || mode == "trx");
    if (!do_tx && !do_rx)
        throw std::runtime_error("--mode must be tx, rx or trx");
    // TX / RX switched on: from the start on the command line; in web mode off until switched on in the page
    bool tx_on = do_tx && !web, rx_on = do_rx && !web;
    if (kbch_of(modcod) == 0)
        throw std::runtime_error("unsupported --modcod");
    if (rolloff_i != 35 && rolloff_i != 25 && rolloff_i != 20)
        throw std::runtime_error("--rolloff must be 35, 25 or 20");
    if (max_iter < 1 || max_iter > 50)
        throw std::runtime_error("--max-iter must be 1..50");
    if (web && (!input.empty() || !output.empty() || !udp_in.empty() || !udp_out.empty()))
        throw std::runtime_error("--web: send files from the web page instead of --input/--output/--udp-in/--udp-out");
    if (!udp_in.empty() && !input.empty())
        throw std::runtime_error("--udp-in and --input cannot be used together");
    if (!udp_out.empty() && !output.empty())
        throw std::runtime_error("--udp-out and --output cannot be used together");
    if (udp_out.find(':') == std::string::npos && !udp_out.empty())
        throw std::runtime_error("--udp-out needs host:port");
    const int ro       = rolloff_i == 25 ? 1 : rolloff_i == 20 ? 2 : 0;
    const double alpha = rolloff_of(ro);
    if (output == "-") g_log = stderr;

    Config cfg;
    if (freq == 0) freq = web ? 1e9 : 2.45e9;
    cfg.tx_freq = tx_freq ? tx_freq : freq;
    cfg.rx_freq = rx_freq ? rx_freq : freq;
    if (bw == 0) bw = rs ? rs * (1 + alpha) : web ? 2e6 : 1e6 * (1 + alpha);
    cfg.tx_bw   = tx_bw ? tx_bw : bw;
    cfg.rx_bw   = rx_bw ? rx_bw : bw;
    cfg.tx_gain = tx_gain >= 0 ? tx_gain : web ? 40 : 60;
    cfg.rx_gain = rx_gain;
    cfg.modcod  = modcod;
    cfg.pilots  = !no_pilots;
    cfg.ro      = ro;
    cfg.max_iter = max_iter;
    cfg.tx_ant  = tx_ant;
    cfg.rx_ant  = rx_ant;

    // ---- open the device with the DVB-S2 FPGA image
    std::string dev_args = args;
    if (!dev_args.empty()) dev_args += ",";
    // largest USB frames (B200 max 16360 bytes): half the host CPU of the 8 kB default
    // (measured RX 7.68 MS/s: 42 % -> 21 % of a core), unless given in --args
    if (args.find("recv_frame_size") == std::string::npos) dev_args += "recv_frame_size=16360,";
    if (args.find("send_frame_size") == std::string::npos) dev_args += "send_frame_size=16360,";
    const double a0      = rolloff_of(ro);
    const double mcr0    = choose_mcr(2.0 * std::max(do_tx ? cfg.tx_bw : 0.0, do_rx ? cfg.rx_bw : 0.0) / (1 + a0));
    dev_args += "fpga=" + fpga + ",enable_user_regs,master_clock_rate=" + std::to_string(mcr0);
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

    Modem modem;
    modem.regs = usrp->get_user_settings_iface(0);
    if (!modem.regs)
        throw std::runtime_error("no user settings interface (UHD too old?)");
    auto s0 = modem.status();
    if (s0[30] != MODEM_ID) {
        fprintf(stderr, "DVB-S2 modem not found in the FPGA (ID word 0x%08x). Is --fpga the DVB-S2 image?\n", s0[30]);
        return EXIT_FAILURE;
    }
    const bool has_cap   = (s0[31] & 0xFFFF) >= 1;   // version 2.1: spectrum snapshot
    const bool has_const = (s0[31] & 0xFFFF) >= 2;   // version 2.2: constellation snapshot
    fprintf(g_log, "DVB-S2 modem found, version %u.%u\n", s0[31] >> 16, s0[31] & 0xFFFF);
    if (web && !has_cap)
        fprintf(g_log, "note: this FPGA image has no spectrum snapshot (version < 2.1), the web page shows no spectrum\n");
    else if (web && !has_const)
        fprintf(g_log, "note: this FPGA image has no constellation snapshot (version < 2.2), the web page shows no constellation\n");
    if (web) mkdir(file_dir.c_str(), 0755);
    if (web_root.empty()) web_root = default_web_root(exe_dir() + "/../web");

    std::signal(SIGINT, &sig_int_handler);
    std::thread tweb;
    if (web)
        tweb = std::thread(web_server, web_port, web_bind, "localhost",
            [web_root, file_dir](int fd) { handle_client(fd, web_root, file_dir); });

    // ---- session start: RF, rates, modem registers, threads
    Session S;
    Actual act;
    auto start_session = [&](const std::string& in, const std::string& out, const std::string& name) {
        S         = Session();
        S.do_tx   = do_tx && tx_on;
        S.do_rx   = do_rx && rx_on;
        S.tx_data = S.do_tx && (!in.empty() || !udp_in.empty());
        S.rx_data = S.do_rx && (!out.empty() || !udp_out.empty());
        S.raw     = raw;
        S.in_path = in;
        S.in_name = name;
        S.out_path = out;
        act       = apply_rf(usrp, cfg, do_tx, do_rx);    // both sides configured, only the switched-on ones stream
        S.fs_act  = do_rx ? act.fs_rx : act.fs_tx;
        S.rs_tx   = act.fs_tx / 2;
        S.rs_rx   = act.fs_rx / 2;
        fprintf(g_log, "TX %s, RX %s | master clock %.3f MHz", S.do_tx ? "on" : "off", S.do_rx ? "on" : "off", act.mcr / 1e6);
        if (S.do_tx) fprintf(g_log, " | TX %.4f MS/s (%.1f clk/sample), Rs %.4f Msym/s, %.3f MHz, gain %.1f dB",
                       act.fs_tx / 1e6, act.mcr / act.fs_tx, S.rs_tx / 1e6, act.tx_freq / 1e6, act.tx_gain);
        if (S.do_rx) fprintf(g_log, " | RX %.4f MS/s (%.1f clk/sample), Rs %.4f Msym/s, %.3f MHz, gain %.1f dB",
                       act.fs_rx / 1e6, act.mcr / act.fs_rx, S.rs_rx / 1e6, act.rx_freq / 1e6, act.rx_gain);
        fprintf(g_log, "\n");
        if ((do_rx && act.mcr / act.fs_rx < 7.999) || (do_tx && act.mcr / act.fs_tx < 7.999))
            throw std::runtime_error("less than 8 radio clocks per sample");

        if (S.tx_data && udp_in.empty()) {
            S.fin = (in == "-") ? stdin : fopen(in.c_str(), "rb");
            if (!S.fin) throw std::runtime_error("cannot open payload file " + in);
        }
        if (S.rx_data && udp_out.empty()) {
            S.fout = (out == "-") ? stdout : fopen(out.c_str(), "wb");
            if (!S.fout) throw std::runtime_error("cannot open payload file " + out);
        }
        if (S.tx_data && !udp_in.empty()) {
            S.uin           = std::unique_ptr<UdpIn>(new UdpIn());
            const sockaddr_in a = udp_addr(udp_in, "127.0.0.1");
            S.uin->fd       = socket(AF_INET, SOCK_DGRAM, 0);
            const int one   = 1, rcvbuf = 4 << 20;
            timeval tv{0, 100000};
            setsockopt(S.uin->fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            setsockopt(S.uin->fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
            setsockopt(S.uin->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            if (S.uin->fd < 0 || bind(S.uin->fd, (const sockaddr*)&a, sizeof(a)) < 0)
                throw std::runtime_error("cannot bind UDP " + addr_str(a) + ": " + strerror(errno));
            fprintf(g_log, "TX payload: UDP datagrams received on %s\n", addr_str(a).c_str());
        }
        if (S.rx_data && !udp_out.empty()) {
            S.uout      = std::unique_ptr<UdpOut>(new UdpOut());
            S.uout->dst = udp_addr(udp_out, "");
            S.uout->fd  = socket(AF_INET, SOCK_DGRAM, 0);
            if (S.uout->fd < 0) throw std::runtime_error("cannot open a UDP socket");
            fprintf(g_log, "RX payload: UDP datagrams sent to %s\n", addr_str(S.uout->dst).c_str());
        }

        // ---- configure the modem
        uint32_t ctrl = CTRL_PLL | CTRL_AGC | CTRL_ES;
        modem.wr(REG_CTRL, ctrl);                       // both parts held in reset
        modem.wr(REG_TXCFG, uint32_t(cfg.modcod & 31) | (cfg.pilots ? 1u << 8 : 0u) | (uint32_t(cfg.ro) << 12));
        modem.wr(REG_FEC, (uint32_t(cfg.max_iter & 63) << 16) | (16u << 8) | 24u);
        if (S.do_tx) ctrl |= CTRL_TX_EN | (S.tx_data ? CTRL_TX_DATA : 0);
        if (S.do_rx) ctrl |= CTRL_RX_EN | (S.rx_data ? CTRL_RX_DATA : 0);
        modem.wr(REG_CTRL, ctrl);
        modem.wr(REG_CLR, 1);
        fprintf(g_log, "%s, %s, roll-off 0.%02d, %s%s\n", MODCOD_NAME[cfg.modcod], cfg.pilots ? "pilots" : "no pilots",
            rolloff_i, S.do_tx ? (S.uin ? "TX payload from UDP " : S.tx_data ? "TX payload from file " : "TX PRBS ") : "",
            S.do_rx ? (S.uout ? "RX payload to UDP" : S.rx_data ? "RX payload to file" : "RX PRBS check") : "");

        // payload rate: 90 % of the frame capacity, in bytes per sample (2 samples / symbol)
        S.bps = 0.9 * double((kbch_of(cfg.modcod) - 80) / 8) / (2.0 * frame_symbols(cfg.modcod, cfg.pilots));
        if (S.tx_data)
            fprintf(g_log, "payload capacity %.1f kB/s, sending at %.1f kB/s\n", S.bps / 0.9 * act.fs_tx / 1e3,
                S.bps * act.fs_tx / 1e3);

        S.tst            = std::unique_ptr<TxStats>(new TxStats());
        S.tst->pad_bytes = 2 * uint64_t((kbch_of(cfg.modcod) - 80) / 8);
        S.rst            = std::unique_ptr<RxStats>(new RxStats());
        S.iq             = std::unique_ptr<InputQueue>(new InputQueue());
        S.sink           = std::unique_ptr<FileSink>(new FileSink());
        std::vector<uint8_t> prefix;
        const size_t dfl_bytes = size_t(kbch_of(cfg.modcod) - 80) / 8;
        // UDP: queue at most ~0.2 s of air time (and at least one maximum-size datagram)
        if (S.uin) S.uin->limit = std::max(size_t(0.2 * S.bps * act.fs_tx), UDP_MAX_PAYLOAD + UDP_OVERHEAD);
        if (S.tx_data && !raw && !S.uin) {
            // preamble (zero bytes while the receiver locks) + header
            prefix.assign(size_t(std::max(0.0, preamble) * S.bps * act.fs_tx), 0);
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
        if (S.uin)
            S.trd = std::thread(udp_reader_worker, S.uin.get(), S.iq.get());
        else if (S.tx_data)
            S.trd = std::thread(reader_worker, S.fin, S.iq.get(), prefix);
        if (S.do_rx) S.trx = std::thread(rx_worker, usrp, S.sink.get(), S.uout.get(), S.rx_data, S.rst.get());
        if (S.do_tx)
            S.ttx = std::thread(tx_worker, usrp, S.tx_data ? S.iq.get() : nullptr, S.bps, S.uin ? dfl_bytes : 0,
                S.tst.get());
        S.t0 = std::chrono::steady_clock::now();
    };

    start_session(input, output, input);

    // ---- web status / spectrum / constellation
    std::vector<float> spec_db;
    double spec_fs = 0, spec_fc = 0;
    std::vector<std::complex<float>> const_x;  // latest constellation (radius 1)
    double const_t = 0;                        // time it was read
    // file mode: the RX stream carries payload bytes, so the spectrum comes from the FPGA snapshot,
    // read in its own thread (~0.3 s per snapshot) to keep the status at 10 Hz; the constellation
    // (data symbols, ~0.08 s per snapshot) is read there too, in both modes, while RX is locked
    std::mutex snap_m, snap_busy;              // snap_busy: held per snapshot and around radio reconfiguration
    std::vector<std::complex<float>> snap_x, snap_c;
    std::atomic<bool> snap_on{false}, const_on{false};
    std::thread snap_thread;
    if (web && has_cap && do_rx)
        snap_thread = std::thread([&] {
            while (!stop_signal) {
                if (!snap_on && !const_on) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                    continue;
                }
                std::vector<std::complex<float>> x, c;
                {
                    std::lock_guard<std::mutex> b(snap_busy);
                    if (snap_on) x = modem.snapshot();
                    if (const_on) c = modem.constellation();
                }
                if (x.size() == size_t(CAP_N)) {
                    std::lock_guard<std::mutex> l(snap_m);
                    snap_x.swap(x);
                }
                if (!c.empty()) {
                    std::lock_guard<std::mutex> l(snap_m);
                    snap_c.swap(c);
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        });
    struct ThreadGuard {                       // also on an exception: stop and join, never std::terminate
        std::thread& t;
        void join()
        {
            if (!t.joinable()) return;
            stop_signal = true;
            t.join();
        }
        ~ThreadGuard() { join(); }
    } snap_guard{snap_thread};
    double update_ms = 0;                      // time of the last status + spectrum read (USB register access)
    // real-time data rates: counter differences over fixed 0.5 s intervals, recomputed every 0.5 s
    const double RATE_INTERVAL = 0.5;
    struct RateSample {
        double t;
        uint64_t tx_frames, tx_bytes, rx_bb_ok, rx_written;
    };
    RateSample rate_mark{};
    std::chrono::steady_clock::time_point rate_t0;
    double tx_rate = 0, tx_host = 0, rx_rate = 0, rx_fps = 0, rx_file = 0, rate_dt = 0;
    double snr_t = 0;                          // time of the last SNR capture (smoothing time constant 0.5 s)
    // RX level / SNR: smoothed over the last captures (about 1 s), restarted with each session
    double esn0_avg = NAN, level_avg = NAN, rssi_db = NAN;   // Es/N0 averaged in dB
    std::chrono::steady_clock::time_point snr_t0;
    bool has_rssi = true;
    auto update_web = [&](const std::vector<uint32_t>& s) {
        // spectrum: latest 1024-sample capture (Hann window, dBFS)
        if (!S.do_rx) spec_db.clear();                    // RX off: no spectrum
        // constellation: latest symbol capture; dropped when RX is off, unlocked or no new capture for 1.5 s
        {
            const double tnow = std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count();
            std::vector<std::complex<float>> c;
            {
                std::lock_guard<std::mutex> l(snap_m);
                c.swap(snap_c);
            }
            if (!c.empty()) {
                const_x.swap(c);
                const_t = tnow;
            }
            if (!S.do_rx || !((s[0] >> 4) & 1) || tnow - const_t > 1.5 || tnow < const_t) const_x.clear();
        }
        if (S.do_rx) {
            std::vector<std::complex<float>> x;
            if (!S.rx_data) {                              // PRBS: raw samples from the RX stream
                if (S.rst->tap_ready) {
                    x.swap(S.rst->tap);
                    S.rst->tap_ready = false;
                }
                S.rst->tap_req = true;
            } else if (has_cap) {                          // file mode: FPGA snapshot (spectrum thread)
                std::lock_guard<std::mutex> l(snap_m);
                x.swap(snap_x);
            }
            const double tnow = std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count();
            if (snr_t0 != S.t0) esn0_avg = level_avg = NAN, snr_t = tnow;
            snr_t0 = S.t0;
            if (x.size() == size_t(CAP_N)) {                // one FFT per update, no averaging
                spec_db  = power_spectrum(x);
                spec_fs  = S.fs_act;
                spec_fc  = act.rx_freq;
                // SNR and level: exponential average with a 0.5 s time constant
                // (10 captures/s in PRBS mode, ~3 snapshots/s in file mode)
                const double e1 = esn0_db_of_kappa(psk_kappa(x, alpha));   // NaN: noise only
                double pw = 0;
                for (const auto& v : x) pw += std::norm(v);
                pw /= double(x.size());
                const double w = 1.0 - std::exp(-std::max(0.0, tnow - snr_t) / 0.5);
                snr_t = tnow;
                if (std::isfinite(e1)) esn0_avg = std::isfinite(esn0_avg) ? esn0_avg + w * (e1 - esn0_avg) : e1;
                level_avg = std::isfinite(level_avg) ? level_avg + w * (pw - level_avg) : pw;
            }
            // AD9361 RSSI (dB, 0.25 dB steps, relative: not calibrated to dBm)
            if (has_rssi) {
                try {
                    rssi_db = usrp->get_rx_sensor("rssi", 0).to_real();
                } catch (const std::exception&) {
                    has_rssi = false;
                    rssi_db  = NAN;
                }
            }
        }
        const uint32_t w0   = s[0];
        const bool lock     = (w0 >> 4) & 1;
        const int mc        = (w0 >> 5) & 31;
        const uint64_t bits = (uint64_t(s[15] & 0xFFFF) << 32) | s[14];
        // data rates (bit/s).  Payload per BBFRAME = DFL = Kbch - 80 bits; TX counts data frames
        // only (no dummy frames), RX (decode rate) counts BBFRAMEs with a good header CRC.
        const double tx_dfl = kbch_of(cfg.modcod) - 80;
        const int rx_dfl_hw = s[13] & 0xFFFF;              // DFL of the last received BBHEADER
        const double rx_dfl = rx_dfl_hw ? rx_dfl_hw : std::max(0, kbch_of(mc) - 80);
        const double tx_cap = tx_dfl / frame_symbols(cfg.modcod, cfg.pilots) * S.rs_tx;
        const double rx_cap = kbch_of(mc) ? (kbch_of(mc) - 80.0) / frame_symbols(mc, (w0 >> 10) & 1) * S.rs_rx : 0;
        const RateSample cur{std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count(), s[18],
            S.tst->bytes, s[10], S.rst->file_written};
        if (rate_t0 != S.t0 || cur.tx_frames < rate_mark.tx_frames || cur.tx_bytes < rate_mark.tx_bytes
            || cur.rx_bb_ok < rate_mark.rx_bb_ok || cur.rx_written < rate_mark.rx_written) {
            rate_mark = cur;                               // new session or statistics cleared: restart
            tx_rate = tx_host = rx_rate = rx_fps = rx_file = rate_dt = 0;
        } else if (cur.t - rate_mark.t >= RATE_INTERVAL) {
            const double dt = cur.t - rate_mark.t;
            tx_rate  = double(cur.tx_frames - rate_mark.tx_frames) * tx_dfl / dt;
            tx_host  = double(cur.tx_bytes - rate_mark.tx_bytes) * 8 / dt;
            rx_fps   = double(cur.rx_bb_ok - rate_mark.rx_bb_ok) / dt;      // decoded BBFRAMEs per second
            rx_rate  = rx_fps * rx_dfl;
            rx_file  = double(cur.rx_written - rate_mark.rx_written) * 8 / dt;
            rate_dt  = dt;
            rate_mark = cur;
        }
        rate_t0 = S.t0;
        const double esn0 = S.do_rx ? esn0_avg : NAN;
        const double ebn0 = lock && rx_cap > 0 ? esn0 - 10.0 * std::log10(rx_cap / S.rs_rx) : NAN;   // per information bit
        const double level_dbfs = S.do_rx && level_avg > 0 ? 10.0 * std::log10(level_avg / (32767.0 * 32767.0)) : NAN;
        std::ostringstream j;
        j.precision(10);
        j << "{\"board\":\"USRP B210\",\"caps\":{\"modem_cfg\":false,\"udp\":false,\"shared_fs\":false"
          << ",\"bw_min\":" << BW_MIN << ",\"bw_max\":" << BW_MAX << ",\"rx_gain_max\":76,\"max_upload\":" << MAX_UPLOAD
          << ",\"const_fpga\":\"2.2\",\"level_src\":\"DDC output\",\"tx_under\":\"Underflow DUC / USB\""
          << ",\"rx_over\":\"USB overflow\",\"duc_bad\":false},";
        j << "\"fpga\":{\"version\":\"" << (s[31] >> 16) << "." << (s[31] & 0xFFFF) << "\",\"spectrum\":"
          << (has_cap ? "true" : "false") << ",\"constellation\":" << (has_const ? "true" : "false") << "},";
        j << "\"update_ms\":" << update_ms << ",";
        j << "\"uptime\":" << std::chrono::duration<double>(std::chrono::steady_clock::now() - S.t0).count() << ",";
        j << "\"config\":{\"tx_freq\":" << cfg.tx_freq << ",\"tx_bw\":" << cfg.tx_bw << ",\"tx_gain\":" << cfg.tx_gain
          << ",\"rx_freq\":" << cfg.rx_freq << ",\"rx_bw\":" << cfg.rx_bw << ",\"rx_gain\":" << cfg.rx_gain
          << ",\"rolloff\":" << alpha << ",\"modcod\":" << jstr(MODCOD_NAME[cfg.modcod]) << ",\"pilots\":"
          << (cfg.pilots ? "true" : "false") << "},";
        j << "\"tx\":{\"on\":" << (S.do_tx ? "true" : "false") << ",\"freq\":" << act.tx_freq << ",\"rs\":" << S.rs_tx
          << ",\"fs\":" << act.fs_tx << ",\"gain\":" << act.tx_gain << ",\"analog_bw\":" << act.tx_abw
          << ",\"mcr\":" << act.mcr << ",\"frames_encoded\":" << s[17] << ",\"frames_sent\":" << s[18]
          << ",\"dummy\":" << s[19] << ",\"duc_underflow\":" << s[26] << ",\"host_underflow\":" << S.tst->underflows
          << ",\"mode\":" << jstr(S.tx_data ? "file" : "prbs") << ",\"file\":" << jstr(S.in_name)
          << ",\"bytes\":" << S.tst->bytes << ",\"done\":" << (S.tst->pad_done ? "true" : "false")
          << ",\"capacity_bps\":" << tx_cap << ",\"rate_bps\":" << tx_rate << ",\"host_bps\":" << tx_host << "},";
        j << "\"rx\":{\"on\":" << (S.do_rx ? "true" : "false") << ",\"freq\":" << act.rx_freq << ",\"rs\":" << S.rs_rx
          << ",\"fs\":" << act.fs_rx << ",\"gain\":" << act.rx_gain << ",\"analog_bw\":" << act.rx_abw
          << ",\"lock\":" << (lock ? "true" : "false") << ",\"modcod\":" << jstr(MODCOD_NAME[mc <= 16 ? mc : 11])
          << ",\"pilots\":" << (((w0 >> 10) & 1) ? "true" : "false") << ",\"fll_stage\":" << ((w0 >> 12) & 3)
          << ",\"cfo_hz\":" << double(int32_t(s[1])) / 4294967296.0 * S.rs_rx << ",\"agc_gain\":" << (s[5] & 0xFFFF)
          << ",\"frames\":" << s[2] << ",\"misses\":" << s[3] << ",\"pls_fail\":" << s[4]
          << ",\"ldpc_iters\":" << ((w0 >> 16) & 63) << ",\"ldpc_drop\":" << s[7] << ",\"bch_corr\":" << s[8]
          << ",\"bch_fail\":" << s[9] << ",\"bb_ok\":" << s[10] << ",\"bb_crc\":" << s[11]
          << ",\"ber_lock\":" << (((w0 >> 14) & 1) ? "true" : "false") << ",\"ber_bits\":" << bits
          << ",\"ber_errors\":" << s[16] << ",\"host_overflow\":" << S.rst->overflows
          << ",\"mode\":" << jstr(S.rx_data ? "file" : "prbs") << ",\"file_state\":" << S.rst->file_state
          << ",\"file_len\":" << (S.rst->file_len == LEN_UNKNOWN ? 0 : S.rst->file_len.load())
          << ",\"file_written\":" << S.rst->file_written << ",\"seq_gaps\":" << S.rst->file_gaps
          << ",\"capacity_bps\":" << rx_cap << ",\"rate_bps\":" << rx_rate << ",\"frames_per_s\":" << rx_fps
          << ",\"file_bps\":" << rx_file << ",\"rate_interval\":" << rate_dt << ",\"rate_time\":" << rate_mark.t
          << ",\"rssi_db\":" << jnum(S.do_rx ? rssi_db : NAN) << ",\"level_dbfs\":" << jnum(level_dbfs)
          << ",\"esn0_db\":" << jnum(esn0) << ",\"ebn0_db\":" << jnum(ebn0)
          << ",\"result\":" << jstr(S.result) << "}}";
        std::ostringstream sp;
        sp.precision(10);
        sp << "{\"fc\":" << spec_fc << ",\"fs\":" << spec_fs << ",\"db\":[";
        for (size_t i = 0; i < spec_db.size(); i++) sp << (i ? "," : "") << std::round(spec_db[i] * 10) / 10;
        sp << "],\"iq\":[";
        for (size_t i = 0; i < const_x.size(); i++)
            sp << (i ? "," : "") << std::round(double(const_x[i].real()) * 1000) / 1000 << ","
               << std::round(double(const_x[i].imag()) * 1000) / 1000;
        sp << "]}";
        std::lock_guard<std::mutex> l(g_web.m);
        g_web.status_json   = j.str();
        g_web.spectrum_json = sp.str();
    };

    // file loopback (web): compare the received file with the one that was sent
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
        std::this_thread::sleep_for(std::chrono::milliseconds(web ? 10 : 1000));
        // ---- requests from the web page
        if (web) {
            std::map<std::string, double> pend;
            bool rq_send = false, rq_prbs = false;
            std::string spath, sname;
            {
                std::lock_guard<std::mutex> l(g_web.m);
                pend.swap(g_web.pending);
                rq_send = g_web.req_send;
                rq_prbs = g_web.req_prbs;
                spath   = g_web.send_path;
                sname   = g_web.send_name;
                g_web.req_send = g_web.req_prbs = false;
            }
            bool restart = rq_send || rq_prbs;
            std::unique_lock<std::mutex> busy(snap_busy, std::defer_lock);
            if (restart || !pend.empty()) busy.lock();
            try {
                for (auto& kv : pend) {
                    const std::string& k = kv.first;
                    const double v       = kv.second;
                    if (k == "tx_freq" && do_tx) {
                        cfg.tx_freq = v;
                        usrp->set_tx_freq(uhd::tune_request_t(v), 0);
                        act.tx_freq = usrp->get_tx_freq(0);
                    } else if (k == "rx_freq" && do_rx) {
                        cfg.rx_freq = v;
                        usrp->set_rx_freq(uhd::tune_request_t(v), 0);
                        act.rx_freq = usrp->get_rx_freq(0);
                    } else if (k == "tx_gain" && do_tx) {
                        cfg.tx_gain = v;
                        usrp->set_tx_gain(v, 0);
                        act.tx_gain = usrp->get_tx_gain(0);
                    } else if (k == "rx_gain" && do_rx) {
                        cfg.rx_gain = v;
                        usrp->set_rx_gain(v, 0);
                        act.rx_gain = usrp->get_rx_gain(0);
                    } else if (k == "tx_bw" && v != cfg.tx_bw && v >= BW_MIN && v <= BW_MAX) {
                        cfg.tx_bw = v;
                        restart   = true;
                    } else if (k == "rx_bw" && v != cfg.rx_bw && v >= BW_MIN && v <= BW_MAX) {
                        cfg.rx_bw = v;
                        restart   = true;
                    } else if (k == "tx_on" && do_tx && (v != 0) != tx_on) {
                        tx_on   = v != 0;
                        restart = true;
                    } else if (k == "rx_on" && do_rx && (v != 0) != rx_on) {
                        rx_on   = v != 0;
                        restart = true;
                    }
                    fprintf(g_log, "web: %s = %.6g\n", k.c_str(), v);
                }
                if (restart) {
                    // keep sending the current file unless PRBS was requested
                    std::string in = S.in_path, name = S.in_name;
                    if (rq_prbs) in.clear(), name.clear();
                    if (rq_send) in = spath, name = sname;
                    if (!(tx_on && rx_on)) in.clear(), name.clear();   // file loopback needs TX and RX on
                    S.stop(modem);
                    std::string out = in.empty() ? "" : file_dir + "/rx_" + name;
                    start_session(in, out, name);
                    // UHD switches the AD9361 chains / front-end switches only when a streamer is
                    // created; with both off nothing is created, so make it re-evaluate here
                    if (!S.do_tx && !S.do_rx) usrp->set_tx_subdev_spec(std::string("A:A"));
                    if (rq_send && !(tx_on && rx_on)) S.result = "TX and RX must be on to send a file";
                    std::lock_guard<std::mutex> l(g_web.m);
                    g_web.rx_path = out;
                }
            } catch (const std::exception& e) {
                fprintf(stderr, "web request failed: %s\n", e.what());
            }
        }
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration<double>(now - t_poll).count() < (web ? 0.1 : 0.999)) continue;     // web: 10 Hz
        t_poll = now;
        snap_on = S.rx_data;
        auto s = modem.status();
        const_on = web && has_const && S.do_rx && ((s[0] >> 4) & 1);
        if (web) {
            update_web(s);
            update_ms = 1e3 * std::chrono::duration<double>(std::chrono::steady_clock::now() - now).count();
        }
        if (std::chrono::duration<double>(now - t_print).count() >= 0.999) {
            t_print = now;
            if (S.do_tx) print_tx(s, *S.tst, S.tx_data, S.uin.get());
            if (S.do_rx) print_rx(s, S.rs_rx, *S.rst, S.rx_data, S.raw, S.uout.get());
        }
        // restart the BER statistics once, after the receiver has settled
        if (S.do_rx && !S.cleared && ((s[0] >> 14) & 1) && s[10] >= 5) {
            modem.wr(REG_CLR, 1);
            S.cleared = true;
            fprintf(g_log, "(statistics cleared after lock)\n");
        }
        double el = std::chrono::duration<double>(now - S.t0).count();
        if (duration > 0 && el >= duration) stop_signal = true;
        if (S.rx_data && !S.raw && S.rst->file_state == 2 && S.rst->file_len != LEN_UNKNOWN && !S.compared) {
            S.compared = true;
            if (S.fout && S.fout != stdout) fflush(S.fout);
            fprintf(g_log, "file received: %llu bytes, seq gaps inside the file %llu%s\n",
                (unsigned long long)S.rst->file_written.load(), (unsigned long long)S.rst->file_gaps.load(),
                S.rst->file_gaps ? "  (bytes were lost: the file is incomplete)" : "");
            if (web) {
                S.result = compare_files(S.in_path, S.out_path);
                fprintf(g_log, "file loopback: %s\n", S.result.c_str());
            } else if (!S.do_tx || !S.tx_data || S.tst->pad_done)
                stop_signal = true;
        }
        if (!web && S.tx_data && S.tst->pad_done && !S.do_rx) {
            // input sent and padded: let the FPGA buffers drain (payload FIFO 2 KB + 2 frames), then stop
            const double frame_s = frame_symbols(cfg.modcod, cfg.pilots) / S.rs_tx;
            const double drain_s = 2048.0 / (S.bps * act.fs_tx) + 3.0 * frame_s + 0.2;
            std::this_thread::sleep_for(std::chrono::duration<double>(drain_s));
            fprintf(g_log, "input sent (%llu bytes incl. preamble and header, + %llu padding bytes)\n",
                (unsigned long long)S.tst->bytes.load(), (unsigned long long)S.tst->pad.load());
            stop_signal = true;
        }
    }
    snap_guard.join();
    S.stop(modem);
    if (tweb.joinable()) tweb.join();
    fprintf(g_log, "done\n");
    return EXIT_SUCCESS;
}
