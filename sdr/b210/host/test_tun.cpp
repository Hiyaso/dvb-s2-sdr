//
// test_tun.cpp -- the TUN payload path of dvbs2_b210 without a B210 (see test_tun.sh).
//
// IP packets -> UdpIn (tun) -> udp_frame -> "air" -> UdpDeframer -> UdpOut (tun) -> IP packets, with the
// same code as dvbs2_b210 (sdr/host_common).  The air stands in for the modem: bytes leave the TX queue
// at a fixed rate and a BBFRAME that is not full when the queue runs empty is completed with zero
// bytes (as tx_worker does); optionally one byte in N is corrupted, or a direction is cut.
//
//   test_tun pair                         SOCK_SEQPACKET socket pairs instead of TUN devices (one
//                                         message = one packet, like TUN), no root: one-way packet path,
//                                         then the two-way link check (LinkMonitor hellos, link up / down)
//   test_tun netns NS_A NS_B ADDR_A ADDR_B [RATE]
//                                         real TUN interfaces dvbs0 in two network namespaces, linked
//                                         both ways at RATE bytes/s (default 236000) with the link check
//                                         and carrier as dvbs2_b210 --host, until SIGINT/SIGTERM
//
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <sys/socket.h>
#include <unistd.h>
#include <chrono>
#include <csignal>
#include <functional>
#include <cstdio>
#include <random>
#include <thread>
#include <vector>
#include "dvbs2_common.hpp"
#include "file_xfer.hpp"
#include "net_tun.hpp"
#include "net_udp.hpp"

static const size_t FRAME = (10632 - 80) / 8;    // 8PSK 2/3 short frame: DFL bytes per BBFRAME

static void air_worker(InputQueue* iq, UdpOut* out, double rate, uint64_t corrupt_every, const std::atomic<bool>* cut)
{
    uint64_t sent = 0, n_air = 0;
    double budget = 0;
    auto t = std::chrono::steady_clock::now();
    std::vector<uint8_t> chunk;
    while (running()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        const auto now = std::chrono::steady_clock::now();
        budget += rate * std::chrono::duration<double>(now - t).count();
        t = now;
        const size_t n = size_t(budget);
        chunk.clear();
        {
            std::lock_guard<std::mutex> l(iq->m);
            while (chunk.size() < n && !iq->q.empty()) {
                chunk.push_back(iq->q.front());
                iq->q.pop_front();
            }
        }
        // queue empty in the middle of a BBFRAME: complete it with zeros, then idle (dummy frames)
        if (chunk.size() < n && sent % FRAME) chunk.insert(chunk.end(), std::min(n - chunk.size(), FRAME - sent % FRAME), 0);
        budget = chunk.size() < n ? 0 : budget - double(chunk.size());
        if (cut && *cut) chunk.clear();                  // direction cut: the bytes never arrive
        for (uint8_t b : chunk) {
            if (corrupt_every && ++n_air % corrupt_every == 0) b ^= 0x5A;
            out->df.push(b);
            sent++;
        }
        out->flush();
    }
}

// ---------------------------------------------------------------- socket-pair test (no root)
struct Result {
    size_t sent = 0, got = 0, bad_content = 0, out_of_order = 0;
    uint64_t drops = 0, crc_bad = 0, lost = 0;
};
static Result run_pair(size_t n_pkt, double rate, double send_rate, size_t limit, uint64_t corrupt_every)
{
    int a[2], b[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, a) < 0 || socketpair(AF_UNIX, SOCK_SEQPACKET, 0, b) < 0) {
        perror("socketpair");
        exit(1);
    }
    for (int fd : {a[0], a[1], b[0], b[1]}) {
        int sz = 4 << 20;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof(sz));
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof(sz));
    }
    stop_signal = false;
    InputQueue iq;
    UdpIn in;
    in.fd = a[1], in.tun = true, in.limit = limit;
    UdpOut out;
    out.fd = b[1], out.tun = true;
    std::thread trd(udp_reader_worker, &in, &iq), tair(air_worker, &iq, &out, rate, corrupt_every, nullptr);

    // packets: 4-byte index + random bytes, 20 .. 1500 B (a few up to 9000 B)
    std::mt19937 rng(7);
    std::vector<std::vector<uint8_t>> pk(n_pkt);
    for (size_t i = 0; i < n_pkt; i++) {
        size_t len = (i % 97 == 5) ? 9000 : 20 + rng() % 1481;
        pk[i].resize(len);
        for (auto& x : pk[i]) x = uint8_t(rng());
        for (int k = 0; k < 4; k++) pk[i][k] = uint8_t(i >> (8 * k));
    }
    Result r;
    std::thread tsend([&] {
        auto t0 = std::chrono::steady_clock::now();
        double bytes = 0;
        for (auto& p : pk) {
            if (send_rate > 0)
                while (bytes / send_rate > std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count())
                    std::this_thread::sleep_for(std::chrono::microseconds(200));
            if (write(a[0], p.data(), p.size()) == ssize_t(p.size())) r.sent++;
            bytes += double(p.size());
        }
    });
    std::vector<uint8_t> buf(70000);
    long last = -1;
    for (;;) {
        pollfd p{b[0], POLLIN, 0};
        if (poll(&p, 1, 1500) <= 0) break;                 // 1.5 s without a packet: done
        const ssize_t got = read(b[0], buf.data(), buf.size());
        if (got < 4) continue;
        const uint32_t idx = buf[0] | buf[1] << 8 | buf[2] << 16 | uint32_t(buf[3]) << 24;
        r.got++;
        if (idx >= n_pkt || size_t(got) != pk[idx].size() || !std::equal(pk[idx].begin(), pk[idx].end(), buf.begin()))
            r.bad_content++;
        else if (long(idx) <= last)
            r.out_of_order++;
        else
            last = long(idx);
    }
    tsend.join();
    stop_signal = true;
    trd.join();
    tair.join();
    r.drops   = in.drops;
    r.crc_bad = out.bad;
    r.lost    = out.lost;
    for (int fd : {a[0], a[1], b[0], b[1]}) close(fd);
    return r;
}

// two stations A (10.60.0.1) and B (10.60.0.2), each with one "interface" (socket pair) for both
// directions, hellos as in dvbs2_b210 --host; the A -> B direction is cut and restored
static int test_link()
{
    int a[2], b[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, a) < 0 || socketpair(AF_UNIX, SOCK_SEQPACKET, 0, b) < 0) {
        perror("socketpair");
        exit(1);
    }
    stop_signal = false;
    const double rate = 236000;
    InputQueue qa, qb;
    UdpIn ia, ib;
    UdpOut oa, ob;
    LinkMonitor la, lb;
    la.my_addr = 0x0A3C0001, lb.my_addr = 0x0A3C0002;
    std::atomic<bool> cut_ab{false}, up_a{false}, up_b{false};
    ia.fd = oa.fd = a[1], ib.fd = ob.fd = b[1];
    for (UdpIn* u : {&ia, &ib}) u->tun = true, u->own_fd = false, u->limit = size_t(0.2 * rate) + UDP_MAX_PAYLOAD;
    for (UdpOut* u : {&oa, &ob}) u->tun = true, u->own_fd = false;
    oa.intercept = [&](const std::vector<uint8_t>& p) { return la.on_packet(p); };
    ob.intercept = [&](const std::vector<uint8_t>& p) { return lb.on_packet(p); };
    std::thread t[] = {std::thread(udp_reader_worker, &ia, &qa), std::thread(udp_reader_worker, &ib, &qb),
        std::thread(air_worker, &qa, &ob, rate, 0, &cut_ab), std::thread(air_worker, &qb, &oa, rate, 0, nullptr),
        std::thread(link_worker, &la, &ia, &qa, [&](bool u) { up_a = u; }),
        std::thread(link_worker, &lb, &ib, &qb, [&](bool u) { up_b = u; })};
    // application side of each interface: count the packets delivered, none may be a hello
    std::atomic<uint64_t> got_a{0}, got_b{0}, leaked{0};
    std::atomic<bool> app_stop{false};
    auto app_rx = [&](int fd, std::atomic<uint64_t>* got) {
        std::vector<uint8_t> buf(70000);
        while (!app_stop) {
            pollfd p{fd, POLLIN, 0};
            if (poll(&p, 1, 50) <= 0) continue;
            const ssize_t n = read(fd, buf.data(), buf.size());
            if (n > 0 && buf[0] == 0) leaked++;
            else if (n > 0) (*got)++;
        }
    };
    std::thread ra(app_rx, a[0], &got_a), rb(app_rx, b[0], &got_b);
    auto send = [](int fd, int n) {
        std::vector<uint8_t> pkt(1000, 0x45);                 // "IPv4" packets
        for (int i = 0; i < n; i++) {
            if (write(fd, pkt.data(), pkt.size()) < 0) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    };
    auto wait_for = [](const std::function<bool()>& f, double s) {
        for (int i = 0; i < int(s * 20) && !f(); i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
        return f();
    };
    int fails = 0;
    auto check = [&](const char* name, bool ok, const std::string& info) {
        printf("%-44s %s  %s\n", name, info.c_str(), ok ? "PASS" : "FAIL");
        fflush(stdout);
        fails += !ok;
    };
    auto st = [&] {
        return "A " + std::string(up_a ? "up" : "down") + " (hellos rx " + std::to_string(la.rx_hellos) + ")  B "
               + (up_b ? "up" : "down") + " (hellos rx " + std::to_string(lb.rx_hellos) + ")";
    };
    bool ok = wait_for([&] { return up_a && up_b; }, 3);
    check("two-way link comes up", ok, st());
    send(a[0], 200);
    send(b[0], 200);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    check("link up: packets both ways", got_a == 200 && got_b == 200 && !leaked,
        "A->B " + std::to_string(got_b) + "/200  B->A " + std::to_string(got_a) + "/200  hellos leaked " + std::to_string(leaked));
    cut_ab = true;
    ok = wait_for([&] { return !up_a && !up_b; }, 3.5);
    check("A->B cut: both stations go down", ok, st() + "  peer seen by A: " + la.peer_str());
    const uint64_t before = got_b, drops0 = ia.link_drops;
    send(a[0], 50);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    check("link down: A's packets are held back", got_b == before && ia.link_drops - drops0 == 50,
        "dropped " + std::to_string(ia.link_drops - drops0) + "/50");
    cut_ab = false;
    ok = wait_for([&] { return up_a && up_b; }, 3);
    check("A->B restored: link up again", ok, st());
    app_stop = true;
    ra.join(), rb.join();
    stop_signal = true;
    for (auto& x : t) x.join();
    for (int fd : {a[0], a[1], b[0], b[1]}) close(fd);
    return fails;
}

static int test_pair()
{
    int fails = 0;
    auto check = [&](const char* name, const Result& r, bool ok) {
        printf("%-44s sent %5zu got %5zu  bad content %zu  out of order %zu  queue drops %llu  CRC bad %llu  lost %llu  %s\n",
            name, r.sent, r.got, r.bad_content, r.out_of_order, (unsigned long long)r.drops,
            (unsigned long long)r.crc_bad, (unsigned long long)r.lost, ok ? "PASS" : "FAIL");
        fflush(stdout);
        fails += !ok;
    };
    const double rate = 2e6;    // fast "air" to keep the test short
    Result r = run_pair(3000, rate, 0, size_t(1) << 30, 0);
    check("clean link, queue large enough", r,
        r.sent == 3000 && r.got == 3000 && !r.bad_content && !r.out_of_order && !r.drops && !r.crc_bad && !r.lost);
    r = run_pair(3000, rate, 0, size_t(1) << 30, 20000);
    check("1 byte in 20000 corrupted", r,
        r.got > 2500 && r.got < 3000 && !r.bad_content && !r.out_of_order && r.crc_bad > 0 && r.got + r.lost >= 2990);
    r = run_pair(3000, rate, 2 * rate, size_t(0.2 * rate), 0);
    check("input 2x the link rate, 0.2 s queue", r,
        r.drops > 0 && r.got + r.drops == r.sent && !r.bad_content && !r.out_of_order && !r.crc_bad);
    fails += test_link();
    printf(fails ? "FAIL\n" : "PASS\n");
    return fails ? 1 : 0;
}

// ---------------------------------------------------------------- two network namespaces (root)
static void enter_netns(const std::string& ns)
{
    const int f = open(("/run/netns/" + ns).c_str(), O_RDONLY | O_CLOEXEC);
    if (f < 0 || setns(f, CLONE_NEWNET) < 0) throw std::runtime_error("cannot enter network namespace " + ns);
    close(f);
}
static void on_signal(int) { stop_signal = true; }

static int test_netns(const std::string& na, const std::string& nb, const std::string& aa, const std::string& ab, double rate)
{
    TunDev ta, tb;
    enter_netns(na);
    ta.open("dvbs0");
    ta.configure(aa, 1500);
    enter_netns(nb);
    tb.open("dvbs0");
    tb.configure(ab, 1500);
    printf("%s dvbs0 %s  <->  %s dvbs0 %s, %.0f B/s each way\n", na.c_str(), aa.c_str(), nb.c_str(), ab.c_str(), rate);
    fflush(stdout);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    InputQueue qab, qba;
    UdpIn ia, ib;
    UdpOut oa, ob;
    for (UdpIn* u : {&ia, &ib}) u->tun = true, u->own_fd = false, u->limit = std::max(size_t(0.2 * rate), UDP_MAX_PAYLOAD + UDP_OVERHEAD);
    for (UdpOut* u : {&oa, &ob}) u->tun = true, u->own_fd = false;
    ia.fd = oa.fd = ta.fd;
    ib.fd = ob.fd = tb.fd;
    LinkMonitor la, lb;
    in_addr x{};
    inet_pton(AF_INET, aa.substr(0, aa.find('/')).c_str(), &x), la.my_addr = ntohl(x.s_addr);
    inet_pton(AF_INET, ab.substr(0, ab.find('/')).c_str(), &x), lb.my_addr = ntohl(x.s_addr);
    oa.intercept = [&](const std::vector<uint8_t>& p) { return la.on_packet(p); };
    ob.intercept = [&](const std::vector<uint8_t>& p) { return lb.on_packet(p); };
    if (!ta.set_carrier(false) || !tb.set_carrier(false)) printf("note: TUNSETCARRIER failed: %s\n", strerror(errno));
    auto carrier = [](TunDev* t, const char* n) {
        return [t, n](bool up) {
            t->set_carrier(up);
            printf("%s: link %s\n", n, up ? "UP" : "down");
            fflush(stdout);
        };
    };
    std::thread t1(udp_reader_worker, &ia, &qab), t2(air_worker, &qab, &ob, rate, 0, nullptr);
    std::thread t3(udp_reader_worker, &ib, &qba), t4(air_worker, &qba, &oa, rate, 0, nullptr);
    std::thread t5(link_worker, &la, &ia, &qab, carrier(&ta, na.c_str())), t6(link_worker, &lb, &ib, &qba, carrier(&tb, nb.c_str()));
    while (!stop_signal) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        printf("A->B in %llu pkt dropped %llu out %llu lost %llu bad %llu | B->A in %llu pkt dropped %llu out %llu lost %llu bad %llu\n",
            (unsigned long long)ia.packets.load(), (unsigned long long)ia.drops.load(), (unsigned long long)ob.packets.load(),
            (unsigned long long)ob.lost.load(), (unsigned long long)ob.bad.load(), (unsigned long long)ib.packets.load(),
            (unsigned long long)ib.drops.load(), (unsigned long long)oa.packets.load(), (unsigned long long)oa.lost.load(),
            (unsigned long long)oa.bad.load());
        fflush(stdout);
    }
    t1.join(), t2.join(), t3.join(), t4.join(), t5.join(), t6.join();
    return 0;
}

int main(int argc, char* argv[])
try {
    const std::string mode = argc > 1 ? argv[1] : "pair";
    if (mode == "pair") return test_pair();
    if (mode == "netns" && argc >= 6) return test_netns(argv[2], argv[3], argv[4], argv[5], argc > 6 ? atof(argv[6]) : 236000);
    fprintf(stderr, "usage: test_tun pair | test_tun netns NS_A NS_B ADDR_A ADDR_B [RATE]\n");
    return 2;
} catch (const std::exception& e) {
    fprintf(stderr, "test_tun: %s\n", e.what());
    return 1;
}
