//
// udp_frame.hpp -- UDP datagrams over the DVB-S2 byte stream (Generic Continuous Stream).
//
// The modem carries a plain byte stream, so each datagram is framed on the TX side and
// recovered on the RX side by searching for the sync word:
//
//   sync 0xC5 0x3A | length (u16) | seq (u16) | CRC-16 of length+seq | payload | CRC-32 of payload
//
// (all big-endian, 12 bytes overhead).  Bytes between frames (zero padding that completes
// a BBFRAME while the input is idle) are skipped.  A frame with a bad CRC is dropped and the
// search restarts one byte after its sync word, so the next good frame is found even when
// bytes were lost in between.  seq counts datagrams, the receiver uses it to count losses.
//
#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

static const uint8_t UDP_SYNC0 = 0xC5, UDP_SYNC1 = 0x3A;
static const size_t UDP_HDR = 8, UDP_OVERHEAD = UDP_HDR + 4;
static const size_t UDP_MAX_PAYLOAD = 65535;

static uint16_t crc16_ccitt(const uint8_t* p, size_t n)          // CRC-16/CCITT-FALSE
{
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= uint16_t(p[i]) << 8;
        for (int b = 0; b < 8; b++) c = (c & 0x8000) ? uint16_t((c << 1) ^ 0x1021) : uint16_t(c << 1);
    }
    return c;
}
static uint32_t crc32_ieee(const uint8_t* p, size_t n)           // CRC-32 as in Ethernet / zlib
{
    static uint32_t tab[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int b = 0; b < 8; b++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            tab[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = tab[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

// append one framed datagram to out
static void udp_frame(const uint8_t* p, size_t n, uint16_t seq, std::vector<uint8_t>& out)
{
    uint8_t h[UDP_HDR] = {UDP_SYNC0, UDP_SYNC1, uint8_t(n >> 8), uint8_t(n), uint8_t(seq >> 8), uint8_t(seq), 0, 0};
    const uint16_t hc = crc16_ccitt(h + 2, 4);
    h[6] = uint8_t(hc >> 8);
    h[7] = uint8_t(hc);
    const uint32_t c = crc32_ieee(p, n);
    out.insert(out.end(), h, h + UDP_HDR);
    out.insert(out.end(), p, p + n);
    for (int k = 3; k >= 0; k--) out.push_back(uint8_t(c >> (8 * k)));
}

// RX side: push() the received bytes, gap() where bytes are known to be missing (sequence
// number gap), then next() returns the recovered datagrams one by one.
struct UdpDeframer {
    std::vector<uint8_t> buf;
    size_t pos    = 0;               // parse position in buf
    uint64_t base = 0;               // stream offset of buf[0]
    std::deque<uint64_t> gaps;       // stream offsets where bytes are missing
    bool have_seq = false;
    uint16_t last_seq = 0;
    uint64_t packets = 0, bad = 0, lost = 0;   // good datagrams, frames with a bad CRC, datagrams missing (seq)

    void push(uint8_t b) { buf.push_back(b); }
    void gap() { gaps.push_back(base + buf.size()); }

    // next good datagram into pkt; false when more bytes are needed
    bool next(std::vector<uint8_t>& pkt)
    {
        for (;;) {
            // sync word
            const size_t n = buf.size();
            while (pos + 1 < n && !(buf[pos] == UDP_SYNC0 && buf[pos + 1] == UDP_SYNC1)) pos++;
            if (pos + UDP_HDR > n) break;
            const uint8_t* h = &buf[pos];
            if (crc16_ccitt(h + 2, 4) != uint16_t((h[6] << 8) | h[7])) {
                pos++;
                continue;
            }
            const size_t len  = size_t(h[2]) << 8 | h[3];
            const size_t need = UDP_OVERHEAD + len;
            // a frame that spans a known gap cannot be good: do not wait for its end
            const uint64_t start = base + pos;
            while (!gaps.empty() && gaps.front() <= start) gaps.pop_front();
            const bool broken = !gaps.empty() && gaps.front() < start + need;
            if (!broken && pos + need > n) break;
            const uint8_t* q = h + UDP_HDR;
            if (broken || crc32_ieee(q, len) != (uint32_t(q[len]) << 24 | uint32_t(q[len + 1]) << 16
                                                    | uint32_t(q[len + 2]) << 8 | q[len + 3])) {
                bad++;
                pos++;
                continue;
            }
            const uint16_t seq = uint16_t((h[4] << 8) | h[5]);
            const uint16_t d   = uint16_t(seq - last_seq - 1);
            if (have_seq && d < 32768) lost += d;          // (a large jump: the transmitter restarted)
            have_seq = true;
            last_seq = seq;
            pkt.assign(q, q + len);
            packets++;
            pos += need;
            compact();
            return true;
        }
        compact();
        return false;
    }
    void compact()
    {
        if (pos < 65536 && pos * 2 < buf.size()) return;
        buf.erase(buf.begin(), buf.begin() + pos);
        base += pos;
        pos = 0;
    }
};
