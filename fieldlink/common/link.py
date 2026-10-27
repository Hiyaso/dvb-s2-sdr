"""雙向資料鏈路。

mode = "dvbs2"    實際走 USRP：
    app ──TS──▶ dvbs2-tx ──IQ──▶ usrp_bridge.py ──▶ USRP TX
    app ◀──TS── dvbs2-rx ◀──IQ── usrp_bridge.py ◀── USRP RX
    同一台 USRP 只能被一個行程開啟，所以 TX/RX 都經過 usrp_bridge（一個 GNU Radio
    flowgraph 同時持有 usrp_source 與 usrp_sink），dvbs2-tx / dvbs2-rx 只透過 pipe 交換 IQ。

mode = "loopback" 本機自我測試：dvbs2-tx 的 IQ 直接接到 dvbs2-rx（可加模擬雜訊），不需要 USRP。

mode = "udp"      開發用：TS 封包直接走 UDP，不經過射頻，方便先把應用層調通。

mode = "tcp"      走網際網路（OneWeb 衛星網路、4G、有線）：TS 位元流直接走一條 TCP 連線，
    app ──TS──▶ TCP ──（OneWeb 終端 NAT / 網際網路）──▶ 地面站 TCP server ──TS──▶ app
    OneWeb 使用者終端在 CGNAT 後面、沒有可被連入的位址，所以由 Nano（role=client）主動連到地面站
    （role=server，位址要能被連到：Tailscale 的 100.x.x.x、或路由器轉發到電腦的公網 IP）。
    TCP 本身可靠且有流量控制，不塞 null packet、不節流、嚴重事件不重送；
    斷線由 TCP keepalive / TCP_USER_TIMEOUT（timeout_s）偵測，supervisor 每 3 秒重連。
    server 可同時接多個 Nano（各自一個解多工器），送出的訊息會廣播給全部，Nano 依訊息裡的 node 過濾。

mode = "multi"    可切換的鏈路（links，例如 [tcp, fpga]）：平常只跑 active 那一條；切換時（儀表板按鈕 → SELECT
    settings.link，有 ACK）先把新鏈路帶起來、兩邊都在新鏈路上收到對方的訊息後才把舊的停掉（make-before-break，
    交接只有幾秒），新鏈路 60 秒內沒通就放棄、維持原來那條。心跳、指令、ACK 用 via="all" 走所有「正在跑」的鏈路，
    所以交接期間兩條都送；每條子鏈路各自一個 Link（supervisor、佇列、解多工器），重複收到的由應用層去重。
    Nano 端 auto_commit=True：新鏈路上一收到地面站的訊息就確定切換；地面站則在新鏈路收到心跳後送一個確認 SELECT，
    收到它的 ACK 才停舊鏈路。

mode = "fpga"     實際走 USRP，但數據機在 FPGA 裡（dvb-s2-sdr 專案的 dvbs2_b210 程式 + 自製 B210 image）：
    app ──UDP 127.0.0.1:udp_in──▶ dvbs2_b210 --mode trx --udp-in/--udp-out ──▶ USRP TX
    app ◀──UDP 127.0.0.1:udp_out── dvbs2_b210                               ◀── USRP RX
    一個 dvbs2_b210 行程同時收發（TX/RX 可用不同頻率與 MODCOD），沒資料時自己送 dummy frame，
    所以這裡不必塞 null packet；每個 UDP 封包在空中各自成框並有 CRC，上層的 TS 分段與 CRC32 照舊。

DVB-S2 是連續傳輸，沒有資料時必須塞 null packet (PID 0x1FFF)，否則調變器沒有輸入、
USRP 會 underflow、對方接收端失鎖。送出執行緒在佇列空的時候持續寫 null packet，
寫入 pipe 會阻塞，因此速率自然被 USRP 的取樣率節流。
"""
import fcntl
import functools
import itertools
import logging
import os
import queue
import json
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

from .ts import NULL_PACKET, TsDemuxer, TsMuxer

F_SETPIPE_SZ = 1031  # Linux
BRIDGE = Path(__file__).resolve().parent.parent / "radio" / "usrp_bridge.py"
NULL_BURST = NULL_PACKET * 7
UDP_CHUNK = 188 * 7


def _shrink_pipe(fd: int, size: int = 4096):
    """縮小 pipe 緩衝，降低 TS 在 pipe 裡排隊造成的延遲。"""
    try:
        fcntl.fcntl(fd, F_SETPIPE_SZ, size)
    except OSError:
        pass


def _hostport(s: str):
    host, port = s.rsplit(":", 1)
    return host, int(port)


def _fmt(v) -> str:
    return repr(float(v))


def _radio_cmd(d: dict, key: str, default: str) -> list:
    """dvbs2-tx / dvbs2-rx 是 Python 腳本。用系統 Python（apt 裝的 GNU Radio）明確執行，
    避免在 venv 裡被 venv 的 numpy 等套件影響。"""
    path = shutil.which(d.get(key, default)) or d.get(key, default)
    py = d.get("radio_python")
    return [py, path] if py else [path]


class _UdpSession:
    paced = False

    def __init__(self, cfg: dict):
        u = cfg["udp"]
        self.peer = _hostport(u["peer"])
        self.rate = float(u.get("rate_kbps", 800)) * 1000 / 8
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(_hostport(u["listen"]))
        self.sock.settimeout(0.5)
        self.closed = False

    def alive(self):
        return not self.closed

    def write(self, data: bytes):
        for off in range(0, len(data), UDP_CHUNK):
            chunk = data[off:off + UDP_CHUNK]
            self.sock.sendto(chunk, self.peer)
            time.sleep(len(chunk) / self.rate)

    def read(self):
        try:
            data, _ = self.sock.recvfrom(65536)
            return data
        except socket.timeout:
            return None
        except OSError:
            return b""

    def close(self):
        self.closed = True

    def cleanup(self):
        self.sock.close()


TCP_CHUNK = 64 * 1024


def _tcp_tune(sock: socket.socket, user_timeout_ms: int):
    """keepalive（閒置 10 s 後每 5 s 探測，3 次失敗斷線）＋ 送出資料 user_timeout 沒 ACK 就斷線，
    這樣 OneWeb／NAT 映射失效或對方斷電時，20 幾秒內就會發現並重連，而不是等核心預設的十幾分鐘。"""
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    for opt, val in (("TCP_KEEPIDLE", 10), ("TCP_KEEPINTVL", 5), ("TCP_KEEPCNT", 3), ("TCP_USER_TIMEOUT", user_timeout_ms)):
        if hasattr(socket, opt):
            sock.setsockopt(socket.IPPROTO_TCP, getattr(socket, opt), val)


def _tcp_info(sock: socket.socket) -> dict:
    """Linux TCP_INFO：RTT（ms）與累計重傳數（struct tcp_info 的 tcpi_rtt @68、tcpi_total_retrans @100）。"""
    try:
        raw = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_INFO, 104)
        return {"rtt_ms": round(struct.unpack_from("I", raw, 68)[0] / 1000, 1),
                "retrans": struct.unpack_from("I", raw, 100)[0]}
    except (OSError, struct.error, AttributeError):
        return {}


class _TcpSession:
    """mode=tcp：TS 位元流走 TCP。role=server 等對方連進來（可多個），role=client 主動連到 server。
    read() 回傳 (連線 key, bytes)，bytes 為空表示該連線結束；Link 依 key 各用一個解多工器。"""
    paced = False
    reliable = True

    def __init__(self, cfg: dict, log: logging.Logger):
        t = cfg["tcp"]
        self.role = t.get("role", "client")
        self.log = log
        self.closed = False
        self.user_timeout_ms = int(float(t.get("timeout_s", 20)) * 1000)
        self._q = queue.Queue()
        self._conns = {}          # key -> socket
        self._since = {}          # key -> 連線建立時間
        self._lock = threading.Lock()
        self.srv = None
        self.peer = None
        if self.role == "server":
            self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.srv.bind(_hostport(t["listen"]))
            self.srv.listen(8)
            self.srv.settimeout(0.5)
            self.log.info("TCP server 等待連線：%s", t["listen"])
            threading.Thread(target=self._accept_loop, name="tcp-accept", daemon=True).start()
        elif self.role == "client":
            host, port = _hostport(t["connect"])
            self.peer = f"{host}:{port}"
            sock = socket.create_connection((host, port), timeout=float(t.get("connect_timeout_s", 10)))
            self._add(self.peer, sock)
            self.log.info("TCP 已連上地面站 %s", self.peer)
        else:
            raise ValueError(f"tcp.role 必須是 server 或 client，不是 {self.role!r}")

    # ---- connections ----
    def _add(self, key: str, sock: socket.socket):
        _tcp_tune(sock, self.user_timeout_ms)
        sock.settimeout(self.user_timeout_ms / 1000)
        with self._lock:
            self._conns[key] = sock
            self._since[key] = time.time()
        threading.Thread(target=self._reader, args=(key, sock), name=f"tcp-rx-{key}", daemon=True).start()

    def _drop(self, key: str, why: str = ""):
        with self._lock:
            sock = self._conns.pop(key, None)
            self._since.pop(key, None)
        if sock is None:
            return
        try:
            sock.close()
        except OSError:
            pass
        self.log.warning("TCP 連線結束 %s%s", key, f"：{why}" if why else "")
        if self.role == "client":
            self.closed = True      # 讓 supervisor 重連

    def _accept_loop(self):
        while not self.closed:
            try:
                sock, addr = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            key = f"{addr[0]}:{addr[1]}"
            self.peer = key
            self.log.info("TCP 連線建立：%s", key)
            self._add(key, sock)

    def _reader(self, key: str, sock: socket.socket):
        why = ""
        try:
            while not self.closed:
                try:
                    data = sock.recv(TCP_CHUNK)
                except socket.timeout:
                    continue
                if not data:
                    why = "對方關閉"
                    break
                self._q.put((key, data))
        except OSError as e:
            why = str(e)
        finally:
            self._drop(key, why)
            self._q.put((key, b""))

    # ---- session API ----
    def alive(self):
        return not self.closed

    def write(self, data: bytes):
        with self._lock:
            conns = list(self._conns.items())
        if not conns:
            if self.role == "client":
                raise OSError("TCP 未連線")
            return      # server 沒有人連著：丟掉（指令與通知由應用層重送）
        for key, sock in conns:
            try:
                sock.sendall(data)
            except OSError as e:
                self._drop(key, f"送出失敗 {e}")

    def read(self):
        try:
            return self._q.get(timeout=0.5)
        except queue.Empty:
            return None

    def close(self):
        self.closed = True
        with self._lock:
            socks = list(self._conns.values())
        for sock in socks:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def cleanup(self):
        with self._lock:
            socks = list(self._conns.values())
            self._conns.clear()
            self._since.clear()
        for sock in socks:
            try:
                sock.close()
            except OSError:
                pass
        if self.srv:
            self.srv.close()

    def info(self) -> dict:
        with self._lock:
            conns = list(self._conns.items())
            since = dict(self._since)
        out = {"transport": "tcp", "role": self.role, "connected": bool(conns), "clients": len(conns),
               "peer": conns[-1][0] if conns else self.peer,
               "since": min(since.values()) if since else None}
        if conns:
            out.update(_tcp_info(conns[-1][1]))
        return out


FPGA_CHUNK = 32 * 1024   # dvbs2_b210 每個 UDP 封包各自成框；大封包減少 BBFRAME 補零的浪費


class _FpgaSession:
    paced = False

    def __init__(self, cfg: dict, log_dir: Path, log: logging.Logger):
        f = cfg["fpga"]
        self.closed = False
        udp_in, udp_out = int(f.get("udp_in", 5000)), int(f.get("udp_out", 6000))
        status_port = int(f.get("status_udp", udp_out + 1))
        self.peer = ("127.0.0.1", udp_in)
        self.rate = float(f.get("rate_kbps", 2000)) * 1000 / 8
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", udp_out))
        self.sock.settimeout(0.5)
        # 數據機狀態（和網頁模式 /api/status、/api/spectrum 相同的 JSON），每秒一次
        self.status = {}
        self.spectrum = {}
        self.status_time = 0.0
        self._ssock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._ssock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._ssock.bind(("127.0.0.1", status_port))
        self._ssock.settimeout(0.5)
        program = Path(f["program"]).expanduser()
        cmd = [str(program), "--mode", "trx", "--fpga", str(Path(f["image"]).expanduser()),
               "--tx-freq", _fmt(f["tx_freq"]), "--rx-freq", _fmt(f["rx_freq"]),
               "--bw", _fmt(f.get("bw", 2e6)), "--rolloff", str(f.get("rolloff", 35)),
               "--modcod", str(f.get("modcod", 13)),
               "--tx-gain", _fmt(f.get("tx_gain", 70)), "--rx-gain", _fmt(f.get("rx_gain", 40)),
               "--udp-in", str(udp_in), "--udp-out", f"127.0.0.1:{udp_out}",
               "--status-udp", f"127.0.0.1:{status_port}"]
        if f.get("args"):
            cmd += ["--args", str(f["args"])]
        if f.get("no_pilots"):
            cmd.append("--no-pilots")
        cmd += [str(x) for x in f.get("extra", [])]
        log_dir.mkdir(parents=True, exist_ok=True)
        self._log = open(log_dir / "dvbs2_b210.log", "ab", buffering=0)
        log.info("啟動 %s", " ".join(cmd))
        try:
            self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=self._log,
                                         stderr=subprocess.STDOUT, cwd=str(program.resolve().parent))
        except Exception:
            self.cleanup()
            raise
        threading.Thread(target=self._status_loop, name="modem-status", daemon=True).start()

    def _status_loop(self):
        while not self.closed:
            try:
                data, _ = self._ssock.recvfrom(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                j = json.loads(data.decode("utf-8"))
            except ValueError:
                continue
            if "db" in j:
                self.spectrum = j
            else:
                self.status = j
                self.status_time = time.time()

    def alive(self):
        return not self.closed and self.proc.poll() is None

    def write(self, data: bytes):
        # 整則訊息連續送出（數據機自己排隊），依鏈路容量節流一次；數據機還沒起來時封包會被拒絕，直接丟掉
        for off in range(0, len(data), FPGA_CHUNK):
            try:
                self.sock.sendto(data[off:off + FPGA_CHUNK], self.peer)
            except OSError:
                pass
        time.sleep(len(data) / self.rate)

    def read(self):
        try:
            data, _ = self.sock.recvfrom(65536)
            return data
        except socket.timeout:
            return None
        except OSError:
            return b""

    def close(self):
        self.closed = True
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)      # dvbs2_b210 收到 Ctrl-C 會關閉串流再結束
            try:
                self.proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def cleanup(self):
        self.sock.close()
        self._ssock.close()
        self._log.close()


class _Dvbs2Session:
    paced = True

    def __init__(self, cfg: dict, log_dir: Path, loopback: bool, log: logging.Logger):
        d = cfg["dvbs2"]
        tx, rx = d["tx"], d["rx"]
        samp = _fmt(d["samp_rate"])
        self.closed = False
        self.procs = []
        self._fds = []
        log_dir.mkdir(parents=True, exist_ok=True)

        def logf(name):
            return open(log_dir / f"{name}.log", "ab", buffering=0)

        iq_tx_r, iq_tx_w = os.pipe()
        ts_rx_r, ts_rx_w = os.pipe()

        tx_cmd = _radio_cmd(d, "tx_cmd", "dvbs2-tx") + [
                  "--source", "fd", "--in-fd", "0",
                  "--sink", "fd", "--out-fd", str(iq_tx_w),
                  "--samp-rate", samp, "--sym-rate", _fmt(tx["sym_rate"]),
                  "--modcod", tx["modcod"], "--frame-size", tx.get("frame_size", "normal"),
                  "--rolloff", str(tx.get("rolloff", 0.2))]
        if tx.get("pilots", True):
            tx_cmd.append("--pilots")
        if loopback:
            sim = d.get("loopback", {})
            if sim.get("snr") is not None:
                tx_cmd += ["--snr", _fmt(sim["snr"])]
            if sim.get("freq_offset") is not None:
                tx_cmd += ["--freq-offset", _fmt(sim["freq_offset"])]
        else:
            tx_cmd += ["--fullscale", str(tx.get("fullscale", 0.8))]

        # loopback 時 dvbs2-rx 直接收 dvbs2-tx 的 IQ，參數也沿用 tx 端
        rx_par = tx if loopback else rx
        iq_rx_r = iq_tx_r
        iq_rx_w = None
        if not loopback:
            iq_rx_r, iq_rx_w = os.pipe()

        rx_cmd = _radio_cmd(d, "rx_cmd", "dvbs2-rx") + [
                  "--source", "fd", "--in-fd", str(iq_rx_r),
                  "--sink", "fd", "--out-fd", str(ts_rx_w),
                  "--samp-rate", samp, "--sym-rate", _fmt(rx_par["sym_rate"]),
                  "--modcod", rx_par["modcod"], "--frame-size", rx_par.get("frame_size", "normal"),
                  "--rolloff", str(rx_par.get("rolloff", 0.2)),
                  "--pilots", "on" if rx_par.get("pilots", True) else "off",
                  "--ldpc-iterations", str(rx.get("ldpc_iterations", 25))]
        if d.get("rx_log", True):
            rx_cmd += ["--log", "--log-period", "5"]

        try:
            log.info("啟動 %s", " ".join(tx_cmd))
            self.tx = subprocess.Popen(tx_cmd, stdin=subprocess.PIPE, stdout=logf("dvbs2-tx"),
                                       stderr=subprocess.STDOUT, pass_fds=(iq_tx_w,))
            self.procs.append(self.tx)

            if not loopback:
                u = d["usrp"]
                bridge_cmd = [d.get("bridge_python", sys.executable), str(BRIDGE),
                              "--tx-fd", str(iq_tx_r), "--rx-fd", str(iq_rx_w),
                              "--args", u.get("args", ""), "--samp-rate", samp,
                              "--tx-freq", _fmt(tx["freq"]), "--rx-freq", _fmt(rx["freq"]),
                              "--tx-gain", _fmt(tx.get("gain", 40)), "--rx-gain", _fmt(rx.get("gain", 30)),
                              "--tx-antenna", u.get("tx_antenna", "TX/RX"),
                              "--rx-antenna", u.get("rx_antenna", "RX2"),
                              "--otw-format", u.get("otw_format", "sc16")]
                if rx.get("lo_offset"):
                    bridge_cmd += ["--rx-lo-offset", _fmt(rx["lo_offset"])]
                log.info("啟動 %s", " ".join(bridge_cmd))
                self.procs.append(subprocess.Popen(bridge_cmd, stdout=logf("usrp_bridge"),
                                                   stderr=subprocess.STDOUT,
                                                   pass_fds=(iq_tx_r, iq_rx_w)))

            log.info("啟動 %s", " ".join(rx_cmd))
            self.procs.append(subprocess.Popen(rx_cmd, stdout=logf("dvbs2-rx"),
                                               stderr=subprocess.STDOUT,
                                               pass_fds=(iq_rx_r, ts_rx_w)))
        except Exception:
            self.close()
            for fd in (iq_tx_r, iq_tx_w, ts_rx_r, ts_rx_w, iq_rx_w):
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            if iq_rx_w is not None:
                os.close(iq_rx_r)
            raise

        # 父行程不需要的 pipe 端點要關掉，子行程結束時才會正確收到 EOF / EPIPE
        for fd in {iq_tx_r, iq_tx_w, ts_rx_w, iq_rx_r} | ({iq_rx_w} if iq_rx_w is not None else set()):
            os.close(fd)

        self.ts_in = self.tx.stdin.fileno()
        _shrink_pipe(self.ts_in)
        self.ts_out = ts_rx_r
        self._fds.append(ts_rx_r)

    def alive(self):
        return not self.closed and all(p.poll() is None for p in self.procs)

    def write(self, data: bytes):
        view = memoryview(data)
        while view:
            n = os.write(self.ts_in, view)
            view = view[n:]

    def read(self):
        return os.read(self.ts_out, 188 * 64)

    def close(self):
        self.closed = True
        for p in self.procs:
            if p.poll() is None:
                p.terminate()
        deadline = time.time() + 5
        for p in self.procs:
            try:
                p.wait(timeout=max(0.1, deadline - time.time()))
            except subprocess.TimeoutExpired:
                p.kill()

    def cleanup(self):
        for fd in self._fds:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            self.tx.stdin.close()
        except Exception:
            pass


class Link:
    """on_message(msg_type:int, msg_id:int, payload:bytes) 會在接收執行緒中被呼叫。"""

    def __init__(self, cfg: dict, name: str, on_message, base_dir: Path = Path(".")):
        self.cfg = cfg
        self.mode = cfg.get("mode", "dvbs2")
        self.pid = int(cfg.get("pid", 0x100))
        self.on_message = on_message
        self.log = logging.getLogger(f"link.{name}")
        self.log_dir = base_dir / cfg.get("log_dir", "logs")
        self._q = queue.PriorityQueue()
        self._order = itertools.count()
        self._msg_id = itertools.count(1)
        self._mux = TsMuxer(self.pid)
        self._demux = TsDemuxer(self.pid, self._deliver)
        self._demuxers = {}        # tcp server：每條連線一個解多工器（key -> TsDemuxer）
        self._demux_done = {}      # 已結束連線的累計統計
        self._running = False
        self._session = None
        self._stats = {"mode": self.mode, "state": "stopped", "tx_messages": 0, "tx_bytes": 0,
                       "rx_bytes": 0, "restarts": 0, "dropped": 0}

    # ---- public ---------------------------------------------------------
    @property
    def running(self) -> bool:
        return self._running

    def start(self):
        if self._running:
            return
        while not self._q.empty():          # 停掉期間排隊的舊訊息（縮圖、心跳）不要在重新啟動時一次倒出去
            try:
                self._q.get_nowait()
            except queue.Empty:
                break
        self._running = True
        threading.Thread(target=self._supervise, name="link-supervisor", daemon=True).start()

    def stop(self):
        self._running = False
        if self._session:
            self._session.close()

    def send(self, msg_type: int, payload: bytes, priority: int = 0, via: str = "active"):
        """priority 0 = 重要（報告、通知），1 = 可丟棄（心跳）。回傳 msg_id。via 只在 multi 模式有意義。"""
        if priority > 0 and self._q.qsize() > 32:
            self._stats["dropped"] += 1
            return None
        mid = next(self._msg_id) & 0xFFFF
        self._q.put((priority, next(self._order), (int(msg_type), mid, payload)))
        return mid

    @property
    def reliable(self) -> bool:
        """TCP 等可靠傳輸：應用層不必為了掉包重送。"""
        return self.mode == "tcp"

    @property
    def active(self) -> str:
        return self.mode

    def set_active(self, name: str) -> bool:
        return False            # 單一鏈路不能切換

    def ready(self) -> bool:
        """這條鏈路現在能不能送資料：tcp 要連上；fpga 要數據機行程活著且 3 秒內有狀態；其他只要在跑。"""
        sess = self._session
        if sess is None or self._stats["state"] != "running" or not sess.alive():
            return False
        if self.mode == "tcp":
            return bool(sess.info().get("connected"))
        if self.mode == "fpga":
            return bool(sess.status) and time.time() - sess.status_time < 3
        return True

    def stats(self) -> dict:
        s = dict(self._stats)
        agg = dict(self._demux_done)
        for d in [self._demux, *list(self._demuxers.values())]:
            for k, v in d.stats.items():
                agg[k] = agg.get(k, 0) + v
        s.update(agg)
        s["queue"] = self._q.qsize()
        sess = self._session
        if sess is not None and hasattr(sess, "info"):
            s.update(sess.info())
        return s

    def modem(self) -> dict | None:
        """fpga 模式：數據機最新狀態（/api/status 格式），3 秒沒更新視為沒有。"""
        sess = self._session
        if sess is None or not hasattr(sess, "status") or not sess.status:
            return None
        if time.time() - sess.status_time > 3:
            return None
        return sess.status

    def spectrum(self) -> dict | None:
        sess = self._session
        if sess is None or not hasattr(sess, "spectrum") or not sess.spectrum:
            return None
        return sess.spectrum

    # ---- internals ------------------------------------------------------
    def _deliver(self, mtype, mid, flags, payload):
        try:
            self.on_message(mtype, mid, payload)
        except Exception:
            self.log.exception("處理收到的訊息時發生錯誤")

    def _open(self):
        if self.mode == "udp":
            return _UdpSession(self.cfg)
        if self.mode == "tcp":
            return _TcpSession(self.cfg, self.log)
        if self.mode == "fpga":
            return _FpgaSession(self.cfg, self.log_dir, self.log)
        if self.mode in ("dvbs2", "loopback"):
            return _Dvbs2Session(self.cfg, self.log_dir, self.mode == "loopback", self.log)
        raise ValueError(f"未知的 link.mode: {self.mode}（可用 tcp / fpga / udp / dvbs2 / loopback）")

    def _sleep(self, secs: float):
        end = time.time() + secs
        while self._running and time.time() < end:
            time.sleep(0.5)

    def _supervise(self):
        fails = 0           # 連續「啟動失敗」或「啟動後 10 秒內就結束」的次數：放慢重試、少印 log（例如 USRP 沒接）
        while self._running:
            try:
                session = self._open()
            except Exception as e:
                fails += 1
                delay = 5 if fails <= 6 else 15 if fails <= 20 else 30
                if fails <= 3 or fails % 12 == 0:
                    self.log.error("鏈路啟動失敗：%s（%d 秒後重試%s）", e, delay, f"，已連續失敗 {fails} 次" if fails > 1 else "")
                self._stats["state"] = "error"
                self._sleep(delay)
                continue
            self._session = session
            self._stats["state"] = "running"
            t_start = time.time()
            threads = [threading.Thread(target=self._tx_loop, args=(session,), daemon=True),
                       threading.Thread(target=self._rx_loop, args=(session,), daemon=True)]
            for t in threads:
                t.start()
            while self._running and session.alive():
                time.sleep(0.5)
            session.close()
            for t in threads:
                t.join(timeout=5)
            session.cleanup()
            if self._running:
                self._stats["restarts"] += 1
                self._stats["state"] = "restarting"
                quick = time.time() - t_start < 10
                fails = fails + 1 if quick else 0
                delay = 3 if fails <= 3 else 15 if fails <= 20 else 30
                if fails <= 3 or fails % 12 == 0:
                    if self.mode == "tcp":
                        self.log.warning("TCP 鏈路中斷，%d 秒後重新連線", delay)
                    else:
                        self.log.warning("鏈路子行程結束，%d 秒後重新啟動（請看 %s/*.log%s）", delay, self.log_dir,
                                         f"；已連續 {fails} 次很快結束" if fails > 1 else "")
                self._sleep(delay)
        self._stats["state"] = "stopped"

    def _tx_loop(self, session):
        while not session.closed:
            try:
                if session.paced:
                    _, _, item = self._q.get_nowait()
                else:
                    _, _, item = self._q.get(timeout=0.2)
            except queue.Empty:
                if not session.paced:
                    continue
                data = NULL_BURST
            else:
                mtype, mid, payload = item
                data = self._mux.packetize(mtype, mid, payload)
                self._stats["tx_messages"] += 1
                self._stats["tx_bytes"] += len(data)
            try:
                session.write(data)
            except OSError:
                break

    def _rx_loop(self, session):
        while not session.closed:
            try:
                item = session.read()
            except OSError:
                break
            if item is None:
                continue
            if isinstance(item, tuple):          # tcp：(連線 key, bytes)
                key, data = item
                if not data:
                    done = self._demuxers.pop(key, None)
                    if done:
                        for k, v in done.stats.items():
                            self._demux_done[k] = self._demux_done.get(k, 0) + v
                    continue
                demux = self._demuxers.get(key)
                if demux is None:
                    demux = self._demuxers[key] = TsDemuxer(self.pid, self._deliver)
            else:
                data = item
                if not data:
                    break
                demux = self._demux
            self._stats["rx_bytes"] += len(data)
            demux.feed(data)


class MultiLink:
    """mode=multi：多條 Link 擇一使用、可切換。平常只有 active 在跑；begin_switch() 先啟動新鏈路，
    commit_switch() 把 active 換過去並停掉舊的，超過 SWITCH_TIMEOUT 沒確認就 abort_switch()。"""
    mode = "multi"
    SWITCH_TIMEOUT = 60.0

    def __init__(self, cfg: dict, name: str, on_message, base_dir: Path = Path("."), auto_commit: bool = False):
        self.cfg = cfg
        self.names = [str(n) for n in (cfg.get("links") or ["tcp", "fpga"])]
        self.active = str(cfg.get("active") or self.names[0])
        if self.active not in self.names:
            raise ValueError(f"link.active={self.active!r} 不在 link.links={self.names}")
        self.auto_commit = auto_commit      # True（Nano）：新鏈路一收到對方訊息就確定切換
        self.log = logging.getLogger(f"link.{name}")
        self.on_message = on_message
        self.links = {}
        for n in self.names:
            sub = dict(cfg)
            sub["mode"] = n
            self.links[n] = Link(sub, f"{name}.{n}", functools.partial(self._on, n), base_dir=base_dir)
        self.switching = None               # {"to": name, "since": t}
        self.last_switch = None             # {"to": name, "result": "ok" | "timeout", "ts": t}
        self.last_rx = None
        self.rx_on = {n: 0.0 for n in self.names}
        self.rx_by = {n: 0 for n in self.names}
        self.tx_by = {n: 0 for n in self.names}
        self._lock = threading.Lock()
        self._alive = True
        threading.Thread(target=self._watch, name="link-switch-watch", daemon=True).start()

    def _on(self, name, mtype, mid, payload):
        self.rx_on[name] = time.time()
        self.last_rx = name
        self.rx_by[name] += 1
        sw = self.switching
        if sw and name == sw["to"] and self.auto_commit:
            self.commit_switch()            # Nano：地面站已經在新鏈路上說話了 → 確定切換
        self.on_message(mtype, mid, payload)

    def _watch(self):
        while self._alive:
            sw = self.switching
            if sw and time.time() - sw["since"] > self.SWITCH_TIMEOUT:
                self.abort_switch("timeout")
            time.sleep(1)

    # ---- public（和 Link 相同的介面）----
    def start(self):
        self.links[self.active].start()

    def stop(self):
        self._alive = False
        for l in self.links.values():
            l.stop()

    def begin_switch(self, name: str) -> bool:
        """啟動新鏈路、進入交接；舊的先留著。name 不存在、已是 active、或正在切換 → False。"""
        name = str(name)
        with self._lock:
            if name not in self.links or name == self.active or self.switching:
                return False
            self.switching = {"to": name, "since": time.time()}
        self.log.info("開始切換資料鏈路 %s → %s（新鏈路兩邊都通了才停舊的，最多等 %d 秒）", self.active, name, int(self.SWITCH_TIMEOUT))
        self.links[name].start()
        return True

    def commit_switch(self):
        with self._lock:
            sw = self.switching
            if not sw:
                return
            old, self.active, self.switching = self.active, sw["to"], None
        self.last_switch = {"to": self.active, "result": "ok", "ts": time.time()}
        self.log.info("資料鏈路已切換到 %s，停止 %s", self.active, old)
        self.links[old].stop()

    def abort_switch(self, why: str = "timeout"):
        with self._lock:
            sw = self.switching
            if not sw:
                return
            self.switching = None
        self.last_switch = {"to": sw["to"], "result": why, "ts": time.time()}
        self.log.warning("切換到 %s 失敗（%s），維持 %s", sw["to"], why, self.active)
        self.links[sw["to"]].stop()

    def set_active(self, name: str) -> bool:
        """立刻硬切（不交接）：停舊的、啟動新的。正常切換請用 begin_switch()。"""
        name = str(name)
        if name not in self.links:
            return False
        if name == self.active:
            return True
        old, self.active = self.active, name
        self.log.info("資料鏈路硬切 %s → %s", old, name)
        self.links[old].stop()
        self.links[name].start()
        return True

    @property
    def reliable(self) -> bool:
        return self.links[self.active].reliable

    def ready(self) -> bool:
        return self.links[self.active].ready()

    def send(self, msg_type: int, payload: bytes, priority: int = 0, via: str = "active"):
        """via="active"：資料走目前的鏈路；"all"：所有正在跑的鏈路（交接期間兩條）；或指定鏈路名稱。"""
        if via == "all":
            targets = [n for n in self.names if self.links[n].running] or [self.active]
        elif via in self.links:
            targets = [via]
        else:
            targets = [self.active]
        mid = None
        for n in targets:
            r = self.links[n].send(msg_type, payload, priority)
            if r is not None:
                self.tx_by[n] += 1
                mid = r if mid is None else mid
        return mid

    def stats(self) -> dict:
        subs = {n: l.stats() for n, l in self.links.items()}
        for n, st in subs.items():
            st["ready"] = self.links[n].ready()
            st["running"] = self.links[n].running
        sw = self.switching
        agg = {"mode": "multi", "active": self.active,
               "switching": dict(sw, age_s=round(time.time() - sw["since"], 1)) if sw else None,
               "last_switch": self.last_switch,
               "last_rx": self.last_rx, "rx_by": dict(self.rx_by), "tx_by": dict(self.tx_by),
               "state": subs[self.active]["state"], "links": subs}
        for k in ("messages", "crc_errors", "cc_errors", "restarts", "dropped", "queue", "rx_bytes", "tx_bytes", "tx_messages"):
            agg[k] = sum(int(st.get(k, 0) or 0) for st in subs.values())
        return agg

    def modem(self) -> dict | None:
        l = self.links.get("fpga")
        return l.modem() if l else None

    def spectrum(self) -> dict | None:
        l = self.links.get("fpga")
        return l.spectrum() if l else None


def make_link(cfg: dict, name: str, on_message, base_dir: Path = Path("."), **multi_kw):
    """依 cfg["mode"] 建立 Link 或 MultiLink（兩者介面相同）；multi_kw 只給 MultiLink（auto_commit）。"""
    if cfg.get("mode") == "multi":
        return MultiLink(cfg, name, on_message, base_dir, **multi_kw)
    return Link(cfg, name, on_message, base_dir)
