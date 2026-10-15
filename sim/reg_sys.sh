#!/bin/bash
# Full loopback regression: name modcod pilots rolloff ppm_step cfo_step noise_amp nok [pll]
cd "$(dirname "$0")"
# timeout wrapper: GNU timeout on Linux, gtimeout (brew coreutils) on macOS, none otherwise
to() { local t=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  else "$@"; fi; }
run() {
  d=out/reg_sys/$1; mkdir -p $d
  ./vl.sh tb_sys $d -GMODCOD=$2 -GPILOTS=$3 -GROLLOFF=$4 -GPPM_STEP=$5 -GCFO=$6 -GNOISE=$7 -GNOK=$8 -GPLL_EN=${9:-1} -GMAXCYC=${10:-8000000} > /dev/null || { echo "$1: BUILD FAIL"; return; }
  (cd $d && to 3000 ./obj/tb_sys > sim.log)
  echo "$1: $(grep -E 'SYS RESULT' $d/sim.log | cut -d: -f2-) $(tail -2 $d/sim.log | head -1)"
}
case "$1" in
  quick)
    run q12_clean        4 1 0 0        0         0     6 &
    run q12_es6_cfo_ppm  4 1 1 214748   42949673  7121  32 1 9000000 &
    wait ;;
  *)
    run q12_clean        4 1 0 0        0         0     6 &
    run q12_es6_cfo_ppm  4 1 1 214748   42949673  7121  32 1 9000000 &
    wait
    run p35_es8_cfo      12 1 0 -214748 -21474836 5648  32 1 9000000 &
    run q34_nopil_es8    7 0 2 0        4294967   5648  12 &
    wait
    run p89_es13         16 1 0 0       8589934   3177  12 &
    run q14_es3          1 1 0 0        4294967   10033 12 1 9000000 &
    wait
    run p23_nopil_es10   13 0 0 107374  4294967   4487  12 &
    run q910_es8         10 1 2 0       -8589934  5648  12 &
    wait
    run q12_es2p5        4 1 0 0        4294967   10920 12 1 9000000 &
    run p56_es11_ro20    15 1 2 -107374 12884902  3994  12 &
    wait ;;
esac
