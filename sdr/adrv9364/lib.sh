#!/bin/bash
# lib.sh -- helpers for sdr/adrv9364/build_fpga.sh and sdr/adrv9364/make_sd_image.sh (sourced, not run).
# Downloads go to sdr/adrv9364/dl (git-ignored); nothing needs root.

ADRV=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$(dirname "$ADRV")")       # repo root (sdr/adrv9364 -> .)
DL=$ADRV/dl
TOOLS=$DL/tools
OUT=$ADRV/out
mkdir -p "$DL" "$TOOLS" "$OUT"

# ADI Kuiper Linux 2026.1.0 (armhf), boot files built from ADI HDL hdl_2026_r1 4840c81f2
KUIPER_URL=https://packages.analog.com/public/raw/files/kuiper_full_32_image_2026.1.0.zip
KUIPER_ZIP=$DL/kuiper_full_32_image_2026.1.0.zip
KUIPER_ZIP_SIZE=2074358964
KUIPER_BOARD=zynq-adrv9364-z7020-bob/lvds     # boot files of the SOM (ADI carrier, LVDS)
ARM_TC_URL=https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-linux-gnueabihf.tar.xz
ARM_TC=$TOOLS/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-linux-gnueabihf
MTOOLS_URL=https://ftp.gnu.org/gnu/mtools/mtools-4.0.48.tar.gz

die() { echo "!! $*" >&2; exit 1; }
say() { echo "== $*"; }

ensure_kuiper() {
  KUIPER_IMG=$(ls "$DL"/image_*-ADI-Kuiper-Linux-armhf.img 2>/dev/null | head -1)
  [ -n "$KUIPER_IMG" ] && return
  if [ "$(stat -c %s "$KUIPER_ZIP" 2>/dev/null)" != "$KUIPER_ZIP_SIZE" ]; then
    say "downloading Kuiper Linux 2026.1.0 (2 GB)"
    curl -fL --retry 3 -C - -o "$KUIPER_ZIP" "$KUIPER_URL" || die "download of $KUIPER_URL failed"
  fi
  say "unpacking the Kuiper image"
  (cd "$DL" && unzip -o -q "$KUIPER_ZIP") || die "unzip failed"
  KUIPER_IMG=$(ls "$DL"/image_*-ADI-Kuiper-Linux-armhf.img | head -1)
}

ensure_mtools() {
  export MTOOLS_SKIP_CHECK=1
  if [ ! -x "$TOOLS/inst/bin/mcopy" ]; then
    say "building mtools (FAT access without root)"
    (cd "$TOOLS" && curl -fsL "$MTOOLS_URL" | tar xz && cd mtools-4.0.48 \
      && ./configure --prefix="$TOOLS/inst" --disable-floppyd > /dev/null && make -j"$(nproc)" > /dev/null 2>&1 \
      && make install > /dev/null 2>&1) || die "mtools build failed"
  fi
  export PATH=$TOOLS/inst/bin:$PATH
}

ensure_toolchain() {
  if [ ! -x "$ARM_TC/bin/arm-none-linux-gnueabihf-g++" ]; then
    say "downloading the Arm GNU toolchain 14.2 (armhf)"
    (cd "$TOOLS" && curl -fsL "$ARM_TC_URL" | tar xJ) || die "toolchain download failed"
  fi
}

# bootgen: Vivado's if on the PATH, otherwise the open-source one (github.com/Xilinx/bootgen)
ensure_bootgen() {
  if command -v bootgen > /dev/null; then BOOTGEN=$(command -v bootgen); return; fi
  BOOTGEN=$TOOLS/bootgen/build/bin/bootgen
  if [ ! -x "$BOOTGEN" ]; then
    say "building bootgen"
    rm -rf "$TOOLS/bootgen"
    git clone -q --depth 1 https://github.com/Xilinx/bootgen.git "$TOOLS/bootgen" \
      && make -C "$TOOLS/bootgen" -j"$(nproc)" > "$TOOLS/bootgen/build.log" 2>&1 || die "bootgen build failed (needs libssl-dev)"
  fi
}

# BOOT.BIN = ADI's FSBL + bitstream + ADI's u-boot (same layout as Kuiper's zynq.bif)
make_boot_bin() { # bitfile out
  kuiper_bootfiles
  ensure_bootgen
  local t; t=$(mktemp -d)
  cp "$DL/boot/sys/fsbl.elf" "$DL"/boot/sys/u-boot*.elf "$t/"
  cp "$1" "$t/system_top.bit"
  printf 'the_ROM_image:\n{\n[bootloader] ./fsbl.elf\n./system_top.bit\n./%s\n}\n' \
    "$(basename "$(ls "$DL"/boot/sys/u-boot*.elf | head -1)")" > "$t/zynq.bif"
  (cd "$t" && "$BOOTGEN" -arch zynq -image zynq.bif -o BOOT.BIN -w on > bootgen.log 2>&1) \
    || { cat "$t/bootgen.log"; die "bootgen failed"; }
  cp "$t/BOOT.BIN" "$2"
  rm -rf "$t"
}

# start sector of partition N of an image
part_start() { sfdisk -d "$1" | awk -v n="$2" -F'[=,]' '$1 ~ "img"n" *:" || $1 ~ "[^0-9]"n" *:" {gsub(/ /,"",$2); print $2}'; }
part_size()  { sfdisk -d "$1" | awk -v n="$2" -F'[=,]' '$1 ~ "img"n" *:" || $1 ~ "[^0-9]"n" *:" {gsub(/ /,"",$4); print $4}'; }

# ADI's boot files for the SOM from the Kuiper boot partition -> $DL/boot
#   $DL/boot/{BOOT.BIN, devicetree.dtb, uImage, uEnv.txt}, $DL/boot/sys/{fsbl.elf, u-boot*.elf, ...}
kuiper_bootfiles() {
  [ -f "$DL/boot/sys/fsbl.elf" ] && [ -f "$DL/boot/uEnv.txt" ] && return
  ensure_kuiper
  ensure_mtools
  local p="$KUIPER_IMG@@$(( $(part_start "$KUIPER_IMG" 1) * 512 ))"
  mkdir -p "$DL/boot/sys"
  mcopy -o -n -i "$p" "::/$KUIPER_BOARD/BOOT.BIN" "::/$KUIPER_BOARD/devicetree.dtb" \
    "::/$KUIPER_BOARD/bootgen_sysfiles.tgz" ::/zynq-common/uImage ::/zynq-common/uEnv.txt \
    ::/zynq-common/version_zynq.txt "$DL/boot/" || die "boot files not found in the Kuiper image"
  tar xzf "$DL/boot/bootgen_sysfiles.tgz" -C "$DL/boot/sys"
}
