#!/bin/bash
# FEC chain loopback regression (symbol level, AWGN)
cd "$(dirname "$0")"
# timeout wrapper: GNU timeout on Linux, gtimeout (brew coreutils) on macOS, none otherwise
to() { local t=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  else "$@"; fi; }
run() {
  d=out/reg_fec/m$1_$2; mkdir -p $d
  ./vl.sh tb_fec $d -GMODCOD=$1 -GESN0=$2 -GNFRAMES=$3 > /dev/null || { echo "BUILD FAIL $1"; return; }
  (cd $d && to 1200 ./obj/tb_fec > sim.log)
  echo "modcod=$1 EsN0=$2: $(grep 'FEC tb' $d/sim.log) $(tail -2 $d/sim.log | head -1)"
}
run 1 0.0 3 & run 12 7.0 3 & wait
run 16 12.0 3 & run 10 8.0 3 & wait
run 13 8.0 3 & run 6 4.0 3 & wait
