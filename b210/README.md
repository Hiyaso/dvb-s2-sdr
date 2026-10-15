# DVB-S2 on USRP B210（Ubuntu）

這是和 Z7020 版完全相同的 DVB-S2 Verilog（TX＋RX、short frame、QPSK／8PSK），
放進 USRP B210 的 FPGA（Spartan-6 XC6SLX150），位置在主機串流和 radio 的 DUC／DDC 之間。
**PC 程式啟動時，UHD 會把這顆 FPGA image 載入 B210**；之後由 PC 下設定、讀狀態、收送資料。

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
| `../rtl/b210/dvbs2_b210.v` | 包在 `radio_legacy` 裡的外殼：使用者暫存器、TX/RX 資料路徑、狀態讀回 |
| `../rtl/b210/b210_fifo.v` | FIFO |
| `patch_uhd_fpga.py` | 把 DVB-S2 加進 UHD 原始碼的 B210 FPGA，並新增 `make B210_DVBS2` 目標 |
| `build_fpga.sh` | 一鍵完成：抓和已安裝版本相同的 UHD 原始碼 → patch → 用 ISE 編譯 |
| `host/dvbs2_b210.cpp` | PC 端程式（UHD C++），用 `host/build.sh` 編譯 |
| `../sim/reg_b210.sh` | 模擬：兩台「B210」中間接通道模型，PRBS 和檔案傳輸兩種模式都測 |

## 需要的東西

* Ubuntu 22.04 或 24.04，UHD 4.1 以上（`sudo apt install libuhd-dev uhd-host`，
  再執行一次 `sudo uhd_images_downloader` 安裝原廠 image）。
* **編譯 FPGA 需要 Xilinx ISE 14.7（Linux 版）**：Vivado 不支援 Spartan-6。
  B210 的 XC6SLX150 不在免費 WebPACK 的支援範圍，需要 ISE Design Edition（或其他涵蓋 LX150 的授權）。
  只有負責編譯 FPGA 的那台機器需要 ISE，兩台測試 PC 只要拿到編好的 `.bin` 就好。
* **UHD 原始碼的版本必須和測試 PC 上安裝的 UHD 函式庫一致**（UHD 會檢查 FPGA 相容編號）。
  `build_fpga.sh` 會自動處理。

## 1. 編譯 FPGA image（只要做一次，約 1–2 小時）

```bash
cd dvbs2_z7020/b210
ISE_SETTINGS=/opt/Xilinx/14.7/ISE_DS/settings64.sh ./build_fpga.sh
# 產出：out/usrp_b210_dvbs2_fpga.bin（時序摘要在 out/usrp_b210_dvbs2_fpga.rpt）
```

也可以手動做：`python3 patch_uhd_fpga.py ~/uhd` → `cd ~/uhd/fpga/usrp3/top/b200 && make B210_DVBS2`。
patch 可以重複執行，原始檔會保留成 `*.orig`。

ISE 14.7 在新版 Ubuntu 上常見的問題：
* ISE 的腳本要用 bash 執行，不能用 dash。
* 可能要 `sudo apt install libncurses5`（或裝 libncurses6 再做連結）。
* ISE 自帶的 `libstdc++.so.6` 如果和系統版本衝突，把 `ISE_DS/ISE/lib/lin64` 底下那份改名即可。

## 2. 編譯 PC 程式（兩台 PC 都要）

```bash
sudo apt install libuhd-dev libboost-program-options-dev cmake g++
cd dvbs2_z7020/b210/host && ./build.sh        # → host/build/dvbs2_b210
```

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

**只有一台 B210 時自收自發：** 用 `--mode trx`（TX 在 TX/RX A，RX 在 RX2 A）。

### 主要參數

| 參數 | 說明 |
|---|---|
| `--rs` | 符號率。取樣率 = 2·Rs，master clock 會自動選（取樣率的 8 倍以上且為 4 的倍數，約 16 MHz 起）。上限 3.84 Msym/s（61.44 MHz） |
| `--modcod` | 1–10 = QPSK 1/4…8/9，12–16 = 8PSK 3/5…8/9。RX 會從 PLHEADER 自己解出 MODCOD 和導頻，RX 端的設定不影響解調 |
| `--no-pilots` | TX 不加導頻 |
| `--rolloff 35/25/20` | **TX 和 RX 要一致**（RX 匹配濾波器使用） |
| `--ref internal/external/gpsdo` | 時脈參考。符號率很低時，兩台的 REF IN 接同一個 10 MHz 並加 `--ref external` |
| `--preamble 1.0` | 傳檔前的填充秒數（RX 鎖定時間） |
| `--tx-gain` / `--rx-gain` | AD9361 的增益；RX AGC 在 FPGA 裡面做 |
| `--args serial=...` | 接了多台 B210 時用來指定 |

酬載容量（以 1 Msym/s、有導頻為例）：QPSK 1/2 約 104 kB/s，8PSK 2/3 約 236 kB/s，8PSK 8/9 約 316 kB/s，
大致和符號率成正比。程式以容量的 90% 送資料；資料不夠時，TX 會自動插入 dummy 幀。

## 暫存器（UHD `get_user_settings_iface(0)`，裝置參數要加 `enable_user_regs`）

`poke32(4*n, v)` 寫第 n 個暫存器；`peek64(8*m)` 讀回狀態字 2m（低 32 位元）和 2m+1（高 32 位元）。

| n | 名稱 | 內容 |
|---|---|---|
| 0 | CTRL | [0] tx_en、[1] rx_en、[2] TX 資料來自主機、[3] RX 位元組送回主機、[6] DD-PLL、[7] AGC、[8] LDPC 提前終止 |
| 1 | TXCFG | [4:0] MODCOD、[8] 導頻、[13:12] roll-off（TX 和 RX 共用） |
| 2–6 | AGC / TIM / FS / FLL / FEC | 編碼和 `doc/register_map.md` 的 0x030–0x040 相同 |
| 7 | CLR | 任意寫入就清除統計 |

狀態字 0–21 和 Z7020 版相同（`doc/register_map.md` 0x080 起：鎖定、MODCOD、CFO、幀數、LDPC、BCH、BER、TX 計數等）。
B210 專用的狀態字：

| 字 | 內容 |
|---|---|
| 22 | [31:20] TX 資料 FIFO、[16:12] TX 取樣 FIFO、[11:0] RX 位元組 FIFO 的填充量 |
| 23 / 24 | TX 收到的主機位元組數 / FIFO 滿時丟掉的位元組數 |
| 25 | RX 送回主機的位元組數 |
| 26 | DUC 欠載次數（沒有 DVB-S2 取樣可送） |
| 27 / 28 | RX / TX 取樣數 |
| 29 | CTRL 讀回 |
| 30 / 31 | ID `0x44564232`（"DVB2"）/ 版本 `0x00020000` |

## 驗證狀況

* `sim/reg_b210.sh`：兩個 `dvbs2_b210`（發射板、接收板）中間接通道模型（CFO 0.2% Rs、+20 ppm、AWGN），
  用和 PC 程式相同的方式控制（暫存器加上夾在取樣串流裡的位元組），每個取樣 8 個時脈：
  - 8PSK 2/3、10 dB、檔案模式：鎖定後收到 9347 位元組，0 錯誤，序號沒有缺漏
  - QPSK 1/2、4 dB、PRBS 模式：8 幀、0 位元錯誤
* B210 版專用的寫法（摺疊式 FIR、Spartan-6 byte-write RAM）重跑過 LDPC、TX 和系統回歸，和 Z7020 版位元精確一致。
* patch 套用到 UHD v4.1.0.5、v4.6.0.0、v4.8.0.0 和 master 都成功；patch 後的 `radio_legacy` 能完整 elaborate
  （只缺 Xilinx primitive 和 coregen）。PC 程式在 UHD 4.6 下編譯成功。
* **還沒驗證的是 ISE 編譯和實機。** 第一次 `make B210_DVBS2` 時，如果 XST 報語法或資源問題，或時序不過，
  把 `build-B210_DVBS2/b200.syr` 和 `b200.twr` 給我。
  - ISE 是用 radio clock 的上限 61.44 MHz 檢查時序。就算這個條件沒過，在較低的 master clock 下
    （1 Msym/s 時預設約 16 MHz）仍然能用，只是能跑的最高符號率會比較低。
