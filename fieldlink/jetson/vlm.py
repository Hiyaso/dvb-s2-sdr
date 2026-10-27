"""透過 Ollama 呼叫本機 VLM，把影像轉成「描述 + 三級狀態」。"""
import base64
import json
import logging
import re
import time

import aiohttp

log = logging.getLogger("vlm")

SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["normal", "warning", "critical"]},
        "description": {"type": "string"},
    },
    "required": ["status", "description"],
}

SYSTEM = """你是場域安全監控系統的影像判讀員。看一張監視畫面，用繁體中文寫一句客觀描述（60 字以內，說明看到什麼、在哪裡、是否異常），並依下列準則分類：
{rules}
只能輸出 JSON：{{"status": "normal" | "warning" | "critical", "description": "..."}}。
不確定時選較嚴重的等級，但不要憑空捏造畫面中沒有的東西。"""

USER = "請判讀這張監視畫面。"

_FALLBACK = [("critical", r"critical|嚴重|危險|火|倒地"), ("warning", r"warning|警告|異常|注意")]


class VlmClient:
    def __init__(self, cfg: dict, session: aiohttp.ClientSession):
        self.cfg = cfg
        self.session = session
        self.model = cfg["model"]
        self.system = SYSTEM.format(rules=cfg.get("rules", "").strip())

    def _body(self, messages, num_predict, schema: bool = True):
        body = {
            "model": self.model,
            "stream": False,
            "keep_alive": -1,               # 常駐記憶體，避免每次重新載入
            "messages": messages,
            "options": {"temperature": 0, "num_predict": num_predict, "num_ctx": int(self.cfg.get("num_ctx", 4096))},
        }
        if schema:
            body["format"] = SCHEMA         # 受限解碼，保證輸出合法 JSON
        if self.cfg.get("think") is not None:
            body["think"] = bool(self.cfg["think"])
        return body

    async def _post(self, body):
        timeout = aiohttp.ClientTimeout(total=float(self.cfg.get("timeout_s", 30)))
        async with self.session.post(f"{self.cfg['url']}/api/chat", json=body, timeout=timeout) as r:
            if r.status != 200:
                raise RuntimeError(f"Ollama HTTP {r.status}: {(await r.text())[:200]}")
            return await r.json()

    async def warmup(self):
        """啟動時先載入模型，第一次推論才不會慢。"""
        t = time.time()
        await self._post(self._body([{"role": "user", "content": "ok"}], 1))
        log.info("VLM %s 已載入（%.1f 秒）", self.model, time.time() - t)

    async def classify(self, jpeg: bytes, context: str = "") -> dict:
        """context：附加在提示後面的輔助資訊（例如 YOLO 偵測結果）。"""
        t0 = time.time()
        user = USER + ("\n\n" + context if context else "")
        messages = [
            {"role": "system", "content": self.system},
            {"role": "user", "content": user, "images": [base64.b64encode(jpeg).decode()]},
        ]
        num_predict = int(self.cfg.get("num_predict", 160))
        if self.cfg.get("mode", "prefill") == "prefill":
            # thinking 版模型（Ollama 的 qwen3-vl:2b 就是）：think=false 和 /no_think 實測都擋不住它思考，
            # 把 token 配額用完後 content 是空的。改用「assistant 預填一個空的 <think></think>」讓模型直接寫答案；
            # 這時不能同時用 format（受限解碼），所以靠 _parse 從回答裡抓 JSON。
            messages.append({"role": "assistant", "content": "<think>\n\n</think>\n\n"})
            body = self._body(messages, num_predict, schema=False)
            body.pop("think", None)
        else:
            # schema：受限解碼保證 JSON；給 instruct 版（不會思考）的模型用
            body = self._body(messages, num_predict)
        data = await self._post(body)
        content = data.get("message", {}).get("content", "")
        status, text = self._parse(content)
        return {"status": status, "text": text, "latency_ms": int((time.time() - t0) * 1000)}

    @staticmethod
    def _parse(content: str):
        # 去掉思考區塊與零星的 <think> / </think> 標籤、```json 圍欄
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.S)
        content = re.sub(r"</?think>", "", content)
        content = re.sub(r"```(?:json)?", "", content).strip()
        # 模型有時會把同一段 JSON 寫兩次：逐一嘗試每個單層 {...}，取第一個能解析的
        candidates = re.findall(r"\{[^{}]*\}", content, flags=re.S) or [content]
        for cand in candidates:
            try:
                obj = json.loads(cand)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            status = str(obj.get("status", "")).lower().strip()
            text = str(obj.get("description", "")).strip()
            if status in ("normal", "warning", "critical") and text:
                return status, text[:200]
        # JSON 壞掉（例如引號沒逃脫）時直接抓欄位
        ms = re.search(r'"status"\s*:\s*"(normal|warning|critical)"', content, re.I)
        md = re.search(r'"description"\s*:\s*"((?:[^"\\]|\\.)*)"', content, re.S)
        if ms and md and md.group(1).strip():
            return ms.group(1).lower(), md.group(1).strip()[:200]
        # 完全沒照格式時的保底：用關鍵字判斷，並保留原文
        for status, pat in _FALLBACK:
            if re.search(pat, content, re.I):
                return status, content[:200]
        return "warning", ("模型輸出無法解析：" + content)[:200]
