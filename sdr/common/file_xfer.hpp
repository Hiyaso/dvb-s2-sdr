//
// file_xfer.hpp -- file transfer framing (preamble, header, length) and the TX payload input queue.
// Shared by sdr/b210/sw/dvbs2_b210.cpp and sdr/adrv9364/sw/dvbs2_adrv.cpp (header-only, one translation unit each).
//
#pragma once
#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <mutex>
#include <vector>
#include "dvbs2_common.hpp"

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
