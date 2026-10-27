#!/usr/bin/env bash
# 在 Jetson 上重啟現場節點程式：停掉舊的實例（fpga 模式時連數據機一起停），再用 nohup 啟動新的
#   ./tools/restart_jetson.sh            log 在 logs/jetson_app.log
cd "$(dirname "$0")/.."
pkill -TERM -f "python jetson/app[.]py" 2>/dev/null; sleep 4
pkill -KILL -f "python jetson/app[.]py" 2>/dev/null
pkill -INT -x dvbs2_b210 2>/dev/null; sleep 2
mkdir -p logs
nohup .venv/bin/python jetson/app.py > logs/jetson_app.log 2>&1 < /dev/null &
sleep 1
pgrep -f "python jetson/app[.]py" >/dev/null && echo "jetson/app.py 已啟動（logs/jetson_app.log）" || { echo "啟動失敗，請看 logs/jetson_app.log"; exit 1; }
