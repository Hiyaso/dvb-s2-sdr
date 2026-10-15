#!/bin/bash
# build.sh -- Verilator build of the BER harness (RTL ldpc_dec + bch_dec, C++ TX/channel/demapper)
set -e
cd "$(dirname "$0")"
R=../../rtl
rm -rf obj
verilator --cc --exe --build -j 2 -O3 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-PINCONNECTEMPTY \
  -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-BLKSEQ --top-module ber_dut --Mdir obj \
  -CFLAGS "-O2" ber_dut.v $R/rx/ldpc_dec.v $R/rx/ldpc_dec_core.v $R/rx/ldpc_rot.v $R/rx/bch_dec.v \
  $R/common/ram_sdp.v $R/gen/*.v ber_main.cpp > build.log 2>&1 || { tail -30 build.log; exit 1; }
echo "built obj/Vber_dut"
