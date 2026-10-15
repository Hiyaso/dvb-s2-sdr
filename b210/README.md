# DVB-S2 on USRP B210（Ubuntu）

這是 repo 根目錄的 DVB-S2 Verilog（`../rtl`，和 Z7020 版完全相同；TX＋RX、short frame、QPSK／8PSK），
放進 USRP B210 的 FPGA（Spartan-6 XC6SLX150），位置在主機串流和 radio 的 DUC／DDC 之間。
**PC 程式啟動時，UHD 會把這顆 FPGA image 載入 B210**；之後由 PC 下設定、讀狀態、收送資料。
也可以只用一台 B210 自收自發，並用瀏覽器看 TX／RX 狀態和接收頻譜（見「4. 網頁模式」）。

```
PC1（發射端）                                    PC2（接收端）
dvbs2_b210 --mode tx                            dvbs2_b210 --mode rx
  │ USB3：要傳的位元組／填充                       ▲ USB3：解出來的位元組／IQ
  ▼                                               │
B210 FPGA radio 0                               B210 FPGA radio 0
  DVB-S2 TX ─▶ DUC ─▶ AD9361 ─▶ TX/RX A  ~~~~~~▶  RX2 A ─▶ AD9361 ─▶ DDC ─▶ DVB-S2 RX
  （BBFRAME、BCH、LDPC、PL 成幀、RRC）            （定時、幀同步、FLL/PLL、LDPC、BCH）
```

## 檔案

| 檔案 | 內容 |
|---|---|
| `rtl/dvbs2_b210.v` | 包在 `radio_legacy` 裡的外殼：使用者暫存器、TX/RX 資料路徑、狀態讀回 |
| `rtl/b210_fifo.v` | FIFO |
| `patch_uhd_fpga.py` | 把 DVB-S2 加進 UHD 原始碼的 B210 FPGA，並新增 `make B210_DVBS2` 目標 |
| `build_fpga.sh` | 一鍵完成：抓和已安裝版本相同的 UHD 原始碼 → patch → 用 ISE 編譯 |
| `host/dvbs2_b210.cpp` | PC 端程式（UHD C++），用 `host/build.sh` 編譯；`--web` 時內建網頁伺服器 |
| `host/web/index.html` | 網頁介面（TX／RX 設定、狀態、頻譜、傳檔） |
| `sim/reg_b210.sh`、`sim/tb_b210.v` | 模擬：兩台「B210」中間接通道模型，PRBS 和檔案傳輸兩種模式都測 |

## 需要的東西

* Ubuntu 22.04 或 24.04，UHD 4.1 以上（`sudo apt install libuhd-dev uhd-host`，
  再執行一次 `sudo uhd_images_downloader` 安裝原廠 image）。
* **編譯 FPGA 需要 Xilinx ISE 14.7（Linux 版）**：Vivado 不支援 Spartan-6。
  B210 的 XC6SLX150 不在免費 WebPACK 的支援範圍，需要涵蓋 LX150 的授權（例如 ISE Embedded / Design Edition）。
  授權檔放在 `~/.Xilinx/`，`build_fpga.sh` 會自動讀取該目錄下所有 `*.lic`。
  只有負責編譯 FPGA 的那台機器需要 ISE，兩台測試 PC 只要拿到編好的 `.bin` 就好。
* **ISE 的授權只認網卡 `eth0` 的 MAC**。新版 Ubuntu 的網卡名稱是 `ens33`、`enp…`，沒有 `eth0` 時
  map 會報授權錯誤。可以建一個假的 `eth0`，MAC 設成授權檔的 HOSTID（重開機後要再做一次）：
  ```bash
  sudo ip link add eth0 type dummy
  sudo ip link set eth0 address 00:0c:29:xx:xx:xx     # 授權檔裡的 HOSTID
  sudo ip link set eth0 up
  ```
* 編譯 FPGA 還需要 `make`、`python3`；沒有 `git` 時 `build_fpga.sh` 會改用 curl 下載 UHD 原始碼壓縮檔。
* **UHD 原始碼的版本必須和測試 PC 上安裝的 UHD 函式庫一致**（UHD 會檢查 FPGA 相容編號）。
  `build_fpga.sh` 會自動處理。

## 1. 編譯 FPGA image（只要做一次，約 1–2 小時）

```bash
cd b210                                   # 在 repo 目錄下
ISE_SETTINGS=/opt/Xilinx/14.7/ISE_DS/settings64.sh ./build_fpga.sh
# 產出：out/usrp_b210_dvbs2_fpga.bin（時序摘要在 out/usrp_b210_dvbs2_fpga.rpt）
```

* 這個 image **只有一組 radio（radio 0：TX/RX A、RX2 A）**：DVB-S2 數據機佔掉了原本 radio 1 的空間，
  B 通道不能用。原廠 image 的雙通道功能不受影響（換回原廠 image 即可）。
* 整個 image：54.7k LUT（59%）、occupied slice 79%、238 個 RAMB16（88%）、156 個 DSP48A1（86%）；
  ISE 14.7 完整編譯約 1 小時（XST 佔大部分，PAR 約 8 分鐘），時序全部通過。

也可以手動做：`python3 patch_uhd_fpga.py ~/uhd` → `cd ~/uhd/fpga/usrp3/top/b200 && make B210_DVBS2`。
patch 可以重複執行，原始檔會保留成 `*.orig`。

ISE 14.7 在新版 Ubuntu 上常見的問題：
* ISE 的腳本要用 bash 執行，不能用 dash。
* 可能要 `sudo apt install libncurses5`（或裝 libncurses6 再做連結）。
* ISE 自帶的 `libstdc++.so.6` 如果和系統版本衝突，把 `ISE_DS/ISE/lib/lin64` 底下那份改名即可。

## 2. 編譯 PC 程式（兩台 PC 都要）

```bash
sudo apt install libuhd-dev libboost-program-options-dev cmake g++
cd b210/host && ./build.sh        # → host/build/dvbs2_b210
```
* 需要 C++17（UHD 4.x 的標頭檔要求）；沒有 cmake 時 `build.sh` 直接用 g++ 編譯。

## 3. 兩台對傳

可以接天線，或用纜線加衰減器。**TX 直接接 RX 時至少要 30 dB 衰減**，不然可能燒壞接收端。
空中傳輸請使用你有執照的頻率。

**PRBS 測試（量 BER）：**
```bash
# PC1
./dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6 --modcod 13 --tx-gain 60
# PC2
./dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --freq 2.45e9 --rs 1e6 --modcod 13 --rx-gain 40
```
PC2 每秒印一行，格式如下（數字只是示意）：
```
RX LOCK 8PSK 2/3 pil FLL3 CFO   +2315.4 Hz | frames 812 miss 0 | LDPC it  6 drop 0 | BCH corr 0 fail 0 | BB ok 806 crc 0 | BER lock 0/8473920 = 0.00e+00
```
**傳檔案：**
```bash
# PC2 先開始收
./dvbs2_b210 --mode rx --fpga usrp_b210_dvbs2_fpga.bin --output received.bin
# PC1
./dvbs2_b210 --mode tx --fpga usrp_b210_dvbs2_fpga.bin --input photo.jpg
```
* TX 先送 1 秒填充（`--preamble`），讓 RX 在檔案開始前鎖定，接著送檔頭（magic + 長度）和檔案，
  最後補兩幀份量的 0x00 讓最後一個 BBFRAME 送出。
* RX 找到檔頭才開始寫檔，收滿長度就自動結束，所以 `received.bin` 和原檔一樣大，前後不會多出東西。
  狀態列會顯示 `file: waiting for header` → `file: x/y B` → `DONE`。
* 先開 RX，等它印出 `DVB-S2 modem found` 再開 TX。
* 每個位元組都帶序號，漏收會顯示在 `seq gaps`，檔案就不完整（沒有重傳）；用 `sha256sum` 比對。
* 串流：`--input -` / `--output -` 使用 stdin / stdout（沒有長度，RX 寫到 Ctrl-C 為止）。
* `--raw` 關掉檔頭：TX 原樣送位元組、RX 每個位元組都寫。

**只有一台 B210 時自收自發：** 用 `--mode trx`（TX 在 TX/RX A，RX 在 RX2 A），或用下面的網頁模式。

### 主要參數

| 參數 | 說明 |
|---|---|
| `--rs` | 符號率。取樣率 = 2·Rs，master clock 會自動選（取樣率的 8 倍以上且為 4 的倍數，約 16 MHz 起）。上限 3.84 Msym/s（61.44 MHz） |
| `--bw`（`--tx-bw`／`--rx-bw`） | 改用佔用頻寬設定符號率：Rs = BW / (1 + roll-off)，例如 2 MHz、0.35 → 1.4815 Msym/s。AD9361 類比濾波器也設成這個頻寬 |
| `--freq`（`--tx-freq`／`--rx-freq`） | RF 頻率，TX 和 RX 可以分開設 |
| `--modcod` | 1–10 = QPSK 1/4…8/9，12–16 = 8PSK 3/5…8/9。RX 會從 PLHEADER 自己解出 MODCOD 和導頻，RX 端的設定不影響解調 |
| `--no-pilots` | TX 不加導頻 |
| `--rolloff 35/25/20` | **TX 和 RX 要一致**（RX 匹配濾波器使用） |
| `--ref internal/external/gpsdo` | 時脈參考。符號率很低時，兩台的 REF IN 接同一個 10 MHz 並加 `--ref external` |
| `--preamble 1.0` | 傳檔前的填充秒數（RX 鎖定時間） |
| `--tx-gain` / `--rx-gain` | AD9361 的增益；RX AGC 在 FPGA 裡面做 |
| `--args serial=...` | 接了多台 B210 時用來指定 |

酬載容量（以 1 Msym/s、有導頻為例）：QPSK 1/2 約 104 kB/s，8PSK 2/3 約 236 kB/s，8PSK 8/9 約 316 kB/s，
大致和符號率成正比。程式以容量的 90% 送資料；資料不夠時，TX 會自動插入 dummy 幀。

## 4. 網頁模式（一台 B210 自收自發＋瀏覽器）

```bash
cd b210/host/build
./dvbs2_b210 --web 8080 --fpga ../../out/usrp_b210_dvbs2_fpga.bin
# 瀏覽器開 http://localhost:8080
```

* **程式啟動時 TX 和 RX 都是關閉的**：在網頁 TX、RX 卡片右上角按「關閉／開啟」切換。TX 關閉時不送 TX 串流，
  UHD 會關掉 AD9361 的 TX 通道和前端開關，沒有射頻輸出；RX 關閉時不收串流、不顯示頻譜。
  切換一次會重新啟動串流（約 1–2 秒）。傳檔自測需要 TX 和 RX 都開啟。
* 預設：`--mode trx`、TX／RX 頻率 **1 GHz**、頻寬 **2 MHz**（Rs = 1.4815 Msym/s，roll-off 0.35）、
  TX 增益 40 dB、RX 增益 40 dB、MODCOD 13（8PSK 2/3）、有導頻。命令列參數可以改預設值。
* 網頁顯示：
  - **TX**：頻率、頻寬、增益（可修改，按「套用 TX」生效）、符號率、取樣率／master clock、類比濾波器頻寬、
    資料來源、已送幀數、dummy 幀、欠載次數
  - **RX**：頻率、頻寬、增益（可修改，按「套用 RX」）、鎖定狀態、偵測到的 MODCOD、**頻率偏移（CFO，Hz）**、FLL 段、
    幀數、LDPC 迭代、BCH、BB CRC、BER、**接收頻譜**（FPGA 抓 1024 個 DDC 取樣，PC 端加 Hann 窗做 FFT，dBFS，每次更新一筆、不做平均）
  - **傳檔自測**：選一個檔案（例如 `.bin`）按「傳送檔案」，檔案經過 TX → 空中／纜線 → RX 解調後存檔，
    網頁顯示進度和比對結果（大小、錯誤位元組），並提供下載；「回到 PRBS 測試」切回 BER 量測。
    送出和收到的檔案放在 `--file-dir`（預設 `dvbs2_files/`）。
* 網頁每秒更新 10 次（狀態和頻譜）。PRBS 模式的頻譜直接用 RX 串流裡的 DDC 取樣計算；傳檔時串流裡是資料位元組，
  頻譜改從 FPGA 快照讀（每次 512 個 USB 暫存器讀取），約每秒 3 次，狀態仍是每秒 10 次。
  `/api/status` 的 `update_ms` 是每次讀狀態所花的時間（約 10 ms）。
* 修改頻寬會重設取樣率和 master clock，數據機會重新鎖定（約 1–2 秒）。
* 只聽 127.0.0.1；要從別台電腦開網頁加 `--web-bind 0.0.0.0`（沒有密碼，只在可信任的網路上用）。
* 1 GHz 落在 960–1215 MHz 航空導航頻段，用天線時請把 TX 增益保持在低值，或改用纜線＋衰減器、
  或改到你有執照的頻率。
* 網頁 API（也可以用 curl）：`GET /api/status`、`GET /api/spectrum`、
  `POST /api/config`（表單欄位 `tx_freq`、`tx_bw`、`tx_gain`、`rx_freq`、`rx_bw`、`rx_gain`，單位 Hz／dB；
  `tx_on`、`rx_on` = 1／0 開關 TX、RX）、
  `POST /api/send?name=檔名`（內容是檔案本體，直接寫到磁碟，上限 2 GB；以 8PSK 2/3、2 MHz 約 300 kB/s 計，1 GB 要傳約 1 小時）、`POST /api/prbs`、`GET /api/received`。

## 暫存器（UHD `get_user_settings_iface(0)`，裝置參數要加 `enable_user_regs`）

`poke32(4*n, v)` 寫第 n 個暫存器；`peek64(8*m)` 讀回狀態字 2m（低 32 位元）和 2m+1（高 32 位元）。

| n | 名稱 | 內容 |
|---|---|---|
| 0 | CTRL | [0] tx_en、[1] rx_en、[2] TX 資料來自主機、[3] RX 位元組送回主機、[6] DD-PLL、[7] AGC、[8] LDPC 提前終止 |
| 1 | TXCFG | [4:0] MODCOD、[8] 導頻、[13:12] roll-off（TX 和 RX 共用） |
| 2–6 | AGC / TIM / FS / FLL / FEC | 編碼和 `../z7020/doc/register_map.md` 的 0x030–0x040 相同 |
| 7 | CLR | 任意寫入就清除統計 |
| 8 | SNAP | 頻譜快照：寫入 [0]=1 開始抓 1024 個連續 DDC 取樣；[9:8] 選讀回的頁（每頁 256 個取樣） |

狀態字 0–21 和 Z7020 版相同（`../z7020/doc/register_map.md` 0x080 起：鎖定、MODCOD、CFO、幀數、LDPC、BCH、BER、TX 計數等）。
B210 專用的狀態字：

| 字 | 內容 |
|---|---|
| 22 | [31:20] TX 資料 FIFO、[16:12] TX 取樣 FIFO、[11:0] RX 位元組 FIFO 的填充量 |
| 23 / 24 | TX 收到的主機位元組數 / FIFO 滿時丟掉的位元組數 |
| 25 | RX 送回主機的位元組數 |
| 26 | DUC 欠載次數（沒有 DVB-S2 取樣可送） |
| 27 / 28 | RX / TX 取樣數 |
| 29 | [31] 快照完成、[30] 快照進行中、[29:0] CTRL 讀回 |
| 30 / 31 | ID `0x44564232`（"DVB2"）/ 版本 `0x00020001`（2.1） |

快照讀回：`peek64(8*(128+w))`（讀回位址 [7]=1），w = 0…127，得到目前頁的第 2w 個（低 32 位元）和第 2w+1 個
（高 32 位元）取樣，格式 `{I[31:16], Q[15:0]}`。

## 驗證狀況

* `sim/reg_b210.sh`：兩個 `dvbs2_b210`（發射板、接收板）中間接通道模型（CFO 0.2% Rs、+20 ppm、AWGN），
  用和 PC 程式相同的方式控制（暫存器加上夾在取樣串流裡的位元組），每個取樣 8 個時脈：
  - 8PSK 2/3、10 dB、檔案模式：鎖定後收到 9347 位元組，0 錯誤，序號沒有缺漏
  - QPSK 1/2、4 dB、PRBS 模式：8 幀、0 位元錯誤
  - QPSK 1/2、檔案模式、資料量低於幀容量（data 幀之間夾 dummy 幀）：0 錯誤
* B210 版專用的寫法（摺疊式 FIR、Spartan-6 byte-write RAM）重跑過 LDPC、TX 和系統回歸，和 Z7020 版位元精確一致。
* patch 套用到 UHD v4.1.0.5、v4.6.0.0、v4.8.0.0、v4.11.0.0 和 master 都成功；patch 後的 `radio_legacy` 能完整 elaborate
  （只缺 Xilinx primitive 和 coregen）。PC 程式在 UHD 4.6 和 4.11 下編譯成功。
* **ISE 14.7 編譯**（UHD 4.11.0.0 原始碼）：繞線完成、所有時序條件通過（radio clock 以 61.44 MHz 檢查）。
* **實機（一台 B210、網頁模式、天線、1 GHz、2 MHz、TX/RX 增益 40 dB）**：
  - 8PSK 2/3 有導頻：鎖定，PRBS 3.7 億位元 0 錯誤，LDPC 平均 1 次迭代，沒有漏幀
  - 網頁修改增益、頻寬（2 → 1 MHz）、頻率後都能重新鎖定；RX 頻率偏 5 kHz 時 CFO 顯示 −5000.0 Hz
  - 300 kB 隨機檔案經空中回環：收到的檔案和原檔 SHA-256 相同
  - 頻譜：訊號帶內約 −46 dBFS，帶外雜訊底約 −91 dBFS
