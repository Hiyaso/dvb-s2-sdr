// rx_timing.v -- symbol timing recovery: Gardner TED + piecewise-parabolic Farrow
// interpolator (alpha = 1/2) + PI loop filter + modulo-1 NCO (Rice, sec. 8.4.4).
//
// Input : matched-filter output, 2 samples/symbol.  One input every >= 6 clocks
//         (the NCO/mu update of a sample completes 6 clocks after it arrives).
// Output: one interpolated symbol per strobe (about 1 per 2 inputs).
// Fixed point: eta, W in units of 2^-24 (W nominal 0.5 = 2^23), mu Q0.16.
//   v = -(e >>> k1s) - integ,  integ += e >>> k2s,  W = 0.5 + v
// With the AGC target used here the TED gain makes k1s = 9, k2s = 18
// equivalent to k1 = 2^-7, k2 = 2^-16 of python/sync_model.py.
`timescale 1ns/1ps
module rx_timing (
    input  wire               clk,
    input  wire               rst,
    input  wire [4:0]         k1s,
    input  wire [4:0]         k2s,
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output reg                out_valid,
    output reg  signed [15:0] out_i,
    output reg  signed [15:0] out_q,
    output wire [15:0]        mu_out,
    output wire signed [31:0] loop_integ
);
// sample history (x0 newest)
reg signed [15:0] x1i, x2i, x3i, x1q, x2q, x3q, x4i, x4q;
reg signed [15:0] x0i, x0q;
reg [15:0] mu;
reg [24:0] eta;              // 1.0 = 2^24
reg [24:0] w;
reg        strobe;
reg signed [31:0] integ;
assign mu_out = mu;
assign loop_integ = integ;

// stage registers
reg        s0, s1, s2, s3;
reg signed [18:0] v2i, v2q, v1i, v1q, v0i, v0q;
reg signed [18:0] w2i, w2q, w1i, w1q, w0i, w0q;   // mid-point window (one sample earlier)
reg signed [18:0] ti, tq, tmi, tmq;
reg signed [15:0] yi, yq;            // interpolant
reg signed [15:0] ymi, ymq;          // interpolant half a symbol earlier (same mu)
reg signed [15:0] pyi, pyq;          // previous interpolant (mid sample)
reg signed [15:0] psi, psq;          // previous symbol
reg signed [33:0] e;
reg               was_strobe;

function signed [15:0] sat16; input signed [35:0] v;
    sat16 = (v > 36'sd32767) ? 16'sd32767 : (v < -36'sd32767) ? -16'sd32767 : v[15:0];
endfunction

wire signed [35:0] m1i = v2i * $signed({1'b0, mu});
wire signed [35:0] m1q = v2q * $signed({1'b0, mu});
wire signed [35:0] m2i = ti  * $signed({1'b0, mu});
wire signed [35:0] m2q = tq  * $signed({1'b0, mu});
wire signed [35:0] n1i = w2i * $signed({1'b0, mu});
wire signed [35:0] n1q = w2q * $signed({1'b0, mu});
wire signed [35:0] n2i = tmi * $signed({1'b0, mu});
wire signed [35:0] n2q = tmq * $signed({1'b0, mu});
wire signed [16:0] dmi = psi - yi;
wire signed [16:0] dmq = psq - yq;
wire signed [33:0] ted = ymi * dmi + ymq * dmq;

// loop filter / NCO, spread over three clocks after the TED (s3 -> s4 -> s5)
wire signed [31:0] e_k1 = e >>> k1s;
wire signed [31:0] e_k2 = e >>> k2s;
wire signed [31:0] integ_n = integ + e_k2;
wire signed [31:0] v_n = -(e_k1) - integ_n;
wire signed [26:0] w_s = 27'sd8388608 + v_n;           // 0.5 + v
wire [24:0] w_n = (w_s < 27'sd6291456) ? 25'd6291456 : (w_s > 27'sd10485760) ? 25'd10485760 : w_s[24:0];
reg  [24:0] w_use;                                      // W for this sample's NCO step (s4)
wire signed [25:0] eta_d = $signed({1'b0, eta}) - $signed({1'b0, w_use});
// mu = eta / W ~ 2*eta*(1 - 2*(W - 0.5)):  operands registered at s5 (mu_upd),
// product registered one clock later (mu_upd2), mu written the clock after that
// (still before the next sample, >= 8 clocks apart, uses it in its cycle 1)
reg  [24:0] mu_eta;
reg  signed [27:0] mu_fac;                                              // (1 - 2dw), Q24
reg         mu_upd, mu_upd2;
reg  signed [55:0] mu_p;                                                // 2eta*(1-2dw), Q48
wire        [16:0] mu_new = (mu_p < 0) ? 17'd0 : mu_p[48:32];          // Q16
reg         s4, s5;

always @(posedge clk) begin
    if (rst) begin
        x0i <= 0; x0q <= 0; x4i <= 0; x4q <= 0; x1i <= 0; x2i <= 0; x3i <= 0; x1q <= 0; x2q <= 0; x3q <= 0;
        mu <= 16'd0; eta <= 25'd0; w <= 25'd8388608; strobe <= 1'b0; integ <= 32'sd0;
        s0 <= 0; s1 <= 0; s2 <= 0; s3 <= 0; s4 <= 0; s5 <= 0; mu_upd <= 1'b0; mu_upd2 <= 1'b0; w_use <= 25'd8388608;
        mu_eta <= 25'd0; mu_fac <= 28'sd16777216; mu_p <= 56'sd0; out_valid <= 1'b0; out_i <= 0; out_q <= 0;
        pyi <= 0; pyq <= 0; psi <= 0; psq <= 0; e <= 0; was_strobe <= 1'b0;
        v2i <= 0; v2q <= 0; v1i <= 0; v1q <= 0; v0i <= 0; v0q <= 0; ti <= 0; tq <= 0; yi <= 0; yq <= 0;
        w2i <= 0; w2q <= 0; w1i <= 0; w1q <= 0; w0i <= 0; w0q <= 0; tmi <= 0; tmq <= 0; ymi <= 0; ymq <= 0;
    end else begin
        s0 <= in_valid; s1 <= s0; s2 <= s1; s3 <= s2;
        out_valid <= 1'b0;
        // ---- cycle 0: new sample, Farrow coefficients (interpolate between x2 and x1)
        if (in_valid) begin
            v2i <= ((in_i - x1i - x2i + x3i) >>> 1);
            v2q <= ((in_q - x1q - x2q + x3q) >>> 1);
            v1i <= -(in_i >>> 1) + x1i + (x1i >>> 1) - (x2i >>> 1) - (x3i >>> 1);
            v1q <= -(in_q >>> 1) + x1q + (x1q >>> 1) - (x2q >>> 1) - (x3q >>> 1);
            v0i <= x2i; v0q <= x2q;
            w2i <= ((x1i - x2i - x3i + x4i) >>> 1);
            w2q <= ((x1q - x2q - x3q + x4q) >>> 1);
            w1i <= -(x1i >>> 1) + x2i + (x2i >>> 1) - (x3i >>> 1) - (x4i >>> 1);
            w1q <= -(x1q >>> 1) + x2q + (x2q >>> 1) - (x3q >>> 1) - (x4q >>> 1);
            w0i <= x3i; w0q <= x3q;
            x4i <= x3i; x3i <= x2i; x2i <= x1i; x1i <= in_i;
            x4q <= x3q; x3q <= x2q; x2q <= x1q; x1q <= in_q;
        end
        // ---- cycle 1: t = v2*mu + v1
        if (s0) begin
            ti <= (m1i >>> 16) + v1i;
            tq <= (m1q >>> 16) + v1q;
            tmi <= (n1i >>> 16) + w1i;
            tmq <= (n1q >>> 16) + w1q;
        end
        // ---- cycle 2: y = t*mu + v0
        if (s1) begin
            yi <= sat16((m2i >>> 16) + v0i);
            yq <= sat16((m2q >>> 16) + v0q);
            ymi <= sat16((n2i >>> 16) + w0i);
            ymq <= sat16((n2q >>> 16) + w0q);
        end
        // ---- cycle 3: strobe -> output symbol, Gardner error
        if (s2) begin
            was_strobe <= strobe;
            if (strobe) begin
                out_valid <= 1'b1; out_i <= yi; out_q <= yq;
                e <= ted;
                psi <= yi; psq <= yq;
            end
            pyi <= yi; pyq <= yq;
        end
        // ---- cycle 4: loop filter (registered)
        s4 <= s3; s5 <= s4;
        if (s3) begin
            if (was_strobe) begin
                integ <= integ_n;
                w     <= w_n;
                w_use <= w_n;
            end else begin
                w_use <= w;
            end
        end
        // ---- cycle 5: NCO step
        mu_upd <= 1'b0;
        if (s4) begin
            if (eta_d < 0) begin
                eta    <= eta_d + 26'sd16777216;
                strobe <= 1'b1;
                mu_eta <= eta;
                mu_fac <= 28'sd16777216 - (($signed({3'b000, w_use}) - 28'sd8388608) <<< 1);
                mu_upd <= 1'b1;
            end else begin
                eta    <= eta_d[24:0];
                strobe <= 1'b0;
            end
        end
        // ---- cycles 6, 7: fractional interval for the next interpolants
        mu_upd2 <= mu_upd;
        if (mu_upd) mu_p <= $signed({2'b00, mu_eta, 1'b0}) * mu_fac;
        if (mu_upd2) mu <= (mu_new > 17'd65535) ? 16'hFFFF : mu_new[15:0];
    end
end
endmodule
