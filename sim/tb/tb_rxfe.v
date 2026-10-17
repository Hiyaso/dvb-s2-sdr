// tb_rxfe.v -- TX -> channel emulator -> AGC -> RRC MF -> timing recovery; dumps symbols.
`timescale 1ns/1ps
module tb_rxfe;
parameter MODCOD = 4;
parameter PILOTS = 1;
parameter DIV = 8;
parameter NSYM = 40000;
parameter integer PPM_STEP = 0;
parameter integer DELAY = 20000;
parameter integer CFO = 0;
parameter integer NOISE = 0;
parameter K1S = 9;
parameter K2S = 18;
reg clk = 0, rst = 1;
always #5 clk = ~clk;
reg [7:0] dcnt = 0;
wire samp_stb = (dcnt == 0);
always @(posedge clk) dcnt <= (dcnt == DIV-1) ? 0 : dcnt + 1;
wire tx_v, sof; wire signed [15:0] tx_i, tx_q; wire [31:0] a, b, c, d; wire rdy;
dvbs2_tx u_tx (.clk(clk), .rst(rst), .enable(1'b1), .modcod(MODCOD[4:0]), .pilots(PILOTS[0]), .rolloff(2'd0),
    .src_stream(1'b0), .s_axis_tdata(8'd0), .s_axis_tvalid(1'b0), .s_axis_tready(rdy),
    .samp_stb(samp_stb), .out_valid(tx_v), .out_i(tx_i), .out_q(tx_q), .sym_sof(sof),
    .frames_encoded(a), .frames_sent(b), .dummy_sent(c), .underflows(d));
wire ch_v; wire signed [15:0] ch_i, ch_q;
ch_emu u_ch (.clk(clk), .rst(rst), .bypass(1'b0), .ppm_step(PPM_STEP), .delay_frac(DELAY[15:0]),
    .cfo_step(CFO), .phase0(16'd5000), .noise_amp(NOISE[15:0]), .sig_gain(16'd16384),
    .in_valid(tx_v), .in_i(tx_i), .in_q(tx_q), .out_valid(ch_v), .out_i(ch_i), .out_q(ch_q));
wire pc_v, pc_ovf; wire signed [15:0] pc_i, pc_q;
sample_pacer #(.MIN_GAP(7)) u_pc (.clk(clk), .rst(rst), .in_valid(ch_v), .in_i(ch_i), .in_q(ch_q), .out_valid(pc_v), .out_i(pc_i), .out_q(pc_q), .overflow(pc_ovf));
wire ag_v; wire signed [15:0] ag_i, ag_q; wire [15:0] gain;
rx_agc u_agc (.clk(clk), .rst(rst), .enable(1'b1), .target(16'd6000), .mu(4'd12),
    .in_valid(pc_v), .in_i(pc_i), .in_q(pc_q), .out_valid(ag_v), .out_i(ag_i), .out_q(ag_q), .gain(gain));
wire mf_v; wire signed [15:0] mf_i, mf_q;
fir_sym33 #(.OUT_SHL(0)) u_mf (.clk(clk), .rst(rst), .rolloff(2'd0), .in_valid(ag_v), .in_i(ag_i), .in_q(ag_q),
    .out_valid(mf_v), .out_i(mf_i), .out_q(mf_q));
wire sy_v; wire signed [15:0] sy_i, sy_q; wire [15:0] mu; wire signed [31:0] integ;
rx_timing u_tim (.clk(clk), .rst(rst), .k1s(K1S[4:0]), .k2s(K2S[4:0]), .in_valid(mf_v), .in_i(mf_i), .in_q(mf_q),
    .out_valid(sy_v), .out_i(sy_i), .out_q(sy_q), .mu_out(mu), .loop_integ(integ));
integer f, fc, n = 0;
initial begin f = $fopen("rx_syms.txt", "w"); fc = $fopen("ch_out.txt", "w"); #100 rst = 0; end
always @(posedge clk) if (mf_v) $fwrite(fc, "%0d %0d\n", mf_i, mf_q);
always @(posedge clk) if (sy_v) begin
    $fwrite(f, "%0d %0d %0d %0d\n", sy_i, sy_q, mu, gain);
    n = n + 1;
    if (n == NSYM) begin $fclose(f); $fclose(fc); $display("done %0d symbols, tx frames %0d", n, b); $finish; end
end
endmodule
