#!/usr/bin/env bash
# 在地面站電腦上重啟地面站程式：停掉舊的實例（fpga 模式時連數據機一起停），再用 nohup 啟動新的
#   ./tools/restart_ground.sh            log 在 logs/ground_app.log，儀表板 http://localhost:8080
cd "$(dirname "$0")/.."
pkill -TERM -f "python ground/app[.]py" 2>/dev/null; sleep 4
pkill -KILL -f "python ground/app[.]py" 2>/dev/null
pkill -INT -x dvbs2_b210 2>/dev/null; sleep 2
mkdir -p logs
nohup .venv/bin/python ground/app.py > logs/ground_app.log 2>&1 < /dev/null &
sleep 1
pgrep -f "python ground/app[.]py" >/dev/null && echo "ground/app.py 已啟動（logs/ground_app.log）" || { echo "啟動失敗，請看 logs/ground_app.log"; exit 1; }
