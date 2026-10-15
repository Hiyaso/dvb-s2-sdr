#!/bin/bash
# BCH decoder regression: random codes, 0..12 errors and uncorrectable frames, vs python model
cd "$(dirname "$0")"
d=out/bch; mkdir -p $d
./vl.sh tb_bch $d > /dev/null || exit 1
python3 gen_bch_vec.py $d ${1:-40} ${2:-7} > /dev/null
(cd $d && ./obj/tb_bch > sim.log && python3 ../../check_bch.py)
