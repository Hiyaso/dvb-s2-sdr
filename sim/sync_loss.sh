#!/bin/bash
# Full-loopback FER/BER near threshold (steady state after 45 frames), to compare with
# the ideal-synchronisation curves of sim/ber.  CFO 0.5 % Rs, +20 ppm, pilots on.
cd "$(dirname "$0")"
run() { # name modcod noise nok
  d=out/sync_loss/$1; mkdir -p $d
  ./vl.sh tb_sys $d -GMODCOD=$2 -GPILOTS=1 -GROLLOFF=0 -GPPM_STEP=85899 -GCFO=10737418 -GNOISE=$3 \
     -GNOK=$4 -GSETTLE=45 -GMAXCYC=60000000 > /dev/null || { echo "$1: BUILD FAIL"; return; }
  (cd $d && ./obj/tb_sys > sim.log)
  echo "$1: $(grep 'STEADY STATE' $d/sim.log)"
}
run q12_es0p5 4 13395 ${1:-150} &
run p23_es6p8 13 6486 ${1:-150} &
wait
