# DVB-S2 on Zynq-7020（PL 環回）

在 xc7z020clg400-1（PYNQ-Z2 / Zybo Z7-20）上用 repo 根目錄的 DVB-S2 RTL 做純 PL 環回測試：
TX → 通道模擬器（時脈偏差、CFO、AWGN）→ RX，PS 端透過 AXI-Lite 設定參數、讀取同步狀態與 BER。

* 時脈 100 MHz（FCLK_CLK0），符號率 `100 MHz / (2·DIV)`，DIV ≥ 8 → 最高 6.25 Msym/s
* 數據機本體（`../rtl`）、參考模型（`../python`）和回歸測試（`../sim`）見根目錄的 `README.md`

## 檔案

| 路徑 | 內容 |
|---|---|
| `rtl/dvbs2_loopback_top.v` | 頂層：`dvbs2_tx` → `ch_emu` → `dvbs2_rx`、LED |
| `rtl/dvbs2_regs.v` | AXI-Lite 暫存器 |
| `doc/register_map.md` | AXI-Lite 暫存器表 |
| `vivado/` | 建專案、Block Design、合成實作、模擬的 Tcl，以及 XDC、PYNQ-Z2 board files |
| `vitis/` | Vitis 裸機程式建置（`build_vitis.tcl`）與下載執行（`run_on_board.tcl`） |
| `sw/` | `dvbs2_demo.c`（Vitis 裸機）、`dvbs2_pynq.py`（PYNQ） |
| `sim/tb_top.v` | 走 AXI-Lite 設定整個頂層的測試平台 |
| `1_build_hw.bat` `2_build_sw.bat` `3_run_on_board.bat` `build_all.bat` | Windows 一鍵建置／上板（輸出到 `out/`，log 在 `logs/`） |

## 用 Vivado 建置（2020.2 以後的版本都可以）

```
cd z7020/vivado
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

* Vivado xsim（先建好專案）：`vivado -mode batch -source vivado/sim.tcl -tclargs tb_sys MODCOD=13 NOISE=4487 CFO=4294967`
  （`tb_sys` 是完整環回，`tb_top` 走 AXI-Lite 設定整個頂層）
* Verilator（快約 50 倍）：`../sim/reg_sys.sh quick|full`；頂層測試平台：`../sim/vl.sh tb_top ../sim/out/tb_top`

## 資源（估計）

下表是估計值：TX 和通道模擬器用 Yosys（`synth_xilinx`）合成得到；RX 的記憶體和乘法器依 RTL 結構逐一計算，
LUT 是依結構推估。實際數字請以 Vivado 的 `vivado/build/reports/utilization.rpt` 為準。

| 模組 | LUT | FF | DSP48 | BRAM36 |
|---|---|---|---|---|
| TX（BB、BCH/LDPC 編碼、成形） | ~2.4K | ~2.3K | 34 | 2.5 |
| 通道模擬器 | ~2.1K | ~1.7K | 22 | 0 |
| RX 前端（AGC、匹配濾波、定時恢復） | ~2.5K | ~2K | ~40 | 0 |
| RX 幀同步（相關器、PLS、FLL/PLL、16K 符號緩衝） | ~7K | ~9K | ~25 | 12 |
| LDPC 解碼器（P = 45，雙緩衝） | ~11K | ~8K | 0 | ~42 |
| BCH 解碼器、解映射、BB 輸出、暫存器 | ~4K | ~3K | ~4 | 1 |
| **合計（xc7z020：53.2K LUT／106K FF／220 DSP／140 BRAM36）** | **~29K（55%）** | **~26K（25%）** | **~125（57%）** | **~58（41%）** |

