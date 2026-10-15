// ber_dut.v -- LDPC decoder + BCH decoder, driven by the C++ BER harness (ber_main.cpp).
`timescale 1ns/1ps
module ber_dut (
    input  wire              clk,
    input  wire              rst,
    input  wire [5:0]        max_iter,
    input  wire [2:0]        alpha_ovr,      // 0 = per-rate default
    input  wire              ld_start,
    input  wire [3:0]        ld_code,
    input  wire [15:0]       ld_meta,
    input  wire              ld_valid,
    input  wire [1:0]        ld_stream,
    input  wire signed [6:0] ld_llr,
    input  wire              ld_end,
    output wire              ld_can_start,
    output wire              b_valid,
    output wire [7:0]        b_data,
    output wire              b_first,
    output wire              b_last,
    output wire              b_fail,
    output wire [3:0]        b_ncorr,
    output wire [31:0]       b_meta
);
wire o_valid, o_first, o_last, o_conv, o_ready, cbusy; wire [7:0] o_data; wire [3:0] o_code;
wire [15:0] o_meta; wire [5:0] o_iters; wire [31:0] fdrop, fdec;
ldpc_dec #(.P(45)) u_ldpc (.clk(clk), .rst(rst), .max_iter(max_iter), .alpha_override(alpha_ovr), .early_stop(1'b1),
    .ld_start(ld_start), .ld_code(ld_code), .ld_meta(ld_meta), .ld_valid(ld_valid), .ld_stream(ld_stream),
    .ld_llr(ld_llr), .ld_end(ld_end), .o_valid(o_valid), .o_data(o_data), .o_ready(o_ready),
    .o_first(o_first), .o_last(o_last), .o_code(o_code), .o_meta(o_meta), .o_iters(o_iters), .o_conv(o_conv),
    .frames_dropped(fdrop), .frames_decoded(fdec), .core_busy(cbusy), .ld_can_start(ld_can_start));
wire [3:0] b_code; wire [31:0] cb, ff;
bch_dec u_bch (.clk(clk), .rst(rst), .i_valid(o_valid), .i_data(o_data), .i_ready(o_ready),
    .i_first(o_first), .i_last(o_last), .i_code(o_code), .i_meta({10'd0, o_iters, o_meta}),
    .o_valid(b_valid), .o_data(b_data), .o_ready(1'b1), .o_first(b_first), .o_last(b_last),
    .o_fail(b_fail), .o_ncorr(b_ncorr), .o_code(b_code), .o_meta(b_meta),
    .corrected_bits(cb), .failed_frames(ff));
endmodule
