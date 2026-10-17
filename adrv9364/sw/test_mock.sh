#!/bin/bash
# test_mock.sh -- PC test of dvbs2_adrv with the software FPGA model (build.sh MOCK=1):
# UDP datagrams in -> TX payload FIFO -> "air" (error-free BBFRAMEs) -> RX frames -> UDP out,
# plus the web API (status JSON, MODCOD change, save settings).  Prints PASS / FAIL.
set -e
cd "$(dirname "$0")"
MOCK=1 ./build.sh > /dev/null
T=$(mktemp -d)
trap 'kill $PID 2>/dev/null || true; rm -rf "$T"' EXIT
cat > "$T/dvbs2.conf" <<EOF
mode = trx
web = 18080
web-bind = 127.0.0.1
modcod = 13
bw = 1.35e6
udp-in = 127.0.0.1:15000
udp-out = 127.0.0.1:15001
EOF
./build/dvbs2_adrv_mock --config "$T/dvbs2.conf" --web-root ./web --file-dir "$T" > "$T/log" 2>&1 &
PID=$!
sleep 1.5
python3 - "$T" <<'EOF'
import json, os, random, socket, sys, time, urllib.request
T = sys.argv[1]
base = 'http://127.0.0.1:18080'
def get(p): return urllib.request.urlopen(base + p, timeout=5).read()
def post(p, d=b''): return urllib.request.urlopen(urllib.request.Request(base + p, data=d), timeout=5).read()
ok = True
s = json.loads(get('/api/status'))
print('status: board %s fpga %s, tx %s rx %s, data %s' % (s['board'], s['fpga']['version'], s['tx']['mode'], s['rx']['mode'], s['config']['data']))
ok &= s['tx']['mode'] == 'udp' and s['rx']['mode'] == 'udp'
ok &= b'DVB-S2 Modem' in get('/')
# UDP link: 1500 datagrams of 1..1400 bytes at ~150 kB/s (8PSK 2/3 capacity at 1 Msym/s ~236 kB/s)
import threading, queue
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); rx.bind(('127.0.0.1', 15001))
rq = queue.Queue()
def rx_thread():
    while True: rq.put(rx.recv(70000))
threading.Thread(target=rx_thread, daemon=True).start()
def recv(timeout):
    return rq.get(timeout=timeout)
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
random.seed(1)
sent = [os.urandom(random.randint(1, 1400)) for _ in range(1500)]
t0 = time.time(); nb = 0
for i, d in enumerate(sent):
    tx.sendto(d, ('127.0.0.1', 15000)); nb += len(d)
    while nb / max(1e-3, time.time() - t0) > 150e3: time.sleep(0.001)
got = []
try:
    while len(got) < len(sent): got.append(recv(3))
except queue.Empty: pass
inorder = got == sent[:len(got)]
print('udp: sent %d datagrams (%d B), received %d, identical and in order: %s' % (len(sent), nb, len(got), inorder))
ok &= len(got) == len(sent) and inorder
s = json.loads(get('/api/status'))
print('tx: udp_packets %d drops %d fill %d B | rx: udp_packets %d lost %d bad %d' % (s['tx']['udp_packets'], s['tx']['udp_drops'], s['tx']['fill'], s['rx']['udp_packets'], s['rx']['udp_lost'], s['rx']['udp_bad']))
# a single small datagram must go out promptly (idle fill completes the BBFRAME)
tx.sendto(b'hello', ('127.0.0.1', 15000)); t1 = time.time()
try: d = recv(3); print('single datagram %r after %.0f ms' % (d, 1e3 * (time.time() - t1))); ok &= d == b'hello'
except queue.Empty: print('single datagram: timeout'); ok = False
# modem change + save
post('/api/config', b'modcod=4&pilots=0')
time.sleep(0.8)
s = json.loads(get('/api/status'))
print('after modcod change: %s pilots %s' % (s['config']['modcod'], s['config']['pilots']))
ok &= s['config']['modcod'] == 'QPSK 1/2' and not s['config']['pilots']
post('/api/save'); time.sleep(0.5)
conf = open(T + '/dvbs2.conf').read()
ok &= 'modcod = 4' in conf and 'udp-out = 127.0.0.1:15001' in conf
print('saved config ok:', 'modcod = 4' in conf)
tx.sendto(b'after restart', ('127.0.0.1', 15000))
try: d = recv(5); ok &= d == b'after restart'; print('datagram after restart: %r' % d)
except queue.Empty: print('datagram after restart: timeout'); ok = False
print('PASS' if ok else 'FAIL')
EOF
kill $PID; wait $PID 2>/dev/null || true
tail -3 "$T/log"
