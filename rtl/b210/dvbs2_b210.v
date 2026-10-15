// dvbs2_b210.v -- DVB-S2 TX + RX inside one radio of the USRP B210 FPGA image
// (instantiated in radio_legacy.v by the patch in b210/patch_uhd_fpga.py).
//
// Runs on radio_clk.  The DUC/DDC of the radio set the sample rate:
//   sample rate = 2 * Rs,  master clock / sample rate (interpolation/decimation) >= 8
//
//   TX  host samples --(tx_en=0)--------------------------------> DUC
//                    --(tx_en=1)-- [payload bytes] -> dvbs2_tx --> DUC
//       The host keeps the TX stream running (it sets the timing and keeps the
//       radio in TX); with tx_data=1 each host sample may carry one payload byte
//       (I = {7'b0, valid, byte}); otherwise the payload is the internal PRBS-23.
//   RX  DDC samples --> dvbs2_rx --> decoded data-field bytes
//                   --(rx_data=0)--> host (I/Q samples, as usual)
//       (rx_data=1)  bytes --> host: I = {6'b0, last, valid, byte}, Q = byte counter
//
// Control: UHD user settings registers (multi_usrp::get_user_settings_iface(0),
// device argument "enable_user_regs"):  poke32(4*n, value) writes register n,
// peek64(8*m) reads status words 2m (low half) and 2m+1 (high half).
`timescale 1ns/1ps
module dvbs2_b210 #(
    parameter LDPC_P = 45
) (
    input  wire        clk,
    input  wire        rst,
    // user settings bus
    input  wire        set_stb,
    input  wire [7:0]  set_addr,
    input  wire [31:0] set_data,
    input  wire [7:0]  rb_addr,
    output reg  [63:0] rb_data,
    // TX: host samples (new_tx_control) and samples to the DUC
    input  wire [31:0] tx_host_sample,
    input  wire        tx_strobe,
    input  wire        tx_run,
    output wire [31:0] tx_duc_sample,
    // RX: samples from the DDC and samples to the RX framer (host)
    input  wire [31:0] rx_ddc_sample,
    input  wire        rx_strobe,
    input  wire        rx_run,
    output wire [31:0] rx_host_sample
);
localparam [31:0] ID      = 32'h44564232;   // "DVB2"
localparam [31:0] VERSION = 32'h00020000;   // 2.0 (B210)

// ---------------------------------------------------------------- registers
localparam [31:0] D_CTRL  = 32'h0000_01C0;  // pll_en, agc_en, early_stop
localparam [31:0] D_TXCFG = 32'h0000_0104;  // QPSK 1/2, pilots, roll-off 0.35
localparam [31:0] D_AGC   = {12'd0, 4'd12, 16'd6000};
localparam [31:0] D_TIM   = {19'd0, 5'd18, 3'd0, 5'd9};
localparam [31:0] D_FS    = {8'd32, 8'd2, 8'd90, 8'd141};
localparam [31:0] D_FLL   = {12'd0, 4'd12, 4'd6, 4'd1, 4'd1, 4'd1};
localparam [31:0] D_FEC   = {5'd0, 3'd0, 2'd0, 6'd25, 8'd16, 8'd24};
reg [31:0] r_ctrl, r_txcfg, r_agc, r_tim, r_fs, r_fll, r_fec;
reg        clr;
always @(posedge clk) begin
    if (rst) begin
        r_ctrl <= D_CTRL; r_txcfg <= D_TXCFG; r_agc <= D_AGC; r_tim <= D_TIM;
        r_fs <= D_FS; r_fll <= D_FLL; r_fec <= D_FEC; clr <= 1'b0;
    end else begin
        clr <= 1'b0;
        if (set_stb) case (set_addr)
            8'd0: r_ctrl  <= set_data;
            8'd1: r_txcfg <= set_data;
            8'd2: r_agc   <= set_data;
            8'd3: r_tim   <= set_data;
            8'd4: r_fs    <= set_data;
            8'd5: r_fll   <= set_data;
            8'd6: r_fec   <= set_data;
            8'd7: clr     <= 1'b1;
            default: ;
        endcase
    end
end
wire tx_en   = r_ctrl[0];
wire rx_en   = r_ctrl[1];
wire tx_data = r_ctrl[2];
wire rx_data = r_ctrl[3];
wire pll_en  = r_ctrl[6];
wire agc_en  = r_ctrl[7];
wire es_en   = r_ctrl[8];

reg rst_tx, rst_rx;
always @(posedge clk) begin
    rst_tx <= rst | !tx_en;
    rst_rx <= rst | !rx_en;
end

// ---------------------------------------------------------------- TX
// payload bytes from the host stream
wire       pl_full, pl_empty;
wire [7:0] pl_dout;
wire       pl_rd;
wire [11:0] pl_count;
wire       host_byte = tx_strobe && tx_run && tx_en && tx_data && tx_host_sample[24];
b210_fifo #(.W(8), .AW(11)) u_plfifo (
    .clk(clk), .rst(rst_tx), .wr(host_byte), .din(tx_host_sample[23:16]), .full(pl_full),
    .rd(pl_rd), .dout(pl_dout), .empty(pl_empty), .count(pl_count));

// sample generation, paced so that a short FIFO always holds samples for the DUC
reg        stb;
reg  [3:0] gap;
reg  [4:0] inflight;
wire       t_v;
wire signed [15:0] t_i, t_q;
wire       sf_full, sf_empty;
wire [31:0] sf_dout;
wire [4:0] sf_count;
wire       duc_take = tx_strobe && tx_run && tx_en;
wire [31:0] tx_enc, tx_sent, tx_dummy, tx_uf;
wire       tx_sof;
dvbs2_tx u_tx (
    .clk(clk), .rst(rst_tx), .enable(1'b1), .modcod(r_txcfg[4:0]), .pilots(r_txcfg[8]),
    .rolloff(r_txcfg[13:12]), .src_stream(tx_data),
    .s_axis_tdata(pl_dout), .s_axis_tvalid(!pl_empty), .s_axis_tready(pl_rd),
    .samp_stb(stb), .out_valid(t_v), .out_i(t_i), .out_q(t_q), .sym_sof(tx_sof),
    .frames_encoded(tx_enc), .frames_sent(tx_sent), .dummy_sent(tx_dummy), .underflows(tx_uf));
b210_fifo #(.W(32), .AW(4)) u_sfifo (
    .clk(clk), .rst(rst_tx), .wr(t_v), .din({t_i, t_q}), .full(sf_full),
    .rd(duc_take), .dout(sf_dout), .empty(sf_empty), .count(sf_count));
always @(posedge clk) begin
    if (rst_tx) begin
        stb <= 1'b0; gap <= 4'd0; inflight <= 5'd0;
    end else begin
        stb <= 1'b0;
        if (gap != 4'd0) gap <= gap - 4'd1;
        if (!stb && gap == 4'd0 && ({1'b0, sf_count} + {1'b0, inflight}) < 6'd12) begin
            stb <= 1'b1; gap <= 4'd7;           // >= 8 clocks between samples
        end
        inflight <= inflight + (stb ? 5'd1 : 5'd0) - (t_v ? 5'd1 : 5'd0);
    end
end
assign tx_duc_sample = !tx_en ? tx_host_sample : (sf_empty ? 32'd0 : sf_dout);

// ---------------------------------------------------------------- RX
wire        r_valid = rx_strobe && rx_run && rx_en;
wire [7:0]  m_d;
wire        m_v, m_l, m_rdy;
wire [15:0] st_agc, st_sgain, st_dfl, st_plsq;
wire [3:0]  st_fs; wire st_lock, st_berlock, st_povf; wire [4:0] st_mc; wire [1:0] st_ty, st_stage;
wire signed [31:0] st_om;
wire [31:0] st_frames, st_miss, st_plsf, st_dec, st_drop, st_bcor, st_bfail, st_ok, st_crc, st_bbf, st_berr;
wire [5:0]  st_iters; wire [7:0] st_mat; wire [47:0] st_bbits;
dvbs2_rx #(.P(LDPC_P)) u_rx (
    .clk(clk), .rst(rst_rx), .rolloff(r_txcfg[13:12]),
    .agc_en(agc_en), .agc_target(r_agc[15:0]), .agc_mu(r_agc[19:16]),
    .tim_k1s(r_tim[4:0]), .tim_k2s(r_tim[12:8]),
    .thr_acq(r_fs[7:0]), .thr_trk(r_fs[15:8]), .fll_n1(r_fs[23:16]), .fll_n2(r_fs[31:24]),
    .fll_kacq(r_fll[3:0]), .fll_k1(r_fll[7:4]), .fll_k3(r_fll[11:8]),
    .pll_en(pll_en), .pll_k1(r_fll[15:12]), .pll_k2(r_fll[19:16]),
    .llr_scale_qpsk(r_fec[7:0]), .llr_scale_8psk(r_fec[15:8]), .ldpc_max_iter(r_fec[21:16]),
    .ldpc_alpha(r_fec[26:24]), .ldpc_early_stop(es_en), .clr_stats(clr),
    .in_valid(r_valid), .in_i(rx_ddc_sample[31:16]), .in_q(rx_ddc_sample[15:0]),
    .m_axis_tvalid(m_v), .m_axis_tdata(m_d), .m_axis_tlast(m_l), .m_axis_tready(m_rdy),
    .st_agc_gain(st_agc), .st_fs_state(st_fs), .st_locked(st_lock), .st_modcod(st_mc), .st_type(st_ty),
    .st_omega(st_om), .st_frames(st_frames), .st_misses(st_miss), .st_plsfail(st_plsf),
    .st_fll_stage(st_stage), .st_sym_gain(st_sgain), .st_plsq(st_plsq), .st_ldpc_dec(st_dec),
    .st_ldpc_drop(st_drop), .st_ldpc_iters(st_iters), .st_bch_corr(st_bcor), .st_bch_fail(st_bfail),
    .st_bb_ok(st_ok), .st_bb_crc(st_crc), .st_bb_bchfail(st_bbf), .st_dfl(st_dfl), .st_matype(st_mat),
    .st_ber_bits(st_bbits), .st_ber_errors(st_berr), .st_ber_lock(st_berlock), .st_pacer_ovf(st_povf));

// decoded bytes -> host words
wire        ob_full, ob_empty;
wire [8:0]  ob_dout;
wire [11:0] ob_count;
wire        host_take = rx_strobe && rx_run;
assign m_rdy = rx_data ? !ob_full : 1'b1;
b210_fifo #(.W(9), .AW(11)) u_obfifo (
    .clk(clk), .rst(rst_rx), .wr(m_v && rx_data && !ob_full), .din({m_l, m_d}), .full(ob_full),
    .rd(host_take), .dout(ob_dout), .empty(ob_empty), .count(ob_count));
reg [15:0] ob_seq;
always @(posedge clk) begin
    if (rst_rx) ob_seq <= 16'd0;
    else if (host_take && !ob_empty) ob_seq <= ob_seq + 16'd1;
end
assign rx_host_sample = !(rx_data && rx_en) ? rx_ddc_sample :
                        ob_empty ? {16'd0, ob_seq} : {6'd0, ob_dout[8], 1'b1, ob_dout[7:0], ob_seq};

// ---------------------------------------------------------------- wrapper counters
reg [31:0] c_txbytes, c_txovf, c_rxbytes, c_ducuf, c_rxsamp, c_txsamp;
always @(posedge clk) begin
    if (rst || clr) begin
        c_txbytes <= 32'd0; c_txovf <= 32'd0; c_rxbytes <= 32'd0; c_ducuf <= 32'd0;
        c_rxsamp <= 32'd0; c_txsamp <= 32'd0;
    end else begin
        if (host_byte && !pl_full) c_txbytes <= c_txbytes + 32'd1;
        if (host_byte && pl_full)  c_txovf   <= c_txovf + 32'd1;
        if (host_take && rx_data && rx_en && !ob_empty) c_rxbytes <= c_rxbytes + 32'd1;
        if (duc_take && sf_empty)  c_ducuf   <= c_ducuf + 32'd1;
        if (r_valid)               c_rxsamp  <= c_rxsamp + 32'd1;
        if (duc_take)              c_txsamp  <= c_txsamp + 32'd1;
    end
end

// ---------------------------------------------------------------- status / readback
wire [32*32-1:0] status;
assign status[ 0*32 +: 32] = {10'd0, st_iters, st_povf, st_berlock, st_stage, st_ty, st_mc, st_lock, st_fs};
assign status[ 1*32 +: 32] = st_om;
assign status[ 2*32 +: 32] = st_frames;
assign status[ 3*32 +: 32] = st_miss;
assign status[ 4*32 +: 32] = st_plsf;
assign status[ 5*32 +: 32] = {st_sgain, st_agc};
assign status[ 6*32 +: 32] = st_dec;
assign status[ 7*32 +: 32] = st_drop;
assign status[ 8*32 +: 32] = st_bcor;
assign status[ 9*32 +: 32] = st_bfail;
assign status[10*32 +: 32] = st_ok;
assign status[11*32 +: 32] = st_crc;
assign status[12*32 +: 32] = st_bbf;
assign status[13*32 +: 32] = {8'd0, st_mat, st_dfl};
assign status[14*32 +: 32] = st_bbits[31:0];
assign status[15*32 +: 32] = {16'd0, st_bbits[47:32]};
assign status[16*32 +: 32] = st_berr;
assign status[17*32 +: 32] = tx_enc;
assign status[18*32 +: 32] = tx_sent;
assign status[19*32 +: 32] = tx_dummy;
assign status[20*32 +: 32] = tx_uf;
assign status[21*32 +: 32] = {16'd0, st_plsq};
assign status[22*32 +: 32] = {pl_count[11:0], 3'd0, sf_count, ob_count[11:0]};
assign status[23*32 +: 32] = c_txbytes;
assign status[24*32 +: 32] = c_txovf;
assign status[25*32 +: 32] = c_rxbytes;
assign status[26*32 +: 32] = c_ducuf;
assign status[27*32 +: 32] = c_rxsamp;
assign status[28*32 +: 32] = c_txsamp;
assign status[29*32 +: 32] = r_ctrl;
assign status[30*32 +: 32] = ID;
assign status[31*32 +: 32] = VERSION;
always @(posedge clk) rb_data <= status[rb_addr[3:0]*64 +: 64];
endmodule
