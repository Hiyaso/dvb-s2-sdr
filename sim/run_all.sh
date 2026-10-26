#!/bin/bash
# run_all.sh -- quick regression of the whole design with Verilator (Linux or macOS).
#   ./run_all.sh          TX, LDPC, BCH, FEC chain, RX front end, quick full loopback (about 40 min)
#   ./run_all.sh full     ... plus the 10 full-loopback scenarios (~1 h more)
# Requirements: verilator >= 5.0, python3 with numpy (see README).
cd "$(dirname "$0")"
command -v verilator >/dev/null || { echo "verilator not found"; exit 1; }
python3 -c "import numpy" 2>/dev/null || { echo "python3 numpy not found"; exit 1; }
verilator --version
mkdir -p out
log() { echo; echo "=================== $1"; }
log "TX vs. golden model";          ./reg_tx.sh   2>&1 | tee out/run_tx.log   | tail -3
log "LDPC decoder (bit-exact)";      ./reg_ldpc.sh 2>&1 | tee out/run_ldpc.log | grep -c PASS | sed 's/$/ \/ 16 PASS/'
log "BCH decoder";                   ./reg_bch.sh  2>&1 | tee out/run_bch.log  | tail -1
log "FEC chain (demap+LDPC+BCH)";    ./reg_fec.sh  2>&1 | tee out/run_fec.log
log "PLS Hadamard transform";        (./vl.sh tb_wht out/wht > /dev/null && out/wht/obj/tb_wht | grep -E "PASS|FAIL") 2>&1 | tee out/run_wht.log
log "RX front end (AGC, timing)";    ./reg_rxfe.sh 2>&1 | tee out/run_rxfe.log
log "full loopback";                 ./reg_sys.sh ${1:-quick} 2>&1 | tee out/run_sys.log
log "B210 integration (2 boards)";   ../sdr/b210/sim/reg_b210.sh 2>&1 | tee out/run_b210.log
echo; echo "logs in sim/out/run_*.log (B210 runs in sdr/b210/sim/out)"
