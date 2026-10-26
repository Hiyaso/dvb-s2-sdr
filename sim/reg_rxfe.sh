#!/bin/bash
cd "$(dirname "$0")"
# name ppm_step delay cfo noise max_evm_db
run() {
  d=out/reg_rxfe/$1; mkdir -p $d
  ./vl.sh tb_rxfe $d -GNSYM=40000 -GPPM_STEP=$2 -GDELAY=$3 -GCFO=$4 -GNOISE=$5 > /dev/null || { echo "$1: BUILD FAIL"; return; }
  (cd $d && ./obj/tb_rxfe > sim.log && python3 ../../../tools/check_rxfe.py 4 1 $(python3 -c "print($4*2/2**32)") $6 > check.log)
  echo "$1: $(cat $d/check.log | tr '\n' ' ')"
}
run clean 0 20000 0 0 -30 &
run ppm100 429497 40000 0 0 -30 &
wait
run ppm-200_cfo1pct -858993 10000 21474836 0 -30 &
run es10_ppm50 214748 30000 21474836 4487 -9 &
wait
run es3_ppm50 214748 30000 21474836 10037 -2 &
run es0_ppm100 429497 50000 0 14178 1 &
wait
