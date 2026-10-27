#!/usr/bin/env python3
"""Jetson Orin Nano 端主程式（現場節點）。

- HTTPS 網頁：手機開 /camera 當 webcam 上傳影像（多支手機各有 id 與名稱）；Jetson 螢幕開 /monitor 看畫面與通知
- 每 interval_s 秒輪流取一支有新影格的手機 → YOLO + VLM → 狀態 + 描述 → DVB-S2 下行（REPORT）
- 被地面站選中的手機持續回傳縮圖（THUMB，低優先權）；地面站的 SELECT 會回 SELECT_ACK
- 收到地面站的通知（NOTIFY）→ 顯示在 /monitor、手機畫面與桌面通知 → 回 NOTIFY_ACK
- 所有送出的訊息都帶 node.id，地面站用來區分多台 Jetson
"""
import argparse
import asyncio
import concurrent.futures
import json
import logging
import secrets
import shutil
import ssl
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import aiohttp
import yaml
from aiohttp import WSMsgType, web

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from common.link import make_link  # noqa: E402
from common.protocol import (STATUS_LABELS, MsgType, now_iso, pack_json, pack_report,  # noqa: E402
                             pack_thumb, unpack_json)
from jetson import fusion  # noqa: E402
from jetson.camera import PhoneRegistry, UrlGrabber, shrink_jpeg  # noqa: E402
from jetson.vlm import VlmClient  # noqa: E402

STATIC = Path(__file__).resolve().parent / "static"
log = logging.getLogger("jetson")


def iso_from_ts(ts: float) -> str:
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="milliseconds")


class JetsonNode:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        node = cfg.get("node") or {}
        self.node_id = str(node.get("id", "nano1"))
        self.node_name = str(node.get("name", self.node_id))
        cam = cfg["camera"]
        self.phones = PhoneRegistry(float(cam.get("stale_after_s", 3)), float(cam.get("phones_offline_s", 60)))
        self.selected = None                      # 地面站（或本機）選中的手機 id
        self.seen_select = set()                  # (地面站 boot, SELECT id)，去重
        self.boot = secrets.token_hex(4)          # 每次開機不同，地面站用 (node, boot, seq) 去重
        self.seq = 0
        self.thumb_seq = 0
        self.thumbs_sent = 0
        self.busy = False
        self.skipped = 0
        self.reports_sent = 0
        self.last_result = None                   # 最新一筆（任一手機）
        self.last_results = {}                    # 手機 id → 最新一筆
        self.last_error = None
        self.notifications = []
        self.seen_notify = set()
        self.clients = {}                         # ws → {"role", "phone"}
        self.started = time.time()
        self.loop = None
        self.http = None
        self.vlm = None
        self.detector = None
        self.yolo_state = "disabled"
        # YOLO 專用單執行緒：模型載入與推論在同一條執行緒，CUDA context 不跨執行緒
        self.yolo_exec = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="yolo")
        self.link = make_link(cfg["link"], "jetson", self._on_link_thread, base_dir=ROOT, auto_commit=True)
        self.data_dir = ROOT / "data" / "jetson"
        (self.data_dir / "images").mkdir(parents=True, exist_ok=True)
        self.report_log = open(self.data_dir / "reports.jsonl", "a", encoding="utf-8")

    # ---------- lifecycle ----------
    async def start(self, app):
        self.loop = asyncio.get_running_loop()
        self.http = aiohttp.ClientSession()
        self.vlm = VlmClient(self.cfg["vlm"], self.http)
        self.link.start()
        src = self.cfg["camera"]["source"]
        if src != "browser":
            # 網址來源當成一支永遠在線的手機
            ph = self.phones.attach("url", "網址來源")
            self.selected = ph.id
            UrlGrabber(src, ph.store, float(self.cfg["camera"].get("phone_fps", 4))).start()
        app["tasks"] = [asyncio.create_task(t) for t in
                        (self._warmup(), self._capture_loop(), self._heartbeat_loop(), self._thumb_loop())]

    async def stop(self, app):
        for t in app.get("tasks", []):
            t.cancel()
        self.link.stop()
        await self.http.close()
        self.report_log.close()

    async def _warmup(self):
        ycfg = self.cfg.get("yolo", {})
        if ycfg.get("enabled", True):
            self.yolo_state = "loading"
            try:
                from jetson.detector import YoloDetector
                self.detector = await self.loop.run_in_executor(self.yolo_exec, YoloDetector, ycfg, ROOT)
                self.yolo_state = "ready"
            except Exception as e:
                self.yolo_state = "error"
                self.last_error = f"YOLO 載入失敗，改為只用 VLM：{e}"
                log.error(self.last_error)
        for attempt in range(1, 4):      # Ollama 可能還在開機或在載入模型：最多試 3 次
            try:
                await self.vlm.warmup()
                if (self.last_error or "").startswith("VLM 載入失敗"):
                    self.last_error = None
                break
            except Exception as e:
                self.last_error = f"VLM 載入失敗：{e or type(e).__name__}"
                log.error("%s（第 %d 次）", self.last_error, attempt)
                await asyncio.sleep(10)

    # ---------- capture + YOLO + VLM（多支手機輪流） ----------
    async def _capture_loop(self):
        interval = float(self.cfg["capture"]["interval_s"])
        next_t = self.loop.time()
        while True:
            next_t += interval
            self.phones.prune()
            if self.selected and not self.phones.get(self.selected):
                self.selected = None
            cands = self.phones.fresh()
            if not int(self.cfg["capture"].get("detect", 1)):
                log.debug("偵測已停止（地面站尚未按開始），略過本次截圖")
            elif not cands:
                log.debug("沒有任何手機有新影格，略過本次截圖")
            elif self.busy:
                self.skipped += 1
                log.warning("上一張還在推論（>%ss），略過本次；可考慮換小模型或降低 vlm_max_side", interval)
            else:
                ph = cands[0]                      # 最久沒被辨識的那支
                jpeg, ts = ph.store.get()
                ph.last_processed = time.time()
                asyncio.create_task(self._process(ph, jpeg, ts))
            await asyncio.sleep(max(0.0, next_t - self.loop.time()))

    async def _process(self, ph, jpeg: bytes, ts: float):
        c = self.cfg["capture"]
        fcfg = self.cfg.get("fusion", {})
        self.busy = True
        dets, yolo_ms, vlm_err = None, None, None
        try:
            small = await self.loop.run_in_executor(None, shrink_jpeg, jpeg, int(c["vlm_max_side"]), 85)
            # 1) YOLO：毫秒等級，先跑
            if self.detector:
                t = time.time()
                try:
                    dets = await self.loop.run_in_executor(self.yolo_exec, self.detector.detect, jpeg)
                    yolo_ms = int((time.time() - t) * 1000)
                except Exception as e:
                    log.error("YOLO 推論失敗：%s", e)
            yolo_status, reasons = fusion.apply_rules(dets, fcfg.get("rules") or [])
            # 2) VLM：帶著 YOLO 的偵測結果一起判讀
            try:
                ctx = fusion.prompt_context(dets) if fcfg.get("yolo_to_vlm", True) else ""
                res = await self.vlm.classify(small, ctx)
                self.last_error = None
            except Exception as e:
                vlm_err = f"VLM 推論失敗：{e}"
                self.last_error = vlm_err
                log.error(vlm_err)
                await self.broadcast({"type": "error", "message": vlm_err})
                # VLM 掛掉時，YOLO 規則有觸發仍要回報，不能因為 VLM 失效就漏掉事件
                if yolo_status == "normal":
                    return
                res = {"status": "normal", "latency_ms": None,
                       "text": "（VLM 無回應，僅依 YOLO 規則判定）" + "；".join(reasons)}
        finally:
            self.busy = False

        status = fusion.fuse(res["status"], yolo_status, fcfg.get("mode", "max"))
        self.seq += 1
        ph.reports += 1
        meta = {"node": self.node_id, "node_name": self.node_name, "boot": self.boot, "seq": self.seq,
                "phone": ph.id, "phone_name": ph.name, "ts": iso_from_ts(ts),
                "status": status, "label": STATUS_LABELS[status], "text": res["text"],
                "vlm_status": None if vlm_err else res["status"], "yolo_status": yolo_status,
                "escalated_by": "yolo" if fusion.LEVEL[status] > fusion.LEVEL[res["status"]] else None,
                "reasons": reasons, "detections": fusion.summarize(dets or []),
                "latency_ms": res["latency_ms"], "yolo_ms": yolo_ms, "model": self.vlm.model,
                "yolo_model": self.detector.model_name if self.detector else None}
        img = None
        if status in c.get("image_on", ["critical"]):
            def make_image():
                im = shrink_jpeg(jpeg, int(c["image_max_side"]), 92)
                if dets and fcfg.get("draw_boxes", True):
                    im = fusion.draw_boxes(im, dets, status, 92)
                return shrink_jpeg(im, int(c["image_max_side"]), int(c["image_quality"]), int(c.get("image_max_kb", 0)))
            img = await self.loop.run_in_executor(None, make_image)
            meta["image_bytes"] = len(img)
            name = f"{self.boot}_{self.seq:06d}.jpg"
            (self.data_dir / "images" / name).write_bytes(img)
            meta_local = dict(meta, image=name)
        else:
            meta_local = meta

        payload = pack_report(meta, img)
        # 單向 DVB-S2 鏈路靠重送提高送達率；TCP（OneWeb）本身可靠就不重送
        repeat = int(c.get("critical_repeat", 1)) if status == "critical" and not self.link.reliable else 1
        for _ in range(max(1, repeat)):
            self.link.send(MsgType.REPORT, payload, priority=0)
        self.reports_sent += 1
        self.last_result = meta_local
        self.last_results[ph.id] = meta_local
        self.report_log.write(json.dumps(meta_local, ensure_ascii=False) + "\n")
        self.report_log.flush()
        log.info("[%s] %s｜%s｜YOLO %s%s（VLM %s ms，YOLO %s ms）", meta["label"], ph.name, meta["text"],
                 fusion.summary_text(dets or []), "，由 YOLO 規則升級" if meta["escalated_by"] else "",
                 meta["latency_ms"], yolo_ms)
        await self.broadcast({"type": "result", "result": meta_local})

    # ---------- 執行期可調的參數（地面站 SELECT 帶 settings，或本機 /api/select） ----------
    SETTINGS = {  # 名稱: (最小, 最大, 型別)
        "detect": (0, 1, int),                 # 1 = 對影像做 YOLO＋VLM 辨識；0 = 只收畫面、送縮圖，不辨識
        "thumb_fps": (0.0, 5.0, float),        # 0 = 不送縮圖
        "thumb_max_side": (160, 960, int),
        "vlm_max_side": (224, 1024, int),
    }

    def settings(self) -> dict:
        c = self.cfg["capture"]
        d = {k: typ(c.get(k)) for k, (_, _, typ) in self.SETTINGS.items() if c.get(k) is not None}
        if self.link.mode == "multi":
            d["link"] = self.link.active          # 資料走哪條鏈路（tcp = OneWeb，fpga = USRP），儀表板可切換
        return d

    def apply_settings(self, new: dict, source: str) -> bool:
        """只接受認得的鍵、夾在範圍內；回傳是否有變更。"""
        changed = False
        for k, (lo, hi, typ) in self.SETTINGS.items():
            if k not in (new or {}):
                continue
            try:
                v = typ(min(max(typ(new[k]), lo), hi))
            except (TypeError, ValueError):
                continue
            if self.cfg["capture"].get(k) != v:
                self.cfg["capture"][k] = v
                changed = True
        if "link" in (new or {}) and self.link.mode == "multi":
            # 切換資料鏈路：先啟動新的，地面站在新鏈路上說話後才停舊的（common/link.py MultiLink）
            if self.link.begin_switch(str(new["link"])):
                changed = True
        if changed:
            log.info("套用設定：%s（%s）", self.settings(), source)
            asyncio.ensure_future(self.broadcast({"type": "state", "state": self.state()}))
        return changed

    # ---------- 縮圖：被選中的手機 ----------
    async def _thumb_loop(self):
        c = self.cfg["capture"]
        last_ts = 0.0
        while True:
            fps = float(c.get("thumb_fps", 1))         # 每圈重讀，地面站可隨時調整
            if fps <= 0:
                await asyncio.sleep(1.0)
                continue
            await asyncio.sleep(1.0 / fps)
            side, quality, max_kb = int(c.get("thumb_max_side", 320)), int(c.get("thumb_quality", 60)), int(c.get("thumb_max_kb", 60))
            ph = self.phones.get(self.selected)
            if not ph:
                continue
            jpeg, ts = ph.store.get()
            if jpeg is None or ts == last_ts:
                continue                           # 沒有新影格就不重送
            if self.link.stats().get("queue", 0) > 8:
                continue                           # 鏈路排隊中：縮圖可丟，讓報告先走
            last_ts = ts
            small = await self.loop.run_in_executor(None, shrink_jpeg, jpeg, side, quality, max_kb)
            self.thumb_seq += 1
            meta = {"node": self.node_id, "phone": ph.id, "phone_name": ph.name, "seq": self.thumb_seq,
                    "ts": iso_from_ts(ts), "bytes": len(small)}
            if self.link.send(MsgType.THUMB, pack_thumb(meta, small), priority=1) is not None:
                self.thumbs_sent += 1

    def apply_select(self, phone_id, source: str):
        """phone_id = None 表示取消；手機還沒連上也可以先選。"""
        if phone_id is not None and not PhoneRegistry.valid_id(str(phone_id)):
            return False
        self.selected = str(phone_id) if phone_id else None
        ph = self.phones.get(self.selected)
        log.info("選擇手機：%s（%s）", ph.name if ph else (self.selected or "無"), source)
        asyncio.ensure_future(self.broadcast({"type": "state", "state": self.state()}))
        return True

    # ---------- link ----------
    def _on_link_thread(self, mtype, mid, payload):
        self.loop.call_soon_threadsafe(self._on_link, mtype, payload)

    def _on_link(self, mtype, payload):
        try:
            if mtype == MsgType.NOTIFY:
                self._on_notify(unpack_json(payload))
            elif mtype == MsgType.SELECT:
                self._on_select(unpack_json(payload))
        except Exception:
            log.warning("收到無法解析的訊息 type=%s", mtype)

    def _for_me(self, msg: dict) -> bool:
        target = msg.get("node")
        return target in (None, "", "*", self.node_id)

    def _on_notify(self, n: dict):
        if not self._for_me(n):
            return
        nid = int(n["id"])
        key = (n.get("boot"), nid)
        # 地面站會重送直到收到 ACK，所以重複的通知只回 ACK 不重複顯示
        self.link.send(MsgType.NOTIFY_ACK, pack_json({"id": nid, "node": self.node_id, "ts": now_iso()}), priority=0, via="all")
        if key in self.seen_notify:
            return
        self.seen_notify.add(key)
        n["received"] = now_iso()
        self.notifications.append(n)
        del self.notifications[:-int(self.cfg["notify"].get("keep", 50))]
        log.info("收到通知 #%s：%s", nid, n.get("text"))
        asyncio.ensure_future(self.broadcast({"type": "notify", "notify": n}))
        if self.cfg["notify"].get("desktop") and shutil.which("notify-send"):
            try:
                subprocess.Popen(["notify-send", "-u", "critical", "地面站通知", str(n.get("text", ""))])
            except OSError:
                pass

    def _on_select(self, s: dict):
        if not self._for_me(s):
            return
        sid = int(s["id"])
        key = (s.get("boot"), sid)
        if key not in self.seen_select:
            self.seen_select.add(key)
            if "phone" in s:
                self.apply_select(s.get("phone"), "地面站")
            if s.get("settings"):
                self.apply_settings(s["settings"], "地面站")
        self.link.send(MsgType.SELECT_ACK, pack_json({"id": sid, "node": self.node_id, "selected": self.selected,
                                                      "settings": self.settings(), "ts": now_iso()}), priority=0, via="all")

    def modem_brief(self) -> dict | None:
        """本機數據機的接收（= 上行）品質與發射狀態，放進心跳給地面站看。"""
        m = self.link.modem()
        if not m:
            return None
        rx, tx = m.get("rx", {}), m.get("tx", {})
        return {"rx": {k: rx.get(k) for k in ("lock", "modcod", "cfo_hz", "esn0_db", "level_dbfs", "misses", "bb_crc",
                                              "ldpc_iters", "host_overflow", "rate_bps")},
                "tx": {k: tx.get(k) for k in ("frames_sent", "dummy", "host_underflow", "rate_bps", "capacity_bps")}}

    def state(self) -> dict:
        phones = self.phones.summary(self.selected)
        fresh = [p for p in phones if p["fresh"]]
        return {"node": self.node_id, "node_name": self.node_name, "boot": self.boot, "t": now_iso(),
                "uptime_s": int(time.time() - self.started),
                "cam_ok": bool(fresh), "phones": phones, "selected": self.selected, "settings": self.settings(),
                "vlm_model": self.cfg["vlm"]["model"], "vlm_busy": self.busy,
                "yolo_model": self.detector.model_name if self.detector else None, "yolo_state": self.yolo_state,
                "last_error": self.last_error, "reports": self.reports_sent, "skipped": self.skipped,
                "thumbs": self.thumbs_sent, "modem": self.modem_brief(),
                "link": self.link_brief()}

    def link_brief(self) -> dict:
        """鏈路狀態精簡版（心跳與 /api/state 用）；multi 模式含每條子鏈路。"""
        st = self.link.stats()
        keys = ("mode", "state", "messages", "crc_errors", "cc_errors", "restarts", "queue",
                "transport", "connected", "peer", "since", "rtt_ms", "retrans",
                "active", "switching", "last_switch", "last_rx", "rx_by", "tx_by")
        out = {k: v for k, v in st.items() if k in keys}
        if st.get("links"):
            out["links"] = {n: {k: v for k, v in sub.items()
                                if k in ("mode", "state", "running", "ready", "connected", "peer", "rtt_ms", "retrans", "restarts", "messages")}
                            for n, sub in st["links"].items()}
        return out

    async def _heartbeat_loop(self):
        period = float(self.cfg.get("heartbeat_s", 2))
        while True:
            s = self.state()
            self.link.send(MsgType.HEARTBEAT, pack_json(s), priority=1, via="all")   # multi：每條可用鏈路都送，地面站才知道兩條都活著
            await self.broadcast({"type": "state", "state": s})
            await asyncio.sleep(period)

    async def broadcast(self, event: dict):
        for ws in list(self.clients):
            try:
                await ws.send_json(event)
            except Exception:
                self.clients.pop(ws, None)

    # ---------- web ----------
    async def ws_handler(self, request):
        ws = web.WebSocketResponse(max_msg_size=8 * 1024 * 1024, heartbeat=10)
        await ws.prepare(request)
        role = request.query.get("role", "monitor")
        phone = None
        if role == "phone":
            pid = request.query.get("id", "")
            if not PhoneRegistry.valid_id(pid):
                await ws.send_json({"type": "error", "message": "手機 id 不合法"})
                await ws.close()
                return ws
            phone = self.phones.attach(pid, request.query.get("name", ""))
            if self.selected is None:
                self.apply_select(phone.id, "自動（第一支連上的手機）")
        self.clients[ws] = {"role": role, "phone": phone.id if phone else None}
        hello = {"type": "hello", "state": self.state(), "result": self.last_result,
                 "results": self.last_results, "notifications": self.notifications}
        if phone:
            hello["phone"] = {"id": phone.id, "name": phone.name}
            hello["result"] = self.last_results.get(phone.id)
        await ws.send_json(hello)
        try:
            async for msg in ws:
                if msg.type == WSMsgType.BINARY and phone:
                    if self.cfg["camera"]["source"] == "browser" and msg.data[:2] == b"\xff\xd8":
                        self.phones.update(phone.id, msg.data)
                elif msg.type == WSMsgType.ERROR:
                    break
        finally:
            self.clients.pop(ws, None)
            if phone:
                self.phones.detach(phone.id)
        return ws

    async def frame(self, request):
        pid = request.query.get("phone") or self.selected
        ph = self.phones.get(pid)
        if ph is None:
            cands = self.phones.fresh()
            ph = cands[0] if cands else None
        jpeg = ph.store.get()[0] if ph else None
        if jpeg is None:
            return web.Response(status=204)
        return web.Response(body=jpeg, content_type="image/jpeg",
                            headers={"Cache-Control": "no-store", "X-Phone": ph.id})

    async def config(self, request):
        c = self.cfg["camera"]
        return web.json_response({"phone_fps": c.get("phone_fps", 4), "phone_max_width": c.get("phone_max_width", 960),
                                  "interval_s": self.cfg["capture"]["interval_s"],
                                  "source": c["source"], "node": self.node_id, "node_name": self.node_name})

    async def select(self, request):
        body = await request.json()
        if "phone" in body and not self.apply_select(body.get("phone"), "本機監控頁"):
            return web.json_response({"error": "手機 id 不合法"}, status=400)
        if body.get("settings"):
            self.apply_settings(body["settings"], "本機監控頁")
        return web.json_response({"selected": self.selected, "settings": self.settings()})

    async def local_image(self, request):
        name = request.match_info["name"]
        path = (self.data_dir / "images" / name).resolve()
        if path.parent != (self.data_dir / "images").resolve() or not path.exists():
            raise web.HTTPNotFound()
        return web.FileResponse(path)


def build_app(node: JetsonNode) -> web.Application:
    app = web.Application(client_max_size=8 * 1024 * 1024)
    app.on_startup.append(node.start)
    app.on_cleanup.append(node.stop)

    async def index(request):
        raise web.HTTPFound("/camera")

    async def page(request):
        return web.FileResponse(STATIC / f"{request.match_info['page']}.html")

    async def state(request):
        return web.json_response(node.state())

    app.router.add_get("/", index)
    app.router.add_get("/{page:camera|monitor}", page)
    app.router.add_get("/ws", node.ws_handler)
    app.router.add_get("/api/frame.jpg", node.frame)
    app.router.add_get("/api/config", node.config)
    app.router.add_get("/api/state", state)
    app.router.add_post("/api/select", node.select)
    app.router.add_get("/images/{name}", node.local_image)
    return app


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default=str(ROOT / "config" / "jetson.yaml"))
    p.add_argument("--link-mode", help="覆寫 link.mode（tcp / fpga / udp / dvbs2 / loopback）")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = yaml.safe_load(open(a.config, encoding="utf-8"))
    if a.link_mode:
        cfg["link"]["mode"] = a.link_mode

    w = cfg["web"]
    ssl_ctx = None
    cert, key = ROOT / w["cert"], ROOT / w["key"]
    if cert.exists() and key.exists():
        ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(cert, key)
    else:
        log.warning("找不到憑證，改用 HTTP；手機瀏覽器將無法開相機。請先執行 jetson/gen_cert.sh")

    node = JetsonNode(cfg)
    scheme = "https" if ssl_ctx else "http"
    log.info("節點 %s（%s）。手機請開 %s://10.42.0.1:%s/camera ；Jetson 螢幕請開 %s://localhost:%s/monitor",
             node.node_id, node.node_name, scheme, w["port"], scheme, w["port"])
    web.run_app(build_app(node), host=w["host"], port=int(w["port"]), ssl_context=ssl_ctx, print=None)


if __name__ == "__main__":
    main()
