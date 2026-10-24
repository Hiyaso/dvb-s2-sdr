#!/bin/bash
# build_fpga.sh -- FPGA image (ADRV9364-Z7020 SOM + DVB-S2 modem) and BOOT.BIN.
#
#   ADI HDL hdl_2026_r1 at the commit of the Kuiper 2026.1.0 boot files, projects/adrv9364z7020
#   + adrv9364/hdl (block design with dvbs2_adrv, SOM-only top), Vivado 2025.1 (ML Standard).
#   Another Vivado version: ADI's version check is switched off (ADI_IGNORE_VERSION_CHECK=1).
#
#   VIVADO_SETTINGS=<path>/settings64.sh   (default: newest Vivado found under /tools/Xilinx,
#                                           /opt/Xilinx, ~/Xilinx; 2025.1 preferred)
#
# Output: adrv9364/out/system_top.bit, system_top.xsa, BOOT.BIN, build_fpga.log  (~40-70 min)
set -e
source "$(dirname "$0")/lib.sh"
ADI_REPO=https://github.com/analogdevicesinc/hdl.git
ADI_BRANCH=hdl_2026_r1
ADI_SHA=4840c81f2af172b036cb3ccb3f9f2dc45ed9c1d3
HDL=$ADRV/adi-hdl
PRJ=$HDL/projects/adrv9364z7020/dvbs2
LOG=$OUT/build_fpga.log

# ---- Vivado
if [ -z "$VIVADO_SETTINGS" ]; then
  for f in /tools/Xilinx/2025.1/Vivado/settings64.sh /tools/Xilinx/Vivado/2025.1/settings64.sh \
           /opt/Xilinx/2025.1/Vivado/settings64.sh /opt/Xilinx/Vivado/2025.1/settings64.sh \
           $HOME/Xilinx/2025.1/Vivado/settings64.sh $HOME/Xilinx/Vivado/2025.1/settings64.sh; do
    [ -f "$f" ] && { VIVADO_SETTINGS=$f; break; }
  done
fi
if [ -z "$VIVADO_SETTINGS" ]; then
  VIVADO_SETTINGS=$(ls -d /tools/Xilinx/*/Vivado/settings64.sh /tools/Xilinx/Vivado/*/settings64.sh \
    /opt/Xilinx/*/Vivado/settings64.sh /opt/Xilinx/Vivado/*/settings64.sh \
    $HOME/Xilinx/*/Vivado/settings64.sh $HOME/Xilinx/Vivado/*/settings64.sh 2>/dev/null | sort -V | tail -1)
fi
[ -f "$VIVADO_SETTINGS" ] || die "Vivado not found: set VIVADO_SETTINGS=<Vivado>/settings64.sh"
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"
VER=$(vivado -version 2>/dev/null | grep -o -m1 'v20[0-9][0-9]\.[0-9]' | tr -d v)
say "Vivado $VER ($VIVADO_SETTINGS)"
if [ "$VER" != "2025.1" ]; then
  echo "   note: ADI hdl_2026_r1 is qualified for Vivado 2025.1; building with $VER (version check off)"
  export ADI_IGNORE_VERSION_CHECK=1
fi

# ---- ADI HDL
if [ ! -d "$HDL/.git" ]; then
  say "cloning ADI HDL ($ADI_BRANCH)"
  git clone -q --filter=blob:none -b "$ADI_BRANCH" "$ADI_REPO" "$HDL"
fi
if [ "$(git -C "$HDL" rev-parse HEAD)" != "$ADI_SHA" ]; then
  git -C "$HDL" fetch -q origin "$ADI_BRANCH" || true
  git -C "$HDL" checkout -q "$ADI_SHA"
fi

# ---- project: adrv9364/hdl + modem RTL
say "project $PRJ"
rm -rf "$PRJ"
mkdir -p "$PRJ/rtl"
cp "$ADRV"/hdl/{Makefile,system_bd.tcl,system_project.tcl,system_top.v,dvbs2_adrv.xdc} "$PRJ/"
cp "$ROOT"/rtl/{common,gen,tx,rx}/*.v "$ADRV"/rtl/*.v "$PRJ/rtl/"

# ---- build (libraries + project, ADI make flow)
say "building (log: $LOG)"
if ! (cd "$PRJ" && make) > "$LOG" 2>&1; then
  tail -30 "$LOG"
  ls "$PRJ"/*.log 2>/dev/null | head
  die "FPGA build failed, see $LOG and $PRJ/*.log"
fi
BIT=$(ls "$PRJ"/*.runs/impl_1/system_top.bit 2>/dev/null | head -1)
XSA=$(ls "$PRJ"/*.sdk/system_top.xsa 2>/dev/null | head -1)
[ -f "$BIT" ] || die "no bitstream (see $LOG)"
cp "$BIT" "$OUT/system_top.bit"
[ -f "$XSA" ] && cp "$XSA" "$OUT/system_top.xsa"
grep -h -A3 "Design Timing Summary" "$PRJ"/*.runs/impl_1/*timing_summary_routed.rpt 2>/dev/null | head -8 || true
# ADI's flow always writes timing_impl.log (report_timing_summary -warn_on_violation)
if [ -f "$PRJ/timing_impl.log" ]; then
  if grep -q "All user specified timing constraints are met" "$PRJ/timing_impl.log"; then
    echo "timing met: $(awk '/Design Timing Summary/{f=1} f && /^ +-?[0-9]+\.[0-9]+ /{print "WNS " $1 " ns, WHS " $5 " ns"; exit}' "$PRJ/timing_impl.log")"
  else
    echo "!! timing not met:"; cat "$PRJ/timing_impl.log"
  fi
fi

# ---- BOOT.BIN
make_boot_bin "$OUT/system_top.bit" "$OUT/BOOT.BIN"
say "done: $OUT/BOOT.BIN (next: adrv9364/make_sd_image.sh)"
