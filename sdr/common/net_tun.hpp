//
// net_tun.hpp -- TUN network interface as payload (routed IPv4, no Ethernet header).
//
// The IP packets the kernel routes to the interface are read one by one and carried like UDP
// datagrams (UdpIn / UdpOut with tun = true, framed as in udp_frame.hpp); on the receiving side
// each recovered packet is written back into that side's interface.  The device is opened once
// and kept for the whole program, so session restarts keep the interface and its address.
// Used by sdr/b210/sw/dvbs2_b210.cpp (header-only, one translation unit).
//
// Creating the interface and setting its address need CAP_NET_ADMIN: run as root, or create it
// once beforehand (sudo ip tuntap add dev dvbs0 mode tun user $USER; sudo ip addr add ...;
// sudo ip link set dvbs0 up) and attach to it as a normal user.
//
// Two-way link (LinkMonitor): each station sends a small hello datagram every 0.5 s inside the
// payload stream, saying whether it hears the other one.  The link is up when this station
// decodes the peer's hellos and the peer reports that it decodes ours; the interface carrier
// follows it (ip link: NO-CARRIER while down), so IP traffic flows only over a working link.
//
#pragma once
#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <cstdlib>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include "net_udp.hpp"

#ifndef TUNSETCARRIER
#define TUNSETCARRIER _IOW('T', 226, int)   // Linux >= 5.0
#endif

struct TunDev {
    int fd = -1;
    std::string name;
    struct Info {
        bool up = false;
        bool running = false;    // up and carrier on
        std::string addr;        // "a.b.c.d/n", empty without an IPv4 address
        int mtu = 0;
    };

    TunDev() = default;
    TunDev(const TunDev&) = delete;
    TunDev& operator=(const TunDev&) = delete;
    ~TunDev()
    {
        if (fd >= 0) close(fd);
    }

    // attach to the interface (created if it does not exist and we may create it)
    void open(const std::string& want)
    {
        if (want.empty() || want.size() >= IFNAMSIZ) throw std::runtime_error("bad TUN interface name '" + want + "'");
        fd = ::open("/dev/net/tun", O_RDWR | O_CLOEXEC);
        if (fd < 0) throw std::runtime_error(std::string("cannot open /dev/net/tun: ") + strerror(errno));
        ifreq ifr{};
        ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
        std::strncpy(ifr.ifr_name, want.c_str(), IFNAMSIZ - 1);
        if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
            const int e = errno;
            ::close(fd);
            fd = -1;
            throw std::runtime_error("cannot attach TUN interface " + want + ": " + strerror(e)
                + (e == EPERM ? " (run as root, or create it once: sudo ip tuntap add dev " + want
                                    + " mode tun user $USER)"
                              : ""));
        }
        name = ifr.ifr_name;
    }

    Info info() const
    {
        Info r;
        const int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) return r;
        ifreq ifr = req();
        if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0) {
            r.up      = (ifr.ifr_flags & IFF_UP) != 0;
            r.running = (ifr.ifr_flags & IFF_RUNNING) != 0;
        }
        ifr = req();
        if (ioctl(s, SIOCGIFMTU, &ifr) == 0) r.mtu = ifr.ifr_mtu;
        ifr = req();
        if (ioctl(s, SIOCGIFADDR, &ifr) == 0) {
            const in_addr a = ((const sockaddr_in*)&ifr.ifr_addr)->sin_addr;
            ifr = req();
            int prefix = 32;
            if (ioctl(s, SIOCGIFNETMASK, &ifr) == 0)
                prefix = __builtin_popcount(ntohl(((const sockaddr_in*)&ifr.ifr_netmask)->sin_addr.s_addr));
            char b[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &a, b, sizeof(b));
            r.addr = std::string(b) + "/" + std::to_string(prefix);
        }
        close(s);
        return r;
    }

    // IPv4 address "a.b.c.d/n", MTU (0 = keep) and up; nothing is changed when it is already so
    void configure(const std::string& cidr, int mtu)
    {
        const size_t sl = cidr.find('/');
        in_addr a{};
        const int prefix = sl == std::string::npos ? 32 : std::atoi(cidr.c_str() + sl + 1);
        if (inet_pton(AF_INET, cidr.substr(0, sl).c_str(), &a) != 1 || prefix < 1 || prefix > 32)
            throw std::runtime_error("bad TUN address '" + cidr + "' (expected a.b.c.d/n)");
        char b[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &a, b, sizeof(b));
        const std::string want = std::string(b) + "/" + std::to_string(prefix);
        const Info now = info();
        if (now.up && now.addr == want && (mtu <= 0 || now.mtu == mtu)) return;

        const int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) throw std::runtime_error("cannot open a socket to configure " + name);
        auto fail = [&](const char* what) {
            const int e = errno;
            close(s);
            throw std::runtime_error("cannot set the " + std::string(what) + " of " + name + ": " + strerror(e)
                + (e == EPERM ? " (run as root, or set it up once: sudo ip addr add " + want + " dev " + name
                                    + " && sudo ip link set " + name + " up" + (mtu > 0 ? " mtu " + std::to_string(mtu) : "")
                                    + ")"
                              : ""));
        };
        ifreq ifr = req();
        if (mtu > 0 && now.mtu != mtu) {
            ifr.ifr_mtu = mtu;
            if (ioctl(s, SIOCSIFMTU, &ifr) < 0) fail("MTU");
        }
        if (now.addr != want) {
            ifr = req();
            sockaddr_in* sa = (sockaddr_in*)&ifr.ifr_addr;
            sa->sin_family  = AF_INET;
            sa->sin_addr    = a;
            if (ioctl(s, SIOCSIFADDR, &ifr) < 0) fail("address");
            ifr = req();
            sa              = (sockaddr_in*)&ifr.ifr_netmask;
            sa->sin_family  = AF_INET;
            sa->sin_addr.s_addr = htonl(prefix == 32 ? 0xFFFFFFFFu : ~(0xFFFFFFFFu >> prefix));
            if (ioctl(s, SIOCSIFNETMASK, &ifr) < 0) fail("netmask");
        }
        ifr = req();
        if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) fail("flags");
        if (!(ifr.ifr_flags & IFF_UP)) {
            ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
            if (ioctl(s, SIOCSIFFLAGS, &ifr) < 0) fail("state (up)");
        }
        close(s);
    }

    // carrier on / off (ip link shows NO-CARRIER and the kernel stops sending to the interface)
    bool set_carrier(bool on)
    {
        int v = on ? 1 : 0;
        return ioctl(fd, TUNSETCARRIER, &v) == 0;
    }

private:
    ifreq req() const
    {
        ifreq r{};
        std::strncpy(r.ifr_name, name.c_str(), IFNAMSIZ - 1);
        return r;
    }
};

// ---------------------------------------------------------------- two-way link check
// hello datagram (20 bytes): magic 00 'DVBS2LK' | version 1 | flags (bit 0: I hear you) | 2 reserved |
// sender IPv4 address | hello counter.  The first byte 0 is never the start of an IP packet.
struct LinkMonitor {
    static constexpr int64_t HELLO_MS = 500, TIMEOUT_MS = 2000;   // hello period, link lost after
    uint32_t my_addr = 0;                    // IPv4 address (host byte order) sent in the hello
    std::atomic<int64_t> last_rx_ms{-1};     // time of the last hello received
    std::atomic<bool> peer_hears{false};     // flag of that hello
    std::atomic<uint32_t> peer_addr{0};
    std::atomic<uint64_t> tx_hellos{0}, rx_hellos{0};

    static int64_t now_ms()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
            .count();
    }
    bool hears() const
    {
        const int64_t t = last_rx_ms;
        return t >= 0 && now_ms() - t < TIMEOUT_MS;
    }
    bool up() const { return hears() && peer_hears; }
    std::vector<uint8_t> hello()
    {
        static const uint8_t magic[8] = {0, 'D', 'V', 'B', 'S', '2', 'L', 'K'};
        std::vector<uint8_t> h(magic, magic + 8);
        const uint64_t n = ++tx_hellos;
        h.insert(h.end(), {1, uint8_t(hears() ? 1 : 0), 0, 0});
        for (int k = 3; k >= 0; k--) h.push_back(uint8_t(my_addr >> (8 * k)));
        for (int k = 3; k >= 0; k--) h.push_back(uint8_t(n >> (8 * k)));
        return h;
    }
    // a received datagram: true when it is a hello (consumed, not written to the interface)
    bool on_packet(const std::vector<uint8_t>& p)
    {
        static const uint8_t magic[8] = {0, 'D', 'V', 'B', 'S', '2', 'L', 'K'};
        if (p.size() < 20 || p[0] != 0 || std::memcmp(p.data(), magic, 8) != 0) return false;
        if (p[8] != 1) return true;          // other version: ignored
        peer_hears = (p[9] & 1) != 0;
        peer_addr  = uint32_t(p[12]) << 24 | uint32_t(p[13]) << 16 | uint32_t(p[14]) << 8 | p[15];
        last_rx_ms = now_ms();
        rx_hellos++;
        return true;
    }
    std::string peer_str() const
    {
        const uint32_t a = peer_addr;
        if (!a) return "";
        return std::to_string(a >> 24) + "." + std::to_string((a >> 16) & 255) + "." + std::to_string((a >> 8) & 255) + "."
               + std::to_string(a & 255);
    }
};

// one session: sends the hellos into the TX queue and follows the link state; on_change(up) is called
// at the start and on every change (sets the interface carrier); while down, input packets are discarded
static void link_worker(LinkMonitor* lm, UdpIn* u, InputQueue* iq, std::function<void(bool)> on_change)
{
    bool up        = lm->up();
    int64_t t_next = 0;
    u->hold        = !up;
    on_change(up);
    while (running()) {
        const int64_t t = LinkMonitor::now_ms();
        if (t >= t_next) {
            const std::vector<uint8_t> h = lm->hello();
            u->queue(iq, h.data(), h.size(), true);
            t_next = t + LinkMonitor::HELLO_MS;
        }
        if (lm->up() != up) {
            up      = !up;
            u->hold = !up;
            on_change(up);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}
