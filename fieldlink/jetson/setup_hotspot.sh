#!/usr/bin/env bash
# 把 Jetson 的 Wi-Fi 設成熱點，手機連上後 Jetson 的 IP 固定是 10.42.0.1
# 用法：sudo ./setup_hotspot.sh [SSID] [密碼(至少8碼)] [介面]
#   BAND=a  5 GHz（預設，避開 2.4 GHz 干擾）；網卡或法規不支援時改 BAND=bg
set -euo pipefail
SSID="${1:-JetsonCam}"
PASS="${2:-jetson1234}"
IFACE="${3:-wlan0}"
BAND="${BAND:-a}"
CON=jetson-hotspot

iw reg set TW || true
nmcli connection delete "$CON" >/dev/null 2>&1 || true
nmcli connection add type wifi ifname "$IFACE" con-name "$CON" autoconnect yes ssid "$SSID"
nmcli connection modify "$CON" \
  802-11-wireless.mode ap 802-11-wireless.band "$BAND" \
  ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS"
nmcli connection up "$CON"
echo "熱點已啟動：SSID=$SSID  Jetson IP=10.42.0.1（開機自動啟動）"
echo "注意：$IFACE 當熱點後就不能同時連外網，Jetson 上網請用有線網路。"
