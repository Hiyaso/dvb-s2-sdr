#!/bin/bash
# setup_ubuntu.sh -- install everything this repo needs on Ubuntu 22.04 / 24.04, then run a quick check.
#
#   ./setup_ubuntu.sh            simulation tools + Python + UHD (B210 host program)
#   ./setup_ubuntu.sh --no-uhd   skip UHD / the B210 host program
#   ./setup_ubuntu.sh --check    install nothing, only report what is missing
#
# Not installed by this script (vendor downloads + licenses):
#   * Xilinx Vivado  (Z7020 / PYNQ-Z2 bitstream, XSim)      -> sdr/z7020/vivado/
#   * Xilinx ISE 14.7 (USRP B210 FPGA image, LX150 licence)  -> sdr/b210/build_fpga.sh
set -e
cd "$(dirname "$0")"
ROOT=$(pwd)
WANT_UHD=1; CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --no-uhd) WANT_UHD=0 ;;
    --check)  CHECK_ONLY=1 ;;
    *) echo "unknown option $a"; exit 1 ;;
  esac
done

. /etc/os-release 2>/dev/null || true
echo "== system: ${PRETTY_NAME:-unknown}"
[ "${ID:-}" = ubuntu ] || echo "   (not Ubuntu: package names below are for Ubuntu/Debian)"

PKGS="build-essential git cmake python3 python3-numpy python3-matplotlib iverilog"
[ $WANT_UHD = 1 ] && PKGS="$PKGS libuhd-dev uhd-host libboost-program-options-dev"

if [ $CHECK_ONLY = 0 ]; then
  echo "== apt install: $PKGS"
  sudo apt-get update
  sudo apt-get install -y $PKGS verilator || true
fi

# Verilator >= 5.006 is needed (--binary --timing).  Ubuntu 24.04 ships 5.020; 22.04 ships 4.038.
vl_ok() {
  command -v verilator >/dev/null || return 1
  v=$(verilator --version | awk '{print $2}')
  [ "$(printf '%s\n5.006\n' "$v" | sort -V | head -1)" = 5.006 ]
}
if ! vl_ok; then
  if [ $CHECK_ONLY = 1 ]; then
    echo "!! verilator >= 5.006 missing"
  else
    echo "== building Verilator v5.020 from source (Ubuntu package too old), ~10 min"
    sudo apt-get install -y autoconf flex bison help2man perl libfl-dev zlib1g-dev ccache
    tmp=$(mktemp -d)
    git clone --depth 1 --branch v5.020 https://github.com/verilator/verilator.git "$tmp/verilator"
    (cd "$tmp/verilator" && autoconf && ./configure && make -j"$(nproc)" && sudo make install)
    rm -rf "$tmp"
  fi
fi

echo
echo "== tool check"
ok=1
for t in verilator iverilog python3 cmake g++; do
  if command -v $t >/dev/null; then
    if [ $t = iverilog ]; then v=$(iverilog -V 2>&1 | head -1); else v=$($t --version 2>&1 | head -1); fi
    printf '   %-10s %s\n' $t "$v"
  else printf '   %-10s MISSING\n' $t; ok=0; fi
done
vl_ok || { echo "   verilator is older than 5.006"; ok=0; }
python3 -c "import numpy, matplotlib" 2>/dev/null && echo "   numpy/matplotlib OK" || { echo "   numpy/matplotlib MISSING"; ok=0; }
if [ $WANT_UHD = 1 ]; then
  if command -v uhd_config_info >/dev/null; then echo "   UHD $(uhd_config_info --version 2>/dev/null | head -1)"
  elif pkg-config --exists uhd 2>/dev/null; then
    echo "   UHD library $(pkg-config --modversion uhd) (uhd-host tools not installed: sudo apt install uhd-host)"
  else echo "   UHD MISSING"; ok=0; fi
fi
command -v vivado >/dev/null && echo "   vivado: $(command -v vivado)" || echo "   vivado: not in PATH (source <Vivado>/settings64.sh when needed)"
[ $ok = 1 ] || { echo "!! some tools are missing"; exit 1; }
[ $CHECK_ONLY = 1 ] && exit 0

if [ $WANT_UHD = 1 ]; then
  echo
  echo "== B210 host program"
  sdr/b210/sw/build.sh
  echo "   (USRP images for the stock FPGA: sudo uhd_images_downloader)"
fi

echo
echo "== quick check: Python golden model + TX RTL regression"
python3 python/run_e2e.py --help >/dev/null && echo "   python models import OK"
sim/reg_tx.sh 2>&1 | tail -3
echo
echo "Done.  Full regression: sim/run_all.sh (about 40 min).  See README.md."
