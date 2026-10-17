# DVB-S2 基頻收發機 Verilog（TX + RX）

完整的 DVB-S2（EN 302 307-1）基頻 TX + RX，Verilog-2001，同一套 RTL 用在三個硬體專案：

* **`z7020/`**：Zynq-7020（PYNQ-Z2 / Zybo Z7-20）PL 環回：TX → 通道模擬器（時脈偏差、CFO、AWGN）→ RX，
  PS 端透過 AXI-Lite 設定參數、讀取同步狀態與 BER。Vivado。說明見 `z7020/README.md`。
* **`b210/`**：USRP B210（Spartan-6 XC6SLX150）：數據機放進 UHD 的 FPGA，加上 PC 端 UHD 程式
  （兩台對傳，或一台自收自發＋網頁介面）。ISE 14.7。說明見 `b210/README.md`。
* **`adrv9364/`**：ADI ADRV9364-Z7020 SOM（自製載板）：數據機放在 `axi_ad9361` 和 DMA 之間，
  一鍵做出 SD 卡 image（Kuiper Linux＋FPGA＋服務），開機後網頁控制、UDP 傳資料（固定 IP 192.168.30.1）。
  Vivado 2025.x＋ADI HDL，時序收斂，尚未在硬體上驗證。說明見 `adrv9364/README.md`。

共同規格：

* 調變／編碼：QPSK 1/4 … 8/9、8PSK 3/5 … 8/9，**short FECFRAME（16200）**，導頻開或關，
  roll-off 0.35 / 0.25 / 0.20，dummy 幀
* 每個取樣至少 8 個時脈（Z7020、ADRV9364：100 MHz → 最高 6.25 Msym/s；B210：master clock ≥ 8 × 取樣率）；
  RX 定時迴路本身需要 7 個時脈，RX 輸入的 pacer 保證取樣間隔 ≥ 7
* ROM 由 Python 參考模型產生；TX 與黃金模型、LDPC／BCH 解碼器與 Python 模型位元精確

## 在另一台 Ubuntu 上使用（快速開始）

```bash
tar xzf dvbs2_z7020_repo.tar.gz      # 或 git clone 這個 repo
cd dvbs2                             # repo 目錄
./setup_ubuntu.sh                    # 裝 Verilator / iverilog / Python / UHD，編 B210 PC 程式，跑一次 TX 回歸
sim/run_all.sh                       # 完整回歸（約 40 分鐘）
```

* Ubuntu 24.04 最省事（Verilator 5.020 直接 apt 裝）；22.04 的 Verilator 太舊，腳本會從原始碼編 v5.020。
* `./setup_ubuntu.sh --check` 只檢查不安裝；`--no-uhd` 不裝 UHD。
* Vivado（Z7020、ADRV9364 bitstream、XSim；ML Standard 免費版即可）和 ISE 14.7（B210 FPGA image）要自己從 AMD 下載安裝，用之前先
  `source <安裝路徑>/settings64.sh`。
* 這是一個 git repo（`git log` 可看紀錄）；模擬和建置的輸出都在 `.gitignore` 裡，不會進版控。
* `CLAUDE.md` 是給 Claude Code 的專案說明（指令、回歸測試、RTL 修改規則），在 repo 裡執行 `claude` 會自動讀取。

## 架構

```
TX  dvbs2_tx
    PRBS-23 / AXI-Stream → BBHEADER(CRC-8) + BB scrambler → BCH(t=12) → LDPC(IRA 累加)
    → 8PSK 交錯 → 映射 → PLHEADER(SOF+PLS, π/2-BPSK) + 導頻 + Gold PL scrambler
    → RRC 成形（33 tap, 2 sps）
CH  ch_emu      8-tap 多相內插（取樣偏差 ppm、分數延遲）→ CORDIC 載波偏移 → AWGN
RX  dvbs2_rx
    AGC → RRC 匹配濾波 → Gardner TED + Farrow 內插 + Rice NCO（定時恢復）
    → rx_frame：NCO 去旋轉 + 16K 符號緩衝 + 差分 SOF/PLSC 相關器（抗 CFO）
                PLS 解碼（9 點頻率格 + 64 點 Hadamard 串流轉換 ML）
                三段 FLL（lag-1 → Luise-Reggiannini 16 lag → 導頻相位差）+ 迴路延遲補償
                區塊相位內插（導頻/標頭）+ 無導頻時判決導向 PLL，增益正規化
    → 軟解映射（LLR）→ LDPC 分層 normalized min-sum（P = 45 平行、雙緩衝、提前終止）
    → BCH（BM + Chien）→ BB 解擾、CRC 檢查 → PRBS BER 檢查器 / AXI-Stream 輸出
```

## 目錄

| 目錄 | 內容 |
|---|---|
| `rtl/tx` `rtl/rx` `rtl/common` | 數據機 RTL（`dvbs2_tx`、`dvbs2_rx`、共用元件，通道模擬器 `ch_emu` 也在 `rtl/common`） |
| `rtl/gen` | 由 `python/gen_rtl_roms.py` 產生的 ROM／參數表（已附上，不需重產） |
| `python/` | 參考模型：TX 黃金模型、位元精確 LDPC/BCH 模型、同步演算法模型、端到端模型 |
| `sim/` | 數據機測試平台（`sim/tb`）、Verilator 回歸腳本、BER 量測（`sim/ber`） |
| `setup_ubuntu.sh` | 安裝開發環境（Verilator、iverilog、Python、UHD） |
| `z7020/` | Zynq-7020 專案：頂層 RTL（`z7020/rtl`）、Vivado／Vitis 腳本、PS 軟體、AXI-Lite 暫存器表、Windows 批次檔 |
| `b210/` | USRP B210 專案：B210 外殼 RTL（`b210/rtl`）、UHD FPGA patch 與 ISE 建置、PC 程式與網頁介面、雙板模擬 |
| `adrv9364/` | ADRV9364-Z7020 SOM 專案：PL 外殼 RTL（`adrv9364/rtl`）、ADI HDL 專案檔、FPGA 與 SD 卡 image 建置、SOM 上的程式與網頁、雙板模擬 |

## 模擬

Verilator（Linux 或 macOS）：`sim/run_all.sh` 一次跑完下表的快速回歸
（約 40 分鐘；`./run_all.sh full` 會再加上 10 種完整環回情境），個別腳本如下：

| 腳本 | 內容 |
|---|---|
| `sim/reg_tx.sh` | TX 輸出與 Python 黃金模型逐樣本比對（所有 MODCOD × 導頻 × roll-off） |
| `sim/reg_ldpc.sh` | LDPC 解碼器與位元精確模型比對（15 種碼率） |
| `sim/reg_bch.sh` | BCH 解碼器（0–12 個錯誤、不可更正幀） |
| `sim/reg_fec.sh` | 解映射 + LDPC + BCH 串接 |
| `sim/reg_rxfe.sh` | AGC + 定時恢復（±200 ppm、Es/N0 0–10 dB） |
| `sim/reg_sys.sh full` | 完整環回 `dvbs2_tx → ch_emu → dvbs2_rx` 10 種情境（CFO 最大 2 % Rs、±50 ppm、無導頻、各種 roll-off） |
| `b210/sim/reg_b210.sh` | B210 版：兩塊板子＋通道模型，PRBS 和檔案傳輸（輸出在 `b210/sim/out`） |
| `adrv9364/sim/reg_adrv.sh` | ADRV9364 版：兩塊 SOM＋通道模型，酬載經 AXI-Lite 進出（輸出在 `adrv9364/sim/out`） |
| `sim/ber/ber_sweep.py` | BER 曲線（RTL LDPC + BCH，理想同步） |

* `sim/vl.sh <tb> <outdir>` 編譯單一測試平台：依序在 `sim/tb`、`b210/sim`、`z7020/sim`、`adrv9364/sim` 找 `<tb>.v`，
  板子專案的測試平台會再加上該專案的 `rtl/`。
* Vivado xsim（Z7020 專案）見 `z7020/README.md`。

### 在 Mac 上驗證

**只用 Python（演算法層級，最快上手）**：`python/run_e2e.py` 把參考模型串成完整鏈路：
TX → 通道（CFO、取樣時脈偏差、分數延遲、AWGN）→ 定時恢復 → 幀同步／PLS／FLL／PLL →
解映射（與 RTL 位元精確）→ LDPC（與 RTL 位元精確）→ BCH → BB 解擾、CRC → 和 PRBS 比對 BER。

```
cd dvbs2                                                   # repo 目錄
python3 -m venv .venv && source .venv/bin/activate      # Homebrew 的 python 需要 venv
pip install numpy matplotlib
cd python
python3 run_e2e.py                                         # 8PSK 2/3、9 dB、CFO 1 % Rs、20 ppm、30 幀
python3 run_e2e.py --modcod 4 --esn0 2 --cfo 0.005 --plot e2e.png   # QPSK 1/2，輸出圖
python3 run_e2e.py --modcod 13 --no-pilots --esn0 10      # 無導頻（判決導向 PLL）
python3 run_e2e.py --ideal-sync --modcod 4 --sweep 0.4 0.6 0.8 --frames 50   # 理想同步的 BER 點
python3 run_e2e.py -h                                      # 所有參數
```

* 每幀印出：對應的 TX 幀、FLL 段、EVM、LDPC 迭代數、BCH 更正數、CRC、位元錯誤。
  前 `--settle` 幀（預設 18）是 FLL 收斂期，不算進 BER。
* `--plot` 會畫出星座圖、每幀的頻率估計（對照真實 CFO）、EVM 和 LDPC 迭代數。
* 速度：同步約每幀 0.2 s，LDPC 每幀 0.2–1.3 s，30 幀大約 20–40 秒。
  量到 10⁻⁶ 需要幾百幀，請改用下面的 Verilator 方法。
* `--n2` 預設 12，讓導頻輔助的 FLL 第 3 段早一點啟動，示範比較快看到結果；RTL 暫存器的預設值是 32。
* 理想同步模式的 LDPC 和解映射與 RTL 位元精確，BER 會和 RTL 曲線一致（雜訊樣本不同，只有統計上的差異）。

**跑真正的 RTL（Verilator）**：Intel 和 Apple Silicon 的 Mac 都可以。

```
brew install verilator coreutils        # verilator >= 5.0；coreutils 提供 gtimeout
source .venv/bin/activate               # 同上，需要 numpy（畫 BER 圖要 matplotlib）
cd sim && ./run_all.sh                  # 快速回歸
cd ber && ./build.sh && python3 ber_sweep.py -j 4 4 13 && python3 plot_ber.py   # BER 曲線
```

## 效能（RTL 模擬）

### BER 曲線（理想同步，RTL LDPC + BCH）

`sim/ber/`：發射端、AWGN（真正的高斯雜訊）和軟解映射用 C++ 寫（解映射與 `rx_demap.v` 位元精確），
LDPC／BCH 解碼器直接用 Verilator 跑 RTL。每個點量到 2×10⁷ bits，或 50 個錯誤幀為止。
圖：`sim/ber/ber_curves.png`；原始數據：`sim/ber/results/`。

| MODCOD | FER = 10⁻² 的 Es/N0 | 2×10⁷ bits 零錯誤（BER < 1.5×10⁻⁷）的 Es/N0 | 平均迭代數 | ETSI normal frame QEF |
|---|---|---|---|---|
| QPSK 1/4 | −1.17 dB | −0.7 dB（−0.9 dB 時 BER 6.5×10⁻⁷） | 25 | −2.35 dB |
| QPSK 1/2 | 0.52 dB | 0.7 dB | 16.5 | 1.00 dB |
| QPSK 3/4 | 4.09 dB | 4.2 dB | 10.3 | 4.03 dB |
| QPSK 8/9 | 6.29 dB | 6.4 dB | 7.3 | 6.20 dB |
| 8PSK 3/5 | 5.83 dB | 6.0 dB | 18.3 | 5.50 dB |
| 8PSK 2/3 | 6.83 dB | 7.0 dB | 13.5 | 6.62 dB |
| 8PSK 8/9 | 11.68 dB | 11.8 dB | 8.3 | 10.69 dB |

* ETSI 的值是 normal frame（64800）的理想門檻，short frame 本來就會差一些。
  QPSK 1/2 的 short frame 實際碼率是 4/9，所以門檻反而比較低。
* 中、高碼率的瀑布很陡，FER 從 10⁻² 降到 0 只需要 0.1–0.2 dB。
* 8PSK 8/9 比 ETSI 差約 1 dB，主要是 short frame 加上 min-sum 和 7-bit 訊息量化的損失。
* QPSK 1/4 在 10⁻⁵–10⁻⁶ 之間下降比較慢（少數幀殘留 13–20 個錯誤，超過 BCH 的 t = 12），
  而且門檻附近每幀都跑滿 25 次迭代。提高迭代數沒有改善（屬於 trapping set）；把 α 改成 5/8 或 7/8 會更差。
  要改善需要更寬的 APP 位元（目前 8 bit）或改用 offset min-sum。
* 重跑：`cd sim/ber && ./build.sh && python3 ber_sweep.py -j 2 4 13`（任選 MODCOD），
  畫圖用 `python3 plot_ber.py`。

### 完整環回（含同步）

`sim/sync_loss.sh`：TX → 通道（CFO 0.5 % Rs、+20 ppm、導頻開）→ RX，去掉前 45 幀收斂期後統計 150 個以上的幀。

| 情境 | 環回 FER | 理想同步達到相同 FER 的 Es/N0 | 同步損失 |
|---|---|---|---|
| QPSK 1/2，Es/N0 0.5 dB | 0.32（72/222） | ≈ 0.35 dB | ≈ 0.15 dB |
| 8PSK 2/3，Es/N0 6.8 dB | 0.18（32/182） | ≈ 6.7 dB | ≈ 0.1 dB |

`sim/reg_sys.sh full` 的 10 種情境（CFO 最大 2 % Rs、±50 ppm、無導頻、roll-off 0.20/0.25/0.35、
QPSK 1/4 到 8PSK 8/9）收斂後都是 0 錯誤。

## 已知限制

* 只支援 short FECFRAME；normal（64800）需要更大的 LDPC 記憶體（Z7020 的 BRAM 還放得下，但沒有實作）。
* QPSK 9/10、16/32APSK 不支援（short frame 本來就沒有 9/10）。
* 符號率上限 6.25 Msym/s（100 MHz、每個取樣 8 個時脈）。要更高的話，需要把接收前端改成每個時脈處理一個取樣。
