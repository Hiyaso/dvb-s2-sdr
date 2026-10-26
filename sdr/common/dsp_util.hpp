//
// dsp_util.hpp -- FFT / power spectrum for the web page and the blind Es/N0 estimate.
// Shared by sdr/b210/sw/dvbs2_b210.cpp and sdr/adrv9364/sw/dvbs2_adrv.cpp (header-only, one translation unit each).
//
#pragma once
#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>

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

// Blind SNR estimate for the web page (M2M4, valid for constant-modulus PSK: PLHEADER, pilots,
// QPSK and 8PSK data).  x: DDC samples at 2 samples/symbol.  The RRC matched filter is evaluated
// at 16 timing phases; the phase with the lowest normalised fourth moment kappa = M4 / M2^2 is the
// best sampling instant.  kappa = 1: no noise, 2: noise only;  Es/N0 = s / (1 - s), s = sqrt(2 - kappa).
// Independent of carrier phase and CFO, so it needs no synchronisation.
static double psk_kappa(const std::vector<std::complex<float>>& x, double alpha)
{
    const int span = 8;                                // matched filter +-8 symbols
    const int ns   = int(x.size()) / 2;
    if (ns <= 2 * span + 16) return NAN;
    double best = NAN;
    for (int p = 0; p < 16; p++) {
        double c[4 * span + 1];                        // y(k + p/16) = sum_m x[2k + m] h(p/16 - m/2)
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
    if (!(kappa < 2.0)) return NAN;                    // noise only (or no data)
    const double s = std::sqrt(2.0 - kappa);           // signal power / total power
    return s >= 0.9999 ? 40.0 : std::min(40.0, 10.0 * std::log10(s / (1.0 - s)));
}
