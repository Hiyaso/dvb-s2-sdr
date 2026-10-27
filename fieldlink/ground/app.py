#!/usr/bin/env python3
"""地面站（電腦）主程式。

- DVB-S2 接收 Jetson 的辨識結果、心跳（含手機清單）、被選手機的縮圖；結果存進 SQLite、嚴重事件影像存檔
- 網頁儀表板 http://localhost:8080 即時顯示狀態、歷史、嚴重事件影像、手機清單與縮圖
- 從網頁選手機 → DVB-S2 上行 SELECT 到 Jetson（沒收到 ACK 自動重送）；輸入文字 → NOTIFY，同樣有 ACK 重送
- 訊息都帶 node id；DVB-S2 時一條鏈路對一台 Jetson（多台要各配一台 USRP）；tcp 模式一個 server 可接多台 Jetson
"""
import argparse
import asyncio
import itertools
import logging
import secrets
import sys
import time
from pathlib import Path

import yaml
from aiohttp import WSMsgType, web

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from common.link import make_link  # noqa: E402
from common.protocol import MsgType, now_iso, pack_json, unpack_json, unpack_report, unpack_thumb  # noqa: E402
from ground.storage import Storage  # noqa: E402

STATIC = Path(__file__).resolve().parent / "static"
log = logging.getLogger("ground")


class GroundStation:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        s = cfg["storage"]
        self.db = Storage(ROOT / s["db"], ROOT / s["images"])
        self.link = make_link(cfg["link"], "ground", self._on_link_thread, base_dir=ROOT)
        self.boot = secrets.token_hex(4)      # Jetson 用 (boot, id) 對 SELECT / NOTIFY 去重
        self.clients = set()
        self.loop = None
        self.hb = None
        self.hb_time = 0.0
        self.link_up = False
        self.pending = {}                     # 通知 id → {"payload", "tries", "next"}
        self.sel_seq = itertools.count(1)
        self.pending_select = None            # {"id", "phone", "payload", "tries", "next", "state"}
        self.phones = []                      # 最近一次心跳裡的手機清單
        self.selected = None                  # Jetson 回報目前選中的手機
        self.settings = {}                    # Jetson 回報目前的縮圖／VLM 設定
        self.thumb = None
        self.thumb_meta = None
        self.thumb_ver = 0
        self.thumbs = 0
        self.ack_id = int(self.db.kv_get("ack_id", 0) or 0)   # 「清空」：這筆 id 以前的報告不再計入儀表板的狀態與 30 分鐘統計
        self.clear_ts = self.db.kv_get("clear_ts", "") or ""     # 最後一次清空的時間

    async def start(self, app):
        self.loop = asyncio.get_running_loop()
        self.link.start()
        # 重啟後把還沒送達的通知標為失敗，避免畫面一直顯示傳送中
        for n in self.db.notifications(200):
            if n["state"] == "sending":
                self.db.update_notification(n["id"], state="failed")
        app["tasks"] = [asyncio.create_task(self._watchdog())]

    async def stop(self, app):
        for t in app.get("tasks", []):
            t.cancel()
        self.link.stop()

    # ---------- link ----------
    def _on_link_thread(self, mtype, mid, payload):
        self.loop.call_soon_threadsafe(self._on_link, mtype, payload)

    def _on_link(self, mtype, payload):
        try:
            if mtype == MsgType.HEARTBEAT:
                self.hb = unpack_json(payload)
                self.hb_time = time.time()
                self.phones = self.hb.get("phones") or []
                self.selected = self.hb.get("selected")
                self.settings = self.hb.get("settings") or self.settings
                if not self.link_up:
                    self.link_up = True
                    ev = self.db.event("link_up", f"node={self.hb.get('node')} boot={self.hb.get('boot')}")
                    log.info("鏈路建立（節點 %s）", self.hb.get("node"))
                    self._emit({"type": "link_event", "event": ev})
                self._emit({"type": "link", "link": self.link_status(), "select": self.select_status()})
            elif mtype == MsgType.REPORT:
                meta, img = unpack_report(payload)
                row = self.db.add_report(meta, img)
                if row:  # None 表示重送的重複資料
                    log.info("[%s] %s｜%s", row["label"], row.get("phone_name") or "", row["text"])
                    self._emit({"type": "report", "report": row})
            elif mtype == MsgType.THUMB:
                meta, img = unpack_thumb(payload)
                if img:
                    self.thumb, self.thumb_meta = img, meta
                    self.thumb_ver += 1
                    self.thumbs += 1
                    self._emit({"type": "thumb", "thumb": self.thumb_status()})
            elif mtype == MsgType.NOTIFY_ACK:
                ack = unpack_json(payload)
                nid = int(ack["id"])
                self.pending.pop(nid, None)
                n = self.db.update_notification(nid, state="delivered", ack_ts=ack.get("ts", now_iso()))
                if n:
                    self._emit({"type": "notify", "notify": n})
            elif mtype == MsgType.SELECT_ACK:
                ack = unpack_json(payload)
                p = self.pending_select
                if p and int(ack.get("id", -1)) == p["id"]:
                    self.selected = ack.get("selected")
                    self.settings = ack.get("settings") or self.settings
                    self.pending_select = None
                    log.info("Jetson 已套用選擇：%s", self.selected or "無")
                    target = (p.get("settings") or {}).get("link")
                    if target and self.link.mode == "multi":
                        if p.get("confirm"):
                            self.link.commit_switch()        # Nano 在新鏈路上回了 ACK → 兩邊都通，停掉舊鏈路
                            ev = self.db.event("link_switch", f"資料鏈路切換到 {target}")
                            self._emit({"type": "link_event", "event": ev})
                            log.info("資料鏈路切換完成：%s", target)
                        elif target != self.link.active and self.link.begin_switch(target):
                            log.info("Nano 接受切換到 %s，本機啟動新鏈路，等它通", target)
                    self._emit({"type": "select", "select": self.select_status()})
        except Exception:
            log.exception("處理訊息失敗 type=%s", mtype)

    @staticmethod
    def modem_summary(m: dict | None) -> dict | None:
        """數據機狀態精簡版（儀表板用）：本機的 RX = 下行，TX = 上行。"""
        if not m:
            return None
        rx, tx = m.get("rx", {}), m.get("tx", {})
        keys_rx = ("on", "lock", "modcod", "pilots", "fll_stage", "cfo_hz", "esn0_db", "ebn0_db", "rssi_db", "level_dbfs",
                   "frames", "misses", "pls_fail", "ldpc_iters", "ldpc_drop", "bch_fail", "bb_ok", "bb_crc",
                   "rate_bps", "capacity_bps", "frames_per_s", "host_overflow", "freq", "rs", "gain", "agc_gain")
        keys_tx = ("on", "freq", "rs", "gain", "frames_sent", "dummy", "duc_underflow", "host_underflow",
                   "rate_bps", "capacity_bps", "host_bps")
        return {"rx": {k: rx.get(k) for k in keys_rx}, "tx": {k: tx.get(k) for k in keys_tx},
                "fpga": m.get("fpga"), "config": m.get("config")}

    def link_status(self) -> dict:
        age = time.time() - self.hb_time if self.hb_time else None
        return {"up": self.link_up, "hb_age_s": None if age is None else round(age, 1),
                "jetson": self.hb, "phones": self.phones, "selected": self.selected, "settings": self.settings,
                "local": self.link.stats(), "modem": self.modem_summary(self.link.modem()),
                "remote_modem": (self.hb or {}).get("modem")}

    def select_status(self) -> dict:
        p = self.pending_select
        if p:
            return {"state": "sending", "phone": p["phone"], "settings": p.get("settings"), "tries": p["tries"],
                    "selected": self.selected, "applied_settings": self.settings}
        return {"state": "applied", "phone": self.selected, "settings": None, "tries": 0,
                "selected": self.selected, "applied_settings": self.settings}

    def thumb_status(self):
        if self.thumb is None:
            return None
        return {"ver": self.thumb_ver, "meta": self.thumb_meta, "count": self.thumbs,
                "url": f"/api/thumb.jpg?v={self.thumb_ver}"}

    async def _watchdog(self):
        n = self.cfg["notify"]
        retry_s, max_tries = float(n.get("retry_s", 6)), int(n.get("max_tries", 5))
        sc = self.cfg.get("select", {})
        sel_retry, sel_max = float(sc.get("retry_s", 3)), int(sc.get("max_tries", 10))
        timeout = float(self.cfg.get("heartbeat_timeout_s", 8))
        while True:
            now = time.time()
            if self.link_up and now - self.hb_time > timeout:
                self.link_up = False
                ev = self.db.event("link_down", f"{timeout:.0f} 秒未收到心跳")
                log.warning("鏈路中斷：%s", ev["detail"])
                self._emit({"type": "link_event", "event": ev})
            for nid, p in list(self.pending.items()):
                if now < p["next"]:
                    continue
                if p["tries"] >= max_tries:
                    self.pending.pop(nid)
                    self._emit({"type": "notify", "notify": self.db.update_notification(nid, state="failed")})
                    continue
                self.link.send(MsgType.NOTIFY, p["payload"], priority=0, via="all")
                p["tries"] += 1
                p["next"] = now + retry_s
                self._emit({"type": "notify", "notify": self.db.update_notification(nid, tries=p["tries"])})
            p = self.pending_select
            if p and now >= p["next"]:
                if p["tries"] >= sel_max:
                    log.warning("選擇手機 %s 沒有收到 Jetson 確認，放棄", p["phone"])
                    self.pending_select = None
                    self._emit({"type": "select", "select": {"state": "failed", "phone": p["phone"],
                                                              "tries": p["tries"], "selected": self.selected}})
                else:
                    self.link.send(MsgType.SELECT, p["payload"], priority=0, via=p.get("via", "all"))
                    p["tries"] += 1
                    p["next"] = now + sel_retry
                    self._emit({"type": "select", "select": self.select_status()})
            # 鏈路交接：新鏈路收到 Nano 的心跳後，經新鏈路送一個確認 SELECT；它的 ACK 回來才停舊鏈路（見 _on_link）
            sw = getattr(self.link, "switching", None)
            if sw and not self.pending_select and not sw.get("confirm_sent") and self.link.rx_on.get(sw["to"], 0) > sw["since"]:
                sw["confirm_sent"] = True
                sid = next(self.sel_seq)
                msg = {"id": sid, "boot": self.boot, "ts": now_iso(), "settings": {"link": sw["to"]}}
                self.pending_select = {"id": sid, "phone": self.selected, "settings": msg["settings"], "tries": 0, "next": 0.0,
                                       "state": "sending", "payload": pack_json(msg), "via": sw["to"], "confirm": True}
                log.info("新鏈路 %s 已收到 Nano 心跳，經它送確認 SELECT #%d", sw["to"], sid)
            elif not sw and self.pending_select and self.pending_select.get("confirm"):
                self.pending_select = None           # 交接已放棄（timeout），確認訊息不必再送
            self._emit({"type": "link", "link": self.link_status(), "select": self.select_status()})
            sp = self.link.spectrum()
            if sp and sp.get("db"):
                self._emit({"type": "spectrum", "spectrum": sp})
            await asyncio.sleep(1)

    # ---------- websocket to dashboard ----------
    def _emit(self, event):
        asyncio.ensure_future(self._broadcast(event))

    async def _broadcast(self, event):
        for ws in list(self.clients):
            try:
                await ws.send_json(event)
            except Exception:
                self.clients.discard(ws)

    async def ws_handler(self, request):
        ws = web.WebSocketResponse(heartbeat=10)
        await ws.prepare(request)
        self.clients.add(ws)
        await ws.send_json({"type": "hello", "reports": self.db.reports(500), "counts": self.db.counts(),
                            "notifications": self.db.notifications(50), "link": self.link_status(),
                            "select": self.select_status(), "thumb": self.thumb_status(),
                            "spectrum": self.link.spectrum(), "ack_id": self.ack_id, "clear_ts": self.clear_ts,
                            "interval_s": self.cfg.get("expected_interval_s", 5)})
        try:
            async for msg in ws:
                if msg.type == WSMsgType.ERROR:
                    break
        finally:
            self.clients.discard(ws)
        return ws

    # ---------- REST ----------
    async def post_notify(self, request):
        body = await request.json()
        text = str(body.get("text", "")).strip()
        if not text:
            return web.json_response({"error": "通知內容是空的"}, status=400)
        if len(text) > 200:
            return web.json_response({"error": "通知最多 200 字"}, status=400)
        n = self.db.add_notification(text)
        payload = pack_json({"id": n["id"], "boot": self.boot, "ts": n["created_ts"], "text": text})
        self.pending[n["id"]] = {"payload": payload, "tries": 0, "next": 0.0}
        self._emit({"type": "notify", "notify": n})
        return web.json_response(n)

    async def post_select(self, request):
        """選擇要看縮圖的手機（phone = null 取消），和／或調整 settings（thumb_fps、thumb_max_side、vlm_max_side）。
        送 SELECT 給 Jetson，沒收到 ACK 由 watchdog 重送。沒給 phone 就只改設定。"""
        body = await request.json()
        msg = {"id": 0, "boot": self.boot, "ts": now_iso()}
        phone = self.selected
        if "phone" in body:
            phone = str(body["phone"]).strip()[:32] if body.get("phone") else None
            msg["phone"] = phone
        settings = body.get("settings")
        if isinstance(settings, dict) and settings:
            msg["settings"] = {k: settings[k] for k in ("detect", "thumb_fps", "thumb_max_side", "vlm_max_side") if k in settings}
            if settings.get("link") in ("tcp", "fpga") and self.link.mode == "multi":
                if getattr(self.link, "switching", None):
                    return web.json_response({"error": "正在切換鏈路，請等它完成"}, status=409)
                msg["settings"]["link"] = settings["link"]   # 切換資料鏈路：Nano ACK 後本機啟動新鏈路，新鏈路通了再停舊的
        if "phone" not in msg and not msg.get("settings"):
            return web.json_response({"error": "沒有要改的東西"}, status=400)
        sid = next(self.sel_seq)
        msg["id"] = sid
        self.pending_select = {"id": sid, "phone": phone, "settings": msg.get("settings"), "tries": 0, "next": 0.0,
                               "state": "sending", "payload": pack_json(msg)}
        log.info("SELECT #%d：手機 %s，設定 %s", sid, phone or "無", msg.get("settings") or "不變")
        self._emit({"type": "select", "select": self.select_status()})
        return web.json_response(self.select_status())

    async def post_ack(self, request):
        """清空：目前為止的報告不再計入儀表板（狀態橫幅、目前狀態、最近 30 分鐘統計與時間軸都歸零）；
        紀錄表與資料庫不刪，之後只累計新進來的報告。"""
        latest = self.db.reports(1)
        self.ack_id = int(latest[0]["id"]) if latest else 0
        self.clear_ts = now_iso()
        self.db.kv_set("ack_id", self.ack_id)
        self.db.kv_set("clear_ts", self.clear_ts)
        ev = self.db.event("clear", f"清空儀表板統計，至報告 #{self.ack_id}")
        log.info("清空儀表板統計（至報告 #%d）", self.ack_id)
        self._emit({"type": "ack", "ack_id": self.ack_id, "clear_ts": self.clear_ts, "event": ev})
        return web.json_response({"ack_id": self.ack_id, "clear_ts": self.clear_ts})

    async def get_thumb(self, request):
        if self.thumb is None:
            return web.Response(status=204)
        return web.Response(body=self.thumb, content_type="image/jpeg",
                            headers={"Cache-Control": "no-store"})

    async def get_reports(self, request):
        q = request.query
        return web.json_response(self.db.reports(min(int(q.get("limit", 200)), 2000),
                                                 q.get("status") or None,
                                                 int(q["before"]) if q.get("before") else None,
                                                 q.get("phone") or None))

    async def export_csv(self, request):
        return web.Response(body=self.db.export_csv(), content_type="text/csv",
                            headers={"Content-Disposition": 'attachment; filename="reports.csv"'})


def build_app(gs: GroundStation) -> web.Application:
    app = web.Application()
    app.on_startup.append(gs.start)
    app.on_cleanup.append(gs.stop)

    async def index(request):
        return web.FileResponse(STATIC / "index.html")

    app.router.add_get("/", index)
    app.router.add_get("/ws", gs.ws_handler)
    app.router.add_post("/api/notify", gs.post_notify)
    app.router.add_post("/api/select", gs.post_select)
    app.router.add_post("/api/ack", gs.post_ack)
    app.router.add_get("/api/thumb.jpg", gs.get_thumb)
    app.router.add_get("/api/reports", gs.get_reports)
    app.router.add_get("/api/export.csv", gs.export_csv)
    app.router.add_static("/images", gs.db.image_dir)
    return app


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default=str(ROOT / "config" / "ground.yaml"))
    p.add_argument("--link-mode", help="覆寫 link.mode（tcp / fpga / udp / dvbs2 / loopback）")
    a = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = yaml.safe_load(open(a.config, encoding="utf-8"))
    if a.link_mode:
        cfg["link"]["mode"] = a.link_mode
    gs = GroundStation(cfg)
    w = cfg["web"]
    log.info("儀表板：http://localhost:%s", w["port"])
    web.run_app(build_app(gs), host=w["host"], port=int(w["port"]), print=None)


if __name__ == "__main__":
    main()
