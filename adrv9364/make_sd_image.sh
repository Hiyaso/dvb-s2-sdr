#!/bin/bash
# make_sd_image.sh -- SD card image for the ADRV9364-Z7020 SOM (no root needed):
#   ADI Kuiper Linux 2026.1.0 (armhf) + BOOT.BIN with the DVB-S2 FPGA image + the dvbs2_adrv
#   service (web page on port 80, UDP data link), static IP on eth0, desktop services off.
#
#   IP=192.168.30.1/24   static address of eth0 (one image per unit: change it for a second SOM)
#   GW=                  default gateway (optional)
#   NAME=dvbs2           host name
#   BOOT_BIN=<file>      default adrv9364/out/BOOT.BIN (adrv9364/build_fpga.sh)
#   STOCK=1              use ADI's original BOOT.BIN (no modem): tests boot + network of the carrier
#   XZ=1                 also write a compressed .img.xz
#
# Output: adrv9364/out/dvbs2-adrv9364.img (7.2 GB, SD card >= 8 GB; write with balenaEtcher / dd)
set -e
source "$(dirname "$0")/lib.sh"
IP=${IP:-192.168.30.1/24}
NAME=${NAME:-dvbs2}
case "$IP" in */*) ;; *) IP=$IP/24 ;; esac
ADDR=${IP%/*}
IMG=$OUT/dvbs2-adrv9364${STOCK:+-stock}.img

ensure_kuiper
kuiper_bootfiles
ensure_mtools
ensure_toolchain
if [ -n "$STOCK" ]; then
  BOOT_BIN=$DL/boot/BOOT.BIN
else
  BOOT_BIN=${BOOT_BIN:-$OUT/BOOT.BIN}
  [ -f "$BOOT_BIN" ] || die "$BOOT_BIN not found: run adrv9364/build_fpga.sh first (or STOCK=1 for ADI's FPGA image)"
fi

say "building dvbs2_adrv (ARM)"
CROSS=$ARM_TC/bin/arm-none-linux-gnueabihf- "$ADRV/sw/build.sh" > /dev/null

say "copying the Kuiper image -> $IMG"
cp --sparse=always "$KUIPER_IMG" "$IMG"
P1=$(part_start "$IMG" 1); P2=$(part_start "$IMG" 2); N2=$(part_size "$IMG" 2)

# ---- boot partition (FAT): BOOT.BIN, devicetree, kernel, u-boot environment of the SOM
say "boot partition"
FAT="$IMG@@$((P1 * 512))"
mcopy -o -i "$FAT" "$BOOT_BIN" ::/BOOT.BIN
mcopy -o -i "$FAT" "$DL/boot/devicetree.dtb" "$DL/boot/uImage" "$DL/boot/uEnv.txt" ::/

# ---- root partition (ext4), edited with debugfs on an extracted copy
say "root partition"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
dd if="$IMG" of="$W/root.ext4" bs=512 skip="$P2" count="$N2" conv=sparse status=none
# Kuiper's image is shipped with an unreplayed journal: replay it first (as the kernel would
# at the first mount), otherwise the replay at boot would undo parts of the edits below
rc=0; e2fsck -fy "$W/root.ext4" > "$W/fsck0.log" 2>&1 || rc=$?
[ "$rc" -le 1 ] || { tail -20 "$W/fsck0.log"; die "root file system check failed before editing (e2fsck $rc)"; }
F=$ADRV/rootfs
cp "$F/dvbs2.conf" "$W/dvbs2.conf"
printf '%s\n' "$NAME" > "$W/hostname"
printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost ip6-loopback\nff02::1\t\tip6-allnodes\nff02::2\t\tip6-allrouters\n\n127.0.1.1\t%s\n' "$NAME" > "$W/hosts"
{
  printf '[connection]\nid=dvbs2-eth0\ntype=ethernet\ninterface-name=eth0\nautoconnect=true\nautoconnect-priority=100\n\n'
  printf '[ethernet]\n\n[ipv4]\nmethod=manual\naddress1=%s%s\n' "$IP" "${GW:+,$GW}"
  printf 'may-fail=false\n\n[ipv6]\nmethod=disabled\n\n[proxy]\n'
} > "$W/dvbs2-eth0.nmconnection"
# the RX output default: broadcast in the SOM's subnet
python3 - "$W/dvbs2.conf" "$IP" <<'EOF'
import ipaddress, sys
p, ip = sys.argv[1], sys.argv[2]
bc = ipaddress.ip_interface(ip).network.broadcast_address
s = open(p).read().replace('@BROADCAST@', str(bc))
open(p, 'w').write(s)
EOF

NM=/etc/NetworkManager/system-connections
SD=/etc/systemd/system
cat > "$W/cmds" <<EOF
mkdir /usr/local/share/dvbs2
mkdir /usr/local/share/dvbs2/web
mkdir /var/lib/dvbs2
cd /usr/local/bin
rm dvbs2_adrv
write $ADRV/sw/build/dvbs2_adrv dvbs2_adrv
cd /usr/local/share/dvbs2/web
rm index.html
write $ADRV/../host_common/web/index.html index.html
cd /etc
rm dvbs2.conf
write $W/dvbs2.conf dvbs2.conf
rm hostname
write $W/hostname hostname
rm hosts
write $W/hosts hosts
cd $SD
rm dvbs2.service
write $F/dvbs2.service dvbs2.service
rm $SD/multi-user.target.wants/dvbs2.service
symlink $SD/multi-user.target.wants/dvbs2.service $SD/dvbs2.service
rm "$NM/Wired connection 1"
rm $NM/eth0-linklocal
cd $NM
rm dvbs2-eth0.nmconnection
write $W/dvbs2-eth0.nmconnection dvbs2-eth0.nmconnection
rm $SD/multi-user.target.wants/x11vnc.service
rm $SD/multi-user.target.wants/xserver.service
rm $SD/display-manager.service
rm $SD/default.target
symlink $SD/default.target /usr/lib/systemd/system/multi-user.target
EOF
# owner root, permissions
for f in /usr/local/share/dvbs2 /usr/local/share/dvbs2/web /var/lib/dvbs2; do
  echo "sif $f uid 0"; echo "sif $f gid 0"; echo "sif $f mode 040755"
done >> "$W/cmds"
for f in /usr/local/bin/dvbs2_adrv:0100755 /usr/local/share/dvbs2/web/index.html:0100644 /etc/dvbs2.conf:0100644 \
         /etc/hostname:0100644 /etc/hosts:0100644 $SD/dvbs2.service:0100644 $NM/dvbs2-eth0.nmconnection:0100600; do
  echo "sif ${f%%:*} uid 0"; echo "sif ${f%%:*} gid 0"; echo "sif ${f%%:*} mode ${f##*:}"
done >> "$W/cmds"
debugfs -w -f "$W/cmds" "$W/root.ext4" > "$W/debugfs.log" 2>&1 || { cat "$W/debugfs.log"; die "debugfs failed"; }
e2fsck -fn "$W/root.ext4" > "$W/fsck.log" 2>&1 || { tail -20 "$W/fsck.log"; die "root file system check failed"; }
# check what landed
for f in /usr/local/bin/dvbs2_adrv /etc/dvbs2.conf $SD/dvbs2.service $NM/dvbs2-eth0.nmconnection; do
  debugfs -R "stat $f" "$W/root.ext4" 2>/dev/null | grep -q "Type: regular" || die "$f missing in the image"
done
dd if="$W/root.ext4" of="$IMG" bs=512 seek="$P2" conv=notrunc,sparse status=none

say "done: $IMG"
echo "   eth0 $IP${GW:+ gw $GW}, host name $NAME, web page http://$ADDR/  (ssh analog@$ADDR, password analog)"
if [ -n "$XZ" ]; then
  say "compressing"
  xz -T0 -k -f "$IMG" && echo "   $IMG.xz"
fi
