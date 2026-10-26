# CLAUDE.md

DVB-S2 baseband modem (ETSI EN 302 307-1), TX + RX, **short FECFRAME (16200) only**,
QPSK 1/4–8/9 and 8PSK 3/5–8/9, pilots on/off, roll-off 0.35/0.25/0.20.
One Verilog-2001 code base at the repo root (modem RTL, Python models, regressions, environment), three board projects under `sdr/`
(plus `sdr/common/`, shared by the two host programs; every board keeps `rtl/`, `sim/`, `sw/`, and its build outputs in `out/`):

* **`sdr/z7020/`** Zynq-7020 (PYNQ-Z2 / Zybo Z7-20): PL loopback TX → channel emulator → RX, PS controls it over AXI-Lite. Vivado.
* **`sdr/b210/`** USRP B210 (Spartan-6 XC6SLX150): modem inside UHD's `radio_legacy`, between the host stream and DUC/DDC, PC program with web UI. ISE 14.7.
* **`sdr/adrv9364/`** ADI ADRV9364-Z7020 SOM on a custom carrier: modem between `axi_ad9361` and ADI's DMA path (ADI HDL hdl_2026_r1 + Vivado),
  SD-card image (Kuiper 2026.1.0) with the `dvbs2_adrv` service on the ARM: web UI + UDP data, static IP 192.168.30.1.

The owner (Jacky) works in satellite / RF. Answer in Traditional Chinese (English if he writes in English), concise, result first.
README.md (PHY only: description, build, structure, directory), sdr/README.md (board index) and sdr/z7020/README.md, sdr/b210/README.md, sdr/adrv9364/README.md
(each: description, hardware requirements, build, usage, web interface) are user-facing docs in English; keep them in sync when behaviour changes.

## Layout

| Path | What |
|---|---|
| `rtl/tx/` | `dvbs2_tx` (BBFRAME+CRC-8, BB scrambler, BCH, LDPC IRA, 8PSK interleave, PL framer + pilots + Gold scrambler, RRC 33-tap 2 sps) |
| `rtl/rx/` | `dvbs2_rx` (AGC, matched filter + Gardner/Farrow timing, frame sync + PLS + 3-stage FLL + phase/DD-PLL in `rx_frame*`, demap, layered min-sum LDPC P=45, BCH BM+Chien, BB out) |
| `rtl/common/` | `fir_sym33`, `cordic`, `ram_sdp`, `sample_pacer`, `ch_emu` (channel emulator, used by Z7020 top and testbenches) |
| `rtl/gen/` | **generated** ROM / parameter modules – never edit by hand |
| `python/` | reference models: `dvbs2_ref` (TX golden), `sync_model`, `frame_model`, `ldpc_fixed` (bit-exact LDPC), `bch_hw_model`, `run_e2e.py`, `gen_rtl_roms.py` |
| `sim/` | regression scripts (`reg_*.sh`, `run_all.sh`), `vl.sh`, core testbenches in `sim/tb/`, vector generators / checkers in `sim/tools/`; outputs go to `sim/out/` (large, git-ignored) |
| `sim/ber/` | BER harness: C++ TX/AWGN/demap + Verilated RTL LDPC/BCH |
| `sdr/z7020/rtl/` | Z7020 top: `dvbs2_loopback_top`, `dvbs2_regs` (AXI-Lite) |
| `sdr/z7020/vivado/`, `sdr/z7020/vitis/`, `sdr/z7020/sw/`, `sdr/z7020/*.bat` | Vivado/Vitis scripts, PYNQ driver, bare-metal demo, Windows one-click build |
| `sdr/z7020/sim/tb_top.v`, `sdr/z7020/doc/register_map.md` | AXI-Lite top testbench, AXI-Lite register map |
| `sdr/b210/rtl/` | `dvbs2_b210` wrapper (user-settings regs, payload bytes inside IQ samples) + FIFO |
| `sdr/b210/sim/` | `tb_b210.v` + `reg_b210.sh` (outputs in `sdr/b210/sim/out/`) |
| `sdr/adrv9364/rtl/` | `dvbs2_adrv` wrapper (AXI-Lite 0x44A00000, 16 kB payload FIFOs, CDC FIFOs to l_clk, spectrum / constellation snapshot) |
| `sdr/adrv9364/hdl/` | ADI project files copied into `<adi-hdl>/projects/adrv9364z7020/dvbs2/` (block design insertion, SOM-only top, CDC xdc) |
| `sdr/adrv9364/` | `build_fpga.sh` (ADI HDL + Vivado → BOOT.BIN), `make_sd_image.sh` (Kuiper image + service, no root: mtools/debugfs), `lib.sh`, `sw/` (ARM program, mock test), `rootfs/`, `sim/` |
| `sdr/common/` | header-only code shared by `sdr/b210/sw/dvbs2_b210.cpp` and `sdr/adrv9364/sw/dvbs2_adrv.cpp`: `udp_frame.hpp`, `net_udp.hpp` (UdpIn/UdpOut), `file_xfer.hpp` (file header, FileSink, InputQueue), `dsp_util.hpp` (FFT, spectrum, M2M4 Es/N0), `mini_http.hpp` (HTTP helpers, `web_server` with a per-program request handler), `dvbs2_common.hpp` (MODCOD tables, `running()` / `g_log`), `net_tun.hpp` (TUN interface, B210 only), `web/index.html` (one web page for both programs; board differences from `/api/status` `board` + `caps`, `default_web_root()` falls back to this directory when the program runs from its build dir) |
| `docs/img/` | images (`e2e_example.png`) |
| `sdr/b210/` | `patch_uhd_fpga.py` (copies `rtl/{common,gen,tx,rx}` + `sdr/b210/rtl` into UHD), `build_fpga.sh` (ISE), `sw/dvbs2_b210.cpp` (UHD C++ PC program) |

`sim/vl.sh <tb>` finds `<tb>.v` in `sim/tb`, `sdr/b210/sim`, `sdr/z7020/sim` or `sdr/adrv9364/sim` and, for a board testbench, also compiles that project's `rtl/`.

## Commands

```bash
./setup_ubuntu.sh [--check] [--no-uhd]      # deps (Verilator >= 5.006, iverilog, numpy, UHD)

# regressions (Verilator, run from anywhere)
sim/reg_tx.sh          # TX vs Python golden, all MODCOD x pilots x roll-off, ~2 min, expect pass=30 fail=0
sim/reg_ldpc.sh        # LDPC bit-exact vs ldpc_fixed, expect 16 PASS
sim/reg_bch.sh         # BCH decoder
sim/reg_fec.sh         # demap + LDPC + BCH chain
sim/reg_rxfe.sh        # AGC + timing recovery: no symbol slips + EVM limit, expect 6 PASS
sim/reg_sys.sh [quick|full]   # full loopback; full = 10 scenarios (CFO up to 2 % Rs, ±50 ppm, no pilots, roll-offs)
sdr/b210/sim/reg_b210.sh   # two dvbs2_b210 boards + channel (defines DVBS2_FIR_FOLD, SPARTAN6)
sdr/adrv9364/sim/reg_adrv.sh   # two dvbs2_adrv SOMs + channel, payload over AXI-Lite, expect 3 PASS
sdr/adrv9364/sw/test_mock.sh   # dvbs2_adrv on the PC with a software FPGA model: UDP + web API, expect PASS
sdr/b210/sw/test_tun.sh      # B210 TUN / UDP packet path without hardware, expect PASS (sudo ... netns: real TUN in two netns)
sim/run_all.sh [full]  # all of the above, ~40 min (+1 h for full)
sim/vl.sh <tb> <outdir> [-Gparam=val ...]   # build one testbench

python3 python/run_e2e.py -h                 # algorithm-level end-to-end model
python3 python/gen_rtl_roms.py               # regenerate rtl/gen/*.v from dvbs2_ref tables
cd sim/ber && ./build.sh && python3 ber_sweep.py -j 2 4 13   # BER curves

# Vivado (source <Vivado>/settings64.sh first)
cd sdr/z7020/vivado && vivado -mode batch -source create_project.tcl -tclargs pynq-z2   # or zybo-z7-20 / generic
vivado -mode batch -source build.tcl                                         # synth + impl + bitstream
vivado -mode batch -source sim.tcl -tclargs tb_sys MODCOD=4 NOISE=8953 CFO=4294967 PPM_STEP=85899

# B210
sdr/b210/sw/build.sh                                   # PC program -> sdr/b210/sw/build/dvbs2_b210
ISE_SETTINGS=/opt/Xilinx/14.7/ISE_DS/settings64.sh sdr/b210/build_fpga.sh   # 1-2 h, needs LX150 licence
```

Long jobs (`run_all.sh`, Vivado/ISE builds, BER sweeps) should run in the background with logs.

## Rules for changing the RTL

* **Bit-exact with the Python models.** TX must match `dvbs2_ref`; LDPC must match `ldpc_fixed`; BCH must match `bch_hw_model`. Change the model and the RTL together and rerun the matching regression.
* **Verilog-2001, synthesizable by Vivado *and* XST (ISE, Spartan-6):**
  one `always` block per array/memory; flattened vectors instead of arrays of vectors on ports and in generate loops;
  no parameter-valued attributes; byte-write RAM only through `ram_sdp_be4` under `SPARTAN6`.
* `` `ifdef DVBS2_FIR_FOLD `` = folded FIR (3 multipliers per rail, 6 clocks/output) for the B210 DSP48A1 budget;
  `` `ifdef SPARTAN6 `` = XST RAM templates. The Z7020 build uses neither. Both variants must stay bit-exact
  (reg_tx with and without FIR_FOLD).
* Timing budget: **≥ 8 clocks per sample** (DIV ≥ 8 on Z7020, master clock ≥ 8 × sample rate on B210);
  the RX timing loop pipeline needs ≥ 7 (input pacer MIN_GAP = 7). LDPC P=45 keeps up with 25 iterations at 16 clocks/symbol.
* `rtl/gen/*.v` comes from `python/gen_rtl_roms.py`; edit the generator, not the output.
* Before saying a change works, run at least the regression that covers it (reg_tx / reg_ldpc / reg_fec / reg_sys quick / reg_b210)
  and report pass/fail counts. Testbenches print `PASS`/`FAIL`.

## ADRV9364 specifics

* Base: ADI HDL `hdl_2026_r1` at 4840c81f2 (the commit of the Kuiper 2026.1.0 boot files), Vivado 2025.1 (2025.2 works with
  `ADI_IGNORE_VERSION_CHECK=1`, set by `build_fpga.sh`). BOOT.BIN = Kuiper's `fsbl.elf` + our bit + Kuiper's u-boot
  (bootgen reproduces ADI's BOOT.BIN byte for byte); Kuiper's `zynq-adrv9364-z7020-bob/lvds/devicetree.dtb` is used unchanged.
* The devicetree reserves 0x43C00000 (mwipcore), so the modem is at 0x44A00000; the program uses `/dev/mem`
  (`CONFIG_STRICT_DEVMEM` off) and sets the axi_ad9361 DAC data source to DMA (0x79024418/58 = 2).
* TX and RX share one sample rate (AD9364 BBPLL); Fs <= 12.5 MS/s (100 MHz / 8), >= 0.52 MS/s (libad9361 FIR, loaded with dlopen).
* `make_sd_image.sh` edits the image without root (mtools for FAT, debugfs for ext4). Kuiper's rootfs ships with an
  unreplayed journal: `e2fsck -fy` before debugfs is required (otherwise the boot-time replay undoes edits). Image defaults transmit at boot.
* Built with Vivado 2025.2: 95 % slices, 100 MHz met with WNS ~0 (after pipelining rx_timing mu / rx_agc average,
  multicycle on the config regs, axi_ad9361 DC filter + IQ correction off, Performance_ExplorePostRoutePhysOpt).
  Any RTL change can break timing; check `timing_impl.log`. Not yet run on hardware.

## B210 specifics

* UHD source used to build the FPGA image must be the **same version** as the UHD installed on the PCs (FPGA compat number);
  `build_fpga.sh` clones tag `v$(uhd_config_info --version)`. Patch verified on UHD 4.1.0.5 / 4.6.0.0 / 4.8.0.0 / 4.11.0.0.
* `patch_uhd_fpga.py` is idempotent (patches from `*.orig`, marker `DVBS2-PATCH`); new make target `B210_DVBS2`.
* Host ↔ FPGA: user settings regs (device arg `enable_user_regs`, `poke32(4*n)`, `peek64(8*m)` → status words 2m/2m+1, ID word 30 = 0x44564232).
  Payload bytes ride in sc16 samples: TX `I[8]` valid + `I[7:0]` byte; RX `I[9]` frame end, `I[8]` valid, `I[7:0]` byte, `Q` = 16-bit seq.
* UDP mode (`--udp-in` / `--udp-out`, host only): each datagram framed as in `sdr/common/udp_frame.hpp` (sync C5 3A, len, seq, CRC-16, data, CRC-32);
  TX zero-fills the current BBFRAME when its queue is empty (BBFRAME = DFL/8 bytes, FIFO reset at session start keeps the count aligned).
* TUN mode (`--tun dvbs0`, host only, `sdr/common/net_tun.hpp`): IP packets of the interface ride exactly like UDP datagrams
  (UdpIn/UdpOut with `tun = true`, fd borrowed from a TunDev kept for the whole run); default address tx 10.60.0.1/24, rx 10.60.0.2/24.
  `--web` works with `--tun` / `--udp-*` (page switches prbs | udp | tun via `caps.data_modes`). Test without hardware: `sdr/b210/sw/test_tun.sh`.
* Two-way link `--host N`: trx + `--tun dvbs0` at `--subnet` + N (default 10.60.0.N/24), FDD (host 1 TX `--freq`, RX `--freq + --duplex`,
  others swapped). LinkMonitor (net_tun.hpp): 20-byte hello (first byte 0, never IP) every 0.5 s in the same framed stream / seq space
  (`UdpIn::queue`), intercepted by `UdpOut::intercept`; up = peer's hellos decoded within 2 s and peer reports it decodes ours;
  carrier via TUNSETCARRIER, `UdpIn::hold` drops input while down. JSON `link{...}`.
* `--config FILE` (boost `parse_config_file`, stored after the command line so the command line wins), `--save-config FILE`
  writes the non-default options and exits; example `sdr/b210/sw/dvbs2_b210.conf`. ADRV9364 has its own `--config` parser.
* File mode: TX sends `--preamble` seconds of zeros, then header (magic `A5 'DVBS2' 5A C3`, u64 len, ~len), then the file; RX writes only after the header and stops after len bytes.
* RX decodes MODCOD/pilots from the PLHEADER; only roll-off (and Rs, frequency) must match TX.
* Built with ISE 14.7 against UHD 4.11.0.0 (routes, timing met: 54.7k LUT / 79 % slices / 88 % BRAM / 86 % DSP) and
  verified on a real B210 in `--web` trx mode. Image is **single-radio** (radio 1 removed to make room).
  Area is tight: the first build failed routing at 92 % slices until the PLS FHT became the streaming `rx_pls_wht`.
* ISE licence: FLEXnet reads the host ID only from `eth0`; on this VM a dummy `eth0` with the licence MAC is needed (lost on reboot).

## Known environment gotchas

* Verilator must be ≥ 5.006 (`--binary --timing`); Ubuntu 22.04's package is too old (setup script builds v5.020).
* Windows + Vivado XSim: if `NoDefaultCurrentDirectoryInExePath` is set, `compile.bat` "is not recognized";
  `sdr/z7020/vivado/sim.tcl` clears it, in the GUI run `unset env(NoDefaultCurrentDirectoryInExePath)` first.
* ISE 14.7 on new Ubuntu: run with bash (not dash), may need libncurses5, may need to rename ISE's bundled libstdc++.
* `sim/out/` (and `sdr/b210/sim/out/`) grows to several GB; it is git-ignored and safe to delete.
