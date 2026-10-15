// dvbs2_rx.v -- DVB-S2 receiver baseband (short FECFRAME, QPSK/8PSK).
//
//   sample_pacer -> rx_agc -> RRC matched filter -> rx_timing (Gardner/Farrow)
//   -> rx_frame (frame sync, PLS, carrier recovery, descrambling)
//   -> rx_demap -> ldpc_dec -> bch_dec -> rx_bbout (BB descrambler, header check,
//      data field output + PRBS-23 BER meter)
`timescale 1ns/1ps
module dvbs2_rx #(
    parameter P = 45
) (
    input  wire               clk,
    input  wire               rst,
    // configuration
    input  wire [1:0]         rolloff,
    input  wire               agc_en,
    input  wire [15:0]        agc_target,
    input  wire [3:0]         agc_mu,
    input  wire [4:0]         tim_k1s,
    input  wire [4:0]         tim_k2s,
    input  wire [7:0]         thr_acq,
    input  wire [7:0]         thr_trk,
    input  wire [7:0]         fll_n1,
    input  wire [7:0]         fll_n2,
    input  wire [3:0]         fll_kacq,
    input  wire [3:0]         fll_k1,
    input  wire [3:0]         fll_k3,
    input  wire               pll_en,
    input  wire [3:0]         pll_k1,
    input  wire [3:0]         pll_k2,
    input  wire [7:0]         llr_scale_qpsk,
    input  wire [7:0]         llr_scale_8psk,
    input  wire [5:0]         ldpc_max_iter,
    input  wire [2:0]         ldpc_alpha,
    input  wire               ldpc_early_stop,
    input  wire               clr_stats,
    // samples (2 per symbol)
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    // decoded data field bytes
    output wire               m_axis_tvalid,
    output wire [7:0]         m_axis_tdata,
    output wire               m_axis_tlast,
    input  wire               m_axis_tready,
    // status
    output wire [15:0]        st_agc_gain,
    output wire [3:0]         st_fs_state,
    output wire               st_locked,
    output wire [4:0]         st_modcod,
    output wire [1:0]         st_type,
    output wire signed [31:0] st_omega,
    output wire [31:0]        st_frames,
    output wire [31:0]        st_misses,
    output wire [31:0]        st_plsfail,
    output wire [1:0]         st_fll_stage,
    output wire [15:0]        st_sym_gain,
    output wire [15:0]        st_plsq,
    output wire [31:0]        st_ldpc_dec,
    output wire [31:0]        st_ldpc_drop,
    output wire [5:0]         st_ldpc_iters,
    output wire [31:0]        st_bch_corr,
    output wire [31:0]        st_bch_fail,
    output wire [31:0]        st_bb_ok,
    output wire [31:0]        st_bb_crc,
    output wire [31:0]        st_bb_bchfail,
    output wire [15:0]        st_dfl,
    output wire [7:0]         st_matype,
    output wire [47:0]        st_ber_bits,
    output wire [31:0]        st_ber_errors,
    output wire               st_ber_lock,
    output wire               st_pacer_ovf
);
// ---------------------------------------------------------------- front end
wire pc_v; wire signed [15:0] pc_i, pc_q;
sample_pacer #(.MIN_GAP(6)) u_pacer (.clk(clk), .rst(rst), .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
    .out_valid(pc_v), .out_i(pc_i), .out_q(pc_q), .overflow(st_pacer_ovf));
wire ag_v; wire signed [15:0] ag_i, ag_q;
rx_agc u_agc (.clk(clk), .rst(rst), .enable(agc_en), .target(agc_target), .mu(agc_mu),
    .in_valid(pc_v), .in_i(pc_i), .in_q(pc_q), .out_valid(ag_v), .out_i(ag_i), .out_q(ag_q),
    .gain(st_agc_gain));
wire mf_v; wire signed [15:0] mf_i, mf_q;
fir_sym33 #(.OUT_SHL(0)) u_mf (.clk(clk), .rst(rst), .rolloff(rolloff), .in_valid(ag_v),
    .in_i(ag_i), .in_q(ag_q), .out_valid(mf_v), .out_i(mf_i), .out_q(mf_q));
wire sy_v; wire signed [15:0] sy_i, sy_q; wire [15:0] mu; wire signed [31:0] integ;
rx_timing u_tim (.clk(clk), .rst(rst), .k1s(tim_k1s), .k2s(tim_k2s), .in_valid(mf_v),
    .in_i(mf_i), .in_q(mf_q), .out_valid(sy_v), .out_i(sy_i), .out_q(sy_q),
    .mu_out(mu), .loop_integ(integ));

// ---------------------------------------------------------------- frame / carrier
wire b_valid, b_first, b_last, b_fail, b_ready; wire [7:0] b_data; wire [3:0] b_ncorr, b_code;
wire [31:0] b_meta;
wire fs_v, fs_rdy, fs_first, fs_last, fs_8; wire signed [15:0] fs_i, fs_q; wire [3:0] fs_code;
wire [15:0] fs_meta;
rx_frame u_frame (
    .clk(clk), .rst(rst), .thr_acq(thr_acq), .thr_trk(thr_trk), .n1(fll_n1), .n2(fll_n2),
    .k_acq_s(fll_kacq), .k1s(fll_k1), .k3s(fll_k3), .pll_en(pll_en), .pll_k1s(pll_k1), .pll_k2s(pll_k2),
    .fec_good(b_valid && b_ready && b_last && !b_fail), .fec_bad(b_valid && b_ready && b_last && b_fail),
    .in_valid(sy_v), .in_i(sy_i), .in_q(sy_q),
    .s_valid(fs_v), .s_ready(fs_rdy), .s_i(fs_i), .s_q(fs_q), .s_first(fs_first), .s_last(fs_last),
    .s_code(fs_code), .s_8psk(fs_8), .s_meta(fs_meta),
    .st_state(st_fs_state), .st_locked(st_locked), .st_modcod(st_modcod), .st_type(st_type),
    .st_omega(st_omega), .st_frames(st_frames), .st_misses(st_misses), .st_plsfail(st_plsfail),
    .st_stage(st_fll_stage), .st_gain(st_sym_gain), .st_plsq(st_plsq));

// ---------------------------------------------------------------- FEC
wire ld_start, ld_valid, ld_end; wire [3:0] ld_code; wire [15:0] ld_meta; wire [1:0] ld_stream;
wire signed [6:0] ld_llr;
rx_demap u_demap (.clk(clk), .rst(rst), .scale_qpsk(llr_scale_qpsk), .scale_8psk(llr_scale_8psk),
    .s_valid(fs_v), .s_ready(fs_rdy), .s_i(fs_i), .s_q(fs_q), .s_first(fs_first), .s_last(fs_last),
    .s_code(fs_code), .s_8psk(fs_8), .s_meta(fs_meta),
    .ld_start(ld_start), .ld_code(ld_code), .ld_meta(ld_meta), .ld_valid(ld_valid),
    .ld_stream(ld_stream), .ld_llr(ld_llr), .ld_end(ld_end));

wire o_valid, o_first, o_last, o_conv, o_ready, cbusy, can_start; wire [7:0] o_data; wire [3:0] o_code;
wire [15:0] o_meta; wire [5:0] o_iters;
ldpc_dec #(.P(P)) u_ldpc (.clk(clk), .rst(rst), .max_iter(ldpc_max_iter), .alpha_override(ldpc_alpha),
    .early_stop(ldpc_early_stop), .ld_start(ld_start), .ld_code(ld_code), .ld_meta(ld_meta),
    .ld_valid(ld_valid), .ld_stream(ld_stream), .ld_llr(ld_llr), .ld_end(ld_end),
    .o_valid(o_valid), .o_data(o_data), .o_ready(o_ready), .o_first(o_first), .o_last(o_last),
    .o_code(o_code), .o_meta(o_meta), .o_iters(o_iters), .o_conv(o_conv),
    .frames_dropped(st_ldpc_drop), .frames_decoded(st_ldpc_dec), .core_busy(cbusy), .ld_can_start(can_start));
reg [5:0] last_iters;
always @(posedge clk) if (o_valid && o_first) last_iters <= o_iters;
assign st_ldpc_iters = last_iters;

bch_dec u_bch (.clk(clk), .rst(rst), .i_valid(o_valid), .i_data(o_data), .i_ready(o_ready),
    .i_first(o_first), .i_last(o_last), .i_code(o_code), .i_meta({10'd0, o_iters, o_meta}),
    .o_valid(b_valid), .o_data(b_data), .o_ready(b_ready), .o_first(b_first), .o_last(b_last),
    .o_fail(b_fail), .o_ncorr(b_ncorr), .o_code(b_code), .o_meta(b_meta),
    .corrected_bits(st_bch_corr), .failed_frames(st_bch_fail));

rx_bbout u_bb (.clk(clk), .rst(rst), .clr_stats(clr_stats), .i_valid(b_valid), .i_data(b_data),
    .i_ready(b_ready), .i_first(b_first), .i_last(b_last), .i_fail(b_fail),
    .m_valid(m_axis_tvalid), .m_data(m_axis_tdata), .m_last(m_axis_tlast), .m_ready(m_axis_tready),
    .frames_ok(st_bb_ok), .frames_crc_err(st_bb_crc), .frames_bch_fail(st_bb_bchfail),
    .last_dfl(st_dfl), .last_matype(st_matype), .ber_bits(st_ber_bits), .ber_errors(st_ber_errors),
    .ber_locked(st_ber_lock));
endmodule
