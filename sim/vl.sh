#!/bin/bash
# vl.sh <top> <outdir> [extra verilator args...]  -- build a testbench with Verilator
# The testbench <top>.v is looked up in sim/tb, sdr/b210/sim, sdr/z7020/sim and sdr/adrv9364/sim; for a board
# project the project's own rtl/ is compiled in addition to the core modem RTL.
set -e
TOP=$1; OUT=$2; shift 2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/rtl/common/*.v $ROOT/rtl/gen/*.v $ROOT/rtl/tx/*.v $ROOT/rtl/rx/*.v"
TB=""
for d in "$ROOT/sim/tb" "$ROOT/sdr/b210/sim" "$ROOT/sdr/z7020/sim" "$ROOT/sdr/adrv9364/sim"; do
  [ -f "$d/$TOP.v" ] && { TB="$d/$TOP.v"; break; }
done
[ -n "$TB" ] || { echo "testbench $TOP.v not found"; exit 1; }
case "$TB" in "$ROOT"/sdr/*) SRC="$SRC $(dirname "$(dirname "$TB")")/rtl/*.v" ;; esac
mkdir -p "$OUT"
verilator --binary --timing -j 2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-PINCONNECTEMPTY \
  -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-BLKSEQ -Wno-INITIALDLY \
  --top-module "$TOP" --Mdir "$OUT/obj" -o "$TOP" -O3 \
  "$TB" $(ls $SRC 2>/dev/null) "$@" > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
echo "built $OUT/obj/$TOP"
