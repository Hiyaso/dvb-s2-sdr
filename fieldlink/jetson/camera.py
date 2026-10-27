"""影像來源：每支手機保存最新一張影格（JPEG），並提供縮圖/壓縮工具。"""
import io
import logging
import re
import threading
import time

from PIL import Image

log = logging.getLogger("camera")


class FrameStore:
    def __init__(self):
        self._lock = threading.Lock()
        self._jpeg = None
        self._ts = 0.0
        self.frames = 0

    def update(self, jpeg: bytes):
        with self._lock:
            self._jpeg = jpeg
            self._ts = time.time()
            self.frames += 1

    def get(self):
        with self._lock:
            return self._jpeg, self._ts

    def age(self) -> float:
        with self._lock:
            return time.time() - self._ts if self._jpeg else float("inf")


class Phone:
    """一支手機（相機頁的一個 id）。conns = 目前連著的 WebSocket 數。"""

    def __init__(self, pid: str, name: str):
        self.id = pid
        self.name = name
        self.store = FrameStore()
        self.conns = 0
        self.first_seen = time.time()
        self.last_seen = time.time()       # 最後一次連線或影格
        self.last_processed = 0.0          # 上次被辨識的時間（輪流排程用）
        self.reports = 0


class PhoneRegistry:
    """多支手機登記簿。手機頁用 ?role=phone&id=...&name=... 連線；id 由手機瀏覽器產生並記住。"""

    ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

    def __init__(self, stale_s: float = 3.0, offline_s: float = 60.0):
        self._lock = threading.Lock()
        self._phones = {}
        self.stale_s = float(stale_s)
        self.offline_s = float(offline_s)

    @classmethod
    def valid_id(cls, pid: str) -> bool:
        return bool(pid) and bool(cls.ID_RE.match(pid))

    @staticmethod
    def clean_name(name: str, default: str) -> str:
        name = " ".join(str(name or "").split())[:24]
        return name or default

    def attach(self, pid: str, name: str) -> Phone:
        with self._lock:
            ph = self._phones.get(pid)
            if ph is None:
                ph = self._phones[pid] = Phone(pid, self.clean_name(name, f"手機 {len(self._phones) + 1}"))
            elif name:
                ph.name = self.clean_name(name, ph.name)
            ph.conns += 1
            ph.last_seen = time.time()
            return ph

    def detach(self, pid: str):
        with self._lock:
            ph = self._phones.get(pid)
            if ph:
                ph.conns = max(0, ph.conns - 1)
                ph.last_seen = time.time()

    def update(self, pid: str, jpeg: bytes):
        with self._lock:
            ph = self._phones.get(pid)
        if ph:
            ph.store.update(jpeg)
            ph.last_seen = time.time()

    def get(self, pid):
        with self._lock:
            return self._phones.get(pid) if pid else None

    def fresh(self) -> list:
        """目前有新影格的手機，依「最久沒被辨識」排序（輪流排程直接取第一個）。"""
        with self._lock:
            phones = list(self._phones.values())
        out = [p for p in phones if p.store.age() <= self.stale_s]
        out.sort(key=lambda p: (p.last_processed, p.first_seen))
        return out

    def prune(self):
        """斷線太久的手機從清單移除。"""
        now = time.time()
        with self._lock:
            for pid, p in list(self._phones.items()):
                if p.conns == 0 and now - p.last_seen > self.offline_s:
                    del self._phones[pid]

    def summary(self, selected: str = None) -> list:
        """給心跳與網頁用的清單。"""
        with self._lock:
            phones = list(self._phones.values())
        out = []
        for p in sorted(phones, key=lambda p: p.first_seen):
            age = p.store.age()
            out.append({"id": p.id, "name": p.name, "online": p.conns > 0,
                        "fresh": age <= self.stale_s, "age_s": None if age == float("inf") else round(age, 1),
                        "frames": p.store.frames, "reports": p.reports, "selected": p.id == selected})
        return out


class UrlGrabber(threading.Thread):
    """從 RTSP / HTTP MJPEG 網址持續讀取（例如 IP Webcam、DroidCam App）。
    一直讀可以清掉解碼器緩衝，確保拿到的是最新影格。"""

    def __init__(self, url: str, store: FrameStore, fps: float = 4):
        super().__init__(daemon=True, name="url-grabber")
        self.url, self.store, self.period = url, store, 1.0 / fps

    def run(self):
        import cv2  # 只有用網址來源才需要 OpenCV
        while True:
            cap = cv2.VideoCapture(self.url)
            if not cap.isOpened():
                log.warning("無法開啟 %s，3 秒後重試", self.url)
                time.sleep(3)
                continue
            log.info("已連上影像來源 %s", self.url)
            last = 0.0
            while True:
                ok, frame = cap.read()
                if not ok:
                    log.warning("影像中斷，重新連線")
                    break
                now = time.time()
                if now - last >= self.period:
                    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                    if ok:
                        self.store.update(buf.tobytes())
                    last = now
            cap.release()
            time.sleep(1)


def shrink_jpeg(jpeg: bytes, max_side: int, quality: int = 80, max_kb: int = 0) -> bytes:
    """縮到最長邊 max_side 並重新壓縮；有 max_kb 時逐步降低品質直到符合大小。"""
    img = Image.open(io.BytesIO(jpeg))
    img = img.convert("RGB")
    img.thumbnail((max_side, max_side), Image.LANCZOS)
    q = quality
    while True:
        out = io.BytesIO()
        img.save(out, "JPEG", quality=q, optimize=True)
        data = out.getvalue()
        if not max_kb or len(data) <= max_kb * 1024 or q <= 30:
            return data
        q -= 10
