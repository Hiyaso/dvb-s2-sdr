#!/bin/bash
# build.sh -- cross-compile dvbs2_adrv for the SOM (ARM, Kuiper Linux armhf).
#   CROSS=<prefix>  compiler prefix (default: Arm GNU toolchain 14.2 in adrv9364/dl/tools,
#                   downloaded by adrv9364/make_sd_image.sh), e.g. CROSS=arm-linux-gnueabihf-
#   MOCK=1          build for this PC with a software model of the FPGA and the AD9364
#                   (build/dvbs2_adrv_mock, for testing the UDP / web parts; see sw/test_mock.sh)
# Output: adrv9364/sw/build/dvbs2_adrv
set -e
cd "$(dirname "$0")"
TC=../dl/tools/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
mkdir -p build
if [ -n "$MOCK" ]; then
  g++ -std=c++17 -O2 -Wall -Wno-unused-function -DDVBS2_MOCK -I../../b210/host -o build/dvbs2_adrv_mock dvbs2_adrv.cpp -pthread -ldl
  echo "built $(pwd)/build/dvbs2_adrv_mock"
  exit 0
fi
CXX=${CROSS:-$TC}g++
[ -x "$(command -v "$CXX")" ] || [ -x "$CXX" ] || { echo "cross compiler $CXX not found (run adrv9364/make_sd_image.sh once, or set CROSS=)"; exit 1; }
# libstdc++ / libgcc linked statically; glibc and libiio / libad9361 (dlopen) from the SOM
"$CXX" -std=c++17 -O2 -s -Wall -Wno-unused-function -I../../b210/host -o build/dvbs2_adrv dvbs2_adrv.cpp \
  -static-libstdc++ -static-libgcc -pthread -ldl
echo "built $(pwd)/build/dvbs2_adrv"
