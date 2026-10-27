# 場域監測：手機影像 → Jetson（YOLO + VLM）→ OneWeb 衛星網路 → 地面站

```
多支手機瀏覽器 ──Wi-Fi 熱點/HTTPS──▶ Jetson Orin Nano（現場節點，node_id）
                                  │ 每 5 秒輪流取一支手機的影格
                                  ├─ YOLO26s（TensorRT FP16，數毫秒）→ 物件清單 ＋ 規則判定
                                  ├─ Qwen3-VL 2B（Ollama）← 影像 ＋ YOLO 物件清單 → 描述 ＋ 狀態
                                  └─ 融合：max(VLM, YOLO 規則) → 一般 / 警告 / 嚴重
                                  │
                                  │ 乙太網路 → OneWeb 使用者終端 → 衛星 → 網際網路（一條 TCP 連線，Nano 主動連到地面站）
                                  ├──▶ 送：報告（嚴重時附影像）、心跳含手機清單、被選手機的縮圖
                                  ◀──┤ 收：選手機、開始/停止偵測、設定、文字通知（Jetson 回 ACK，沒收到就重送）
                                  │
                              地面站電腦（路由器轉發 TCP 6767）：儀表板（手機清單、縮圖、選手機、鏈路狀態）、SQLite、影像存檔、CSV 匯出
```

**鏈路（2026-10-27 起）**：OneWeb 衛星上網與 USRP DVB-S2 無線**二選一、儀表板可切換**（`link.mode: multi`，預設走 OneWeb；一次只跑一條，切換是先啟動新鏈路、兩邊都通了才停舊的，實測 3–8 秒）。OneWeb 走 `tcp` 模式：OneWeb 終端在 CGNAT 後面不能被連入，所以由 Nano 當 TCP client 連到地面站的對外位址
（路由器把 TCP 6767 轉發到地面站電腦），指令從同一條連線回送。TCP 本身可靠，不再需要為掉包重送，也不節流。
**USRP 鏈路**：自建的 DVB-S2 無線鏈路（`fpga` 模式），數據機跑在 USRP B210 的 FPGA 裡（[dvb-s2-sdr](https://github.com/Hiyaso/dvb-s2-sdr) 專案的 `dvbs2_b210` 程式＋自製 image），
兩端各一個 `dvbs2_b210` 行程同時收發，應用程式只對本機 UDP 埠讀寫。舊的 gr-dvbs2rx 路線（`dvbs2` 模式）仍保留但不再需要。
架構圖：[docs/架構圖_oneweb.svg](docs/架構圖_oneweb.svg)（OneWeb 版）、[docs/架構圖.svg](docs/架構圖.svg)（DVB-S2 版）。

**日常操作（開機順序、Nano 端、PC 端、手機端、排障）請看 [操作手冊.md](操作手冊.md)。**

## 目錄

| 路徑 | 內容 |
|---|---|
| `jetson/app.py` | Jetson 主程式（網頁、截圖、YOLO、VLM、鏈路） |
| `jetson/detector.py` | YOLO 偵測（Ultralytics，自動匯出 TensorRT） |
| `jetson/fusion.py` | YOLO 與 VLM 融合：提示、規則、畫框 |
| `jetson/vlm.py` | Ollama VLM 呼叫，JSON schema 限制輸出 |
| `jetson/camera.py` | 多支手機的登記簿（每支一個最新影格、名稱、在線狀態）與縮圖工具 |
| `jetson/static/camera.html` | 手機相機頁 |
| `jetson/static/monitor.html` | Jetson 螢幕監控頁，通知會全螢幕跳出 |
| `ground/app.py`、`ground/storage.py` | 地面站主程式與資料保存 |
| `ground/static/index.html` | 地面站儀表板（深色地面站風格：頂部列＋時鐘、狀態橫幅、指標卡、手機面板、即時縮圖、**資料鏈路面板**（tcp：連線／RTT／重傳；fpga：DVB-S2 接收含頻譜與瀑布圖）、上行狀態、時間軸、紀錄、通知） |
| `common/link.py` | 鏈路：`multi`（預設：`tcp`／`fpga` 擇一、儀表板切換，`MultiLink`）/ `tcp`（OneWeb／網際網路；Nano 為 client、地面站為 server，可接多台）/ `fpga`（dvbs2_b210；並用 `--status-udp` 收數據機每秒的狀態與頻譜 JSON）/ `udp`（開發用）/ `dvbs2`、`loopback`（舊的 gr-dvbs2rx） |
| `common/ts.py` | MPEG-TS 分段重組（CRC32、continuity counter） |
| `radio/usrp_bridge.py` | （舊路線）讓 TX、RX 共用同一台 USRP 的 GNU Radio flowgraph |
| `config/*.yaml` | 兩端設定 |
| `tools/link_selftest.py` | TS 分段重組單元測試、gr-dvbs2rx loopback |
| `tools/fake_phone.py` | 假手機：不用真手機就能測多支手機、輪流辨識、縮圖、選手機 |
| `tools/mock_ollama.py` | 假 Ollama：開發機上沒有 GPU 時測整個流程 |
| `tools/restart_jetson.sh`、`tools/restart_ground.sh`、`tools/stop_*.sh` | 重啟／停止兩端的程式與數據機（log 在 `logs/`） |
| `操作手冊.md` | 日常操作手冊 |
| `docs/架構圖_oneweb.svg`、`docs/架構圖.svg` | 架構圖（OneWeb 版／DVB-S2 版，各有 PNG） |

## 安裝

Jetson（JetPack 6.x 或 7.x，腳本會自動判斷）：

```bash
./tools/install_jetson.sh          # GNU Radio、UHD、gr-dvbs2rx、.venv（PyTorch、Ultralytics）、Ollama、qwen3-vl:2b
sudo ./jetson/setup_hotspot.sh JetsonCam 你的密碼
./jetson/gen_cert.sh
```

地面站電腦（Ubuntu 22.04 / 24.04）：只需要 Python 套件，不需要 GNU Radio。tcp 模式再加：`sudo ufw allow 6767/tcp`，路由器把 TCP 6767 轉發到這台。
備用的 fpga 模式另外要有編好的 `dvbs2_b210` 與 FPGA image（dvb-s2-sdr 專案的 `b210/host/build.sh`、`b210/build_fpga.sh`），路徑填在 `config/ground.yaml` 的 `link.fpga`。

```bash
python3 -m venv .venv && .venv/bin/pip install aiohttp pyyaml pillow      # 或 sudo apt install python3-aiohttp python3-yaml python3-pil
```

Jetson：tcp 模式只要 `config/jetson.yaml` 的 `link.tcp.connect` 填地面站的對外位址，並把 OneWeb 終端接到 RJ45。fpga 模式同樣要有 `dvbs2_b210`（aarch64 重編）與 image，路徑填在 `link.fpga`；`install_jetson.sh` 裝的 GNU Radio 只有舊路線才用到。

## 執行

```bash
# 地面站（tcp 模式：監聽 6767 等 Nano 連入；fpga 模式會自己啟動 dvbs2_b210，log 在 logs/dvbs2_b210.log）
.venv/bin/python ground/app.py        # 儀表板 http://localhost:8080

# Jetson（用安裝腳本建立的 .venv；tcp 模式連到 link.tcp.connect，連不上每 5 秒重試）
.venv/bin/python jetson/app.py                # 手機開 https://10.42.0.1:8443/camera，輸入名稱後開始傳送
                                      # Jetson 螢幕開 https://localhost:8443/monitor
```

沒有真手機時，從任何能連到 Jetson 的電腦跑假手機（例如 USB 連線的 192.168.55.1）：

```bash
.venv/bin/python tools/fake_phone.py --url https://192.168.55.1:8443 --id pA --name "A 區大門"
```

第一次啟動 Jetson 時會自動下載 `yolo26s.pt` 並匯出成 `models/yolo26s.engine`，在 Orin Nano 上要幾分鐘，之後直接載入。
TensorRT 引擎綁定 GPU 與 TensorRT 版本，升級 JetPack 後請刪掉 `.engine` 讓它重新匯出。

## 分段驗證（建議順序）

1. `python3 tools/link_selftest.py unit`：純軟體測 TS 分段重組。
2. 一台電腦上跑完整流程（不需要 USRP、GPU）：`tools/mock_ollama.py` 當 VLM、兩端 `link.mode: tcp`（Jetson 的 `connect` 指向 127.0.0.1:6767）或 `--link-mode udp`、`tools/fake_phone.py` 當手機。
3. 從地面站自己測對外埠：`nc -zv 123.193.37.73 6767` 要 `succeeded`、`logs/ground_app.log` 多一行 `TCP 連線建立`（路由器轉發＋防火牆都對）。
4. Nano 接上 OneWeb，`link.tcp.connect` 填地面站對外位址，啟動後 log 出現 `TCP 已連上地面站`；先用假手機、再換真手機。
5. 備用 fpga 模式：每台 USRP 先用 dvb-s2-sdr 的 `dvbs2_b210 --web 8080` 自收自發確認 image 正常，再兩端 `link.mode: fpga`；空中傳輸的頻率、功率必須符合 NCC 規範。

鏈路問題：tcp 模式看 `logs/jetson_app.log`／`logs/ground_app.log` 的 `TCP` 行與儀表板的資料鏈路面板；fpga 模式看兩端的 `logs/dvbs2_b210.log`（每秒一行：LOCK、CFO、LDPC 迭代、BBFRAME CRC、UDP 封包數、USB 欠載／溢位）。

## 鏈路切換（`link.mode: multi`，預設）

```yaml
link:
  mode: multi
  links: [tcp, fpga]     # OneWeb、USRP
  active: tcp            # 開機後走哪條（兩邊一樣）
```

- 平常只跑 `active` 那條。儀表板「資料鏈路」面板的 **OneWeb／USRP** 鈕送 `SELECT settings.link`；流程（`common/link.py` `MultiLink`）：
  Nano 收到指令回 ACK 並啟動新鏈路 → 地面站收到 ACK 也啟動新鏈路（`begin_switch`）→ 地面站在新鏈路收到 Nano 心跳後，經新鏈路送確認 SELECT → Nano 在新鏈路收到任何訊息就 `commit_switch`（停舊鏈路）並回 ACK → 地面站收到 ACK 也 `commit_switch`。
  交接期間心跳與 ACK 走兩條（`via="all"` = 所有正在跑的鏈路），報告等資料仍走舊的；新鏈路 60 秒內沒通就 `abort_switch`，維持原鏈路。
- 實測（2026-10-27）：OneWeb→USRP 約 8 秒（含 dvbs2_b210 啟動與鎖定）、USRP→OneWeb 約 3 秒，各兩次；切完後另一條的行程確實停止（`pgrep dvbs2_b210` 為空）。
- Nano 的 `/api/select {"settings": {"link": "fpga"}}` 與監控頁的按鈕也能切（本機發起，流程相同）。

## 鏈路設定（OneWeb／網際網路，`tcp`）

```yaml
# config/jetson.yaml
link:
  mode: tcp
  tcp: {role: client, connect: 123.193.37.73:6767, connect_timeout_s: 10, timeout_s: 20}
# config/ground.yaml
link:
  mode: tcp
  tcp: {role: server, listen: 0.0.0.0:6767, timeout_s: 20}
```

- 訊息仍是 MPEG-TS 分段＋CRC32，直接寫進 TCP 位元流；地面站對每條連線各用一個解多工器，所以多台 Jetson 可以同時連同一個埠。
- Nano 主動連線、斷線後 3 秒重連、連不上每 5 秒重試；兩邊都設 TCP keepalive（10 s／5 s×3）與 `TCP_USER_TIMEOUT`（`timeout_s`），OneWeb 斷線或 NAT 映射失效 20 幾秒內就會發現。
- 心跳每 2 秒一次，順便維持 NAT 映射；地面站 8 秒沒心跳記「鏈路中斷」。
- TCP 可靠，嚴重事件不再重送（`Link.reliable`），縮圖仍是低優先權、排隊時跳過。
- 儀表板的「資料鏈路」面板顯示連線／RTT／TCP 重傳／收送量／重連次數（來自 Linux `TCP_INFO`），Nano 心跳回報它那邊的同樣資訊。
- 地面站要能被連到：路由器轉發 TCP 6767 → 地面站電腦 ＋ `sudo ufw allow 6767/tcp`；對外 IP 變了要改 Nano 的 `connect`。
  不想依賴路由器時，兩邊裝 Tailscale、`connect` 填地面站的 100.x.x.x，順便可以從任何地方 SSH 進 Nano。
- 2026-10-27 驗證：本機兩程式經公網位址 123.193.37.73:6767（路由器 hairpin）連線，報告、縮圖、選手機 ACK、通知全部通過；地面站重啟後 Nano 端 8 秒內重連。
  真 Nano 經 OneWeb（終端 192.168.100.1，對外 175.111.235.59）連上：RTT 約 300 ms、TCP 重傳 0、SELECT 來回 0.4 秒；路徑 20 跳（衛星約 120 ms，再經中華電信國際閘道 → 洛杉磯 → Arelion → PCCW → 台灣固網 → 凱擘），見 `docs/架構圖_oneweb.svg` 底部。

## 鏈路設定（USRP：FPGA 數據機，`fpga`）

兩端 `link.fpga` 的頻率要對調（Jetson 的 `tx_freq` = 地面站的 `rx_freq`，反之亦然），`bw`、`rolloff` 要一致；MODCOD 各自決定，RX 會從 PLHEADER 自動解出。
2026-10 實測（兩台 NI USRP-2901／B210、天線、同一房間）：

| 方向 | 頻率 | MODCOD | TX 增益 | 結果 |
|---|---|---|---|---|
| Jetson → 地面站 | 1000 MHz | 13（8PSK 2/3，約 2.5 Mbit/s） | 70 | Es/N0 約 13 dB，0 位元錯誤 |
| 地面站 → Jetson | 1050 MHz | 4（QPSK 1/2，約 1.2 Mbit/s） | 80 | 指令量小，用最穩的；這方向餘裕較小，8PSK 2/3 會解不出 |

- TX 增益 40 在兩台之間完全收不到（對方底噪沒有變化），70 以上才夠；自己的 TX 開著會讓本機 RX 的 Es/N0 掉約 2 dB。
- Jetson 跑 YOLO＋VLM 時 CPU 很滿，`dvbs2_b210` 可能出現 USB 欠載（log 的 `host U`）。把使用者加進 `usrp` 群組讓 UHD 能用即時優先權：`sudo usermod -aG usrp $USER`，重新登入後生效。
- `rate_kbps` 是應用層送出的節流，略低於 MODCOD 容量的 90 %；超過時 `dvbs2_b210` 只留約 0.2 秒的佇列、多的封包直接丟。
- 鏈路沒有重傳：報告只送一次（嚴重事件重送 `critical_repeat` 次、地面站去重），縮圖可丟，選手機與通知靠 ACK 重送。

## 儀表板上的鏈路狀態

tcp 模式：「資料鏈路：OneWeb 衛星網路（TCP）」面板顯示已連線／等待連入、連著幾台 Jetson、RTT、對方位址與連線時間、TCP 重傳、收送量、重連次數、Jetson 端狀態；頻譜區塊隱藏。

fpga 模式：`dvbs2_b210 --status-udp 127.0.0.1:6001`（自動加）每秒把和網頁模式相同的狀態 JSON 與 1024 點頻譜丟到本機 UDP，
`common/link.py` 收下來後：地面站儀表板的「DVB-S2 接收」面板顯示鎖定／MODCOD／導頻／FLL、Es/N0（M2M4 盲估計）、解碼率、頻率偏移、訊號電平、
幀數／漏幀／LDPC／BCH／CRC／USB 溢位，以及頻譜圖與瀑布圖（dB 範圍可調，每秒一列）；Jetson 的心跳帶著它自己的接收品質（上行）與發射統計，
顯示在「鏈路與上行」面板。解碼率的分母在對方只送 dummy 幀時改用心跳回報的下行容量。

**開始／停止偵測**：橫幅左側的按鈕控制 Jetson 是否對影像做 YOLO＋VLM 辨識（`capture.detect`，走 SELECT settings 有 ACK）；
預設開機後是停止的（`detect: 0`），手機畫面與縮圖不受影響。目前狀態面板的膠囊顯示「偵測中／偵測已停止」，Jetson 的 /monitor 頁也能切。

**清空**：橫幅上的「清空」把目前為止的報告從儀表板移除（`POST /api/ack`，`ack_id` 與 `clear_ts` 存在 SQLite 的 kv 表，重整與重啟都記得）：
狀態橫幅與目前狀態回到「已清除」、最近 30 分鐘的統計與時間軸歸零、嚴重事件影像收起、指標卡清空；紀錄表與資料庫不刪，之後只累計新報告。

## 多支手機、選手機與縮圖

- 手機相機頁要先輸入名稱；瀏覽器會記住一個固定 id，之後重開頁面還是同一支。
- Jetson 每 `interval_s` 秒取「最久沒被辨識、且有新影格」的那支做 YOLO＋VLM，所以 N 支手機每支大約 N × interval_s 秒一筆報告（VLM 推論比 interval_s 久時會更慢，log 會印「略過本次」）。
- 心跳帶手機清單（名稱、在線、幾秒前有畫面、已辨識次數、是否被選中）；地面站儀表板的「手機」面板據此顯示，按「看這支」送 SELECT。
- 被選中的手機每秒 `thumb_fps` 張縮圖（`thumb_max_side`、`thumb_quality`），低優先權，鏈路排隊時自動跳過；地面站只保留最新一張，不存檔。
- **預設偏低**（每秒 1 張、320 px，VLM 影像 448 px）以減輕 Orin Nano 的記憶體與 CPU 壓力；儀表板「手機」面板的三個下拉選單可隨時調整
  （縮圖每秒 0–3 張、縮圖大小、VLM 影像 320/448/640 px），走 SELECT 訊息、有 ACK，Jetson 心跳會回報目前值；Jetson 本機也可 `POST /api/select {"settings": {...}}`。
  VLM 影像 640 px 約 1300 個 token、448 px 約 650 個，直接影響推論時間與記憶體。
- 第一支連上的手機會被自動選中，地面站可隨時改；Jetson 的 /monitor 頁也能本機改。

## 多台 Jetson

每台 `config/jetson.yaml` 的 `node.id` 要不同；所有訊息都帶 node id，地面站資料庫與 CSV 記錄來源節點，指令可指定目標節點。
tcp 模式：每台 Jetson 都連到地面站同一個埠，地面站對每條連線各自解多工、指令廣播給全部，Jetson 依 `node` 欄位過濾（目前儀表板的即時狀態仍以最後一個心跳為準）。
fpga 模式：地面站一台 USRP 同時只能收一個頻道，所以一條鏈路對一台 Jetson；要接多台時每台配一台地面站 USRP、各用自己的頻率對（`link.fpga.args: serial=...`）。

## YOLO + VLM 的分工

YOLO 每張數毫秒，負責「有沒有、有幾個、在哪裡」；VLM 負責「這代表什麼狀況」並寫出描述。

- YOLO 的偵測清單（類別、信心、位置）會寫進 VLM 的提示，補 VLM 對小物件和數量的弱點。
- `fusion.rules` 定義 YOLO 可以直接拉高狀態的規則，最終狀態取兩者中較嚴重的，寧可多報不要漏報。
- VLM 沒回應時，只要 YOLO 規則有觸發仍會回報，事件不會因為 VLM 故障而漏掉。
- 嚴重事件回傳的影像會畫上偵測框：每個類別固定一種顏色（同一類別每張圖都同色，`fusion.PALETTE`），框上標籤是類別與信心，圖的外框用狀態色（紅＝嚴重）。
- 地面站會記錄 VLM 判定、YOLO 規則判定、是否由 YOLO 升級，CSV 也有這些欄位，方便事後評估兩者各自的準確度。

預設的 `yolo26s.pt` 是 COCO 預訓練模型，只認得人、車、刀等 80 類，沒有火、煙、倒地。所以預設規則是空的，YOLO 只提供物件資訊給 VLM。
要讓 YOLO 規則真正發揮作用，請訓練自己的模型。

## 訓練場域專用的 YOLO

```bash
pip install ultralytics
# data.yaml 列出你的類別，例如 fire、smoke、fallen_person、no_helmet
yolo detect train model=yolo26s.pt data=data.yaml imgsz=640 epochs=100 batch=16
```

訓練建議在有獨立 GPU 的電腦上做，Orin Nano 只負責推論。完成後把 `runs/detect/train/weights/best.pt` 複製到 Jetson 的 `models/`，
修改 `config/jetson.yaml`：

```yaml
yolo:
  model: models/best.pt
fusion:
  rules:
    - {name: 明火, classes: [fire], min_conf: 0.45, level: critical}
    - {name: 濃煙, classes: [smoke], min_conf: 0.50, level: critical}
```

## 記憶體

Orin Nano 8 GB 由 CPU 與 GPU 共用。Qwen3-VL 2B、YOLO（含 PyTorch CUDA context）與桌面環境同時跑會偏緊（FPGA 數據機行程本身很輕）。
吃不消時依序：

- 監控頁改用其他裝置開 `https://10.42.0.1:8443/monitor`，Jetson 改開機到無桌面模式（`sudo systemctl set-default multi-user.target`），可省下約 0.8 GB。
- `yolo.model` 改用 `yolo26n.pt`。
- 用 `jtop` 觀察記憶體與 GPU 使用量。

## 授權

Ultralytics YOLO 程式與權重為 AGPL-3.0，商業閉源產品需向 Ultralytics 購買 Enterprise 授權。
gr-dvbs2rx 為 GPL-3.0，Qwen3-VL 為 Apache-2.0。
