"""YOLO 物件偵測（Ultralytics，TensorRT FP16 引擎）。

第一次啟動時如果只有 .pt，會自動匯出成 .engine（在 Orin Nano 上約需數分鐘，只做一次）。
TensorRT 引擎綁定 GPU 與 TensorRT 版本，換機器或升級 JetPack 後要刪掉 .engine 重新匯出。

模型載入與推論都在同一個專用執行緒裡做（見 app.py 的 yolo_executor），避免 CUDA context 跨執行緒。
"""
import io
import logging
import time
from pathlib import Path

from PIL import Image

log = logging.getLogger("yolo")


class YoloDetector:
    def __init__(self, cfg: dict, root: Path):
        from ultralytics import YOLO  # 延遲匯入：沒啟用 YOLO 時不需要安裝 torch

        self.cfg = cfg
        self.imgsz = int(cfg.get("imgsz", 640))
        self.conf = float(cfg.get("conf", 0.35))
        self.iou = float(cfg.get("iou", 0.5))
        self.max_det = int(cfg.get("max_det", 50))
        model_path = root / cfg["model"]

        if model_path.suffix == ".pt" and cfg.get("tensorrt", True):
            engine = model_path.with_suffix(".engine")
            if not engine.exists():
                log.info("找不到 %s，從 %s 匯出 TensorRT FP16 引擎（只做一次，約數分鐘）…", engine.name, model_path.name)
                engine.parent.mkdir(parents=True, exist_ok=True)
                src = YOLO(str(model_path)) if model_path.exists() else YOLO(model_path.name)  # 沒有檔案會自動下載
                out = src.export(format="engine", half=True, imgsz=self.imgsz, device=0, verbose=False)
                Path(out).replace(engine)
            model_path = engine

        self.model = YOLO(str(model_path) if model_path.exists() else model_path.name, task="detect")
        self.names = self.model.names
        wanted = cfg.get("classes")
        self.class_ids = None
        if wanted:
            lookup = {v: k for k, v in self.names.items()}
            missing = [c for c in wanted if c not in lookup]
            if missing:
                log.warning("模型沒有這些類別，已忽略：%s", missing)
            self.class_ids = [lookup[c] for c in wanted if c in lookup]
        self.model_name = model_path.name
        t = time.time()
        self.model.predict(Image.new("RGB", (self.imgsz, self.imgsz)), imgsz=self.imgsz, verbose=False)
        log.info("YOLO %s 已載入（%d 類，暖機 %.1f 秒）", self.model_name, len(self.names), time.time() - t)

    def detect(self, jpeg: bytes) -> list:
        """回傳 [{"cls", "conf", "box":[x1,y1,x2,y2]（0~1 正規化）}]，依信心排序。"""
        img = Image.open(io.BytesIO(jpeg)).convert("RGB")
        r = self.model.predict(img, imgsz=self.imgsz, conf=self.conf, iou=self.iou,
                               classes=self.class_ids, max_det=self.max_det, verbose=False)[0]
        out = []
        for xyxyn, conf, cls in zip(r.boxes.xyxyn.tolist(), r.boxes.conf.tolist(), r.boxes.cls.tolist()):
            out.append({"cls": self.names[int(cls)], "conf": round(float(conf), 3),
                        "box": [round(v, 4) for v in xyxyn]})
        out.sort(key=lambda d: -d["conf"])
        return out
