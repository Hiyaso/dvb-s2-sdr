"""應用層訊息格式（跑在 TS 訊息之上）。"""
import json
import struct
from datetime import datetime
from enum import IntEnum
from typing import Optional, Tuple


class MsgType(IntEnum):
    HEARTBEAT = 1    # Jetson → 地面站：心跳與狀態
    REPORT = 2       # Jetson → 地面站：VLM 辨識結果（嚴重時附 JPEG）
    NOTIFY = 3       # 地面站 → Jetson：文字通知
    NOTIFY_ACK = 4   # Jetson → 地面站：通知已顯示
    SELECT = 5       # 地面站 → Jetson：選擇要傳縮圖的手機（Jetson 回 SELECT_ACK，沒回就重送）
    SELECT_ACK = 6   # Jetson → 地面站：已套用選擇，附目前選中的手機
    THUMB = 7        # Jetson → 地面站：被選手機的縮圖（u32 JSON 長度 | JSON | JPEG，和 REPORT 同格式）


STATUSES = ("normal", "warning", "critical")
STATUS_LABELS = {"normal": "一般", "warning": "警告", "critical": "嚴重"}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def pack_json(obj: dict) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def unpack_json(payload: bytes) -> dict:
    return json.loads(payload.decode("utf-8"))


def pack_report(meta: dict, jpeg: Optional[bytes] = None) -> bytes:
    """REPORT payload = u32 JSON 長度 | JSON | (可選) JPEG"""
    j = pack_json(meta)
    return struct.pack(">I", len(j)) + j + (jpeg or b"")


def unpack_report(payload: bytes) -> Tuple[dict, Optional[bytes]]:
    (jlen,) = struct.unpack_from(">I", payload, 0)
    meta = json.loads(payload[4:4 + jlen].decode("utf-8"))
    img = payload[4 + jlen:]
    return meta, (img if img else None)


# 縮圖訊息沿用 REPORT 的「JSON + JPEG」格式
pack_thumb = pack_report
unpack_thumb = unpack_report
