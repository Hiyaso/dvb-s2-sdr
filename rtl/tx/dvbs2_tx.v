// dvbs2_tx.v -- DVB-S2 transmitter baseband (short FECFRAME, QPSK/8PSK, CCM).
//
//   tx_bbframe -> tx_fec_enc (BCH+LDPC, ping-pong codeword buffer)
//              -> tx_plframer (interleaver, mapper, PLHEADER, pilots, scrambler)
//              -> tx_shaper (RRC, 2 samples/symbol, one sample per samp_stb)
`timescale 1ns/1ps
module dvbs2_tx (
    input  wire               clk,
    input  wire               rst,
    input  wire               enable,
    input  wire [4:0]         modcod,
    input  wire               pilots,
    input  wire [1:0]         rolloff,
    input  wire               src_stream,
    input  wire [7:0]         s_axis_tdata,
    input  wire               s_axis_tvalid,
    output wire               s_axis_tready,
    input  wire               samp_stb,
    output wire               out_valid,
    output wire signed [15:0] out_i,
    output wire signed [15:0] out_q,
    output wire               sym_sof,        // debug: PL frame start symbol accepted
    output wire [31:0]        frames_encoded,
    output wire [31:0]        frames_sent,
    output wire [31:0]        dummy_sent,
    output wire [31:0]        underflows
);
wire        bb_start, bb_bit, bb_valid, bb_ready, bb_busy;
wire [13:0] bb_kbch;
tx_bbframe u_bb (
    .clk(clk), .rst(rst), .start(bb_start), .kbch(bb_kbch), .rolloff(rolloff),
    .src_stream(src_stream), .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready), .out_bit(bb_bit), .out_valid(bb_valid),
    .out_ready(bb_ready), .busy(bb_busy));

wire        cw_rbank, cw_rdata, cw_release, cw_rel_bank, cw_p0, cw_p1;
wire [13:0] cw_raddr;
wire [1:0]  cw_full;
wire [4:0]  cw_m0, cw_m1;
tx_fec_enc u_fec (
    .clk(clk), .rst(rst), .enable(enable), .modcod_in(modcod), .pilots_in(pilots),
    .bb_start(bb_start), .bb_kbch(bb_kbch), .bb_bit(bb_bit), .bb_valid(bb_valid), .bb_ready(bb_ready),
    .cw_rbank(cw_rbank), .cw_raddr(cw_raddr), .cw_rdata(cw_rdata), .cw_full(cw_full),
    .cw_modcod0(cw_m0), .cw_modcod1(cw_m1), .cw_pilots0(cw_p0), .cw_pilots1(cw_p1),
    .cw_release(cw_release), .cw_rel_bank(cw_rel_bank), .frames_encoded(frames_encoded));

wire [2:0] sym_k;
wire       sym_valid, sym_ready, sof;
tx_plframer u_pl (
    .clk(clk), .rst(rst), .enable(enable),
    .cw_rbank(cw_rbank), .cw_raddr(cw_raddr), .cw_rdata(cw_rdata), .cw_full(cw_full),
    .cw_modcod0(cw_m0), .cw_modcod1(cw_m1), .cw_pilots0(cw_p0), .cw_pilots1(cw_p1),
    .cw_release(cw_release), .cw_rel_bank(cw_rel_bank), .sym_k(sym_k), .sym_valid(sym_valid), .sym_ready(sym_ready),
    .sym_sof(sof), .frames_sent(frames_sent), .dummy_sent(dummy_sent));
assign sym_sof = sof && sym_valid && sym_ready;

tx_shaper u_sh (
    .clk(clk), .rst(rst), .rolloff(rolloff), .samp_stb(samp_stb),
    .sym_k(sym_k), .sym_valid(sym_valid), .sym_ready(sym_ready),
    .out_valid(out_valid), .out_i(out_i), .out_q(out_q), .underflows(underflows));
endmodule
