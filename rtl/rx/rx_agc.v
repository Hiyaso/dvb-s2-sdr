// rx_agc.v -- digital AGC on the incoming 2-samples/symbol stream.
//   y = sat(x * gain / 1024)                     gain: Q6.10
//   |y| ~ max(|I|,|Q|) + 3/8 min(|I|,|Q|),  avg <- avg + (|y| - avg)/1024
//   gain <- gain + (target - avg) * 2^-mu        (mu default 12 -> ~4k samples)
`timescale 1ns/1ps
module rx_agc (
    input  wire               clk,
    input  wire               rst,
    input  wire               enable,
    input  wire [15:0]        target,      // desired mean |y| (default 6000)
    input  wire [3:0]         mu,          // loop gain exponent (default 12)
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output reg                out_valid,
    output reg  signed [15:0] out_i,
    output reg  signed [15:0] out_q,
    output wire [15:0]        gain
);
reg  signed [33:0] gacc;                     // gain * 2^16
assign gain = gacc[31:16];
wire [15:0] g = enable ? gain : 16'd1024;
wire signed [33:0] pi = in_i * $signed({1'b0, g});
wire signed [33:0] pq = in_q * $signed({1'b0, g});
wire signed [33:0] si = pi >>> 10;
wire signed [33:0] sq = pq >>> 10;
function signed [15:0] sat16; input signed [33:0] v;
    sat16 = (v > 34'sd32767) ? 16'sd32767 : (v < -34'sd32767) ? -16'sd32767 : v[15:0];
endfunction
reg  [25:0] avg_acc;                          // avg * 1024
wire [15:0] avg = avg_acc[25:10];
wire [15:0] ai = out_i[15] ? -out_i : out_i;
wire [15:0] aq = out_q[15] ? -out_q : out_q;
wire [15:0] mx = (ai > aq) ? ai : aq;
wire [15:0] mn = (ai > aq) ? aq : ai;
wire [16:0] mag = mx + ((mn >> 2) + (mn >> 3));
wire signed [17:0] diff = $signed({2'b00, target}) - $signed({2'b00, avg});
wire signed [33:0] step = ($signed(diff) <<< 16) >>> mu;
wire signed [33:0] gnext = gacc + step;
localparam signed [33:0] GMIN = 34'sd1 <<< 16;            // gain >= 1/1024
localparam signed [33:0] GMAX = 34'sd65535 <<< 16;
// gain update one clock after the sample (from the average up to the previous sample),
// average update one clock later from the registered |y| (samples are >= 2 clocks apart)
reg upd, upd2;
reg [16:0] mag_r;
always @(posedge clk) begin
    if (rst) begin
        // average starts at the target: from 0 the gain winds up while the average fills
        // (overshoot to ~0, kicks the timing loop off by thousands of ppm at low Es/N0)
        gacc <= 34'sd1024 <<< 16; avg_acc <= {target, 10'd0}; out_valid <= 1'b0; out_i <= 0; out_q <= 0;
        upd <= 1'b0; upd2 <= 1'b0; mag_r <= 17'd0;
    end else begin
        out_valid <= in_valid;
        if (in_valid) begin out_i <= sat16(si); out_q <= sat16(sq); end
        upd  <= in_valid;
        upd2 <= upd;
        if (upd) begin
            mag_r <= mag;
            if (enable) gacc <= (gnext < GMIN) ? GMIN : (gnext > GMAX) ? GMAX : gnext;
        end
        if (upd2) avg_acc <= avg_acc + mag_r - {10'd0, avg};
    end
end
endmodule
