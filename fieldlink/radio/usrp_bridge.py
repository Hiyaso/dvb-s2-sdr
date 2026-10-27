#!/usr/bin/env python3
"""USRP 橋接 flowgraph：一個行程同時持有 USRP 的 TX 與 RX。

    fd(--tx-fd, fc32 IQ, 來自 dvbs2-tx) ──▶ uhd.usrp_sink
    uhd.usrp_source ──▶ fd(--rx-fd, fc32 IQ, 給 dvbs2-rx)

由 common/link.py 啟動，不需要手動執行。需用安裝了 GNU Radio 3.10 + gr-uhd 的系統 Python。
所有訊息都印到 stderr（stdout 不使用）。
"""
import argparse
import signal
import sys
import time

from gnuradio import blocks, gr, uhd


def log(*a):
    print("[usrp_bridge]", *a, file=sys.stderr, flush=True)


class UsrpBridge(gr.top_block):
    def __init__(self, a):
        gr.top_block.__init__(self, "usrp_bridge", catch_exceptions=True)
        stream = uhd.stream_args(cpu_format="fc32", otw_format=a.otw_format, channels=[0])

        self.src = uhd.usrp_source(a.args, stream)
        self.snk = uhd.usrp_sink(a.args, stream, "")

        self.src.set_samp_rate(a.samp_rate)
        self.snk.set_samp_rate(a.samp_rate)
        for name, dev in (("RX", self.src), ("TX", self.snk)):
            actual = dev.get_samp_rate()
            if abs(actual - a.samp_rate) > 1:
                log(f"警告：{name} 取樣率要求 {a.samp_rate:.0f}，實際 {actual:.0f}；"
                    "dvbs2-tx/rx 的 --samp-rate 必須一致")

        if a.rx_lo_offset:
            self.src.set_center_freq(uhd.tune_request(a.rx_freq, a.rx_lo_offset), 0)
        else:
            self.src.set_center_freq(a.rx_freq, 0)
        self.snk.set_center_freq(a.tx_freq, 0)
        self.src.set_gain(a.rx_gain, 0)
        self.snk.set_gain(a.tx_gain, 0)
        self.src.set_antenna(a.rx_antenna, 0)
        self.snk.set_antenna(a.tx_antenna, 0)
        log(f"TX {a.tx_freq/1e6:.3f} MHz gain {a.tx_gain} dB ({a.tx_antenna}) | "
            f"RX {a.rx_freq/1e6:.3f} MHz gain {a.rx_gain} dB ({a.rx_antenna}) | "
            f"fs {a.samp_rate/1e6:.3f} Msps")

        self.fd_in = blocks.file_descriptor_source(gr.sizeof_gr_complex, a.tx_fd, False)
        self.fd_out = blocks.file_descriptor_sink(gr.sizeof_gr_complex, a.rx_fd)
        self.connect(self.fd_in, self.snk)
        self.connect(self.src, self.fd_out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--tx-fd", type=int, required=True)
    p.add_argument("--rx-fd", type=int, required=True)
    p.add_argument("--args", default="")
    p.add_argument("--samp-rate", type=float, required=True)
    p.add_argument("--tx-freq", type=float, required=True)
    p.add_argument("--rx-freq", type=float, required=True)
    p.add_argument("--tx-gain", type=float, default=40)
    p.add_argument("--rx-gain", type=float, default=30)
    p.add_argument("--tx-antenna", default="TX/RX")
    p.add_argument("--rx-antenna", default="RX2")
    p.add_argument("--rx-lo-offset", type=float, default=0.0)
    p.add_argument("--otw-format", default="sc16")
    a = p.parse_args()

    tb = UsrpBridge(a)

    def stop(*_):
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    tb.start()
    log("running")
    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
