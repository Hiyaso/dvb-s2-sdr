// fir_sym33.v -- 33-tap symmetric complex FIR (RRC, 16 symbols @ 2 samples/symbol).
//
// Direct form with symmetric folding: 17 pre-adders + 17 multipliers per rail
// (maps onto DSP48E1 pre-adder/multiplier).  The delay line advances on in_valid;
// the arithmetic pipeline is free running, so out_valid simply follows in_valid
// after LAT clocks.  Requires at least 2 clocks between in_valid pulses
// (the system uses >= 4).
//
// y = sum(h_k * x[n-k]) >> 17 (coefficients are Q1.17), saturated to 16 bit,
// then shifted left by OUT_SHL (0..3) before saturation for extra gain.
`timescale 1ns/1ps
module fir_sym33 #(
    parameter OUT_SHL = 0
) (
    input  wire               clk,
    input  wire               rst,
    input  wire [1:0]         rolloff,
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output reg                out_valid,
    output reg  signed [15:0] out_i,
    output reg  signed [15:0] out_q
);
localparam N = 33;
localparam H = 17;
localparam LAT = 7;

reg signed [15:0] dl_i [0:N-1];
reg signed [15:0] dl_q [0:N-1];
integer k;
always @(posedge clk) begin
    if (rst) begin
        for (k = 0; k < N; k = k + 1) begin dl_i[k] <= 16'sd0; dl_q[k] <= 16'sd0; end
    end else if (in_valid) begin
        dl_i[0] <= in_i; dl_q[0] <= in_q;
        for (k = 1; k < N; k = k + 1) begin dl_i[k] <= dl_i[k-1]; dl_q[k] <= dl_q[k-1]; end
    end
end

// coefficients (registered, change only with rolloff)
reg signed [17:0] coef [0:H-1];
wire [18*H-1:0] coef_w;
genvar g;
generate for (g = 0; g < H; g = g + 1) begin : g_coef
    rrc_coef_rom u_rom (.rolloff(rolloff), .idx(g[4:0]), .coef(coef_w[18*g +: 18]));
end endgenerate
always @(posedge clk) begin
    for (k = 0; k < H; k = k + 1) coef[k] <= coef_w[18*k +: 18];
end

`ifdef DVBS2_FIR_FOLD
// ---------------------------------------------------------------------------
// Folded implementation (DSP-limited devices, e.g. Spartan-6 on the USRP B210):
// 3 multipliers per rail, 6 clocks per output sample.  Requires >= 8 clocks
// between in_valid pulses.  Bit-exact with the parallel version (same products,
// exact integer accumulation, same rounding).
reg  [2:0]  ph;
reg         busy;
reg         fa_v, fa_last, fp_v, fp_last;
reg  signed [16:0] fa_i [0:2];
reg  signed [16:0] fa_q [0:2];
reg  signed [17:0] fc   [0:2];
reg  signed [34:0] fp_i [0:2];
reg  signed [34:0] fp_q [0:2];
reg  signed [39:0] acc_i, acc_q, s3_i, s3_q;
reg         s3_v;
integer j, kk;
always @(posedge clk) begin
    if (rst) begin
        ph <= 3'd0; busy <= 1'b0; fa_v <= 1'b0; fa_last <= 1'b0;
    end else begin
        fa_v <= busy; fa_last <= busy && (ph == 3'd5);
        if (in_valid) begin busy <= 1'b1; ph <= 3'd0; end
        else if (busy) begin
            if (ph == 3'd5) busy <= 1'b0;
            ph <= ph + 3'd1;
        end
    end
    // stage A: pre-adds and coefficients of taps 3*ph .. 3*ph+2
    for (j = 0; j < 3; j = j + 1) begin
        kk = 3 * ph + j;
        if (kk < H - 1) begin
            fa_i[j] <= dl_i[kk] + dl_i[N-1-kk];
            fa_q[j] <= dl_q[kk] + dl_q[N-1-kk];
            fc[j]   <= coef[kk];
        end else if (kk == H - 1) begin
            fa_i[j] <= dl_i[H-1];
            fa_q[j] <= dl_q[H-1];
            fc[j]   <= coef[H-1];
        end else begin
            fa_i[j] <= 17'sd0; fa_q[j] <= 17'sd0; fc[j] <= 18'sd0;
        end
    end
    // stage B: products
    fp_v <= fa_v; fp_last <= fa_last;
    for (j = 0; j < 3; j = j + 1) begin
        fp_i[j] <= fa_i[j] * fc[j];
        fp_q[j] <= fa_q[j] * fc[j];
    end
end
// stage C: accumulation (first product group restarts the accumulator)
reg fp_first;
always @(posedge clk) begin
    if (rst) begin
        fp_first <= 1'b1; s3_v <= 1'b0; acc_i <= 40'sd0; acc_q <= 40'sd0; s3_i <= 40'sd0; s3_q <= 40'sd0;
    end else begin
        s3_v <= 1'b0;
        if (fp_v) begin
            if (fp_last) begin
                s3_i <= (fp_first ? 40'sd0 : acc_i) + fp_i[0] + fp_i[1] + fp_i[2];
                s3_q <= (fp_first ? 40'sd0 : acc_q) + fp_q[0] + fp_q[1] + fp_q[2];
                s3_v <= 1'b1;
                fp_first <= 1'b1;
            end else begin
                acc_i <= (fp_first ? 40'sd0 : acc_i) + fp_i[0] + fp_i[1] + fp_i[2];
                acc_q <= (fp_first ? 40'sd0 : acc_q) + fp_q[0] + fp_q[1] + fp_q[2];
                fp_first <= 1'b0;
            end
        end
    end
end
`else
// stage 1: pre-add, stage 2: multiply, stage 3: product register
reg signed [16:0] pa_i [0:H-1];
reg signed [16:0] pa_q [0:H-1];
reg signed [34:0] pr_i [0:H-1];
reg signed [34:0] pr_q [0:H-1];
reg signed [34:0] pr2_i [0:H-1];
reg signed [34:0] pr2_q [0:H-1];
always @(posedge clk) begin
    for (k = 0; k < H-1; k = k + 1) begin
        pa_i[k] <= dl_i[k] + dl_i[N-1-k];
        pa_q[k] <= dl_q[k] + dl_q[N-1-k];
    end
    pa_i[H-1] <= dl_i[H-1];
    pa_q[H-1] <= dl_q[H-1];
    for (k = 0; k < H; k = k + 1) begin
        pr_i[k]  <= pa_i[k] * coef[k];
        pr_q[k]  <= pa_q[k] * coef[k];
        pr2_i[k] <= pr_i[k];
        pr2_q[k] <= pr_q[k];
    end
end

// adder tree: 17 -> 9 -> 5 -> 3 -> 1 (with the odd term carried)
reg signed [39:0] s1_i [0:8];
reg signed [39:0] s1_q [0:8];
reg signed [39:0] s2_i [0:4];
reg signed [39:0] s2_q [0:4];
reg signed [39:0] s3_i, s3_q;
always @(posedge clk) begin
    for (k = 0; k < 8; k = k + 1) begin
        s1_i[k] <= pr2_i[2*k] + pr2_i[2*k+1];
        s1_q[k] <= pr2_q[2*k] + pr2_q[2*k+1];
    end
    s1_i[8] <= pr2_i[16];
    s1_q[8] <= pr2_q[16];
    for (k = 0; k < 4; k = k + 1) begin
        s2_i[k] <= s1_i[2*k] + s1_i[2*k+1];
        s2_q[k] <= s1_q[2*k] + s1_q[2*k+1];
    end
    s2_i[4] <= s1_i[8];
    s2_q[4] <= s1_q[8];
    s3_i <= (s2_i[0] + s2_i[1]) + (s2_i[2] + s2_i[3]) + s2_i[4];
    s3_q <= (s2_q[0] + s2_q[1]) + (s2_q[2] + s2_q[3]) + s2_q[4];
end

`endif

// rounding, scaling, saturation
wire signed [39:0] r_i = (s3_i + (40'sd1 <<< (16 - OUT_SHL))) >>> (17 - OUT_SHL);
wire signed [39:0] r_q = (s3_q + (40'sd1 <<< (16 - OUT_SHL))) >>> (17 - OUT_SHL);
function signed [15:0] sat16;
    input signed [39:0] v;
    begin
        if (v > 40'sd32767) sat16 = 16'sd32767;
        else if (v < -40'sd32767) sat16 = -16'sd32767;
        else sat16 = v[15:0];
    end
endfunction

`ifdef DVBS2_FIR_FOLD
wire out_take = s3_v;
`else
reg [LAT-1:0] vpipe;
always @(posedge clk) begin
    if (rst) vpipe <= {LAT{1'b0}};
    else vpipe <= {vpipe[LAT-2:0], in_valid};
end
wire out_take = vpipe[LAT-1];
`endif
always @(posedge clk) begin
    if (rst) begin
        out_valid <= 1'b0; out_i <= 16'sd0; out_q <= 16'sd0;
    end else begin
        out_valid <= out_take;
        if (out_take) begin
            out_i <= sat16(r_i);
            out_q <= sat16(r_q);
        end
    end
end
endmodule
