#!/bin/bash
# B210 integration test (outputs in sdr/b210/sim/out): two dvbs2_b210 instances (TX board, RX board) + channel emulator.
cd "$(dirname "$0")"
VL=../../../sim/vl.sh
to() { local t=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  else "$@"; fi; }
run() { # name modcod pilots data noise [extra verilator args]
  d=out/reg_b210/$1; mkdir -p $d
  $VL tb_b210 $d -GMODCOD=$2 -GPILOTS=$3 -GDATA=$4 -GNOISE=$5 "${@:6}" +define+DVBS2_FIR_FOLD +define+SPARTAN6 > /dev/null || { echo "$1: BUILD FAIL"; return; }
  (cd $d && to 5000 ./obj/tb_b210 > sim.log)
  echo "$1: $(grep -E 'payload|ber_errors|constellation|PASS|FAIL' $d/sim.log | tr '\n' ' ')"
}
run p23_data_es10   13 1 1 4487 &
run q12_prbs_es4    4  1 0 8953 &
# QPSK file mode below the frame capacity: DUMMY PLFRAMEs between data frames
run q12_data_dummy  4  1 1 7121 -GBYTE_EVERY=25 -GNOK=12 -GMAXCYC=12000000 &
wait
