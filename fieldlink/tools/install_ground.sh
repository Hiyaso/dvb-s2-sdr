#!/usr/bin/env bash
# 地面站電腦（Ubuntu 22.04 / 24.04）安裝
set -euo pipefail
sudo apt update
sudo apt install -y gnuradio gnuradio-dev uhd-host libuhd-dev cmake git pkg-config \
  libsndfile1-dev libspdlog-dev pybind11-dev python3-packaging doxygen graphviz \
  python3-yaml python3-aiohttp
sudo uhd_images_downloader
if ! command -v dvbs2-rx >/dev/null; then
  cd /tmp && rm -rf gr-dvbs2rx && git clone --recursive https://github.com/igorauad/gr-dvbs2rx.git
  cd gr-dvbs2rx && mkdir build && cd build
  cmake -DCMAKE_BUILD_TYPE=Release .. && make -j"$(nproc)" && sudo make install && sudo ldconfig
fi
echo "完成。執行：python3 ground/app.py"
