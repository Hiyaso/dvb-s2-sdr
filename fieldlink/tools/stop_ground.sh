#!/usr/bin/env bash
# 在地面站電腦上停止地面站程式與數據機
pkill -TERM -f "python ground/app[.]py" 2>/dev/null; sleep 4
pkill -KILL -f "python ground/app[.]py" 2>/dev/null
pkill -INT -x dvbs2_b210 2>/dev/null; sleep 2
pkill -KILL -x dvbs2_b210 2>/dev/null
pgrep -f "python ground/app[.]py" >/dev/null && { echo "ground/app.py 還在"; exit 1; }
echo "ground/app.py 與 dvbs2_b210 已停止"
