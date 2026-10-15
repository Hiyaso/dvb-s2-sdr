#!/bin/bash
# build.sh -- build the PC program (Ubuntu):  sudo apt install libuhd-dev libboost-program-options-dev cmake g++
# (without cmake the program is compiled with g++ directly)
set -e
cd "$(dirname "$0")"
mkdir -p build && cd build
if command -v cmake > /dev/null; then
  cmake .. > /dev/null
  make -j"$(nproc)"
else
  g++ -std=c++17 -O2 -o dvbs2_b210 ../dvbs2_b210.cpp -luhd -lboost_program_options -lpthread
fi
echo "built $(pwd)/dvbs2_b210"
