# DVB-S2 on Zynq-7020 (PL loopback)

## Description

A pure-PL loopback test of the DVB-S2 PHY ([`../../rtl`](../../rtl)) on an xc7z020clg400-1:
**TX → channel emulator (clock offset, CFO, AWGN) → RX**, all inside the FPGA. The ARM (PS) sets the
modem and channel parameters over AXI-Lite and reads lock state, counters and BER.

* Clock 100 MHz (FCLK_CLK0). Symbol rate = `100 MHz / (2·DIV)` with DIV ≥ 8, so up to 6.25 Msym/s.
* Modem: QPSK 1/4 … 8/9, 8PSK 3/5 … 8/9, short frame, pilots on/off, roll-off 0.35 / 0.25 / 0.20.
* Channel emulator `ch_emu`: clock offset (ppm), fractional delay, carrier offset, phase, AWGN at a set Es/N0.
* AXI-Lite slave `dvbs2_0` at `0x43C0_0000` (4 KB); register map in [`doc/register_map.md`](doc/register_map.md).
* LEDs: [0] frame lock, [1] BER lock, [2] blinks on each good BBFRAME, [3] heartbeat.

| Path | Contents |
|---|---|
| `rtl/dvbs2_loopback_top.v` | Top: `dvbs2_tx` → `ch_emu` → `dvbs2_rx`, LEDs |
| `rtl/dvbs2_regs.v` | AXI-Lite registers |
| `doc/register_map.md` | AXI-Lite register map |
| `vivado/` | Tcl to create the project, block design, synthesis/implementation and simulation; XDC; PYNQ-Z2 board files |
| `vitis/` | Vitis bare-metal build (`build_vitis.tcl`) and download/run (`run_on_board.tcl`) |
| `sw/dvbs2_pynq.py` | PYNQ driver and demo |
| `sw/dvbs2_demo.c` | Vitis bare-metal demo (UART output) |
| `sim/tb_top.v` | Testbench that configures the whole top through AXI-Lite |
| `1_build_hw.bat` `2_build_sw.bat` `3_run_on_board.bat` `build_all.bat` | Windows one-click build / run (outputs in `out/`, logs in `logs/`) |

**Estimated resources** (TX and channel emulator from Yosys `synth_xilinx`; RX counted from the RTL
structure; check `vivado/build/reports/utilization.rpt` for the real numbers):

| Block | LUT | FF | DSP48 | BRAM36 |
|---|---|---|---|---|
| TX (BB, BCH/LDPC encoder, shaping) | ~2.4K | ~2.3K | 34 | 2.5 |
| Channel emulator | ~2.1K | ~1.7K | 22 | 0 |
| RX front end (AGC, matched filter, timing) | ~2.5K | ~2K | ~40 | 0 |
| RX frame sync (correlator, PLS, FLL/PLL, 16K buffer) | ~7K | ~9K | ~25 | 12 |
| LDPC decoder (P = 45, double buffered) | ~11K | ~8K | 0 | ~42 |
| BCH decoder, demapper, BB output, registers | ~4K | ~3K | ~4 | 1 |
| **Total (xc7z020: 53.2K LUT / 106K FF / 220 DSP / 140 BRAM36)** | **~29K (55 %)** | **~26K (25 %)** | **~125 (57 %)** | **~58 (41 %)** |

## Hardware requirements

* A Zynq-7020 board with xc7z020clg400-1: **TUL PYNQ-Z2** or **Digilent Zybo Z7-20**
  (any other xc7z020 board works with the `generic` target, see below). No RF hardware is needed.
* **Vivado 2020.2 or later** (the free ML Standard / WebPACK edition covers the xc7z020).
* Board files: PYNQ-Z2 board files are included in `vivado/boards/`; for the Zybo install the Digilent
  `vivado-boards`. Without board files the build falls back to the bare part and a generic PS7
  configuration, and you must check the DDR settings yourself.
* To run it, one of:
  * a **PYNQ** SD-card image on the PYNQ-Z2 (Python driver), or
  * **Vitis** (same version as Vivado) and the board's USB-UART / JTAG for the bare-metal demo.
* Windows one-click scripts expect Vivado/Vitis in `C:\Xilinx\<XVER>` (default 2021.2); override with
  `XILINX_ROOT` and `XVER`.

## Build

### Linux / Vivado batch mode

```bash
source <Vivado install dir>/settings64.sh
cd sdr/z7020/vivado
vivado -mode batch -source create_project.tcl -tclargs pynq-z2     # or zybo-z7-20 / generic
vivado -mode batch -source build.tcl                               # synthesis + implementation + bitstream
```

* Outputs: `vivado/build/dvbs2_z7020.bit`, `.hwh` (for PYNQ), `.xsa` (for Vitis) and `build/reports/`
  (utilization, timing, power); copies also go to `out/`. WNS/WHS are printed at the end and a failing
  timing check shows up as a CRITICAL WARNING.
* The project can also be opened in the GUI: `vivado/build/dvbs2_z7020/dvbs2_z7020.xpr`.

### Bare-metal application (Vitis)

```bash
cd sdr/z7020/vitis
xsct build_vitis.tcl        # platform from vivado/build/dvbs2_z7020.xsa + app from sw/dvbs2_demo.c -> out/dvbs2_demo.elf
```

By hand: create a platform from `dvbs2_z7020.xsa`, an empty standalone C application, add
`sw/dvbs2_demo.c` and link with `-lm`.

### Windows

Double-click `build_all.bat` (hardware, about 30–60 min, then the Vitis application), or run
`1_build_hw.bat` and `2_build_sw.bat` separately. Outputs go to `out/`, logs to `logs/`.

### Simulation

* Verilator (about 50× faster than XSim), from the repository root:
  `sim/reg_sys.sh quick|full` for the modem loopback, `sim/vl.sh tb_top sim/out/tb_top` for this top.
* Vivado XSim (after creating the project):
  `vivado -mode batch -source vivado/sim.tcl -tclargs tb_sys MODCOD=13 NOISE=4487 CFO=4294967`
  (`tb_sys` is the modem loopback, `tb_top` drives the whole top over AXI-Lite).

## Usage

### PYNQ-Z2

Copy `dvbs2_z7020.bit`, `dvbs2_z7020.hwh` (same base name) and `sw/dvbs2_pynq.py` to the board, then in Python
or a Jupyter notebook:

```python
from dvbs2_pynq import DVBS2
d = DVBS2('dvbs2_z7020.bit')                 # loads the overlay; modem at 0x43C00000
d.configure(modcod=13, pilots=True)          # 8PSK 2/3
d.set_channel(esn0_db=9.0, cfo_rs=0.01, ppm=20)
d.status()                                   # lock, MODCOD, CFO, frames, LDPC/BCH counters, BER
d.ber_sweep(4, [0.5, 1.0, 1.5, 2.0])         # BER/FER sweep for QPSK 1/2
```

Other methods: `set_symbol_rate(rs_hz)`, `restart_rx()`, `clear_stats()`, `rd(off)` / `wr(off, v)` for raw registers.

### Bare metal

Program the bitstream and run `dvbs2_demo.elf` (`3_run_on_board.bat` on Windows, or `xsct vitis/run_on_board.tcl`).
The demo prints the lock state and a BER sweep on the UART at 115200 8N1.

### Registers

Control registers at 0x000–0x040 (ID, VERSION, CTRL, TXCFG, DIV, channel emulator CH_*, RX_AGC/TIM/FS/FLL/FEC)
and status words from 0x080 (lock, MODCOD, CFO, frame / miss / PLS-fail counters, LDPC, BCH, BBFRAME, BER).
See [`doc/register_map.md`](doc/register_map.md) for every field; the B210 and ADRV9364 projects reuse
the same encodings.

## Web interface

This project has no web interface: it runs without a network-facing program. Use the PYNQ Jupyter notebook
server on the PYNQ-Z2 (browser at `http://<board>:9090`) with `dvbs2_pynq.py`, or the UART output of the
bare-metal demo. For a browser UI with spectrum and constellation, see the [B210](../b210/README.md) and
[ADRV9364](../adrv9364/README.md) projects.
