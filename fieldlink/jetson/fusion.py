"""YOLO 與 VLM 的融合。

1. YOLO 偵測結果整理成文字，附在 VLM 的提示裡，補強 VLM 對小物件、數量的弱點。
2. YOLO 規則：特定類別達到信心/數量門檻時，直接判定 warning / critical。
3. 最終狀態 = max(VLM 狀態, YOLO 規則狀態)：任一方判定較嚴重就採用較嚴重的，
   寧可多報不要漏報。若想讓 VLM 有否決權，把 fusion.mode 設為 "vlm"（只把 YOLO 當參考）。
"""
import io
import zlib
from collections import OrderedDict

from PIL import Image, ImageDraw, ImageFont

LEVEL = {"normal": 0, "warning": 1, "critical": 2}
NAME = {v: k for k, v in LEVEL.items()}
COLOR = {"normal": (35, 121, 90), "warning": (214, 150, 20), "critical": (214, 48, 36)}
# 偵測框顏色：每個類別固定一色（依類別名稱雜湊挑選），同一類別在每張圖都一樣，不同類別容易分辨
PALETTE = [(230, 57, 70), (29, 158, 117), (37, 99, 235), (245, 158, 11), (168, 85, 247), (14, 165, 233),
           (236, 72, 153), (132, 204, 22), (249, 115, 22), (20, 184, 166), (217, 70, 239), (234, 179, 8)]


def class_color(cls: str) -> tuple:
    return PALETTE[zlib.crc32(str(cls).encode("utf-8")) % len(PALETTE)]


def summarize(dets: list) -> list:
    """[{"cls","n","max_conf"}]，依最高信心排序，給報告與儀表板用。"""
    agg = OrderedDict()
    for d in dets:
        a = agg.setdefault(d["cls"], {"cls": d["cls"], "n": 0, "max_conf": 0.0})
        a["n"] += 1
        a["max_conf"] = max(a["max_conf"], d["conf"])
    return sorted(agg.values(), key=lambda a: -a["max_conf"])


def summary_text(dets: list) -> str:
    if not dets:
        return "無"
    return "、".join(f"{a['cls']}×{a['n']}（{a['max_conf']:.2f}）" for a in summarize(dets))


def prompt_context(dets) -> str:
    if dets is None:
        return ""
    if not dets:
        return ("物件偵測器（YOLO）沒有偵測到它認得的物件。它只認得特定類別，"
                "畫面中仍可能有它不認得的狀況，請以你看到的畫面為準。")
    lines = [f"- {d['cls']}，信心 {d['conf']:.2f}，位置 x {d['box'][0]:.2f}~{d['box'][2]:.2f}、"
             f"y {d['box'][1]:.2f}~{d['box'][3]:.2f}" for d in dets[:15]]
    return ("物件偵測器（YOLO）在這張畫面偵測到（座標為畫面比例，0 為左上）：\n" + "\n".join(lines) +
            "\n偵測器可能誤報或漏報，請以你看到的畫面為準；若列出的物件與風險有關，請仔細確認後再判斷。")


def apply_rules(dets, rules: list):
    """回傳 (狀態, [觸發原因])。"""
    if not dets or not rules:
        return "normal", []
    level, reasons = 0, []
    for r in rules:
        classes = set(r.get("classes", []))
        hits = [d for d in dets if d["cls"] in classes and d["conf"] >= float(r.get("min_conf", 0.5))]
        if len(hits) >= int(r.get("min_count", 1)):
            lv = LEVEL[r.get("level", "warning")]
            best = max(hits, key=lambda d: d["conf"])
            reasons.append(f"{r.get('name', '/'.join(classes))}：{best['cls']}×{len(hits)}（{best['conf']:.2f}）")
            level = max(level, lv)
    return NAME[level], reasons


def fuse(vlm_status: str, yolo_status: str, mode: str = "max") -> str:
    if mode == "vlm":
        return vlm_status
    return NAME[max(LEVEL[vlm_status], LEVEL[yolo_status])]


def draw_boxes(jpeg: bytes, dets: list, status: str, quality: int = 80) -> bytes:
    """把偵測框畫在（已縮圖的）影像上，回傳 JPEG。每個類別一種顏色（class_color），
    圖的外框用狀態色（normal 綠 / warning 黃 / critical 紅）。"""
    if not dets:
        return jpeg
    img = Image.open(io.BytesIO(jpeg)).convert("RGB")
    w, h = img.size
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=max(12, w // 50))
    except TypeError:  # Pillow < 10.1
        font = ImageFont.load_default()
    lw = max(2, w // 320)
    edge = COLOR.get(status, COLOR["warning"])
    draw.rectangle([0, 0, w - 1, h - 1], outline=edge, width=lw * 2)
    for d in dets[:30]:
        color = class_color(d["cls"])
        x1, y1, x2, y2 = d["box"][0] * w, d["box"][1] * h, d["box"][2] * w, d["box"][3] * h
        draw.rectangle([x1, y1, x2, y2], outline=color, width=lw)
        label = f"{d['cls']} {d['conf']:.2f}"
        tb = draw.textbbox((x1, y1), label, font=font)
        ty = y1 - (tb[3] - tb[1]) - 4 if y1 > (tb[3] - tb[1]) + 4 else y1
        draw.rectangle([x1, ty, x1 + (tb[2] - tb[0]) + 6, ty + (tb[3] - tb[1]) + 4], fill=color)
        draw.text((x1 + 3, ty + 1), label, fill=(255, 255, 255), font=font)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=quality, optimize=True)
    return out.getvalue()
