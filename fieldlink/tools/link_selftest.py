#!/usr/bin/env python3
"""鏈路自我測試。

  python3 tools/link_selftest.py unit       純軟體：TS 分段/重組、掉包、錯位、CRC
  python3 tools/link_selftest.py loopback   dvbs2-tx → (模擬雜訊) → dvbs2-rx，不需要 USRP，
                                            用來確認 gr-dvbs2rx 裝好、參數正確
"""
import argparse
import os
import random
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402

from common.link import Link  # noqa: E402
from common.protocol import MsgType, pack_report, unpack_report  # noqa: E402
from common.ts import NULL_PACKET, TS_SIZE, TsDemuxer, TsMuxer  # noqa: E402


def unit():
    random.seed(1)
    got = []
    mux, demux = TsMuxer(0x100), TsDemuxer(0x100, lambda t, i, f, p: got.append((t, i, p)))
    msgs = [os.urandom(random.choice([0, 1, 50, 170, 184, 500, 4000, 60000])) for _ in range(200)]
    stream = bytearray(os.urandom(77))  # 開頭故意塞垃圾測試同步
    for i, m in enumerate(msgs):
        stream += mux.packetize(MsgType.REPORT, i, m)
        stream += NULL_PACKET * random.randint(0, 3)
    pos = 0
    while pos < len(stream):  # 隨機切塊餵入
        n = random.randint(1, 3000)
        demux.feed(bytes(stream[pos:pos + n]))
        pos += n
    assert [p for _, _, p in got] == msgs, "無損情況重組失敗"
    print(f"無損：{len(got)}/{len(msgs)} 則正確")

    # 掉包：隨機刪掉 TS 封包，受影響的訊息必須被丟棄、其餘必須正確
    got.clear()
    demux = TsDemuxer(0x100, lambda t, i, f, p: got.append((t, i, p)))
    mux = TsMuxer(0x100)
    pkts = []
    for i, m in enumerate(msgs):
        data = mux.packetize(MsgType.REPORT, i, m)
        pkts += [data[k:k + TS_SIZE] for k in range(0, len(data), TS_SIZE)]
    kept = [p for p in pkts if random.random() > 0.01]
    demux.feed(b"".join(kept))
    ok = all(p == msgs[i] for _, i, p in got)
    assert ok, "掉包後收到錯誤資料"
    print(f"1% 掉包：收到 {len(got)}/{len(msgs)} 則，全部內容正確；統計 {demux.stats}")

    meta = {"boot": "ab", "seq": 1, "status": "critical", "text": "測試"}
    m2, img = unpack_report(pack_report(meta, b"\xff\xd8jpeg"))
    assert m2 == meta and img == b"\xff\xd8jpeg"
    print("unit 測試通過")


def loopback(cfg_path):
    cfg = yaml.safe_load(open(cfg_path, encoding="utf-8"))["link"]
    cfg["mode"] = "loopback"
    received = {}
    done = threading.Event()
    sent = {}

    def on_msg(mtype, mid, payload):
        received[mid] = (time.time(), payload)
        if len(received) >= len(sent):
            done.set()

    link = Link(cfg, "selftest", on_msg, base_dir=ROOT)
    link.start()
    print("等待 dvbs2-rx 鎖定（約數秒）…")
    time.sleep(8)
    payloads = [b"hello" * 10, os.urandom(2000), pack_report({"status": "critical", "text": "火"}, os.urandom(50_000))]
    for p in payloads:
        mid = link.send(MsgType.REPORT, p)
        sent[mid] = (time.time(), p)
    done.wait(timeout=60)
    link.stop()
    ok = 0
    for mid, (t0, p) in sent.items():
        r = received.get(mid)
        if r and r[1] == p:
            ok += 1
            print(f"  msg {mid}: {len(p):>6} bytes，延遲 {r[0] - t0:.2f} 秒")
        else:
            print(f"  msg {mid}: 沒收到")
    print(f"結果：{ok}/{len(sent)}；鏈路統計 {link.stats()}")
    print("沒收到時請看 logs/dvbs2-tx.log 與 logs/dvbs2-rx.log")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["unit", "loopback"])
    ap.add_argument("--config", default=str(ROOT / "config" / "ground.yaml"))
    a = ap.parse_args()
    unit() if a.what == "unit" else loopback(a.config)
