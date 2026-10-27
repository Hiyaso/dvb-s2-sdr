"""MPEG-TS 封裝/解封裝與訊息分段。

DVB-S2 發射端 (gr-dtv / dvbs2-tx) 的輸入與接收端 (dvbs2-rx) 的輸出都是 188-byte
MPEG-TS。這裡把一則「訊息」切成多個 TS 封包送在單一 PID 上：

    第一個封包 PUSI=1，payload 開頭是 14-byte 訊息標頭：
        magic(2)=A5 5A | type(1) | flags(1) | msg_id(2) | length(4) | crc32(4)
    之後的封包 PUSI=0，接續 payload，最後一包不足的部分補 0xFF。

接收端用 continuity counter 偵測掉包，CRC32 驗證整則訊息；任一失敗就丟棄該則。
"""
import struct
import zlib

TS_SIZE = 188
TS_SYNC = 0x47
TS_PAYLOAD = 184
NULL_PID = 0x1FFF

MAGIC = b"\xA5\x5A"
MSG_HDR = struct.Struct(">2sBBHII")  # 14 bytes
MAX_MSG_LEN = 4 * 1024 * 1024

NULL_PACKET = bytes([TS_SYNC, 0x1F, 0xFF, 0x10]) + b"\xFF" * TS_PAYLOAD
_SYNC_BYTE = bytes([TS_SYNC])


class TsMuxer:
    """把訊息切成 TS 封包。continuity counter 由 muxer 自己維護，
    所以同一個 muxer 只能由單一執行緒（送出端）使用，呼叫順序就是送出順序。"""

    def __init__(self, pid: int):
        if not 0 <= pid < NULL_PID:
            raise ValueError("PID 必須介於 0x0000 與 0x1FFE")
        self.pid = pid
        self.cc = 0

    def packetize(self, msg_type: int, msg_id: int, payload: bytes, flags: int = 0) -> bytes:
        if len(payload) > MAX_MSG_LEN:
            raise ValueError("訊息過大")
        frame = MSG_HDR.pack(MAGIC, msg_type & 0xFF, flags & 0xFF, msg_id & 0xFFFF,
                             len(payload), zlib.crc32(payload) & 0xFFFFFFFF) + payload
        out = bytearray()
        for off in range(0, len(frame), TS_PAYLOAD):
            chunk = frame[off:off + TS_PAYLOAD]
            pusi = 0x40 if off == 0 else 0x00
            out += bytes([TS_SYNC, pusi | ((self.pid >> 8) & 0x1F), self.pid & 0xFF, 0x10 | self.cc])
            out += chunk
            if len(chunk) < TS_PAYLOAD:
                out += b"\xFF" * (TS_PAYLOAD - len(chunk))
            self.cc = (self.cc + 1) & 0x0F
        return bytes(out)


class TsDemuxer:
    """從任意切割的位元組流中找回 TS 封包並重組訊息。

    on_message(msg_type, msg_id, flags, payload) 在呼叫 feed() 的執行緒中被呼叫。
    """

    def __init__(self, pid: int, on_message):
        self.pid = pid
        self.on_message = on_message
        self._buf = bytearray()
        self._reset_msg()
        self.stats = {"ts_packets": 0, "messages": 0, "crc_errors": 0,
                      "cc_errors": 0, "resyncs": 0, "tei": 0, "bad_header": 0}

    def _reset_msg(self):
        self._msg = None
        self._data = bytearray()
        self._last_cc = None

    def feed(self, data: bytes):
        self._buf += data
        buf = self._buf
        n = len(buf)
        i = 0
        while n - i >= TS_SIZE:
            aligned = buf[i] == TS_SYNC and (n - i < 2 * TS_SIZE or buf[i + TS_SIZE] == TS_SYNC)
            if not aligned:
                # 失去同步：找下一個 0x47，且其後 188 bytes 處也要是 0x47
                self.stats["resyncs"] += 1
                j = buf.find(_SYNC_BYTE, i + 1)
                while j != -1 and n - j >= 2 * TS_SIZE and buf[j + TS_SIZE] != TS_SYNC:
                    j = buf.find(_SYNC_BYTE, j + 1)
                if j == -1:
                    i = n
                    break
                i = j
                continue
            self._packet(bytes(buf[i:i + TS_SIZE]))
            i += TS_SIZE
        del buf[:i]

    def _packet(self, pkt: bytes):
        self.stats["ts_packets"] += 1
        b1, b2, b3 = pkt[1], pkt[2], pkt[3]
        pid = ((b1 & 0x1F) << 8) | b2
        if pid != self.pid:
            return
        if b1 & 0x80:  # transport error indicator
            self.stats["tei"] += 1
            self._reset_msg()
            return
        afc = (b3 >> 4) & 0x03
        cc = b3 & 0x0F
        if afc in (0, 2):  # 沒有 payload
            return
        start = 4
        if afc == 3:
            start = 5 + pkt[4]
            if start >= TS_SIZE:
                return
        payload = pkt[start:]

        if b1 & 0x40:  # PUSI：新訊息開頭
            if self._msg is not None:
                self.stats["cc_errors"] += 1  # 上一則沒收完
            self._reset_msg()
            if len(payload) < MSG_HDR.size:
                self.stats["bad_header"] += 1
                return
            magic, mtype, flags, mid, length, crc = MSG_HDR.unpack_from(payload, 0)
            if magic != MAGIC or length > MAX_MSG_LEN:
                self.stats["bad_header"] += 1
                return
            self._msg = (mtype, mid, flags, length, crc)
            self._data += payload[MSG_HDR.size:]
            self._last_cc = cc
        else:
            if self._msg is None:
                return
            if cc == self._last_cc:
                return  # 重複封包，依 ISO/IEC 13818-1 忽略
            if cc != ((self._last_cc + 1) & 0x0F):
                self.stats["cc_errors"] += 1
                self._reset_msg()
                return
            self._last_cc = cc
            self._data += payload

        mtype, mid, flags, length, crc = self._msg
        if len(self._data) >= length:
            body = bytes(self._data[:length])
            self._reset_msg()
            if zlib.crc32(body) & 0xFFFFFFFF != crc:
                self.stats["crc_errors"] += 1
                return
            self.stats["messages"] += 1
            self.on_message(mtype, mid, flags, body)
