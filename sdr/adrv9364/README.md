# DVB-S2 on ADRV9364-Z7020 SOM

## Description

The DVB-S2 PHY ([`../../rtl`](../../rtl), the same RTL as the other boards: TX + RX, short frame,
QPSK / 8PSK) in the PL of an Analog Devices ADRV9364-Z7020 SOM, between the `axi_ad9361` core and
ADI's DMA data path. The SOM boots ADI Kuiper Linux from an SD card and starts the `dvbs2_adrv`
service: **controlled over the network (web page), payload in and out over UDP**. No PC program is needed.

```
PC A ──UDP→ :5000 ──▶ [SOM 1] DVB-S2 TX ─▶ AD9364 ~~~ RF ~~~ AD9364 ─▶ DVB-S2 RX [SOM 2] ──UDP→ :5001 ──▶ PC B
                      ARM: dvbs2_adrv (web :80, UDP)                ARM: dvbs2_adrv
                      PL : AXI-Lite FIFO ⇄ modem ⇄ axi_ad9361       PL : axi_ad9361 ⇄ modem ⇄ AXI-Lite FIFO
```

**Status:** the FPGA builds with Vivado 2025.2 and meets timing, the SD-card image is built, and the
simulations and PC-side tests pass. **It has not been run on hardware yet** (follow "First boot check" below).

* Sample rate Fs = 2·Rs, modem clock 100 MHz, at least 8 clocks per sample → Fs ≤ 12.5 MS/s,
  **Rs ≤ 6.25 Msym/s**; the AD9364 goes down to 0.52 MS/s. **TX and RX share one sample rate**
  (one BBPLL); the frequencies are independent (FDD).
* Payload rate (air capacity, pilots on, roll-off 0.35):

  | MODCOD | 2 MHz bandwidth (Rs 1.48 Msym/s, default) | 8.4 MHz bandwidth (Rs 6.25 Msym/s, maximum) |
  |---|---|---|
  | QPSK 1/4 | 0.53 Mbit/s | 2.2 Mbit/s |
  | QPSK 1/2 (default) | 1.23 Mbit/s | 5.2 Mbit/s |
  | QPSK 3/4 | 2.06 Mbit/s | 8.7 Mbit/s |
  | 8PSK 2/3 | 2.79 Mbit/s | 11.8 Mbit/s |
  | 8PSK 8/9 | 3.75 Mbit/s | 15.8 Mbit/s |

* Limitations: not yet verified on hardware; one sample rate for TX and RX; almost no timing margin at
  100 MHz (re-check timing after any RTL change); each SOM's IP address is fixed when its image is built
  (`IP=`, change later with `nmcli`); UDP interface only (no TAP / bridged virtual NIC yet).

| Path | Contents |
|---|---|
| `rtl/dvbs2_adrv.v` | PL wrapper: AXI-Lite registers (0x44A00000), 16 kB TX/RX payload FIFOs, clock-domain-crossing FIFOs, spectrum / constellation capture |
| `rtl/adrv_afifo.v`, `rtl/adrv_fifo.v` | Asynchronous (Gray code) and synchronous FIFOs |
| `hdl/` | Vivado project copied into ADI HDL `projects/adrv9364z7020/dvbs2/`: block design, SOM-only top, CDC / multicycle constraints |
| `build_fpga.sh` | One step: fetch ADI HDL (hdl_2026_r1) → create project → Vivado synthesis / implementation → BOOT.BIN |
| `make_sd_image.sh` | One step: Kuiper Linux 2026.1.0 image + BOOT.BIN + `dvbs2_adrv` service + static IP → `.img` |
| `lib.sh` | Shared by both scripts: downloads Kuiper and the tools (mtools, Arm compiler, bootgen), assembles BOOT.BIN |
| `sw/dvbs2_adrv.cpp` | Program on the SOM: modem through `/dev/mem`, AD9364 through sysfs + libad9361, UDP, web server, file transfer (shared parts in `../common/`) |
| `sw/build.sh`, `sw/test_mock.sh` | Cross-compile; PC test of UDP and the web API against a software FPGA model |
| `rootfs/` | `dvbs2.service` and the `/etc/dvbs2.conf` template installed into the image |
| `sim/tb_adrv.v`, `sim/reg_adrv.sh` | Two SOMs (separate sample clocks, 12-bit DAC/ADC) + channel model, payload over AXI-Lite |

Downloads and build outputs go to `dl/`, `adi-hdl/`, `out/`, `sw/build/` and `sim/out/` (all git-ignored).

## Hardware requirements

* **ADRV9364-Z7020 SOM** on a **custom carrier board**. The FPGA top only uses the SOM's own pins
  (AD9364, SPI, control GPIO, I2C) and drives no carrier PL pins. The Ethernet PHY is on the SOM;
  SD card, UART and Ethernet magnetics / RJ45 are on the carrier and must be wired as on ADI's carrier:
  SD0 = MIO40–45, card detect = MIO50 (low when a card is inserted), UART1 = MIO48/49 (115200 8N1),
  boot mode set to SD.
* An **SD card of 8 GB or more**, Ethernet to the PC, antennas or a cable with **at least 30 dB attenuation**.
* **Build machine:** Ubuntu (Linux), no root needed, about 25 GB of disk (Kuiper image 7 GB, two output images,
  the ADI HDL project). The scripts download Kuiper (2 GB) and the Arm GNU toolchain 14.2 and build mtools and
  bootgen (needs `libssl-dev`).
* **Vivado 2025.1 or 2025.2**; the free ML Standard edition covers the xc7z020. Only Zynq-7000 support is needed,
  not Vitis. ADI hdl_2026_r1 is validated on 2025.1; this project was built with **2025.2**
  (`build_fpga.sh` disables ADI's version check). FSBL and u-boot are ADI's from Kuiper (the PS configuration is
  unchanged; rebuilding ADI's BOOT.BIN with bootgen gives an identical file).

## Build

### 1. FPGA (1–2 hours)

```bash
VIVADO_SETTINGS=<Vivado install dir>/settings64.sh sdr/adrv9364/build_fpga.sh
# e.g. VIVADO_SETTINGS=/tools/Xilinx/2025.1/Vivado/settings64.sh
#      without it the script looks for Vivado under /tools/Xilinx, /opt/Xilinx, ~/Xilinx (2025.1 first)
# -> sdr/adrv9364/out/system_top.bit, system_top.xsa, BOOT.BIN (log: sdr/adrv9364/out/build_fpga.log)
```

If timing fails, ADI's flow stops (`timing_impl.log`) and no BOOT.BIN is written.

**Resources and timing** (Vivado 2025.2, xc7z020clg400-1):

| | LUT | FF | BRAM36 | DSP |
|---|---|---|---|---|
| Whole design | 38.6k (72 %) | 36.5k (34 %) | 75 (54 %) | 121 (55 %) |
| of which modem `dvbs2_adrv` | 31.4k | 25.1k | 65 + 12 × RAMB18 | 117 |
| of which `axi_ad9361` | 4.5k | 7.9k | 0 | 4 |

Slices are **95 %** used and 100 MHz just closes (WNS 0.000 ns, WHS 0.014 ns). What it took:

* RTL: one extra register stage in the RX timing recovery μ computation (`rx_timing.v`) and the AGC average
  (`rx_agc.v`), with unchanged per-sample results (`reg_rxfe` identical); RX input pacer minimum gap 6 → 7 clocks.
* Wrapper: registered RX-FIFO almost-full flag, limited reset fan-out.
* Constraints: multicycle 4 on the control registers (they only change while the modem is in reset).
* Unused DC filter and IQ correction removed from `axi_ad9361` (the AD9364 tracks DC and quadrature itself).
* Vivado: synthesis retiming, implementation strategy Performance_ExplorePostRoutePhysOpt, plus ADI's
  automatic timing-fix script.

If a later RTL change or Vivado version misses timing slightly, start from the worst path in `timing_impl.log`.

### 2. SD-card image (about 5 minutes)

```bash
sdr/adrv9364/make_sd_image.sh                       # -> sdr/adrv9364/out/dvbs2-adrv9364.img (7.2 GB)
IP=192.168.30.2/24 sdr/adrv9364/make_sd_image.sh    # second SOM with another IP (one image per SOM; same output name)
GW=192.168.30.254 sdr/adrv9364/make_sd_image.sh     # with a default gateway
STOCK=1 sdr/adrv9364/make_sd_image.sh               # -> dvbs2-adrv9364-stock.img: ADI's stock FPGA (no modem), to test the carrier
XZ=1 sdr/adrv9364/make_sd_image.sh                  # also write a .img.xz (about 2 GB, Etcher can write it directly)
```

Write it with balenaEtcher, or
`sudo dd if=sdr/adrv9364/out/dvbs2-adrv9364.img of=/dev/sdX bs=4M conv=fsync status=progress`
(check with `lsblk` that `/dev/sdX` is the SD card).

What the image changes:

* Boot partition: `BOOT.BIN` (ADI FSBL + this bitstream + ADI u-boot), the SOM's `devicetree.dtb`, `uImage`, `uEnv.txt`.
* `/usr/local/bin/dvbs2_adrv`, `/usr/local/share/dvbs2/web/`, `/etc/dvbs2.conf`, `dvbs2.service` (started at boot).
* NetworkManager: static IP on eth0 (replaces DHCP / link-local), host name `dvbs2`.
* Desktop off (Xvfb, x11vnc, lightdm), boots to text mode to leave the CPU to the modem program; SSH stays on.

The script needs no root: mtools edits the FAT partition and debugfs the ext4 one. Kuiper ships with an
unreplayed ext4 journal, so the script replays it with `e2fsck` first (otherwise the kernel's replay at the first
boot would undo the edits) and checks the file system again afterwards.

### Simulation and tests

```bash
sdr/adrv9364/sim/reg_adrv.sh     # two SOMs + channel: 8PSK 2/3 payload, QPSK 1/2 PRBS, QPSK 1/4 payload; expect 3 PASS
sdr/adrv9364/sw/test_mock.sh     # on the PC: 1500 UDP datagrams through a software FPGA model + web API; expect PASS
```

Current results: `reg_adrv` 3/3 PASS (0 payload byte errors), `test_mock` PASS (1500 datagrams identical and in order).

## Usage

Default network: eth0 static **192.168.30.1/24**, web page `http://192.168.30.1/`,
`ssh analog@192.168.30.1` (password `analog`). Give the PC an address in the same subnet (e.g. 192.168.30.10/24)
and wait 30–60 s after power-on.

**The default configuration transmits at boot** (2.45 GHz, tx-gain 50 = 39.75 dB attenuation, well below 0 dBm).
Test with a cable and attenuator, or set `tx-on = 0` first.

* **UDP data** (default): datagrams sent to UDP port 5000 of the SOM are transmitted; received datagrams go to
  `192.168.30.255:5001` (subnet broadcast), where a PC program listens. Each datagram carries a CRC and sequence
  number over the air; bad ones are dropped and losses counted. If the air rate is too low, excess datagrams are
  dropped at TX (no growing delay). With no data the modem sends dummy frames, and a single small datagram goes out
  within about one frame time. The ports differ so the broadcast does not loop back into the receive port
  (with `udp-out` set to one PC address the same port can be used).
* **PRBS test:** "PRBS test" on the web page; RX shows the BER.
* **Two SOMs, both directions:** both in `mode = trx`, SOM 1 TX frequency = SOM 2 RX frequency and vice versa.
* **Command line** (over SSH): `journalctl -u dvbs2 -f` shows TX/RX statistics every 10 s;
  after `sudo systemctl stop dvbs2` run `sudo dvbs2_adrv --help` by hand.
* With the modem off the DAC uses the normal DMA data, so IIO (`iio_info`, IIO Oscilloscope through iiod) works as usual.

`/etc/dvbs2.conf` (all options in `dvbs2_adrv --help`; `#` starts a comment):

```
mode = trx              # tx | rx | trx
tx-freq = 2.45e9        # Hz
rx-freq = 2.45e9
bw = 2e6                # occupied bandwidth Rs·(1+roll-off), about 0.35 … 8.4 MHz (shared by TX and RX)
tx-gain = 50            # 0 … 89.75 dB (= 89.75 − attenuation)
rx-gain = 40            # manual gain
modcod = 4              # 1..10 QPSK 1/4..8/9, 12..16 8PSK 3/5..8/9
pilots = 1
rolloff = 35            # 35 | 25 | 20
tx-on = 1               # transmit at boot
rx-on = 1
data = udp              # udp | prbs
udp-in = 0.0.0.0:5000
udp-out = 192.168.30.255:5001
```

### First boot check

1. Start with the `STOCK=1` image to check the carrier: Linux boots to a login prompt on the UART,
   `ping 192.168.30.1` answers, `ssh analog@192.168.30.1` works, `iio_info | grep ad9361-phy` shows the AD9364.
   (This image has no modem, so `systemctl status dvbs2` keeps reporting "DVB-S2 modem not found"; that is expected.)
2. Switch to `dvbs2-adrv9364.img`: `journalctl -u dvbs2` should show "DVB-S2 modem found, version 3.1" and the web page opens.
3. Connect TX to RX (cable + 30 dB or more): RX should show Locked and PRBS BER 0; then try UDP and file transfer.

| Symptom | Likely cause |
|---|---|
| No UART output at all | Boot mode not SD, SD-card wiring, UART pins (MIO48/49) |
| Stops at "Waiting for root device" | Card detect (MIO50) not connected or inverted, SD card not written correctly |
| Boots but no ping | Ethernet (SOM PHY → carrier magnetics / RJ45), PC not in 192.168.30.x |
| "DVB-S2 modem not found" | BOOT.BIN is not the DVB-S2 one (stock image) |
| "ad9361-phy not found" | AD9364 did not come up (`dmesg \| grep ad9361`) |
| RX does not lock | Frequency / bandwidth / roll-off differ from TX, RX gain too low or saturated (Signal level on the web page) |

### Register interface (AXI-Lite, 0x44A00000)

Kuiper's devicetree reserves 0x43C00000 for the MathWorks IP, so the modem sits at 0x44A00000; the program uses
`/dev/mem` (the kernel has `CONFIG_STRICT_DEVMEM` off).

| Address | Contents |
|---|---|
| 0x000 + 4n | Control register n (as on the B210: 0 CTRL, 1 TXCFG, 2 AGC, 3 TIM, 4 FS, 5 FLL, 6 FEC, 7 CLR, 8 CAP) |
| 0x020 | CAP: write [0]=1 to capture; [1] source 0 = ADC samples (spectrum), 1 = data symbols after carrier recovery (constellation, radius 4096, only when locked) |
| 0x100 + 4k | Status word k (0–31 as on the B210; 29 = [31] capture done, [30] busy, [29] source; 32 ADC overflow, 33 frames for the ARM, 34 frames pending, 35 TX sample FIFO) |
| 0x200 | TXDATA: write 4 payload bytes ([7:0] first) |
| 0x204 | RXLEN: length of the next complete frame {1, 0…, bytes}, 0 = none |
| 0x208 | RXDATA: read 4 bytes (the last word of a frame holds 1–4) |
| 0x20C | {TX FIFO free words, RX FIFO used words} |
| 0x1000 + 4i | Capture buffer: 1024 ADC samples or data symbols {I, Q} |

While TX is enabled the `axi_ad9361` DAC channels must take their data from DMA (0x79024418 / 0x79024458 = 2);
the program sets this itself.

## Web interface

Open `http://192.168.30.1/` (port 80; `web` and `web-bind` in `/etc/dvbs2.conf`).

* The page is [`../common/web/index.html`](../common/web/index.html), shared with the B210 program and
  installed at `/usr/local/share/dvbs2/web/`. On this board every card is shown.
* **RX Decode & RF Signal:** decode rate (0–100 % of the MODCOD capacity every 0.5 s), lock with MODCOD/pilots,
  Es/N0 (blind M2M4 estimate), Eb/N0, RSSI (AD9364, relative dB), signal level (ADC dBFS; red above −3 dBFS),
  carrier offset. Below it the decode-rate chart of the last 2 minutes.
* **TX / RX cards:** frequency, bandwidth and gain with on/off buttons. TX and RX share one sample rate, so the
  bandwidth set on either card applies to both.
* **Modem:** MODCOD, roll-off, pilots, LDPC iterations ("Apply modem" restarts TX and RX). RX detects MODCOD and
  pilots from the PLHEADER; only roll-off and bandwidth must match the transmitter.
* **Data Link (UDP):** switch between PRBS test and UDP data, set the UDP addresses, datagram counters
  (in, dropped, idle fill, out, lost / bad CRC). "Save settings" writes `/etc/dvbs2.conf`, used at the next boot.
* **Spectrum and constellation** from the FPGA capture (1024 ADC samples / 1024 symbols after carrier recovery),
  with decision-directed MER / EVM.
* **File loopback test:** with this SOM's TX connected to its RX, send a file (up to 1 GB); it is compared
  automatically and can be downloaded.
* **Baseband Modem Status:** TX and RX counters (frames, dummy frames, DAC underflow / payload overflow, LDPC, BCH,
  BBFRAME CRC, BER, ADC overflow).
* No password: keep the SOM on a trusted network.
* **HTTP API:** `GET /api/status` (board, capabilities, configuration, TX/RX state), `GET /api/spectrum`,
  `POST /api/config` (`tx_freq`, `rx_freq`, `tx_bw`/`rx_bw`, `tx_gain`, `rx_gain`, `tx_on`, `rx_on`, `modcod`,
  `pilots`, `rolloff`, `max_iter`, `udp_in`, `udp_out`), `POST /api/prbs`, `POST /api/udp`, `POST /api/save`,
  `POST /api/send?name=FILE`, `GET /api/received`.
