#!/bin/bash
# TX regression: all supported MODCODs, pilots on/off, the three roll-offs.
cd "$(dirname "$0")"
pass=0; fail=0
for mc in 1 2 3 4 5 6 7 8 9 10 12 13 14 15 16; do
  for pil in 0 1; do
    ro=$(( (mc + pil) % 3 ))
    d=out/reg_tx/m${mc}_p${pil}
    ./vl.sh tb_tx $d -GMODCOD=$mc -GPILOTS=$pil -GROLLOFF=$ro -GNFRAMES=3 > /dev/null || { echo "BUILD FAIL $mc"; fail=$((fail+1)); continue; }
    (cd $d && ./obj/tb_tx > sim.log && python3 ../../../tools/check_tx.py $mc $pil $ro . > check.log 2>&1)
    if grep -q PASS $d/check.log; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL modcod=$mc pilots=$pil"; tail -3 $d/check.log; fi
  done
done
echo "TX regression: pass=$pass fail=$fail"
