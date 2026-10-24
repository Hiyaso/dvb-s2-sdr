#!/bin/bash
# ADRV9364 integration test (outputs in adrv9364/sim/out): two dvbs2_adrv instances (TX SOM, RX SOM)
# + channel emulator, payload over AXI-Lite (TXDATA / RXLEN / RXDATA), separate AD9364 sample clocks.
cd "$(dirname "$0")"
VL=../../sim/vl.sh
to() { local t=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  else "$@"; fi; }
run() { # name modcod pilots data noise [extra verilator args]
  d=out/reg_adrv/$1; mkdir -p $d
  $VL tb_adrv $d -GMODCOD=$2 -GPILOTS=$3 -GDATA=$4 -GNOISE=$5 "${@:6}" > /dev/null || { echo "$1: BUILD FAIL"; return; }
  (cd $d && to 5000 ./obj/tb_adrv > sim.log)
  echo "$1: $(grep -E 'payload|ber_errors|constellation|PASS|FAIL' $d/sim.log | tr '\n' ' ')"
}
run p23_data_es10   13 1 1 4487 &
run q12_prbs_es4    4  1 0 8953 &
# QPSK 1/4: 374-byte data field (last word of each frame holds 2 bytes), no pilots
run q14_data_np     1  0 1 8953 -GNOK=12 &
wait
