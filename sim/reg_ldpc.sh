#!/bin/bash
# LDPC decoder regression: every code rate (QPSK and 8PSK), near-threshold noise.
cd "$(dirname "$0")"
./vl.sh tb_ldpc out/reg_ldpc/build > /dev/null || exit 1
pass=0; fail=0
run() { # modcod esn0 nframes maxit
  d=out/reg_ldpc/m$1_$2
  mkdir -p $d
  python3 gen_ldpc_vec.py $d $1 $2 $3 $4 $1
  (cd $d && ../build/obj/tb_ldpc +maxit=$4 > sim.log; python3 ../../../check_ldpc.py > check.log)
  if grep -q PASS $d/check.log; then pass=$((pass+1)); echo "PASS modcod=$1 EsN0=$2 $(grep 'tb done' $d/sim.log | cut -d: -f2)"; else fail=$((fail+1)); echo "FAIL modcod=$1 EsN0=$2"; cat $d/check.log | head -5; fi
}
run 1 -1.0 3 25 & run 2 0.0 3 25 & wait
run 3 1.0 3 25 & run 4 1.8 3 25 & wait
run 5 2.8 3 25 & run 6 3.5 3 25 & wait
run 7 4.5 3 25 & run 8 5.2 3 25 & wait
run 9 5.8 3 25 & run 10 7.0 3 25 & wait
run 12 6.3 3 25 & run 13 7.2 3 25 & wait
run 14 8.5 3 25 & run 15 9.8 3 25 & wait
run 16 11.2 3 25 & run 4 0.5 2 10 & wait
echo "LDPC regression done"
