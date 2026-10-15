#!/bin/bash
# vl.sh <top> <outdir> [extra verilator args...]  -- build a testbench with Verilator
set -e
TOP=$1; OUT=$2; shift 2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/rtl/common/*.v $ROOT/rtl/gen/*.v $ROOT/rtl/tx/*.v $ROOT/rtl/rx/*.v $ROOT/rtl/top/*.v $ROOT/rtl/b210/*.v"
mkdir -p "$OUT"
verilator --binary --timing -j 2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-PINCONNECTEMPTY \
  -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-BLKSEQ -Wno-INITIALDLY \
  --top-module "$TOP" --Mdir "$OUT/obj" -o "$TOP" -O3 \
  "$ROOT/sim/tb/$TOP.v" $(ls $SRC 2>/dev/null) "$@" > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
echo "built $OUT/obj/$TOP"
