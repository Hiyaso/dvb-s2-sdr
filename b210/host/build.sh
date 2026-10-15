#!/bin/bash
# build.sh -- build the PC program (Ubuntu):  sudo apt install libuhd-dev libboost-program-options-dev cmake g++
set -e
cd "$(dirname "$0")"
mkdir -p build && cd build
cmake .. > /dev/null
make -j"$(nproc)"
echo "built $(pwd)/dvbs2_b210"
