# dvbs2_loopback_top 暫存器表

AXI4-Lite，32 位元，基底位址 `0x43C0_0000`（`vivado/bd_system.tcl` 指定，範圍 4 KB）。
`FCLK = 100 MHz`。偏移量以位元組計。

## 控制暫存器（R/W）

| 偏移 | 名稱 | 位元 | 說明 | 預設 |
|---|---|---|---|---|
| 0x000 | ID | 31:0 | 唯讀 `0x44564232`（"DVB2"） | |
| 0x004 | VERSION | 31:0 | 唯讀，`0x00010000` = 1.0 | |
| 0x008 | CTRL | 0 | `tx_en`：TX 發送（關閉時 TX 停止產生幀） | 1 |
| | | 1 | `rx_rst`：RX 軟體重置（寫 1 後再寫 0） | 0 |
| | | 2 | `tx_rst`：TX 與通道模擬器軟體重置 | 0 |
| | | 3 | `clr_stats`：清除 BB/BER 統計（自動歸零） | 0 |
| | | 4 | `ch_bypass`：通道模擬器旁路 | 0 |
| | | 5 | `src_stream`：TX 資料來源 0 = PRBS-23，1 = `s_axis_tx` | 0 |
| | | 6 | `pll_en`：無導頻幀的判決導向 PLL | 1 |
| | | 7 | `agc_en`：RX AGC | 1 |
| | | 8 | `early_stop`：LDPC 提前終止 | 1 |
| 0x00C | TX_CFG | 4:0 | MODCOD（1–10 QPSK 1/4–8/9，12–16 8PSK 3/5–8/9） | 4 |
| | | 8 | 導頻 pilots | 1 |
| | | 13:12 | roll-off：0 = 0.35，1 = 0.25，2 = 0.20（TX 與 RX 共用） | 0 |
| 0x010 | SAMPLE_DIV | 7:0 | 每取樣時脈數（寫入值 < 8 時硬體以 8 計）。Rs = FCLK / (2·DIV) | 10 |
| 0x014 | CH_PPM | 31:0 | 取樣時脈偏差，帶號：ppm·10⁻⁶·2³² | 0 |
| 0x018 | CH_DELAY | 15:0 | 起始分數延遲（Q0.16 取樣） | 0 |
| 0x01C | CH_CFO | 31:0 | 載波偏移，每取樣相位增量（2³² = 一圈）。偏移 f/Rs → (f/Rs)/2·2³² | 0 |
| 0x020 | CH_PHASE | 15:0 | 起始載波相位（2¹⁶ = 一圈） | 0 |
| 0x024 | CH_NOISE | 15:0 | 雜訊振幅：每軌 σ = 0.8165·值。Es/N0 → 值 = 16384 / √(2·10^(Es/N0/10)) / 0.8165 | 0 |
| 0x028 | CH_GAIN | 15:0 | 訊號增益 Q2.14（16384 = 1.0） | 16384 |
| 0x030 | RX_AGC | 15:0 | AGC 目標平均振幅 | 6000 |
| | | 19:16 | AGC 迴路增益指數 mu | 12 |
| 0x034 | RX_TIM | 4:0 | 定時迴路比例增益右移 k1s（k1 = 2^-k1s·TED 標度） | 9 |
| | | 12:8 | 定時迴路積分增益右移 k2s | 18 |
| 0x038 | RX_FS | 7:0 | 搜尋門檻 thr_acq（比值 ×256） | 141（0.55） |
| | | 15:8 | 追蹤門檻 thr_trk | 90（0.35） |
| | | 23:16 | FLL 第 1 段幀數 n1 | 2 |
| | | 31:24 | FLL 第 2 段幀數 n2 | 32 |
| 0x03C | RX_FLL | 3:0 | 捕獲時頻率修正右移 k_acq | 1 |
| | | 7:4 | 第 1 段增益右移 k1 | 1 |
| | | 11:8 | 第 3 段增益右移 k3 | 1 |
| | | 15:12 | DD-PLL 比例增益右移 | 6 |
| | | 19:16 | DD-PLL 積分增益右移 | 12 |
| 0x040 | RX_FEC | 7:0 | QPSK LLR 縮放 | 24 |
| | | 15:8 | 8PSK LLR 縮放 | 16 |
| | | 21:16 | LDPC 最大迭代次數 | 25 |
| | | 26:24 | min-sum α 分子（/8），0 = 依碼率預設 | 0 |

## 狀態暫存器（唯讀）

| 偏移 | 名稱 | 說明 |
|---|---|---|
| 0x080 | RX_STATUS | [3:0] 幀同步狀態機，[4] 幀鎖定，[9:5] 接收 MODCOD，[11:10] TYPE（[10] = pilots），[13:12] FLL 段，[14] BER 檢查器鎖定（上一幀錯誤率 < 1/64），[15] pacer 溢位，[21:16] 最近一幀 LDPC 迭代數 |
| 0x084 | RX_OMEGA | NCO 頻率，帶號，每符號 2³² = 一圈（CFO/Rs = 值 / 2³²） |
| 0x088 | RX_FRAMES | 處理過的幀數（含 dummy） |
| 0x08C | RX_MISSES | 追蹤時遺失的標頭數 |
| 0x090 | RX_PLSFAIL | PLS 解碼失敗次數 |
| 0x094 | RX_GAINS | [15:0] AGC 增益（Q6.10），[31:16] 符號增益（Q4.12） |
| 0x098 | LDPC_DEC | LDPC 解碼幀數 |
| 0x09C | LDPC_DROP | 因解碼器忙碌而丟棄的幀數（符號率超過解碼能力） |
| 0x0A0 | BCH_CORR | BCH 累計更正位元數 |
| 0x0A4 | BCH_FAIL | BCH 解碼失敗幀數 |
| 0x0A8 | BB_OK | BBHEADER CRC 正確的幀數 * |
| 0x0AC | BB_CRC | BBHEADER CRC 錯誤幀數 * |
| 0x0B0 | BB_BCHFAIL | BCH 失敗的 BBFRAME 數 * |
| 0x0B4 | BB_INFO | [15:0] DFL，[23:16] MATYPE-1 |
| 0x0B8 | BER_BITS_LO | 已比對位元數（低 32 位）* |
| 0x0BC | BER_BITS_HI | 已比對位元數（高 16 位）* |
| 0x0C0 | BER_ERRORS | 位元錯誤數 * |
| 0x0C4 | TX_FRAMES_ENC | TX 已編碼幀數 |
| 0x0C8 | TX_FRAMES_SENT | TX 已送出資料幀數 |
| 0x0CC | TX_DUMMY | TX 送出的 dummy 幀數 |
| 0x0D0 | TX_UNDERFLOW | TX 成形濾波器欠載次數（只在啟動時出現） |
| 0x0D4 | RX_PLSQ | 最近一次 PLS 解碼的相關值（品質指標） |

\* `CTRL.clr_stats` 會清除這些計數器。

## 換算

* 符號率：`Rs = 100 MHz / (2·SAMPLE_DIV)`，預設 DIV = 10 → 5 Msym/s，
  最高 DIV = 8 → 6.25 Msym/s（接收端定時迴路每個取樣需 6 個時脈的管線）。
* LDPC 解碼器（P = 45、100 MHz、雙緩衝）在 6.25 Msym/s 下，25 次迭代仍跟得上；
  若把最大迭代數調高到解碼時間超過一幀，解碼器會丟幀，計入 `LDPC_DROP`。
* QPSK 1/4 在門檻附近提前終止較少觸發（常跑滿最大迭代數），屬正常。
