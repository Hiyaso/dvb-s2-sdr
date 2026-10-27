#!/usr/bin/env python3
"""假手機：不用真手機就能測多支手機、輪流辨識、縮圖與選手機。

  python3 tools/fake_phone.py --url https://192.168.55.1:8443 --id pA --name "A 區" [--fps 4] [--duration 60]

連到 Jetson 的 /ws?role=phone，像 camera.html 一樣送 JPEG 影格（PIL 畫出名稱、時間與一個移動的方塊），
並印出 Jetson 回來的辨識結果、通知與「被地面站選中」的狀態。自簽憑證不檢查。
"""
import argparse
import asyncio
import hashlib
import io
import json
import time
from datetime import datetime

import aiohttp
from PIL import Image, ImageDraw, ImageFont


def make_frame(name: str, n: int, size=(640, 360)) -> bytes:
    h = hashlib.md5(name.encode()).digest()
    bg = (60 + h[0] % 120, 60 + h[1] % 120, 60 + h[2] % 120)
    img = Image.new("RGB", size, bg)
    d = ImageDraw.Draw(img)
    try:
        big, small = ImageFont.load_default(size=40), ImageFont.load_default(size=22)
    except TypeError:
        big = small = ImageFont.load_default()
    d.text((20, 20), name, fill=(255, 255, 255), font=big)
    d.text((20, 80), datetime.now().strftime("%H:%M:%S") + f"  frame {n}", fill=(255, 255, 255), font=small)
    x = (n * 9) % (size[0] - 80)
    d.rectangle([x, 200, x + 80, 280], fill=(255, 220, 40), outline=(0, 0, 0), width=3)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=75)
    return out.getvalue()


async def run(a):
    url = a.url.rstrip("/")
    ws_url = url.replace("https://", "wss://").replace("http://", "ws://")
    ws_url += f"/ws?role=phone&id={a.id}&name={aiohttp.helpers.quote(a.name)}"
    t_end = time.time() + a.duration
    n = 0
    async with aiohttp.ClientSession() as s:
        while time.time() < t_end:
            try:
                async with s.ws_connect(ws_url, ssl=False, heartbeat=10) as ws:
                    print(f"[{a.name}] 已連線 {ws_url}")

                    async def sender():
                        nonlocal n
                        while time.time() < t_end and not ws.closed:
                            await ws.send_bytes(make_frame(a.name, n))
                            n += 1
                            await asyncio.sleep(1.0 / a.fps)

                    task = asyncio.create_task(sender())
                    try:
                        async for msg in ws:
                            if msg.type != aiohttp.WSMsgType.TEXT:
                                continue
                            m = json.loads(msg.data)
                            t = m.get("type")
                            if t == "result" and m["result"].get("phone") == a.id:
                                r = m["result"]
                                print(f"[{a.name}] 結果 {r['label']}：{r['text']}")
                            elif t == "state":
                                sel = m["state"].get("selected") == a.id
                                if sel != getattr(run, "_sel", None):
                                    run._sel = sel
                                    print(f"[{a.name}] {'被地面站選中' if sel else '未被選中'}")
                            elif t == "notify":
                                print(f"[{a.name}] 通知：{m['notify'].get('text')}")
                            elif t == "error":
                                print(f"[{a.name}] 錯誤：{m.get('message')}")
                            if time.time() >= t_end:
                                break
                    finally:
                        task.cancel()
            except (aiohttp.ClientError, OSError) as e:
                print(f"[{a.name}] 連線失敗：{e}，3 秒後重試")
                await asyncio.sleep(3)
    print(f"[{a.name}] 結束，共送 {n} 張")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="https://192.168.55.1:8443")
    p.add_argument("--id", default="pA")
    p.add_argument("--name", default="假手機 A")
    p.add_argument("--fps", type=float, default=4)
    p.add_argument("--duration", type=float, default=60)
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
