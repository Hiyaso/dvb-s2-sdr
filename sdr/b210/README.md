# DVB-S2 on USRP B210

## Description

The DVB-S2 PHY ([`../../rtl`](../../rtl), the same RTL as the other boards: TX + RX, short frame,
QPSK / 8PSK) built into the FPGA of an Ettus USRP B210 (Spartan-6 XC6SLX150), between the host
sample streams and the radio's DUC / DDC. **UHD loads this FPGA image when the PC program opens the
device**; the PC program then configures the modem, reads its status and moves the payload bytes.
One B210 can also transmit to itself, with a browser UI showing decode rate, SNR / RSSI, spectrum
and constellation.

```
PC1 (transmitter)                                PC2 (receiver)
dvbs2_b210 --mode tx                             dvbs2_b210 --mode rx
  │ USB3: payload bytes / fill                     ▲ USB3: decoded bytes / IQ
  ▼                                                │
B210 FPGA radio 0                                B210 FPGA radio 0
  DVB-S2 TX ─▶ DUC ─▶ AD9361 ─▶ TX/RX A  ~~~~~~▶  RX2 A ─▶ AD9361 ─▶ DDC ─▶ DVB-S2 RX
  (BBFRAME, BCH, LDPC, PL framing, RRC)            (timing, frame sync, FLL/PLL, LDPC, BCH)
```

* Payload modes: PRBS-23 BER test, file transfer (header + length, sequence-numbered bytes), raw
  stdin/stdout stream, UDP datagrams (each datagram framed with CRC and sequence number), and a
  **TUN network interface**: a routed IP link where every IP packet sent to `dvbs0` crosses DVB-S2.
  Two-way with `--host N` (station 1 = 10.60.0.1, station 2 = 10.60.0.2, one frequency per direction; traffic
  flows only while both directions are decoded), or one-way TX 10.60.0.1 → RX 10.60.0.2; the web page shows the status.
* Payload capacity at 1 Msym/s with pilots: QPSK 1/2 ≈ 104 kB/s, 8PSK 2/3 ≈ 236 kB/s, 8PSK 8/9 ≈ 316 kB/s,
  proportional to the symbol rate. The program sends at 90 % of capacity; the FPGA inserts dummy frames when
  there is no data.
* The receiver detects MODCOD and pilots from the PLHEADER; only roll-off, symbol rate and frequency
  must match the transmitter.
* **Single-radio image:** the modem takes the space of radio 1, so only radio 0 (TX/RX A, RX2 A) is available.
  Switch back to the stock image for two channels.

| Path | Contents |
|---|---|
| `rtl/dvbs2_b210.v` | Wrapper inside `radio_legacy`: user-settings registers, TX/RX data paths, status read-back |
| `rtl/b210_fifo.v` | FIFO |
| `patch_uhd_fpga.py` | Adds the modem to the B210 FPGA in a UHD source tree, with a new `make B210_DVBS2` target |
| `build_fpga.sh` | One step: fetch the UHD source matching the installed UHD → patch → ISE build |
| `sw/dvbs2_b210.cpp` | PC program (UHD C++), built with `sw/build.sh`; built-in web server with `--web` |
| `sw/dvbs2_b210.conf` | Example configuration file (`--config`): station 1 of the two-way IP link, every key explained |
| `../common/` | Headers shared with the ADRV9364 program (UDP framing, file transfer, spectrum / SNR, mini HTTP server) and the web page `web/index.html`; `net_tun.hpp` (TUN interface) is used by this program only |
| `sw/test_tun.sh`, `sw/test_tun.cpp` | Test of the TUN / UDP packet path without a B210 (socket pairs; with `sudo ... netns`, two real TUN interfaces in network namespaces) |
| `sim/tb_b210.v`, `sim/reg_b210.sh` | Two "B210s" with a channel model between them; PRBS and file modes |

**Verification status**

* `sim/reg_b210.sh`: two `dvbs2_b210` wrappers (TX board, RX board) with a channel model (CFO 0.2 % Rs,
  +20 ppm, AWGN), driven exactly like the PC program (registers + bytes inside the sample stream),
  8 clocks per sample: 8PSK 2/3 file mode 0 errors; QPSK 1/2 PRBS 0 bit errors; QPSK 1/2 file mode
  below frame capacity (dummy frames in between) 0 errors.
* The B210-specific RTL variants (folded FIR, Spartan-6 byte-write RAM) are bit-exact with the Z7020 build
  (LDPC, TX and system regressions).
* TUN / UDP packet path (`sw/test_tun.sh`, the program's own code with an emulated link): 3000 packets of
  20–9000 B arrive intact and in order; with 1 byte in 20000 corrupted every damaged packet is dropped by
  the CRC and counted (2873 received + 127 lost = 3000); with input at twice the link rate the 0.2 s queue
  drops the excess and the rest arrives intact. Two-way link check (two stations over the emulated air): the link
  comes up after the first hellos, 200 packets each way arrive with no hello leaked into the interface; cutting
  one direction takes both stations down within 2 s and the packets are held back; restoring it brings the link
  up again. The root test with real TUN interfaces and carrier (`sudo sw/test_tun.sh netns`) and the TUN mode on
  the B210 itself have not been run yet.
* The patch applies to UHD v4.1.0.5, v4.6.0.0, v4.8.0.0, v4.11.0.0 and master.
* ISE 14.7 build against UHD 4.11.0.0: routed, all timing constraints met (radio clock checked at 61.44 MHz).
* **Hardware** (one B210, web mode, antennas, 1 GHz, 2 MHz, gains 40 dB): 8PSK 2/3 with pilots locks,
  3.7×10⁸ PRBS bits with 0 errors; gain / bandwidth / frequency changes from the web page relock;
  a 300 kB file over the air arrives with the same SHA-256. UDP at 200 packets/s (≈ 215 kB/s): 3000/3000
  packets correct, latency median 51 ms, p99 109 ms.

## Hardware requirements

* **Ettus USRP B210** on a USB 3 port. For a two-board test, two B210s and two PCs (or one PC per board).
* For the IP link (TUN): one B210 and one PC per station. One-way (TX station → RX station) carries UDP;
  ping, TCP and other two-way traffic need both stations in `--mode trx` on two frequencies.
  Creating the TUN interface and setting its address needs root (`sudo`), or a one-time setup by root (see below).
* RF: antennas, or a cable with **at least 30 dB attenuation** between TX and RX (a direct connection can
  damage the receiver). Transmit over the air only on frequencies you are licensed for.
  For very low symbol rates connect both REF IN to the same 10 MHz and use `--ref external`.
* **PC:** Ubuntu 22.04 or 24.04, UHD 4.1 or later (`sudo apt install libuhd-dev uhd-host`, then
  `sudo uhd_images_downloader` once), `libboost-program-options-dev`, `cmake`, `g++` with C++17.
* **FPGA build only** (one machine; the test PCs only need the finished `.bin`):
  * **Xilinx ISE 14.7 for Linux.** Vivado does not support Spartan-6, and the free WebPACK does not cover
    the XC6SLX150: a licence that includes the LX150 is required (e.g. ISE Embedded / Design Edition).
    Put the licence in `~/.Xilinx/`; `build_fpga.sh` picks up every `*.lic` there.
  * `make`, `python3`, and `git` (without git, `build_fpga.sh` downloads a source tarball with curl).
  * **The UHD source must be the same version as the UHD library on the test PCs** (UHD checks the FPGA
    compatibility number); `build_fpga.sh` clones tag `v$(uhd_config_info --version)` automatically.
  * The ISE licence only reads the MAC of a NIC named `eth0`. On Ubuntu with `ens33` / `enp…` names,
    create a dummy `eth0` with the licence HOSTID (repeat after every reboot):
    ```bash
    sudo ip link add eth0 type dummy
    sudo ip link set eth0 address 00:0c:29:xx:xx:xx     # HOSTID from the licence file
    sudo ip link set eth0 up
    ```
  * ISE 14.7 on recent Ubuntu: run it with bash (not dash); you may need `libncurses5`; if ISE's bundled
    `libstdc++.so.6` clashes with the system one, rename the copy in `ISE_DS/ISE/lib/lin64`.

## Build

### 1. FPGA image (once, about 1–2 hours)

```bash
cd sdr/b210
ISE_SETTINGS=/opt/Xilinx/14.7/ISE_DS/settings64.sh ./build_fpga.sh
# -> out/usrp_b210_dvbs2_fpga.bin (timing summary in out/usrp_b210_dvbs2_fpga.rpt)
```

By hand: `python3 patch_uhd_fpga.py ~/uhd`, then `cd ~/uhd/fpga/usrp3/top/b200 && make B210_DVBS2`.
The patch is idempotent (it always starts from the `*.orig` copies it keeps).

Resources of the whole image: 54.7k LUT (59 %), 79 % occupied slices, 238 RAMB16 (88 %), 156 DSP48A1 (86 %);
a full ISE run takes about 1 hour (mostly XST; PAR ≈ 8 min). These numbers predate the extra pipeline stage
in RX timing recovery / AGC (about 100 more registers; `reg_b210` passes, not yet rebuilt in ISE).

### 2. PC program (on every PC)

```bash
sudo apt install libuhd-dev libboost-program-options-dev cmake g++
sdr/b210/sw/build.sh            # -> sdr/b210/sw/build/dvbs2_b210
```

Without cmake, `build.sh` compiles directly with g++.

### Simulation and tests

```bash
sdr/b210/sim/reg_b210.sh          # outputs in sdr/b210/sim/out
sdr/b210/sw/test_tun.sh         # TUN / UDP packet path without a B210 (no root), expect PASS
sudo sdr/b210/sw/test_tun.sh netns   # the same with real TUN interfaces in two network namespaces and the
                                       # two-way link check: carrier, ping both ways, UDP, TCP (iperf3); expect PASS
```

## Usage

Copy `out/usrp_b210_dvbs2_fpga.bin` next to the program, or pass its path with `--fpga`.

### PRBS test between two PCs (BER)

```bash
# PC1
./dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6 --modcod 13 --tx-gain 60
# PC2
./dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6 --modcod 13 --rx-gain 40
```

PC2 prints one status line per second, for example:

```
RX LOCK 8PSK 2/3 pil FLL3 CFO   +2315.4 Hz | frames 812 miss 0 | LDPC it  6 drop 0 | BCH corr 0 fail 0 | BB ok 806 crc 0 | BER lock 0/8473920 = 0.00e+00
```

### File transfer

```bash
# PC2: start the receiver first and wait for "DVB-S2 modem found"
./dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --output received.bin
# PC1
./dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --input photo.jpg
```

* TX sends `--preamble` seconds (default 1) of fill so RX can lock, then a header (magic `A5 'DVBS2' 5A C3`,
  64-bit length, inverted length) and the file, then two frames of 0x00 to flush the last BBFRAME.
* RX writes only after the header and stops after `length` bytes, so `received.bin` has the original size.
  The status line shows `file: waiting for header` → `file: x/y B` → `DONE`.
* Every byte carries a sequence number; missing bytes show as `seq gaps` (no retransmission). Compare with `sha256sum`.
* `--input -` / `--output -` stream stdin / stdout (no length; RX writes until Ctrl-C). `--raw` disables the header.

### UDP datagrams

```bash
# PC2: forward received datagrams to 192.168.1.10:6000
./dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --udp-out 192.168.1.10:6000
# PC1: transmit datagrams arriving on 127.0.0.1:5000 (use --udp-in 0.0.0.0:5000 for other hosts)
./dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --udp-in 5000
```

* Each datagram (0–65535 B) is framed on its own and delivered with the same boundaries:
  `C5 3A | length u16 | seq u16 | CRC-16 (length + seq) | data | CRC-32 (data)`, big endian, 12 bytes overhead
  (`../common/udp_frame.hpp`).
* When TX runs out of data it pads the current BBFRAME with 0x00, so a small datagram never waits in a half-full
  frame; after that it sends dummy frames. Latency is dominated by UHD's TX USB buffering: median ≈ 51 ms at 2 MHz,
  8PSK 2/3; `--args num_send_frames=4,send_frame_size=4096` brings it to ≈ 23 ms at a higher risk of USB underruns.
* RX finds frames by the sync word and drops datagrams with a bad CRC or across a sequence gap.
  Status: TX `udp in N pkt, dropped, fill`; RX `udp out N pkt, lost, bad CRC`.
* UDP semantics: no retransmission. Datagrams sent before RX locks are lost; above the MODCOD capacity TX keeps
  only ≈ 0.2 s of queue and drops the rest (`dropped`).
* IPv4 only. `--udp-in` listens on 127.0.0.1 by default (no authentication: anyone who can reach the port can
  transmit over RF). `--udp-in` cannot be combined with `--input`, `--udp-out` not with `--output`.
  With `--web` the UDP mode is selected on the page (Data Link card), next to PRBS and the network interface.

### IP link over DVB-S2 (TUN network interface)

`--tun dvbs0` creates (or attaches to) the TUN interface `dvbs0`. Every IP packet the kernel routes to it is
framed like a UDP datagram above (CRC, sequence number, 0.2 s drop queue) and sent over DVB-S2; the receiving
station writes each recovered packet into its own `dvbs0`. The interface stays while the program runs, also
when the web page restarts the streams.

**Two-way link (`--host N`).** Each station sends and receives on one address, `10.60.0.N`: station 1 is
10.60.0.1, station 2 is 10.60.0.2. `--host` sets `--mode trx`, `--tun dvbs0` and the address, and splits the
two directions over two frequencies (FDD): host 1 transmits on `--freq` and receives on `--freq + --duplex`
(default 10 MHz), the other host the other way round.

```bash
# PC1, station 1: dvbs0 = 10.60.0.1/24, TX 2450 MHz, RX 2460 MHz
sudo ./dvbs2_b210 --host 1 --web 8080 --on --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --bw 2e6 --tx-gain 60 --rx-gain 40
# PC2, station 2: dvbs0 = 10.60.0.2/24, TX 2460 MHz, RX 2450 MHz
sudo ./dvbs2_b210 --host 2 --web 8080 --on --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --bw 2e6 --tx-gain 60 --rx-gain 40
```

Or with the example file on both PCs: `sudo ./dvbs2_b210 --config dvbs2_b210.conf` (station 1) and
`sudo ./dvbs2_b210 --config dvbs2_b210.conf --host 2` (see [Configuration file](#configuration-file)).

The IP link carries traffic only while the DVB-S2 link works in both directions. Each station sends a small
hello (20 bytes) every 0.5 s inside its payload stream, saying whether it decodes the other one. The link is
**up** when a station decodes the peer's hellos and the peer reports that it decodes ours; it goes down 2 s
after that stops. While down, `dvbs0` has no carrier (`ip link` shows `NO-CARRIER`), so the kernel does not send
to it, and packets that still arrive are dropped and counted. The program prints `link UP: peer 10.60.0.2, both
directions decoded` / `link down: ...` on every change and the state once per second.

```bash
ip link show dvbs0           # LOWER_UP = link up, NO-CARRIER = down
ping 10.60.0.2               # from station 1; ssh, TCP, iperf3 work as on any slow link
# UDP both ways:   PC2: nc -u -l 10.60.0.2 5000     PC1: nc -u 10.60.0.2 5000   (type on either side)
```

* `--subnet 10.60.0.0/24` sets the network (station N = subnet + N); `--duplex` the distance of the two
  frequencies; `--tx-freq` / `--rx-freq` override the plan. `--host` is point-to-point: two stations.
* `--on` starts TX and RX at once (in web mode they are otherwise off until switched on in the page).
  Open `http://localhost:8080` on each PC (add `--web-bind 0.0.0.0` to open it from elsewhere): the
  **Data Link (network interface)** card shows the interface (address, carrier), the link
  (`Connected to 10.60.0.2 · both directions decoded`, or why it is down: no hello from the peer / the peer
  does not decode us yet / TX or RX off), hellos sent and received, and the packet counters.
* Without running the program as root, let root create the interface once (it is then kept until reboot)
  and start the program as your user:
  ```bash
  sudo ip tuntap add dev dvbs0 mode tun user $USER
  sudo ip addr add 10.60.0.1/24 dev dvbs0      # 10.60.0.2/24 on station 2
  sudo ip link set dvbs0 up
  ```
  Switching the carrier needs Linux 5.0 or later; on older kernels the carrier stays on and the program
  only drops the packets while the link is down.
* Capacity is the payload rate above, in each direction (e.g. 8PSK 2/3 at 2 MHz ≈ 300 kB/s); traffic above it
  is dropped at TX after 0.2 s of queue. Latency is about 50 ms one way (UHD TX buffering). The kernel also sends
  a few IPv6 link-local packets when the carrier comes up; `sudo sysctl -w net.ipv6.conf.dvbs0.disable_ipv6=1`
  stops them.
* There is no encryption or authentication on the air, and anything routed to `dvbs0` is transmitted. Do not
  enable IP forwarding into `dvbs0` unless that is intended.

**One-way link** (one transmitter, one receiver, UDP only: ping replies and TCP acknowledgements need the way
back). `--mode tx --tun dvbs0` gives 10.60.0.1/24, `--mode rx --tun dvbs0` 10.60.0.2/24 (`--tun-addr` to change,
`none` to leave it as it is). There is no link check: the interface has carrier all the time.

```bash
sudo ./dvbs2_b210 --mode tx --tun dvbs0 --web 8080 --on --freq 2.45e9 --bw 2e6 --tx-gain 60   # PC1
sudo ./dvbs2_b210 --mode rx --tun dvbs0 --web 8080 --on --freq 2.45e9 --bw 2e6 --rx-gain 40   # PC2
echo "hello over DVB-S2" | nc -u -w1 10.60.0.2 5000                                            # PC1 -> PC2
```

`--mode trx --tun` on one B210 with TX and RX on the same frequency sends the packets back to its own
interface; the program prints a note in that case.

### Configuration file

Defaults can be kept in a file instead of on the command line: `--config FILE` reads `key = value` lines,
where the keys are the long option names (`dvbs2_b210 --help`), switches take `1` / `0`, and `#` starts a comment.
Options given on the command line override the file. [`sw/dvbs2_b210.conf`](sw/dvbs2_b210.conf) is an
example for the two-way IP link above.

```bash
sudo ./dvbs2_b210 --config dvbs2_b210.conf               # station 1 (10.60.0.1), as in the file
sudo ./dvbs2_b210 --config dvbs2_b210.conf --host 2      # station 2 (10.60.0.2) from the same file
```

`--save-config FILE` writes the options given (command line and `--config`) to FILE and exits, so a working
command line can be turned into a file:

```bash
./dvbs2_b210 --mode rx --tun dvbs0 --web 8080 --on --freq 2.45e9 --bw 2e6 --rx-gain 40 --save-config rx.conf
sudo ./dvbs2_b210 --config rx.conf
```

An unknown key or a value that does not parse stops the program with the file name in the message.

### One B210 transmitting to itself

Use `--mode trx` (TX on TX/RX A, RX on RX2 A, cable + attenuator), or the web mode below.

### Main options

| Option | Meaning |
|---|---|
| `--rs` | Symbol rate. Sample rate = 2·Rs; the master clock is chosen automatically (≥ 8 × sample rate, a multiple of 4, from about 16 MHz). Maximum 3.84 Msym/s (61.44 MHz) |
| `--bw` (`--tx-bw` / `--rx-bw`) | Set the symbol rate from the occupied bandwidth: Rs = BW / (1 + roll-off), e.g. 2 MHz at 0.35 → 1.4815 Msym/s. Also sets the AD9361 analog filter |
| `--freq` (`--tx-freq` / `--rx-freq`) | RF frequency; TX and RX can differ |
| `--modcod` | 1–10 = QPSK 1/4 … 8/9, 12–16 = 8PSK 3/5 … 8/9 (TX only; RX decodes it from the PLHEADER) |
| `--no-pilots` | TX without pilots |
| `--rolloff 35/25/20` | **Must match on TX and RX** (RX matched filter) |
| `--ref internal/external/gpsdo` | Clock reference |
| `--preamble 1.0` | Seconds of fill before a file (RX lock time) |
| `--tx-gain` / `--rx-gain` | AD9361 gains; the RX AGC runs in the FPGA |
| `--args serial=...` | Select a device. The program adds `recv_frame_size=16360,send_frame_size=16360` (largest USB packets, about half the CPU load) unless you set them |
| `--host N` | Two-way IP link station N: `--mode trx`, `--tun dvbs0` with address 10.60.0.N, host 1 TX `--freq` / RX `--freq + --duplex`, other hosts swapped; IP traffic only while both directions are decoded |
| `--subnet A/N`, `--duplex HZ` | `--host`: network of the link (default 10.60.0.0/24), distance of the two frequencies (default 10 MHz) |
| `--tun NAME` | TX and RX payload = IP packets of TUN interface NAME (created if needed; root or a prepared interface) |
| `--tun-addr A/N` | IPv4 address of the TUN interface (default `--mode tx` 10.60.0.1/24, `rx` 10.60.0.2/24; `none` = leave it) |
| `--tun-mtu N` | TUN MTU (default 1500; 0 = leave it) |
| `--data prbs\|udp\|tun` | Web mode: payload at start (default `tun` with `--tun`, `udp` with `--udp-in`/`--udp-out`, else `prbs`) |
| `--on` | Web mode: TX and RX switched on at start |
| `--config FILE` | Read defaults from FILE (`key = value`, long option names); the command line wins |
| `--save-config FILE` | Write the given options to FILE and exit |

### Register interface

UHD `get_user_settings_iface(0)`, device argument `enable_user_regs`. `poke32(4*n, v)` writes register n;
`peek64(8*m)` returns status words 2m (low 32 bits) and 2m+1 (high 32 bits).

| n | Name | Contents |
|---|---|---|
| 0 | CTRL | [0] tx_en, [1] rx_en, [2] TX data from host, [3] RX bytes to host, [6] DD-PLL, [7] AGC, [8] LDPC early stop |
| 1 | TXCFG | [4:0] MODCOD, [8] pilots, [13:12] roll-off (shared by TX and RX) |
| 2–6 | AGC / TIM / FS / FLL / FEC | Same encoding as 0x030–0x040 in [`../z7020/doc/register_map.md`](../z7020/doc/register_map.md) |
| 7 | CLR | Any write clears the statistics |
| 8 | SNAP | Snapshot: write [0]=1 to capture; [1] source 0 = 1024 consecutive DDC samples (spectrum), 1 = 1024 data symbols after carrier recovery (constellation, radius 4096, only when locked); [9:8] read-back page (256 samples each) |

Status words 0–21 are the same as the Z7020 project (from 0x080 in its register map). B210-specific words:

| Word | Contents |
|---|---|
| 22 | Fill levels: [31:20] TX data FIFO, [16:12] TX sample FIFO, [11:0] RX byte FIFO |
| 23 / 24 | Host bytes received by TX / bytes dropped because the FIFO was full |
| 25 | RX bytes sent to the host |
| 26 | DUC underruns (no DVB-S2 sample available) |
| 27 / 28 | RX / TX sample counts |
| 29 | [31] snapshot done, [30] snapshot busy, [29] snapshot source, [28:0] CTRL read-back |
| 30 / 31 | ID `0x44564232` ("DVB2") / version `0x00020002` (2.2) |

Snapshot read-back: `peek64(8*(128+w))` for w = 0 … 127 returns samples 2w (low) and 2w+1 (high) of the current page,
format `{I[31:16], Q[15:0]}`.

## Web interface

One B210 transmitting to itself, controlled from a browser:

```bash
cd sdr/b210/sw/build
./dvbs2_b210 --web 8080 --fpga ../../out/usrp_b210_dvbs2_fpga.bin
# open http://localhost:8080
```

* The page is [`../common/web/index.html`](../common/web/index.html), shared with the ADRV9364 program.
  The program serves it from `<program>/../web` if that exists, otherwise from `sdr/common/web` in the source
  tree (`--web-root DIR` overrides). The modem settings card (MODCOD etc. are command-line options here) is hidden.
* **Data Link card** (shown when the program was started with `--tun` and/or `--udp-in`/`--udp-out`): buttons to
  switch the payload between PRBS test, UDP data and network interface; the TUN interface name, state, address and
  MTU; packet counters (TX in / dropped / idle fill, RX out / lost / bad CRC). The UDP addresses are shown but set on
  the command line. After a file loopback test, "Back to network interface" / "Back to UDP data" returns to the link.
* **TX and RX are off at start** (unless `--on`). Toggle them with the Off/On buttons on the TX and RX cards. With TX off no TX
  stream runs and UHD switches off the AD9361 TX chain; with RX off there is no RX stream and no spectrum.
  Each toggle restarts the streams (1–2 s). The file self-test needs both on.
* Defaults: `--mode trx`, TX/RX at **1 GHz**, bandwidth **2 MHz** (Rs = 1.4815 Msym/s, roll-off 0.35), gains
  40 dB, MODCOD 13 (8PSK 2/3), pilots on. Command-line options change the defaults.
  1 GHz is in the 960–1215 MHz aeronautical navigation band: keep the TX gain low with antennas, or use a cable
  and attenuator, or a frequency you are licensed for.
* Layout, top to bottom: **RX Decode & RF Signal** (large tiles) → decode-rate chart → TX / RX settings →
  spectrum and constellation → file loopback → **Baseband Modem Status**. Light/dark theme follows the system.
  * **RX Decode & RF Signal:** decode rate (0–100 % of the MODCOD capacity, every 0.5 s, with Mbit/s, frames/s and
    capacity), lock state with MODCOD/pilots, Es/N0, Eb/N0, RSSI, signal level, carrier offset (Hz or kHz, and
    ppm of the RX frequency, when locked).
  * **Decode-rate chart:** last 2 minutes, one point per 0.5 s; hover (or click and use ←/→) for a point's
    value and time; a table lists the last 20 points.
  * **Es/N0** is a blind M2M4 estimate on the PC from the 1024 snapshot samples (RRC matched filter, best of 16
    timing phases, independent of carrier phase and CFO, works before lock), smoothed with a 0.5 s time constant;
    ±0.3 dB over 0–25 dB in simulation. On hardware it tops out at about 22–23 dB (B210 TX/RX EVM).
    **RSSI** is the AD9361 reading (relative dB, 0.25 dB steps, not calibrated dBm). **Signal level** is the DDC output
    power in dBFS including noise; above −3 dBFS it turns red (lower the RX gain).
  * **TX / RX cards:** frequency, bandwidth and gain (Apply), symbol rate, sample rate, clocks per sample and
    master clock, analog filter bandwidth. Changing the bandwidth resets the sample rate and master clock and
    the modem relocks (1–2 s; a file in progress is resent); frequency and gain apply immediately.
  * **Spectrum:** 1024 DDC samples, Hann window, FFT on the PC, 0 to −110 dBFS, x axis in MHz from the centre;
    the occupied bandwidth is shaded. Needs FPGA image 2.1 or later.
  * **Constellation:** data symbols after carrier recovery and PL descrambling (no PLHEADER or pilots), 512 points,
    radius normalised to 1, ideal points as circles; MER and EVM are decision-directed (they read slightly high at
    low SNR). Updates only while locked. Needs FPGA image 2.2 or later.
  * **File loopback test:** choose a file and press "Send file". It goes TX → air/cable → RX and is saved; the page
    shows progress, TX/RX rates, time remaining, sequence gaps and the comparison result (size, bad bytes) with a
    download link. "Back to PRBS test" returns to BER mode. Files are kept in `--file-dir` (default `dvbs2_files/`).
  * **Baseband Modem Status:** TX data rate, capacity and use, data source, frames encoded/sent, dummy frames,
    DUC/USB underruns; RX decode rate, state (lock / MODCOD / pilots / FLL stage), frames / missed / PLS failures,
    LDPC iterations / drops, BCH corrected / failed, BBFRAME OK / CRC errors, BER (PRBS mode), USB overflows.
* The page refreshes 10 times per second. In PRBS mode the spectrum comes from the DDC samples in the RX stream;
  during a file transfer it is read from the FPGA snapshot (about 3 per second). The constellation always comes
  from the snapshot.
* The server listens on 127.0.0.1; add `--web-bind 0.0.0.0` to open it from another computer
  (no password: use it only on a trusted network).
* **HTTP API** (works with curl):
  * `GET /api/status`: board, capabilities, configuration, TX and RX state. Rates in bit/s:
    `tx.rate_bps`, `tx.capacity_bps`, `tx.host_bps`, `rx.rate_bps`, `rx.frames_per_s`, `rx.capacity_bps`,
    `rx.file_bps`, `rx.rate_interval`, `rx.rate_time`. Quality: `rx.esn0_db`, `rx.ebn0_db`, `rx.rssi_db`,
    `rx.level_dbfs` (null without data). `update_ms` is the time one status read takes (≈ 10 ms).
  * `GET /api/spectrum`: `db` spectrum and `iq` constellation points `[I0, Q0, I1, Q1, …]`.
  * `POST /api/config`: form fields `tx_freq`, `tx_bw`, `tx_gain`, `rx_freq`, `rx_bw`, `rx_gain` (Hz / dB),
    `tx_on`, `rx_on` (1/0).
  * `POST /api/send?name=FILE` (body = file, up to 2 GB; at ≈ 300 kB/s, 1 GB takes about an hour),
    `GET /api/received`.
  * `POST /api/prbs`, `POST /api/udp`, `POST /api/tun`: switch the payload mode (UDP / TUN only when started with
    them). `/api/status` reports it in `config.data`, the interface in `config.tun`, `tun_up`, `tun_addr`, `tun_mtu`, `tun_carrier`,
    with `--host` the station in `config.host` and the link in `link.up`, `hears`, `peer_hears`, `peer`, `hello_age` (s),
    `hellos_tx`, `hellos_rx`, `link_drops`,
    and the packet counters in `tx.udp_packets`, `udp_bytes`, `udp_drops`, `fill`, `rx.udp_packets`, `udp_bytes`,
    `udp_lost`, `udp_bad` (also for TUN); `tx.mode` / `rx.mode` are `prbs`, `file`, `udp` or `tun`.
