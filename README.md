# DVB-S2 基頻收發機（Zynq-7020，PL 環回）

在 xc7z020clg400-1（PYNQ-Z2 / Zybo Z7-20）上實作的完整 DVB-S2（EN 302 307-1）基頻
TX + RX，純 PL 環回測試：TX → 通道模擬器（時脈偏差、CFO、AWGN）→ RX，PS 端透過 AXI-Lite
設定參數、讀取同步狀態與 BER。

* 調變／編碼：QPSK 1/4 … 8/9、8PSK 3/5 … 8/9，**short FECFRAME（16200）**，導頻開或關，
  roll-off 0.35 / 0.25 / 0.20，dummy 幀
* 時脈 100 MHz（FCLK_CLK0），符號率 `100 MHz / (2·DIV)`，DIV ≥ 8 → 最高 6.25 Msym/s
* 全部 Verilog-2001，ROM 由 Python 參考模型產生；LDPC 解碼器與 Python 模型位元精確

## 在另一台 Ubuntu 上使用（快速開始）

```bash
tar xzf dvbs2_z7020_repo.tar.gz      # 或 git clone 這個 repo
cd dvbs2_z7020
./setup_ubuntu.sh                    # 裝 Verilator / iverilog / Python / UHD，編 B210 PC 程式，跑一次 TX 回歸
sim/run_all.sh                       # 完整回歸（約 40 分鐘）
```

* Ubuntu 24.04 最省事（Verilator 5.020 直接 apt 裝）；22.04 的 Verilator 太舊，腳本會從原始碼編 v5.020。
* `./setup_ubuntu.sh --check` 只檢查不安裝；`--no-uhd` 不裝 UHD。
* Vivado（Z7020 bitstream、XSim）和 ISE 14.7（B210 FPGA image）要自己從 AMD 下載安裝，用之前先
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
                PLS 解碼（9 點頻率格 + FHT-32 ML）
                三段 FLL（lag-1 → Luise-Reggiannini 16 lag → 導頻相位差）+ 迴路延遲補償
                區塊相位內插（導頻/標頭）+ 無導頻時判決導向 PLL，增益正規化
    → 軟解映射（LLR）→ LDPC 分層 normalized min-sum（P = 45 平行、雙緩衝、提前終止）
    → BCH（BM + Chien）→ BB 解擾、CRC 檢查 → PRBS BER 檢查器 / AXI-Stream 輸出
```

## 目錄

| 目錄 | 內容 |
|---|---|
| `rtl/tx` `rtl/rx` `rtl/top` `rtl/common` | RTL（頂層 `rtl/top/dvbs2_loopback_top.v`） |
| `rtl/gen` | 由 `python/gen_rtl_roms.py` 產生的 ROM／參數表（已附上，不需重產） |
| `vivado/` | 建專案、Block Design、合成實作、模擬的 Tcl，以及 XDC |
| `sw/` | `dvbs2_demo.c`（Vitis 裸機）、`dvbs2_pynq.py`（PYNQ） |
| `python/` | 參考模型：TX 黃金模型、位元精確 LDPC/BCH 模型、同步演算法模型 |
| `sim/` | 測試平台（`sim/tb`）、Verilator 回歸腳本、BER 量測（`sim/ber`） |
| `doc/register_map.md` | AXI-Lite 暫存器表 |
| `b210/` | USRP B210 版：同一套 RTL 放進 B210 的 FPGA，加上 PC 端 UHD 程式（兩台對傳），說明見 `b210/README.md` |

## 用 Vivado 建置（2020.2 以後的版本都可以）

```
cd vivado
vivado -mode batch -source create_project.tcl -tclargs pynq-z2     # 或 zybo-z7-20 / generic
vivado -mode batch -source build.tcl                               # 合成 + 實作 + bitstream
```

* 產出：`vivado/build/dvbs2_z7020.bit`、`.hwh`（PYNQ 用）、`.xsa`（Vitis 用）、`build/reports/`
  （使用率、時序、功耗）。結束時會印出 WNS/WHS，時序不過會出現 CRITICAL WARNING。
* 板子的 board files 需要先安裝（PYNQ-Z2：TUL；Zybo：Digilent vivado-boards）。找不到時，
  會改用裸 part 和通用的 PS7 設定，這時要自己確認 DDR 參數。
* 也可以用 GUI 開 `vivado/build/dvbs2_z7020/dvbs2_z7020.xpr`。
* 位址：`dvbs2_0` 在 `0x43C0_0000`（4 KB）。LED：[0] 幀鎖定、[1] BER 鎖定、[2] 收到正確 BBFRAME 時閃爍、[3] 心跳。

## 上板執行

**PYNQ-Z2**：把 `dvbs2_z7020.bit`、`dvbs2_z7020.hwh`、`sw/dvbs2_pynq.py` 複製到板子上（檔名要一致），然後：

```python
from dvbs2_pynq import DVBS2
d = DVBS2('dvbs2_z7020.bit')
d.configure(modcod=13, pilots=True)          # 8PSK 2/3
d.set_channel(esn0_db=9.0, cfo_rs=0.01, ppm=20)
d.status()
d.ber_sweep(4, [0.5, 1.0, 1.5, 2.0])         # QPSK 1/2 的 BER/FER 掃描
```

**Vitis 裸機**：用 `dvbs2_z7020.xsa` 建 platform，建一個 standalone 空白 C 應用程式，加入
`sw/dvbs2_demo.c`，linker 加上 `-lm`。UART 115200 會印出鎖定狀態和 BER 掃描結果。

## 模擬

* Vivado xsim：`vivado -mode batch -source vivado/sim.tcl -tclargs tb_sys MODCOD=13 NOISE=4487 CFO=4294967`
  （`tb_sys` 是完整環回，`tb_top` 走 AXI-Lite 設定整個頂層）
* Verilator（Linux 或 macOS，速度約快 50 倍）：`sim/run_all.sh` 一次跑完下表的快速回歸
  （約 40 分鐘；`./run_all.sh full` 會再加上 10 種完整環回情境），個別腳本如下：

| 腳本 | 內容 |
|---|---|
| `sim/reg_tx.sh` | TX 輸出與 Python 黃金模型逐樣本比對（所有 MODCOD × 導頻 × roll-off） |
| `sim/reg_ldpc.sh` | LDPC 解碼器與位元精確模型比對（15 種碼率） |
| `sim/reg_bch.sh` | BCH 解碼器（0–12 個錯誤、不可更正幀） |
| `sim/reg_fec.sh` | 解映射 + LDPC + BCH 串接 |
| `sim/reg_rxfe.sh` | AGC + 定時恢復（±200 ppm、Es/N0 0–10 dB） |
| `sim/reg_sys.sh full` | 完整環回 10 種情境（CFO 最大 2 % Rs、±50 ppm、無導頻、各種 roll-off） |
| `sim/reg_b210.sh` | B210 版：兩塊板子＋通道模型，PRBS 和檔案傳輸 |
| `sim/ber/ber_sweep.py` | BER 曲線（RTL LDPC + BCH，理想同步） |

### 在 Mac 上驗證

**只用 Python（演算法層級，最快上手）**：`python/run_e2e.py` 把參考模型串成完整鏈路：
TX → 通道（CFO、取樣時脈偏差、分數延遲、AWGN）→ 定時恢復 → 幀同步／PLS／FLL／PLL →
解映射（與 RTL 位元精確）→ LDPC（與 RTL 位元精確）→ BCH → BB 解擾、CRC → 和 PRBS 比對 BER。

```
cd dvbs2_z7020
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

## 資源（估計）

下表是估計值：TX 和通道模擬器用 Yosys（`synth_xilinx`）合成得到；RX 的記憶體和乘法器依 RTL 結構逐一計算，
LUT 是依結構推估。實際數字請以 Vivado 的 `build/reports/utilization.rpt` 為準。

| 模組 | LUT | FF | DSP48 | BRAM36 |
|---|---|---|---|---|
| TX（BB、BCH/LDPC 編碼、成形） | ~2.4K | ~2.3K | 34 | 2.5 |
| 通道模擬器 | ~2.1K | ~1.7K | 22 | 0 |
| RX 前端（AGC、匹配濾波、定時恢復） | ~2.5K | ~2K | ~40 | 0 |
| RX 幀同步（相關器、PLS、FLL/PLL、16K 符號緩衝） | ~7K | ~9K | ~25 | 12 |
| LDPC 解碼器（P = 45，雙緩衝） | ~11K | ~8K | 0 | ~42 |
| BCH 解碼器、解映射、BB 輸出、暫存器 | ~4K | ~3K | ~4 | 1 |
| **合計（xc7z020：53.2K LUT／106K FF／220 DSP／140 BRAM36）** | **~29K（55%）** | **~26K（25%）** | **~125（57%）** | **~58（41%）** |

## 已知限制

* 只支援 short FECFRAME；normal（64800）需要更大的 LDPC 記憶體（Z7020 的 BRAM 還放得下，但沒有實作）。
* QPSK 9/10、16/32APSK 不支援（short frame 本來就沒有 9/10）。
* 符號率上限 6.25 Msym/s（100 MHz、每個取樣 8 個時脈）。要更高的話，需要把接收前端改成每個時脈處理一個取樣。
* 通道模擬器的 AWGN 是 8 個均勻分布相加的近似，尾端（> 4σ）比真正的高斯分布少，所以在極低 BER 下會略顯樂觀；
  上面的 BER 曲線是用 C++ 產生真正的高斯雜訊，不受這點影響。
