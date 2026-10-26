//
// net_udp.hpp -- UDP payload mode: datagrams in (TX) and out (RX), framed as in udp_frame.hpp.
// Shared by sdr/b210/host/dvbs2_b210.cpp and sdr/adrv9364/sw/dvbs2_adrv.cpp (header-only, one translation unit each).
//
#pragma once
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include "dvbs2_common.hpp"
#include "file_xfer.hpp"
#include "udp_frame.hpp"

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
