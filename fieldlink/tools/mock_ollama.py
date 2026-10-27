#!/usr/bin/env python3
"""假的 Ollama：開發機上沒有 GPU / 模型時用來測試整個流程。

  python3 tools/mock_ollama.py [--port 11434] [--delay 0.8]

只實作 jetson/vlm.py 用到的 POST /api/chat：回傳合法 JSON（status + description），
狀態依序循環 normal → normal → warning → critical，方便看儀表板各種狀態與嚴重事件影像。
"""
import argparse
import asyncio
import itertools
import json

from aiohttp import web

CYCLE = itertools.cycle([("normal", "場域正常，走道暢通，沒有人員或設備異常。"),
                         ("normal", "畫面穩定，光線充足，未見異常。"),
                         ("warning", "有人員進入限制區域，請注意。"),
                         ("critical", "畫面中疑似有明火與濃煙，需要立即處理。")])


async def chat(request):
    body = await request.json()
    msgs = body.get("messages", [])
    if not any(m.get("images") for m in msgs):      # warmup
        return web.json_response({"message": {"role": "assistant", "content": "ok"}})
    await asyncio.sleep(request.app["delay"])
    status, text = next(CYCLE)
    return web.json_response({"message": {"role": "assistant",
                                          "content": json.dumps({"status": status, "description": text}, ensure_ascii=False)}})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=11434)
    p.add_argument("--delay", type=float, default=0.8, help="模擬推論秒數")
    a = p.parse_args()
    app = web.Application(client_max_size=16 * 1024 * 1024)
    app["delay"] = a.delay
    app.router.add_post("/api/chat", chat)
    web.run_app(app, host="127.0.0.1", port=a.port, print=None)


if __name__ == "__main__":
    main()
