// ch_emu.v -- channel emulator for the PL loopback: sampling-clock offset and
// fractional delay (8-tap polyphase interpolator, 64 phases), carrier frequency /
// phase offset (NCO + CORDIC) and additive white Gaussian noise (sum of 8
// uniforms per rail from two xorshift64 generators).
//
//   time step per output = 1 + ppm_step * 2^-32   (signed)
//   cfo_step: carrier phase increment per output sample (2^32 = one turn)
//   noise_amp: noise sigma per rail = noise_amp * 0.8165 (LSB)  (0 = no noise)
// Requires >= 4 clocks between input samples.
`timescale 1ns/1ps
module ch_emu (
    input  wire               clk,
    input  wire               rst,
    input  wire               bypass,
    input  wire signed [31:0] ppm_step,
    input  wire [15:0]        delay_frac,     // initial fractional delay (Q0.16)
    input  wire [31:0]        cfo_step,
    input  wire [15:0]        phase0,         // initial carrier phase (2^16 = turn)
    input  wire [15:0]        noise_amp,
    input  wire [15:0]        sig_gain,       // Q2.14 signal gain (16384 = 1.0)
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output reg                out_valid,
    output reg  signed [15:0] out_i,
    output reg  signed [15:0] out_q
);
// ------------------------------------------------------------ resampler
reg signed [15:0] wi [0:7];
reg signed [15:0] wq [0:7];
reg  signed [40:0] pos;           // Q9.32 position of the next output in the window
reg         started;
integer k;
wire        can_out = started && (pos < $signed({9'd4, 32'd0}));
wire [5:0]  ph = pos[31:26];
wire signed [15:0] c [0:7];
genvar g;
generate for (g = 0; g < 8; g = g + 1) begin : g_c
    ch_interp_rom u_r (.phase(ph), .tap(g[2:0]), .c(c[g]));
end endgenerate
reg signed [31:0] pr_i [0:7];
reg signed [31:0] pr_q [0:7];
reg        p_v;
reg        r_v;
reg signed [17:0] r_i, r_q;
reg        h_v;
reg signed [33:0] h_i [0:1];      // partial sums of 4 products
reg signed [33:0] h_q [0:1];
wire signed [34:0] acc_i = h_i[0] + h_i[1];
wire signed [34:0] acc_q = h_q[0] + h_q[1];
wire [40:0] step = {9'd1, 32'd0} + {{9{ppm_step[31]}}, ppm_step};
always @(posedge clk) begin
    if (rst) begin
        for (k = 0; k < 8; k = k + 1) begin wi[k] <= 0; wq[k] <= 0; pr_i[k] <= 0; pr_q[k] <= 0; end
        pos <= {9'd4, 32'd0}; started <= 1'b0; p_v <= 1'b0; h_v <= 1'b0; r_v <= 1'b0; r_i <= 0; r_q <= 0;
        h_i[0] <= 0; h_i[1] <= 0; h_q[0] <= 0; h_q[1] <= 0;
    end else begin
        p_v <= 1'b0;
        if (in_valid) begin
            for (k = 0; k < 7; k = k + 1) begin wi[k] <= wi[k+1]; wq[k] <= wq[k+1]; end
            wi[7] <= in_i; wq[7] <= in_q;
            if (!started) begin
                started <= 1'b1;
                pos <= $signed({9'd4, 32'd0}) - $signed({9'd0, delay_frac, 16'd0});
            end else begin
                pos <= pos - $signed({9'd1, 32'd0});
            end
        end else if (can_out) begin
            // stage 1: products with the current window and phase
            p_v <= 1'b1;
            for (k = 0; k < 8; k = k + 1) begin
                pr_i[k] <= wi[k] * c[k];
                pr_q[k] <= wq[k] * c[k];
            end
            pos <= pos + $signed(step);
        end
        // stage 2: partial sums, stage 3: sum
        h_v <= p_v;
        if (p_v) begin
            h_i[0] <= (pr_i[0] + pr_i[1]) + (pr_i[2] + pr_i[3]);
            h_i[1] <= (pr_i[4] + pr_i[5]) + (pr_i[6] + pr_i[7]);
            h_q[0] <= (pr_q[0] + pr_q[1]) + (pr_q[2] + pr_q[3]);
            h_q[1] <= (pr_q[4] + pr_q[5]) + (pr_q[6] + pr_q[7]);
        end
        r_v <= h_v;
        if (h_v) begin
            r_i <= acc_i >>> 14;
            r_q <= acc_q >>> 14;
        end
    end
end

// ------------------------------------------------------------ carrier offset
reg  [31:0] ph_acc;
wire        rot_v;
wire signed [17:0] rot_i, rot_q;
cordic_rot #(.W(18)) u_rot (.clk(clk), .in_v(r_v), .in_x(r_i), .in_y(r_q),
    .in_ang(ph_acc[31:16] + phase0), .in_tag(1'b0),
    .out_v(rot_v), .out_x(rot_i), .out_y(rot_q), .out_tag());
always @(posedge clk) begin
    if (rst) ph_acc <= 32'd0;
    else if (r_v) ph_acc <= ph_acc + cfo_step;
end

// ------------------------------------------------------------ noise
reg [63:0] xs1, xs2;
wire [63:0] t1a = xs1 ^ (xs1 << 13);
wire [63:0] t1b = t1a ^ (t1a >> 7);
wire [63:0] n1  = t1b ^ (t1b << 17);
wire [63:0] t2a = xs2 ^ (xs2 << 13);
wire [63:0] t2b = t2a ^ (t2a >> 7);
wire [63:0] n2  = t2b ^ (t2b << 17);
reg  [18:0] sum_i, sum_q, part_i, part_q;
reg         half;
wire [17:0] u4_i = xs1[15:0] + xs1[31:16] + xs1[47:32] + xs1[63:48];
wire [17:0] u4_q = xs2[15:0] + xs2[31:16] + xs2[47:32] + xs2[63:48];
always @(posedge clk) begin
    if (rst) begin
        xs1 <= 64'h9E3779B97F4A7C15; xs2 <= 64'hD1B54A32D192ED03;
        half <= 1'b0; part_i <= 0; part_q <= 0; sum_i <= 19'd262144; sum_q <= 19'd262144;
    end else begin
        xs1 <= n1; xs2 <= n2;
        half <= ~half;
        if (!half) begin part_i <= u4_i; part_q <= u4_q; end
        else begin sum_i <= part_i + u4_i; sum_q <= part_q + u4_q; end
    end
end
wire signed [19:0] gn_i = $signed({1'b0, sum_i}) - 20'sd262140;   // mean 8 * 32767.5
wire signed [19:0] gn_q = $signed({1'b0, sum_q}) - 20'sd262140;
reg  signed [36:0] nz_i, nz_q;
always @(posedge clk) begin
    nz_i <= gn_i * $signed({1'b0, noise_amp});
    nz_q <= gn_q * $signed({1'b0, noise_amp});
end

// ------------------------------------------------------------ output
// CORDIC gain K = 1.6468: signal gain applied as sig_gain * 0.6073
// 3 pipeline steps: gain product, CORDIC-gain compensation product, noise add
reg  signed [35:0] sg_i, sg_q;
reg  signed [37:0] sk_i, sk_q;
reg                o1_v, o2_v;
always @(posedge clk) begin
    if (rst) begin o1_v <= 1'b0; o2_v <= 1'b0; end
    else begin o1_v <= rot_v; o2_v <= o1_v; end
    sg_i <= rot_i * $signed({1'b0, sig_gain});
    sg_q <= rot_q * $signed({1'b0, sig_gain});
    sk_i <= ((sg_i >>> 14) * 38'sd19898) >>> 15;
    sk_q <= ((sg_q >>> 14) * 38'sd19898) >>> 15;
end
wire signed [37:0] y_i = sk_i + (nz_i >>> 16);
wire signed [37:0] y_q = sk_q + (nz_q >>> 16);
function signed [15:0] sat16; input signed [37:0] v;
    sat16 = (v > 38'sd32767) ? 16'sd32767 : (v < -38'sd32767) ? -16'sd32767 : v[15:0];
endfunction
always @(posedge clk) begin
    if (rst) begin
        out_valid <= 1'b0; out_i <= 0; out_q <= 0;
    end else if (bypass) begin
        out_valid <= in_valid;
        if (in_valid) begin out_i <= in_i; out_q <= in_q; end
    end else begin
        out_valid <= o2_v;
        if (o2_v) begin out_i <= sat16(y_i); out_q <= sat16(y_q); end
    end
end
endmodule
