#!/usr/bin/env bash
# 在 Jetson 上停止現場節點程式與數據機
pkill -TERM -f "python jetson/app[.]py" 2>/dev/null; sleep 4
pkill -KILL -f "python jetson/app[.]py" 2>/dev/null
pkill -INT -x dvbs2_b210 2>/dev/null; sleep 2
pkill -KILL -x dvbs2_b210 2>/dev/null
pgrep -f "python jetson/app[.]py" >/dev/null && { echo "jetson/app.py 還在"; exit 1; }
echo "jetson/app.py 與 dvbs2_b210 已停止"
