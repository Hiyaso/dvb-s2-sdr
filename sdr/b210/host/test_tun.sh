#!/bin/bash
# test_tun.sh -- TUN payload path of dvbs2_b210 without a B210 (test_tun.cpp, same code as the program).
#   ./test_tun.sh              socket pairs instead of TUN devices (no root): clean link, corrupted bytes,
#                              input faster than the link; prints PASS / FAIL
#   sudo ./test_tun.sh netns   real TUN interfaces dvbs0 in two network namespaces, 10.60.0.1 <-> 10.60.0.2
#                              over an emulated 236 kB/s link each way (8PSK 2/3 at 1 Msym/s) with the
#                              two-way link check of dvbs2_b210 --host: carrier, ping both ways, UDP
#                              10.60.0.1 -> 10.60.0.2, TCP (iperf3); prints PASS / FAIL
set -e
cd "$(dirname "$0")"
mkdir -p build
g++ -std=c++17 -O2 -Wall -Wno-unused-function -Wno-unused-variable -I../../host_common -o build/test_tun test_tun.cpp -pthread
[ "$1" = netns ] || exec build/test_tun pair

[ "$(id -u)" = 0 ] || { echo "the netns test needs root: sudo $0 netns"; exit 1; }
A=dvbs_test_a B=dvbs_test_b
cleanup() { kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; ip netns del $A 2>/dev/null || true; ip netns del $B 2>/dev/null || true; }
trap cleanup EXIT
cleanup
ip netns add $A
ip netns add $B
build/test_tun netns $A $B 10.60.0.1/24 10.60.0.2/24 236000 > build/test_tun_link.log 2>&1 &
PID=$!
ok=1
for i in $(seq 50); do [ "$(grep -c 'link UP' build/test_tun_link.log)" -ge 2 ] && break; sleep 0.1; done
head -1 build/test_tun_link.log
echo "== two-way link check: carrier on both interfaces"
grep "link " build/test_tun_link.log | head -4
for ns in $A $B; do
  ip netns exec $ns ip link show dvbs0 | grep -q LOWER_UP && echo "$ns dvbs0: carrier" || { echo "$ns dvbs0: NO carrier"; ok=0; }
done

echo "== ping 10.60.0.1 -> 10.60.0.2"
out=$(ip netns exec $A ping -c 10 -i 0.2 -W 2 10.60.0.2) || ok=0; echo "$out" | tail -2
echo "== ping 10.60.0.2 -> 10.60.0.1"
out=$(ip netns exec $B ping -c 10 -i 0.2 -W 2 10.60.0.1) || ok=0; echo "$out" | tail -2

echo "== one-way UDP 10.60.0.1 -> 10.60.0.2: 1000 datagrams of 1000 B at 100 kB/s"
ip netns exec $B timeout 20 python3 - > build/test_tun_udp.log <<'EOF' &
import hashlib, socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('10.60.0.2', 5000))
s.settimeout(3)
n = good = 0
try:
    while True:
        d = s.recv(65536)
        n += 1
        good += hashlib.sha256(d[8:]).digest()[:8] == d[:8]
except socket.timeout:
    pass
print(n, good)
EOF
RX=$!
sleep 0.5
ip netns exec $A python3 - <<'EOF'
import hashlib, os, socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(1000):
    p = os.urandom(992)
    s.sendto(hashlib.sha256(p).digest()[:8] + p, ('10.60.0.2', 5000))
    time.sleep(0.01)
EOF
wait $RX || true
read n good < build/test_tun_udp.log || true
echo "received ${n:-0} datagrams, ${good:-0} intact"
[ "${good:-0}" -ge 990 ] && [ "${n:-0}" = "${good:-0}" ] || ok=0

if command -v iperf3 > /dev/null; then
  echo "== TCP over the link (iperf3, 8 s)"
  ip netns exec $B iperf3 -s -1 -B 10.60.0.2 > /dev/null 2>&1 &
  sleep 0.5
  ip netns exec $A iperf3 -c 10.60.0.2 -t 8 -f k | grep -E "sender|receiver" || ok=0
fi
tail -1 build/test_tun_link.log
[ $ok = 1 ] && echo PASS || echo FAIL
