# DVB-S2 Baseband PHY in Verilog (TX + RX)

## Description

A complete DVB-S2 (ETSI EN 302 307-1) baseband transmitter and receiver in synthesizable Verilog-2001,
with bit-exact Python reference models and Verilator regressions. The same RTL is built for three
hardware platforms; those board projects live in [`sdr/`](sdr/) and each has its own README.

* **Modulation / coding:** QPSK 1/4 … 8/9 and 8PSK 3/5 … 8/9, **short FECFRAME (16200) only**,
  pilots on or off, roll-off 0.35 / 0.25 / 0.20, dummy frames.
* **Clocking:** at least 8 clocks per sample. At 100 MHz that gives up to 6.25 Msym/s
  (2 samples per symbol). The RX timing loop itself needs 7 clocks, and the RX input pacer
  guarantees a sample spacing of at least 7.
* **Verification:** the ROMs are generated from the Python reference model. TX output matches the
  golden model sample for sample, and the LDPC and BCH decoders match their Python models bit for bit.
* **Synthesis:** Vivado (7-series) and XST (ISE 14.7, Spartan-6) from the same sources.
  `DVBS2_FIR_FOLD` selects a folded FIR and `SPARTAN6` selects XST RAM templates; both variants are bit-exact.

### Performance (RTL simulation)

BER with ideal synchronisation, RTL LDPC (25 iterations) + BCH, measured to 2×10⁷ bits or 50 frame errors
(`sim/ber/`; plot in `sim/ber/ber_curves.png`, raw data in `sim/ber/results/`):

| MODCOD | Es/N0 at FER 10⁻² | Es/N0 with 0 errors in 2×10⁷ bits | Avg. iterations | ETSI normal-frame QEF |
|---|---|---|---|---|
| QPSK 1/4 | −1.17 dB | −0.7 dB | 25 | −2.35 dB |
| QPSK 1/2 | 0.52 dB | 0.7 dB | 16.5 | 1.00 dB |
| QPSK 3/4 | 4.09 dB | 4.2 dB | 10.3 | 4.03 dB |
| QPSK 8/9 | 6.29 dB | 6.4 dB | 7.3 | 6.20 dB |
| 8PSK 3/5 | 5.83 dB | 6.0 dB | 18.3 | 5.50 dB |
| 8PSK 2/3 | 6.83 dB | 7.0 dB | 13.5 | 6.62 dB |
| 8PSK 8/9 | 11.68 dB | 11.8 dB | 8.3 | 10.69 dB |

* The ETSI values are thresholds for the normal frame (64800); short frames are expected to be somewhat worse.
  QPSK 1/2 is effectively rate 4/9 in a short frame, which is why its threshold is lower.
* 8PSK 8/9 is about 1 dB from ETSI: short frame plus min-sum and 7-bit message quantisation.
* QPSK 1/4 has a slow floor between 10⁻⁵ and 10⁻⁶ (a few frames keep 13–20 errors, beyond BCH t = 12;
  a trapping set). More iterations do not help; wider APP words or offset min-sum would.
* Full loopback with synchronisation (`sim/sync_loss.sh`, CFO 0.5 % Rs, +20 ppm, pilots on) loses
  about 0.1–0.15 dB against ideal sync. All 10 scenarios of `sim/reg_sys.sh full`
  (CFO up to 2 % Rs, ±50 ppm, no pilots, all roll-offs, QPSK 1/4 to 8PSK 8/9) are error-free after lock.

### Limitations

* Short FECFRAME only; the normal frame (64800) needs a larger LDPC memory and is not implemented.
* No QPSK 9/10 (not defined for short frames) and no 16/32APSK.
* Symbol rate up to 6.25 Msym/s at 100 MHz; higher rates need an RX front end that takes one sample per clock.

## Build

### Environment (Ubuntu)

```bash
git clone <this repo> dvbs2 && cd dvbs2
./setup_ubuntu.sh            # Verilator >= 5.006, iverilog, Python + numpy, UHD; runs one TX regression
./setup_ubuntu.sh --check    # check only, install nothing
./setup_ubuntu.sh --no-uhd   # skip UHD (only needed for the B210 project)
```

* Ubuntu 24.04 ships Verilator 5.020. The 22.04 package is too old, so the script builds v5.020 from source.
* Vivado and ISE 14.7 are only needed for the board projects in `sdr/`; install them from AMD and
  `source <install dir>/settings64.sh` before use.
* On macOS: `brew install verilator coreutils` (coreutils provides `gtimeout`), then use a Python venv with numpy.

### Regenerate the ROMs

`rtl/gen/*.v` is generated from the Python tables and is checked in. Edit the generator, not the output:

```bash
python3 python/gen_rtl_roms.py
```

### Simulate and verify

All regressions use Verilator and can be run from any directory. Testbenches print `PASS` / `FAIL`.

| Command | What it checks |
|---|---|
| `sim/reg_tx.sh` | TX vs. the Python golden model, every MODCOD × pilots × roll-off (expect `pass=30 fail=0`, ~2 min) |
| `sim/reg_ldpc.sh` | LDPC decoder vs. the bit-exact model `ldpc_fixed` (expect 16 PASS) |
| `sim/reg_bch.sh` | BCH decoder: 0–12 errors and uncorrectable frames |
| `sim/reg_fec.sh` | Demapper + LDPC + BCH chain |
| `sim/reg_rxfe.sh` | AGC + timing recovery (±200 ppm, Es/N0 0–10 dB) |
| `sim/reg_sys.sh quick\|full` | Full loopback `dvbs2_tx → ch_emu → dvbs2_rx`; `full` runs 10 scenarios |
| `sim/run_all.sh [full]` | All of the above plus the B210 board regression (~40 min, +1 h for `full`) |
| `sim/vl.sh <tb> <outdir> [-Gparam=val ...]` | Build one testbench. It looks in `sim/tb` and in `sdr/*/sim`; a board testbench also compiles that board's `rtl/` |

BER curves (C++ TX, AWGN and demapper, bit-exact with `rx_demap.v`; RTL LDPC/BCH through Verilator):

```bash
cd sim/ber && ./build.sh && python3 ber_sweep.py -j 2 4 13 && python3 plot_ber.py
```

### Algorithm-level model (Python only)

`python/run_e2e.py` chains the reference models into a full link: TX → channel (CFO, clock offset,
fractional delay, AWGN) → timing recovery → frame sync / PLS / FLL / PLL → demapper → LDPC → BCH → BB
descrambler and CRC → BER against the PRBS. The demapper and LDPC are bit-exact with the RTL.

```bash
cd python
python3 run_e2e.py                                               # 8PSK 2/3, 9 dB, CFO 1 % Rs, 20 ppm, 30 frames
python3 run_e2e.py --modcod 4 --esn0 2 --cfo 0.005 --plot e2e.png
python3 run_e2e.py --modcod 13 --no-pilots --esn0 10             # decision-directed PLL
python3 run_e2e.py --ideal-sync --modcod 4 --sweep 0.4 0.6 0.8 --frames 50
python3 run_e2e.py -h
```

## Structure

```
TX  dvbs2_tx
    PRBS-23 / AXI-Stream → BBHEADER (CRC-8) + BB scrambler → BCH (t = 12) → LDPC (IRA accumulator)
    → 8PSK interleaver → mapper → PLHEADER (SOF + PLS, π/2-BPSK) + pilots + Gold PL scrambler
    → RRC shaping (33 taps, 2 samples/symbol)

CH  ch_emu
    8-tap polyphase interpolator (clock offset in ppm, fractional delay) → CORDIC carrier offset → AWGN

RX  dvbs2_rx
    AGC → RRC matched filter → Gardner TED + Farrow interpolator + Rice NCO (timing recovery)
    → rx_frame: NCO derotation + 16K-symbol buffer + differential SOF/PLSC correlator (CFO tolerant)
                PLS decoding (9-point frequency grid + streaming 64-point Hadamard ML)
                3-stage FLL (lag 1 → Luise-Reggiannini 16 lags → pilot phase difference) + loop-delay compensation
                block phase interpolation (pilots / header), decision-directed PLL without pilots, gain normalisation
    → soft demapper (LLR) → layered normalized min-sum LDPC (P = 45, double buffered, early stop)
    → BCH (Berlekamp-Massey + Chien) → BB descrambler + CRC check → PRBS BER checker / AXI-Stream out
```

The channel emulator `ch_emu` is only used by the Z7020 loopback top and the testbenches.

## Directory

| Path | Contents |
|---|---|
| `rtl/tx/` | `dvbs2_tx`: BBFRAME + CRC-8, BB scrambler, BCH, LDPC IRA, 8PSK interleaver, PL framer + pilots + Gold scrambler, RRC |
| `rtl/rx/` | `dvbs2_rx`: AGC, matched filter + Gardner/Farrow timing, frame sync + PLS + FLL + PLL (`rx_frame*`), demapper, LDPC, BCH, BB output |
| `rtl/common/` | `fir_sym33`, `cordic`, `ram_sdp`, `sample_pacer`, `ch_emu` (channel emulator) |
| `rtl/gen/` | Generated ROM / parameter modules (from `python/gen_rtl_roms.py`; do not edit by hand) |
| `python/` | Reference models: `dvbs2_ref` (TX golden), `ldpc_fixed` (bit-exact LDPC), `bch_hw_model`, `sync_model`, `frame_model`, `run_e2e.py`, `gen_rtl_roms.py` |
| `sim/` | Regression scripts (`reg_*.sh`, `run_all.sh`, `sync_loss.sh`), `vl.sh`; outputs in `sim/out/` (git-ignored) |
| `sim/tb/` | Core testbenches |
| `sim/tools/` | Vector generators and result checkers called by the regression scripts (`gen_*_vec.py`, `check_*.py`) |
| `sim/ber/` | BER harness: C++ TX / AWGN / demapper + Verilated RTL LDPC and BCH |
| `docs/img/` | Images (e.g. `e2e_example.png`, output of `run_e2e.py --plot`) |
| `setup_ubuntu.sh` | Development environment setup |
| `sdr/` | Board projects built from this PHY, see [`sdr/README.md`](sdr/README.md) |
| `CLAUDE.md` | Project notes for Claude Code (commands, regressions, rules for changing the RTL) |
