#!/bin/bash
# build_fpga.sh -- build the USRP B210 FPGA image with the DVB-S2 modem (Ubuntu, Xilinx ISE 14.7).
#
#   ./build_fpga.sh [UHD source directory]
#
# * The UHD source must match the UHD library installed on the PCs that will use the
#   image (UHD checks the FPGA compatibility number).  Without an argument the script
#   clones the tag of the installed UHD (uhd_config_info --version) into ./uhd-src.
# * ISE: set ISE_SETTINGS if ISE is not in /opt/Xilinx/14.7/ISE_DS/settings64.sh.
#   The XC6SLX150 (B210) is not covered by the free WebPACK license.
# Result: ./out/usrp_b210_dvbs2_fpga.bin
set -e -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
UHD_SRC=${1:-$HERE/uhd-src}
ISE_SETTINGS=${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}

if [ ! -d "$UHD_SRC/fpga/usrp3" ]; then
  VER=$(uhd_config_info --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$VER" ] || { echo "cannot determine the installed UHD version (uhd_config_info); pass a UHD source dir"; exit 1; }
  echo "installed UHD $VER -> cloning tag v$VER"
  git clone --depth 1 --branch "v$VER" https://github.com/EttusResearch/uhd.git "$UHD_SRC"
fi
python3 "$HERE/patch_uhd_fpga.py" "$UHD_SRC"

[ -f "$ISE_SETTINGS" ] || { echo "ISE settings not found: $ISE_SETTINGS (set ISE_SETTINGS=...)"; exit 1; }
# ISE's settings script needs bash; it prints a lot, keep it quiet
source "$ISE_SETTINGS" > /dev/null
command -v xtclsh > /dev/null || { echo "xtclsh not found after sourcing $ISE_SETTINGS"; exit 1; }

cd "$UHD_SRC/fpga/usrp3/top/b200"
echo "building B210_DVBS2 (this takes 1-2 hours) ..."
touch "$HERE/build_fpga.log.start"
make B210_DVBS2 2>&1 | tee "$HERE/build_fpga.log" || true
mkdir -p "$HERE/out"
B=build-B210_DVBS2
if [ -s build/usrp_b210_dvbs2_fpga.bin ] && [ build/usrp_b210_dvbs2_fpga.bin -nt "$HERE/build_fpga.log.start" ]; then
  cp build/usrp_b210_dvbs2_fpga.* "$HERE/out/"
elif [ -s $B/b200.bin ]; then
  # post_build did not run (e.g. stopped by the timing check): take the image directly
  cp $B/b200.bin "$HERE/out/usrp_b210_dvbs2_fpga.bin"
  for e in syr twr rpt; do [ -f $B/b200.$e ] && cp $B/b200.$e "$HERE/out/usrp_b210_dvbs2_fpga.$e"; done
  echo "NOTE: post_build was skipped; check the timing report out/usrp_b210_dvbs2_fpga.twr"
else
  echo "BUILD FAILED: no bitstream.  Send me $UHD_SRC/fpga/usrp3/top/b200/$B/b200.syr (and build_fpga.log)"
  exit 1
fi
echo
echo "=== image: $HERE/out/usrp_b210_dvbs2_fpga.bin"
grep -iE -A3 "Timing Summary|timing (errors|score)" "$HERE"/out/usrp_b210_dvbs2_fpga.{rpt,twr} 2>/dev/null | head -20 || true
