//
// dvbs2_common.hpp -- DVB-S2 frame parameters and the run state of the host programs.
// Shared by b210/host/dvbs2_b210.cpp and adrv9364/sw/dvbs2_adrv.cpp (header-only, one translation unit each).
//
#pragma once
#include <atomic>
#include <cstdio>

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

static std::atomic<bool> stop_signal{false};   // Ctrl-C / SIGTERM / end of program
static std::atomic<bool> sess_stop{false};     // end of the current session
static FILE* g_log = stdout;     // status output (stderr when the payload goes to stdout)
static bool running() { return !stop_signal && !sess_stop; }
