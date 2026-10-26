# SDR Board Projects

Hardware implementations of the DVB-S2 PHY in [`../rtl`](../rtl). All three use the same modem RTL;
each directory adds a board-specific wrapper, build scripts and software.

| Directory | Hardware | Toolchain | What it does | Status |
|---|---|---|---|---|
| [`z7020/`](z7020/README.md) | Zynq-7020 (PYNQ-Z2, Zybo Z7-20) | Vivado | PL loopback TX → channel emulator → RX, controlled by the PS over AXI-Lite | Simulated (`tb_top`, `reg_sys`); Vivado scripts, PYNQ driver and bare-metal demo |
| [`b210/`](b210/README.md) | Ettus USRP B210 (Spartan-6 XC6SLX150) | ISE 14.7 + UHD | Modem inside the UHD FPGA image; PC program with web UI, file and UDP transfer, IP link over a TUN interface | Verified on hardware |
| [`adrv9364/`](adrv9364/README.md) | ADI ADRV9364-Z7020 SOM | Vivado + ADI HDL | Modem between `axi_ad9361` and the DMA path; SD-card image with a web UI and UDP data service | Timing met, not yet run on hardware |
| `common/` | — | C++17 | Header-only code shared by the B210 PC program and the ADRV9364 SOM program (UDP framing, file transfer, spectrum / SNR estimation, mini HTTP server), the TUN interface used by the B210 program (`net_tun.hpp`) and the shared web page `web/index.html` | — |

Board regressions (Verilator) are run from any directory:

```bash
sdr/b210/sim/reg_b210.sh       # two B210 wrappers + channel
sdr/adrv9364/sim/reg_adrv.sh   # two ADRV9364 wrappers + channel, expect 3 PASS
sdr/adrv9364/sw/test_mock.sh   # ADRV9364 program on the PC with a software FPGA model, expect PASS
```
