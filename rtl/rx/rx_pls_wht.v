// rx_pls_wht.v -- 64-point Walsh-Hadamard transform for the PLS decoder,
// streaming radix-2 single-path-delay-feedback pipeline (6 stages, delays
// 32/16/8/4/2/1, one registered output per stage).
//
//   F[k] = sum_j x[j] * (-1)^popcount(j & k),  natural order in and out.
//
// Feed x[0..63] on 64 enabled clocks (en), then keep en high (x = don't care)
// until all outputs are out. "start" (one clock, with or before the first
// sample) restarts the tick counter. out_v pulses one clock after the enabled
// clock that produced F[out_k]. Integer arithmetic without overflow, so the
// result is identical to any other evaluation order (bit-exact with the old
// parallel in-place FHT).
`timescale 1ns/1ps
module rx_pls_wht #(parameter W = 28) (
    input  wire               clk,
    input  wire               start,
    input  wire               en,
    input  wire signed [W-1:0] x,
    output reg                out_v,
    output reg  [5:0]         out_k,
    output wire signed [W-1:0] out_f
);
// stage s valid input starts at tick L_s: L_0 = 0, L_{s+1} = L_s + D_s + 1
localparam [7:0] L0 = 8'd0, L1 = 8'd33, L2 = 8'd50, L3 = 8'd59, L4 = 8'd64, L5 = 8'd67, LO = 8'd68;
reg  [7:0] tick;
wire [7:0] t0 = tick - L0, t1 = tick - L1, t2 = tick - L2, t3 = tick - L3, t4 = tick - L4, t5 = tick - L5;
wire signed [W-1:0] y0, y1, y2, y3, y4;
rx_wht_stage #(.W(W), .D(32)) u_s0 (.clk(clk), .en(en), .ph(t0[5]), .x(x),  .y(y0));
rx_wht_stage #(.W(W), .D(16)) u_s1 (.clk(clk), .en(en), .ph(t1[4]), .x(y0), .y(y1));
rx_wht_stage #(.W(W), .D(8))  u_s2 (.clk(clk), .en(en), .ph(t2[3]), .x(y1), .y(y2));
rx_wht_stage #(.W(W), .D(4))  u_s3 (.clk(clk), .en(en), .ph(t3[2]), .x(y2), .y(y3));
rx_wht_stage #(.W(W), .D(2))  u_s4 (.clk(clk), .en(en), .ph(t4[1]), .x(y3), .y(y4));
rx_wht_stage #(.W(W), .D(1))  u_s5 (.clk(clk), .en(en), .ph(t5[0]), .x(y4), .y(out_f));
always @(posedge clk) begin
    out_v <= 1'b0;
    if (start) tick <= 8'd0;
    else if (en) begin
        if (tick != 8'hFF) tick <= tick + 8'd1;
        out_v <= (tick >= LO) && (tick < LO + 8'd64);
        out_k <= tick[5:0] - LO[5:0];
    end
end
endmodule

// one SDF stage: phase A (ph = 0) stores x, outputs the stored differences;
// phase B (ph = 1) outputs head + x, stores head - x.
module rx_wht_stage #(parameter W = 28, parameter D = 32) (
    input  wire               clk,
    input  wire               en,
    input  wire               ph,
    input  wire signed [W-1:0] x,
    output reg  signed [W-1:0] y
);
reg  signed [W-1:0] dl [0:D-1];
wire signed [W-1:0] a = dl[D-1];
integer k;
always @(posedge clk) begin
    if (en) begin
        dl[0] <= ph ? a - x : x;
        for (k = 1; k < D; k = k + 1) dl[k] <= dl[k-1];
    end
end
always @(posedge clk) begin
    if (en) y <= ph ? a + x : a;
end
endmodule
