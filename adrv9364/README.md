# DVB-S2 on ADRV9364-Z7020 SOM（SD 卡開機、網路控制、UDP 傳資料）

這是 repo 根目錄的 DVB-S2 Verilog（`../rtl`，和 Z7020／B210 版完全相同；TX＋RX、short frame、QPSK／8PSK），
放進 ADI ADRV9364-Z7020 SOM 的 PL，位置在 `axi_ad9361` 核心和 ADI 的 DMA 資料路徑之間。
SOM 上跑 ADI Kuiper Linux，開機後 `dvbs2_adrv` 服務自動啟動：
**用網路（網頁）控制，資料用 UDP 進出**，不需要 PC 程式。

```
PC A ──UDP→ :5000 ──▶ [SOM 1] DVB-S2 TX ─▶ AD9364 ~~~ RF ~~~ AD9364 ─▶ DVB-S2 RX [SOM 2] ──UDP→ :5001 ──▶ PC B
                      ARM：dvbs2_adrv（網頁 :80、UDP）              ARM：dvbs2_adrv
                      PL ：AXI-Lite FIFO ⇄ 數據機 ⇄ axi_ad9361       PL ：axi_ad9361 ⇄ 數據機 ⇄ AXI-Lite FIFO
```

**目前狀態**：FPGA 用 Vivado 2025.2 編過、時序收斂；SD 卡 image 做好了；模擬和 PC 端測試都通過。
**還沒在實際硬體上跑過**（第一次開機請照「4. 第一次開機檢查」）。

## 規格

* SOM 用的是**自製載板**：FPGA 頂層只用 SOM 本身的腳位（AD9364、SPI、控制 GPIO、I2C），
  不驅動任何載板 PL 腳位。乙太網路 PHY 在 SOM 上；SD 卡、UART、乙太網路變壓器／RJ45 在載板上，
  接法要和 ADI 載板相同：SD0 = MIO40–45、card detect = MIO50（插卡時為低）、UART1 = MIO48/49（115200 8N1），
  開機模式設成 SD。
* 預設網路：eth0 固定 IP **192.168.30.1/24**，網頁 `http://192.168.30.1/`，
  `ssh analog@192.168.30.1`（密碼 `analog`）。
* 取樣率 Fs = 2·Rs，數據機時脈 100 MHz，每個取樣至少 8 個時脈 → Fs ≤ 12.5 MS/s、**Rs ≤ 6.25 Msym/s**；
  AD9364 最低 0.52 MS/s。**TX 和 RX 共用同一個取樣率**（同一顆 BBPLL），頻率可以各自設定（FDD）。
* 酬載速率（空中容量，pilots 開，roll-off 0.35）：

  | MODCOD | 頻寬 2 MHz（Rs 1.48 Msym/s，預設） | 頻寬 8.4 MHz（Rs 6.25 Msym/s，最大） |
  |---|---|---|
  | QPSK 1/4 | 0.53 Mbit/s | 2.2 Mbit/s |
  | QPSK 1/2（預設） | 1.23 Mbit/s | 5.2 Mbit/s |
  | QPSK 3/4 | 2.06 Mbit/s | 8.7 Mbit/s |
  | 8PSK 2/3 | 2.79 Mbit/s | 11.8 Mbit/s |
  | 8PSK 8/9 | 3.75 Mbit/s | 15.8 Mbit/s |

## 檔案

| 檔案 | 內容 |
|---|---|
| `rtl/dvbs2_adrv.v` | PL 外殼：AXI-Lite 暫存器（0x44A00000）、TX／RX 酬載 FIFO（各 16 kB）、跨時脈 FIFO、頻譜／星座圖擷取 |
| `rtl/adrv_afifo.v`、`rtl/adrv_fifo.v` | 非同步（gray code）／同步 FIFO |
| `hdl/` | Vivado 專案（複製進 ADI HDL `projects/adrv9364z7020/dvbs2/`）：block design、SOM-only 頂層、CDC／multicycle 約束 |
| `build_fpga.sh` | 一鍵：抓 ADI HDL（hdl_2026_r1）→ 建專案 → Vivado 合成／實作 → BOOT.BIN |
| `make_sd_image.sh` | 一鍵：Kuiper Linux 2026.1.0 image ＋ BOOT.BIN ＋ `dvbs2_adrv` 服務 ＋ 固定 IP → `.img` |
| `lib.sh` | 上面兩個腳本共用：下載 Kuiper、工具（mtools、ARM 編譯器、bootgen）、BOOT.BIN |
| `sw/dvbs2_adrv.cpp` | SOM 上的程式：/dev/mem 控制數據機、sysfs＋libad9361 設 AD9364、UDP、網頁、檔案傳輸 |
| `sw/web/index.html` | 網頁介面（解碼速率、SNR／RSSI／CFO、頻譜＋星座圖、RF 與數據機設定、PRBS／UDP 模式、儲存設定、傳檔） |
| `sw/build.sh`、`sw/test_mock.sh` | 交叉編譯；PC 上用軟體 FPGA 模型測 UDP 和網頁 API |
| `rootfs/` | 放進 image 的 `dvbs2.service`、`/etc/dvbs2.conf` 範本 |
| `sim/tb_adrv.v`、`sim/reg_adrv.sh` | 模擬：兩塊 SOM（各自的取樣時脈、12 位元 DAC／ADC）＋通道模型，酬載走 AXI-Lite |

下載和建置的東西都在 `dl/`、`adi-hdl/`、`out/`、`sw/build/`、`sim/out/`（都在 `.gitignore` 裡）。

## 需要的東西

* Ubuntu（Linux）機器，不需要 root。腳本會自己下載 Kuiper（2 GB）、Arm GNU 編譯器 14.2、
  編 mtools 和 bootgen（需要 `libssl-dev`）。磁碟約需 25 GB（Kuiper image 7 GB、兩個輸出 image、ADI HDL 專案）。
* **Vivado 2025.1 或 2025.2**，ML Standard 免費版即可（xc7z020 在免費範圍），安裝時只勾 Zynq-7000，
  不需要 Vitis。ADI hdl_2026_r1 驗證的是 2025.1；本專案用 **2025.2** 編過（`build_fpga.sh` 會自動關掉 ADI 的版本檢查）。
  FSBL 和 u-boot 用 Kuiper 裡 ADI 編好的（PS 設定沒改，只多了 PL 邏輯；用 bootgen 重組 ADI 的 BOOT.BIN 會得到一模一樣的檔案）。
* 8 GB 以上的 SD 卡。

## 1. 編 FPGA（1–2 小時）

```bash
VIVADO_SETTINGS=<Vivado 安裝目錄>/settings64.sh adrv9364/build_fpga.sh
# 例：VIVADO_SETTINGS=/tools/Xilinx/2025.1/Vivado/settings64.sh
#     沒給的話會找 /tools/Xilinx、/opt/Xilinx、~/Xilinx 底下的 Vivado（優先 2025.1）
# → adrv9364/out/system_top.bit, system_top.xsa, BOOT.BIN（log：adrv9364/out/build_fpga.log）
```

時序不過時 ADI 的流程會停下來（`timing_impl.log`），不會產生 BOOT.BIN。

**資源與時序**（Vivado 2025.2，xc7z020clg400-1）：

| | LUT | FF | BRAM36 | DSP |
|---|---|---|---|---|
| 整個設計 | 38.6k（72 %） | 36.5k（34 %） | 75（54 %） | 121（55 %） |
| 其中數據機 `dvbs2_adrv` | 31.4k | 25.1k | 65 + 12 × RAMB18 | 117 |
| 其中 `axi_ad9361` | 4.5k | 7.9k | 0 | 4 |

Slice 用了 **95 %**，100 MHz 時序剛好收斂（WNS 0.000 ns、WHS 0.014 ns），餘裕很小。為了收斂做了：

* RTL：RX 定時恢復（`rx_timing.v`）的 μ 計算和 AGC（`rx_agc.v`）的平均各多一級暫存器
  （每個取樣的結果不變，`reg_rxfe` 和改之前逐字相同）；RX 輸入 pacer 的最小間隔從 6 改成 7 個時脈
* 外殼：RX FIFO 將滿旗標改成暫存器輸出、reset 限制 fanout
* 約束：控制暫存器（只在數據機 reset 時改）設 multicycle 4
* 拿掉 `axi_ad9361` 裡沒用到的 DC 濾波和 IQ 校正（AD9364 自己有 DC／正交追蹤）
* Vivado：合成 retiming、實作策略 Performance_ExplorePostRoutePhysOpt，加上 ADI 的自動時序修正腳本

改 RTL 或換 Vivado 版本後如果時序差一點點，先看 `timing_impl.log` 最差的路徑在哪個模組。

## 2. 做 SD 卡 image（約 5 分鐘）

```bash
adrv9364/make_sd_image.sh                       # → adrv9364/out/dvbs2-adrv9364.img（7.2 GB）
IP=192.168.30.2/24 adrv9364/make_sd_image.sh    # 第二台 SOM 用別的 IP（每台一個 image；會覆蓋同名輸出檔）
GW=192.168.30.254 adrv9364/make_sd_image.sh     # 需要預設閘道時
STOCK=1 adrv9364/make_sd_image.sh               # → dvbs2-adrv9364-stock.img：ADI 原廠 FPGA（沒有數據機），先測載板能不能開機／上網
XZ=1 adrv9364/make_sd_image.sh                  # 另外壓一個 .img.xz（約 2 GB，Etcher 可以直接寫）
```

寫進 SD 卡：balenaEtcher，或 `sudo dd if=adrv9364/out/dvbs2-adrv9364.img of=/dev/sdX bs=4M conv=fsync status=progress`
（`/dev/sdX` 先用 `lsblk` 確認是 SD 卡）。

image 裡改了：

* 開機分割區：`BOOT.BIN`（ADI FSBL ＋ 本專案 bitstream ＋ ADI u-boot）、SOM 的 `devicetree.dtb`、`uImage`、`uEnv.txt`
* `/usr/local/bin/dvbs2_adrv`、`/usr/local/share/dvbs2/web/`、`/etc/dvbs2.conf`、`dvbs2.service`（開機自動啟動）
* NetworkManager：eth0 固定 IP（取代原本的 DHCP／link-local 設定），主機名稱 `dvbs2`
* 關掉桌面（Xvfb、x11vnc、lightdm），開到文字模式，把 CPU 留給數據機程式；SSH 照常開著

腳本不用 root：FAT 分割區用 mtools、ext4 分割區用 debugfs 改。
ADI 的 Kuiper image 出廠時 ext4 journal 沒有回放，腳本會先用 `e2fsck` 回放再修改
（否則第一次開機時核心回放 journal 會把修改蓋掉），改完再檢查一次檔案系統。

## 3. 使用

開機約 30–60 秒後打開 `http://192.168.30.1/`。PC 的 IP 設成同網段（例如 192.168.30.10/24）。

* **UDP 資料**（預設）：送到 SOM 的 UDP port 5000 的封包會被發射；收到的封包送到
  `192.168.30.255:5001`（網段廣播），PC 的程式在 5001 收。每個封包在空中有 CRC 和序號，
  壞的丟掉、遺失會計數；空中速率不夠時多出來的封包在 TX 端丟掉（不延遲）；
  沒有資料時送 dummy 幀，單一小封包約一幀時間內送出。
  兩個 port 分開是為了避免廣播回到自己的接收 port 造成迴圈（`udp-out` 設成單一 PC 位址時可以用同一個 port）。
* **PRBS 測試**：網頁上「PRBS test」，RX 端顯示 BER。
* **傳檔**：同一台 SOM 的 TX 接 RX（線＋衰減器），網頁上選檔案送出（最大 1 GB），收完自動比對。
* 網頁上可以改頻率、頻寬、增益、MODCOD、pilots、roll-off、LDPC 迭代數、UDP 位址，
  「Save settings」寫回 `/etc/dvbs2.conf`，下次開機沿用。
  RX 自動從 PLHEADER 認 MODCOD／pilots，只有 roll-off 和頻寬要和 TX 一樣。
* 兩台互傳（雙向）：兩台都 `mode = trx`，SOM 1 的 TX 頻率 = SOM 2 的 RX 頻率，反之亦然（兩個頻率）。
* 命令列（SSH 上去後）：`journalctl -u dvbs2 -f` 看狀態（每 10 秒印一次 TX／RX 統計）；
  `sudo systemctl stop dvbs2` 後可以手動跑 `sudo dvbs2_adrv --help`。
* 數據機關掉時 DAC 走原本的 DMA 資料，IIO（`iio_info`、IIO Oscilloscope 透過 iiod）照常可用。

`/etc/dvbs2.conf`（`dvbs2_adrv --help` 有全部選項，`#` 後面是註解）：

```
mode = trx              # tx | rx | trx
tx-freq = 2.45e9        # Hz
rx-freq = 2.45e9
bw = 2e6                # 佔用頻寬 Rs·(1+roll-off)，0.4 … 8.4 MHz（TX、RX 共用）
tx-gain = 50            # 0 … 89.75 dB（= 89.75 − 衰減）
rx-gain = 40            # 手動增益
modcod = 4              # 1..10 QPSK 1/4..8/9，12..16 8PSK 3/5..8/9
pilots = 1
rolloff = 35            # 35 | 25 | 20
tx-on = 1               # 開機就發射
rx-on = 1
data = udp              # udp | prbs
udp-in = 0.0.0.0:5000
udp-out = 192.168.30.255:5001
```

**注意：預設開機就發射**（2.45 GHz、tx-gain 50 = 衰減 39.75 dB，輸出遠低於 0 dBm）。
測試時用線＋衰減器，或先把 `tx-on = 0`。

## 4. 第一次開機檢查

1. 先用 `STOCK=1` 的 image 確認載板：UART 看到 Linux 開機到登入提示、`ping 192.168.30.1` 有回應、
   `ssh analog@192.168.30.1` 能登入、`iio_info | grep ad9361-phy` 有 AD9364。
   （這個 image 沒有數據機，`systemctl status dvbs2` 會一直顯示 "DVB-S2 modem not found"，是正常的。）
2. 換成 `dvbs2-adrv9364.img`：`journalctl -u dvbs2` 應該有 "DVB-S2 modem found, version 3.1"，網頁打得開。
3. TX 接 RX（線＋30 dB 以上衰減），網頁上 RX 應該 Locked、PRBS BER 為 0；再試 UDP 和傳檔。

| 現象 | 可能原因 |
|---|---|
| UART 沒有任何輸出 | 開機模式不是 SD、SD 卡接線、UART 腳位（MIO48/49） |
| 停在 "Waiting for root device" | card detect（MIO50）沒有接或極性相反、SD 卡沒寫好 |
| 開機了但 ping 不到 | 乙太網路（SOM 的 PHY → 載板變壓器／RJ45）、PC 不在 192.168.30.x |
| "DVB-S2 modem not found" | BOOT.BIN 不是 DVB-S2 版（STOCK image） |
| "ad9361-phy not found" | AD9364 沒有起來（`dmesg | grep ad9361`） |
| RX 不 lock | 頻率／頻寬／roll-off 和 TX 不一樣、RX 增益太低或飽和（網頁的 Signal level） |

## 5. 模擬與測試

```bash
adrv9364/sim/reg_adrv.sh     # 兩塊 SOM＋通道：8PSK 2/3 酬載、QPSK 1/2 PRBS、QPSK 1/4 酬載，期望 3 個 PASS
adrv9364/sw/test_mock.sh     # PC 上：1500 個 UDP 封包經過軟體 FPGA 模型，網頁 API，期望 PASS
```

目前結果：`reg_adrv` 3/3 PASS（酬載 0 個位元組錯誤）、`test_mock` PASS（1500 個封包完全相同、順序正確）。

## 暫存器（AXI-Lite，0x44A00000）

Kuiper 的 devicetree 把 0x43C00000 留給 MathWorks IP，所以數據機放在 0x44A00000；程式用 `/dev/mem` 存取
（核心沒有開 `CONFIG_STRICT_DEVMEM`）。

| 位址 | 內容 |
|---|---|
| 0x000 + 4n | 控制暫存器 n（和 B210 相同：0 CTRL、1 TXCFG、2 AGC、3 TIM、4 FS、5 FLL、6 FEC、7 CLR、8 CAP） |
| 0x020 | CAP：寫 [0]=1 開始擷取，[1] 來源：0 = ADC 取樣（頻譜）、1 = 載波恢復後的資料符號（星座圖，半徑 4096，只在鎖定時有） |
| 0x100 + 4k | 狀態字 k（0–31 和 B210 相同，29 = [31] 擷取完成、[30] 擷取中、[29] 來源；32 ADC overflow、33 給 ARM 的幀數、34 等待中的幀、35 TX 取樣 FIFO） |
| 0x200 | TXDATA：寫 4 個酬載位元組（[7:0] 先送） |
| 0x204 | RXLEN：讀出下一個完整幀的長度 {1, 0…, bytes}，0 = 沒有 |
| 0x208 | RXDATA：讀 4 個位元組（幀的最後一個字有 1–4 個） |
| 0x20C | {TX FIFO 剩餘字數, RX FIFO 已用字數} |
| 0x1000 + 4i | 擷取結果：1024 個 ADC 取樣或資料符號 {I, Q} |

TX 啟用時 `axi_ad9361` DAC 通道的資料來源要選 DMA（0x79024418／0x79024458 = 2），程式會自己設。

## 已知限制

* 還沒在硬體上驗證。
* TX、RX 同一個取樣率；Rs 最高 6.25 Msym/s。
* 100 MHz 時序餘裕幾乎是 0：改 RTL 後要重看時序。
* 每台 SOM 的 IP 在做 image 時決定（`IP=`），之後要改請用 `nmcli` 或重做 image。
* 只有 UDP 介面；把連結當成虛擬網卡（TAP／橋接，任何 IP 流量都能過）還沒做。
