"""雙向資料鏈路。

mode = "dvbs2"    實際走 USRP：
    app ──TS──▶ dvbs2-tx ──IQ──▶ usrp_bridge.py ──▶ USRP TX
    app ◀──TS── dvbs2-rx ◀──IQ── usrp_bridge.py ◀── USRP RX
    同一台 USRP 只能被一個行程開啟，所以 TX/RX 都經過 usrp_bridge（一個 GNU Radio
    flowgraph 同時持有 usrp_source 與 usrp_sink），dvbs2-tx / dvbs2-rx 只透過 pipe 交換 IQ。

mode = "loopback" 本機自我測試：dvbs2-tx 的 IQ 直接接到 dvbs2-rx（可加模擬雜訊），不需要 USRP。

mode = "udp"      開發用：TS 封包直接走 UDP，不經過射頻，方便先把應用層調通。

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
import itertools
import logging
import os
import queue
import json
import shutil
import signal
import socket
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
        self._running = False
        self._session = None
        self._stats = {"mode": self.mode, "state": "stopped", "tx_messages": 0, "tx_bytes": 0,
                       "rx_bytes": 0, "restarts": 0, "dropped": 0}

    # ---- public ---------------------------------------------------------
    def start(self):
        self._running = True
        threading.Thread(target=self._supervise, name="link-supervisor", daemon=True).start()

    def stop(self):
        self._running = False
        if self._session:
            self._session.close()

    def send(self, msg_type: int, payload: bytes, priority: int = 0):
        """priority 0 = 重要（報告、通知），1 = 可丟棄（心跳）。回傳 msg_id。"""
        if priority > 0 and self._q.qsize() > 32:
            self._stats["dropped"] += 1
            return None
        mid = next(self._msg_id) & 0xFFFF
        self._q.put((priority, next(self._order), (int(msg_type), mid, payload)))
        return mid

    def stats(self) -> dict:
        s = dict(self._stats)
        s.update(self._demux.stats)
        s["queue"] = self._q.qsize()
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
        if self.mode == "fpga":
            return _FpgaSession(self.cfg, self.log_dir, self.log)
        if self.mode in ("dvbs2", "loopback"):
            return _Dvbs2Session(self.cfg, self.log_dir, self.mode == "loopback", self.log)
        raise ValueError(f"未知的 link.mode: {self.mode}（可用 fpga / udp / dvbs2 / loopback）")

    def _supervise(self):
        while self._running:
            try:
                session = self._open()
            except Exception as e:
                self.log.error("鏈路啟動失敗：%s（5 秒後重試）", e)
                self._stats["state"] = "error"
                time.sleep(5)
                continue
            self._session = session
            self._stats["state"] = "running"
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
                self.log.warning("鏈路子行程結束，3 秒後重新啟動（請看 %s/*.log）", self.log_dir)
                time.sleep(3)
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
                data = session.read()
            except OSError:
                break
            if data is None:
                continue
            if not data:
                break
            self._stats["rx_bytes"] += len(data)
            self._demux.feed(data)
