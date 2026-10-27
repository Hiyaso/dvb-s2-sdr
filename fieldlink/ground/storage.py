"""地面站資料保存：SQLite（辨識結果、通知、鏈路事件）＋ 影像檔。"""
import csv
import io
import json
import sqlite3
import threading
from pathlib import Path

from common.protocol import STATUS_LABELS, now_iso

SCHEMA = """
CREATE TABLE IF NOT EXISTS reports (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    boot        TEXT NOT NULL,
    seq         INTEGER NOT NULL,
    device_ts   TEXT,          -- Jetson 截圖時間
    recv_ts     TEXT NOT NULL, -- 地面站收到時間
    status      TEXT NOT NULL,
    text        TEXT,
    model       TEXT,
    latency_ms  INTEGER,
    image       TEXT,          -- 相對於 images 目錄的路徑
    UNIQUE (boot, seq)
);
CREATE INDEX IF NOT EXISTS idx_reports_status ON reports(status);
CREATE TABLE IF NOT EXISTS notifications (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_ts  TEXT NOT NULL,
    text        TEXT NOT NULL,
    state       TEXT NOT NULL DEFAULT 'sending',   -- sending / delivered / failed
    tries       INTEGER NOT NULL DEFAULT 0,
    ack_ts      TEXT
);
CREATE TABLE IF NOT EXISTS kv (
    k       TEXT PRIMARY KEY,
    v       TEXT
);
CREATE TABLE IF NOT EXISTS link_events (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts      TEXT NOT NULL,
    event   TEXT NOT NULL,
    detail  TEXT
);
"""


class Storage:
    def __init__(self, db_path: Path, image_dir: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        image_dir.mkdir(parents=True, exist_ok=True)
        self.image_dir = image_dir
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self._migrate()
        self.lock = threading.Lock()

    # YOLO + VLM 融合後新增的欄位；舊資料庫自動補欄位
    EXTRA_COLS = {"vlm_status": "TEXT", "yolo_status": "TEXT", "escalated_by": "TEXT",
                  "reasons": "TEXT", "detections": "TEXT", "yolo_ms": "INTEGER", "yolo_model": "TEXT",
                  "node": "TEXT", "node_name": "TEXT", "phone": "TEXT", "phone_name": "TEXT"}

    def _migrate(self):
        have = {r["name"] for r in self.db.execute("PRAGMA table_info(reports)")}
        for col, typ in self.EXTRA_COLS.items():
            if col not in have:
                self.db.execute(f"ALTER TABLE reports ADD COLUMN {col} {typ}")
        self.db.commit()

    # ---------- reports ----------
    @staticmethod
    def _report(row) -> dict:
        d = dict(row)
        d["label"] = STATUS_LABELS.get(d["status"], d["status"])
        d["image_url"] = f"/images/{d['image']}" if d.get("image") else None
        for k in ("reasons", "detections"):
            d[k] = json.loads(d[k]) if d.get(k) else []
        return d

    @staticmethod
    def _boot_key(meta: dict) -> str:
        """UNIQUE (boot, seq) 去重用；多台 Jetson 時把節點 id 併進去。"""
        node = meta.get("node")
        return f"{node}:{meta.get('boot')}" if node else str(meta.get("boot"))

    def add_report(self, meta: dict, jpeg) -> dict | None:
        """寫入一筆辨識結果；(node, boot, seq) 重複（例如嚴重事件重送）時回傳 None。"""
        with self.lock:
            try:
                cur = self.db.execute(
                    "INSERT INTO reports (boot, seq, device_ts, recv_ts, status, text, model, latency_ms,"
                    " vlm_status, yolo_status, escalated_by, reasons, detections, yolo_ms, yolo_model,"
                    " node, node_name, phone, phone_name)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (self._boot_key(meta), int(meta.get("seq", 0)), meta.get("ts"), now_iso(),
                     meta.get("status", "warning"), meta.get("text", ""), meta.get("model"),
                     meta.get("latency_ms"), meta.get("vlm_status"), meta.get("yolo_status"),
                     meta.get("escalated_by"), json.dumps(meta.get("reasons") or [], ensure_ascii=False),
                     json.dumps(meta.get("detections") or [], ensure_ascii=False),
                     meta.get("yolo_ms"), meta.get("yolo_model"),
                     meta.get("node"), meta.get("node_name"), meta.get("phone"), meta.get("phone_name")))
            except sqlite3.IntegrityError:
                return None
            rid = cur.lastrowid
            if jpeg:
                day = (meta.get("ts") or now_iso())[:10].replace("-", "")
                rel = f"{day}/{self._boot_key(meta).replace(':', '_')}_{int(meta.get('seq', 0)):06d}.jpg"
                path = self.image_dir / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(jpeg)
                self.db.execute("UPDATE reports SET image=? WHERE id=?", (rel, rid))
            self.db.commit()
            return self._report(self.db.execute("SELECT * FROM reports WHERE id=?", (rid,)).fetchone())

    def reports(self, limit: int = 200, status: str | None = None, before_id: int | None = None,
                phone: str | None = None) -> list:
        q, args = "SELECT * FROM reports WHERE 1=1", []
        if status:
            q += " AND status=?"
            args.append(status)
        if phone:
            q += " AND phone=?"
            args.append(phone)
        if before_id:
            q += " AND id<?"
            args.append(before_id)
        q += " ORDER BY id DESC LIMIT ?"
        args.append(limit)
        with self.lock:
            return [self._report(r) for r in self.db.execute(q, args)]

    def counts(self) -> dict:
        with self.lock:
            rows = self.db.execute("SELECT status, COUNT(*) n FROM reports GROUP BY status").fetchall()
        return {r["status"]: r["n"] for r in rows}

    # ---------- notifications ----------
    def add_notification(self, text: str) -> dict:
        with self.lock:
            cur = self.db.execute("INSERT INTO notifications (created_ts, text) VALUES (?,?)", (now_iso(), text))
            self.db.commit()
            return dict(self.db.execute("SELECT * FROM notifications WHERE id=?", (cur.lastrowid,)).fetchone())

    def update_notification(self, nid: int, **fields) -> dict | None:
        if fields:
            cols = ", ".join(f"{k}=?" for k in fields)
            with self.lock:
                self.db.execute(f"UPDATE notifications SET {cols} WHERE id=?", (*fields.values(), nid))
                self.db.commit()
        with self.lock:
            row = self.db.execute("SELECT * FROM notifications WHERE id=?", (nid,)).fetchone()
        return dict(row) if row else None

    def notifications(self, limit: int = 50) -> list:
        with self.lock:
            return [dict(r) for r in self.db.execute(
                "SELECT * FROM notifications ORDER BY id DESC LIMIT ?", (limit,))]

    # ---------- 小型設定值（例如已清除警告的最後一筆 id） ----------
    def kv_get(self, k: str, default=None):
        with self.lock:
            row = self.db.execute("SELECT v FROM kv WHERE k=?", (k,)).fetchone()
        return row["v"] if row else default

    def kv_set(self, k: str, v):
        with self.lock:
            self.db.execute("INSERT INTO kv (k, v) VALUES (?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))
            self.db.commit()

    # ---------- link events ----------
    def event(self, event: str, detail: str = "") -> dict:
        ts = now_iso()
        with self.lock:
            self.db.execute("INSERT INTO link_events (ts, event, detail) VALUES (?,?,?)", (ts, event, detail))
            self.db.commit()
        return {"ts": ts, "event": event, "detail": detail}

    # ---------- export ----------
    def export_csv(self) -> bytes:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id", "截圖時間", "接收時間", "節點", "手機", "最終狀態", "VLM 判定", "YOLO 規則判定", "由 YOLO 升級",
                    "描述", "YOLO 偵測", "YOLO 規則觸發", "VLM 模型", "VLM 毫秒", "YOLO 模型", "YOLO 毫秒",
                    "影像", "boot", "seq"])
        lab = lambda v: STATUS_LABELS.get(v, v or "")  # noqa: E731
        with self.lock:
            for r in self.db.execute("SELECT * FROM reports ORDER BY id"):
                dets = json.loads(r["detections"]) if r["detections"] else []
                w.writerow([r["id"], r["device_ts"], r["recv_ts"], r["node_name"] or r["node"] or "",
                            r["phone_name"] or r["phone"] or "", lab(r["status"]), lab(r["vlm_status"]),
                            lab(r["yolo_status"]), "是" if r["escalated_by"] else "", r["text"],
                            "、".join(f"{d['cls']}×{d['n']}" for d in dets),
                            "；".join(json.loads(r["reasons"]) if r["reasons"] else []),
                            r["model"], r["latency_ms"], r["yolo_model"] or "", r["yolo_ms"],
                            r["image"] or "", r["boot"], r["seq"]])
        return buf.getvalue().encode("utf-8-sig")  # 加 BOM，Excel 開啟中文不亂碼
