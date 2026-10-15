// rx_frame_front.v -- streaming part of the frame synchroniser.
//
//  * NCO derotation of every symbol: z' = z * exp(-j*phi), phi += omega.
//    A new omega can be scheduled to take effect at a given symbol index.
//  * z' (12-bit I/Q) is written to the circular symbol buffer (index = symbol count).
//  * Differential SOF/PLSC correlator on z' (CFO tolerant):
//        d_n = z'_n conj(z'_{n-1})
//        A = sum_{i=1..25} d_{h+i} conj(c_i)   (SOF),  B = sum_i d_{h+27+2i} conj(p_i)  (PLSC pairs)
//        M = max(|A+B|, |A-B|),  P = sum |d| over the 89 header differentials
//    evaluated for "header ends at symbol n" (h = n-89).
//  * Peak events: SEARCH -> local maximum of M above thr_acq (window +-4);
//                 TRACK  -> best M in [exp_end-2, exp_end+2].
`timescale 1ns/1ps
module rx_frame_front (
    input  wire               clk,
    input  wire               rst,
    input  wire [7:0]         thr_acq,       // ratio threshold, Q0.8
    input  wire [7:0]         thr_trk,
    // symbol input
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    // frequency control
    output reg  signed [31:0] omega,         // current NCO frequency (2^32 = 1 turn / symbol)
    input  wire               om_set,        // load omega_new at symbol om_at (or now if om_now)
    input  wire               om_now,
    input  wire signed [31:0] om_new,
    input  wire [31:0]        om_at,
    // symbol buffer write port
    output reg                buf_we,
    output reg  [13:0]        buf_waddr,
    output reg  [23:0]        buf_wdata,
    output reg  [31:0]        nwr,           // number of symbols written so far
    // events
    input  wire               mode_track,    // 0: search peaks, 1: watch exp_end window
    input  wire [31:0]        exp_end,        // index of the expected header END symbol
    output reg                ev_valid,
    output reg  [31:0]        ev_idx,        // header END index (header start = idx-89)
    output reg                ev_hit,        // above threshold (always 1 for search events)
    output reg  signed [23:0] ev_ar, ev_ai, ev_br, ev_bi
);
localparam [24:0] A_NEG = 25'h12d910f;
localparam [31:0] B_NEG = 32'hca93c1b9;

// ---------------------------------------------------------------- NCO
reg  [31:0] phi;
reg  [31:0] nin;
reg         pend;
reg  signed [31:0] om_p;
reg  [31:0] om_atr;
wire        rot_v;
wire signed [17:0] rot_x, rot_y;
cordic_rot #(.W(18)) u_nco (.clk(clk), .in_v(in_valid), .in_x({{2{in_i[15]}}, in_i}),
    .in_y({{2{in_q[15]}}, in_q}), .in_ang(-phi[31:16]), .in_tag(1'b0),
    .out_v(rot_v), .out_x(rot_x), .out_y(rot_y), .out_tag());
always @(posedge clk) begin
    if (rst) begin
        phi <= 32'd0; nin <= 32'd0; omega <= 32'sd0; pend <= 1'b0; om_p <= 0; om_atr <= 0;
    end else begin
        if (om_set) begin
            if (om_now) omega <= om_new;
            else begin pend <= 1'b1; om_p <= om_new; om_atr <= om_at; end
        end
        if (in_valid) begin
            nin <= nin + 32'd1;
            if (pend && nin == om_atr) begin
                phi <= phi + om_p; omega <= om_p; pend <= 1'b0;
            end else begin
                phi <= phi + omega;
            end
        end
    end
end

// ---------------------------------------------------------------- buffer write
function signed [11:0] sat12; input signed [17:0] v;
    reg signed [17:0] s;
    begin
        s = v >>> 4;
        sat12 = (s > 18'sd2047) ? 12'sd2047 : (s < -18'sd2047) ? -12'sd2047 : s[11:0];
    end
endfunction
reg  signed [11:0] zi, zq, pzi, pzq;
reg         zv;
always @(posedge clk) begin
    if (rst) begin
        buf_we <= 1'b0; buf_waddr <= 14'd0; buf_wdata <= 24'd0; nwr <= 32'd0;
        zi <= 0; zq <= 0; pzi <= 0; pzq <= 0; zv <= 1'b0;
    end else begin
        buf_we <= rot_v;
        zv <= rot_v;
        if (rot_v) begin
            buf_waddr <= nwr[13:0];
            buf_wdata <= {sat12(rot_x), sat12(rot_y)};
            nwr <= nwr + 32'd1;
            pzi <= zi; pzq <= zq;
            zi <= sat12(rot_x); zq <= sat12(rot_y);
        end
    end
end

// ---------------------------------------------------------------- correlator
// Fully pipelined (one result per clock if needed); latency is irrelevant
// because events carry the symbol index.
// stage 0: registered products d = z conj(zprev)
reg  signed [24:0] p_re, p_im;
reg         p_v;
always @(posedge clk) begin
    if (rst) begin p_re <= 0; p_im <= 0; p_v <= 1'b0; end
    else begin
        p_v <= zv;
        if (zv) begin p_re <= zi * pzi + zq * pzq; p_im <= zq * pzi - zi * pzq; end
    end
end
wire signed [15:0] pr16 = p_re >>> 8;
wire signed [15:0] pi16 = p_im >>> 8;
// stage 0b: |d| (alpha-max-beta-min), registered
reg  signed [15:0] dr16, di16, dr16_a, di16_a;
reg  [15:0] adr, adi;
reg  [15:0] dm;
reg         a_v, d_v;
always @(posedge clk) begin
    if (rst) begin a_v <= 1'b0; d_v <= 1'b0; end
    else begin a_v <= p_v; d_v <= a_v; end
    // step 1: absolute values
    adr <= pr16[15] ? -pr16 : pr16;
    adi <= pi16[15] ? -pi16 : pi16;
    // step 2: magnitude estimate, differential value delayed to match
    dm  <= (adr > adi) ? adr + (adi >> 2) + (adi >> 3) : adi + (adr >> 2) + (adr >> 3);
    if (a_v) begin dr16 <= dr16_a; di16 <= di16_a; end
end
always @(posedge clk) if (p_v) begin dr16_a <= pr16; di16_a <= pi16; end
// stage 1: shift register of differentials (flattened vectors: element k at [16k +: 16])
reg  [16*90-1:0] dsr_r, dsr_i, dmag;
reg  [31:0] cidx;            // index of the symbol whose d is in dsr[0]
reg  [23:0] psum;
reg         c1v;
reg  [31:0] nwr_d;
always @(posedge clk) begin
    if (rst) begin
        dsr_r <= {(16*90){1'b0}}; dsr_i <= {(16*90){1'b0}}; dmag <= {(16*90){1'b0}};
        cidx <= 32'hFFFFFFFF; psum <= 24'd0; c1v <= 1'b0; nwr_d <= 32'd0;
    end else begin
        c1v <= d_v;
        if (zv) nwr_d <= nwr;
        if (d_v) begin
            dsr_r <= {dsr_r[16*89-1:0], dr16};
            dsr_i <= {dsr_i[16*89-1:0], di16};
            dmag  <= {dmag[16*89-1:0], dm};
            // P covers dsr[0..88] after the shift: add new, drop the one leaving (old dsr[88])
            psum <= psum + dm - dmag[16*88 +: 16];
            cidx <= nwr_d - 32'd1;
        end
    end
end
// stage 2: correlation sums, 3-level 4:1 adder tree (64 -> 16 -> 4 -> 1)
//   A: d_{h+k} = dsr[89-k], k = 1..25 (terms 0..24, 25..31 zero)
//   B: d_{h+27+2k} = dsr[62-2k], k = 0..31
//   term = d * conj(c), c = +-j*... : (re, im) = (+-dsr_i, -+dsr_r)
wire [16*32-1:0] ta_r, ta_i, tb_r, tb_i;
genvar gk;
generate for (gk = 0; gk < 32; gk = gk + 1) begin : g_terms
    if (gk < 25) begin : g_a
        assign ta_r[16*gk +: 16] = A_NEG[gk] ? -dsr_i[16*(88-gk) +: 16] :  dsr_i[16*(88-gk) +: 16];
        assign ta_i[16*gk +: 16] = A_NEG[gk] ?  dsr_r[16*(88-gk) +: 16] : -dsr_r[16*(88-gk) +: 16];
    end else begin : g_az
        assign ta_r[16*gk +: 16] = 16'd0;
        assign ta_i[16*gk +: 16] = 16'd0;
    end
    assign tb_r[16*gk +: 16] = B_NEG[gk] ? -dsr_i[16*(62-2*gk) +: 16] :  dsr_i[16*(62-2*gk) +: 16];
    assign tb_i[16*gk +: 16] = B_NEG[gk] ?  dsr_r[16*(62-2*gk) +: 16] : -dsr_r[16*(62-2*gk) +: 16];
end endgenerate
function signed [17:0] sum4; input [63:0] v;     // sum of four signed 16-bit values
    sum4 = ($signed(v[15:0]) + $signed(v[31:16])) + ($signed(v[47:32]) + $signed(v[63:48]));
endfunction
reg  signed [17:0] l1ar [0:7], l1ai [0:7], l1br [0:7], l1bi [0:7];
reg  signed [19:0] l2ar [0:1], l2ai [0:1], l2br [0:1], l2bi [0:1];
reg  [23:0] l1p, l2p;
reg  [31:0] l1idx, l2idx;
reg         l1v, l2v;
integer gi;
always @(posedge clk) begin
    for (gi = 0; gi < 8; gi = gi + 1) begin
        l1ar[gi] <= sum4(ta_r[64*gi +: 64]);
        l1ai[gi] <= sum4(ta_i[64*gi +: 64]);
        l1br[gi] <= sum4(tb_r[64*gi +: 64]);
        l1bi[gi] <= sum4(tb_i[64*gi +: 64]);
    end
    for (gi = 0; gi < 2; gi = gi + 1) begin
        l2ar[gi] <= (l1ar[4*gi] + l1ar[4*gi+1]) + (l1ar[4*gi+2] + l1ar[4*gi+3]);
        l2ai[gi] <= (l1ai[4*gi] + l1ai[4*gi+1]) + (l1ai[4*gi+2] + l1ai[4*gi+3]);
        l2br[gi] <= (l1br[4*gi] + l1br[4*gi+1]) + (l1br[4*gi+2] + l1br[4*gi+3]);
        l2bi[gi] <= (l1bi[4*gi] + l1bi[4*gi+1]) + (l1bi[4*gi+2] + l1bi[4*gi+3]);
    end
end
reg  signed [23:0] ar, ai, br, bi;
reg  [23:0] pp;
reg  [31:0] c2idx;
reg         c2v;
always @(posedge clk) begin
    if (rst) begin l1v <= 1'b0; l2v <= 1'b0; c2v <= 1'b0; end
    else begin l1v <= c1v; l2v <= l1v; c2v <= l2v; end
    l1p <= psum; l1idx <= cidx;
    l2p <= l1p;  l2idx <= l1idx;
    ar <= l2ar[0] + l2ar[1]; ai <= l2ai[0] + l2ai[1];
    br <= l2br[0] + l2br[1]; bi <= l2bi[0] + l2bi[1];
    pp <= l2p; c2idx <= l2idx;
end
// stage 3: M = max(|A+B|, |A-B|) (alpha-max-beta-min), 3 pipeline steps
reg  signed [24:0] s_pr, s_pi, s_mr, s_mi;
reg  [24:0] a_pr, a_pi, a_mr, a_mi;
reg  [24:0] mag_p, mag_m;
reg  signed [23:0] q1ar, q1ai, q1br, q1bi, q2ar, q2ai, q2br, q2bi, q3ar, q3ai, q3br, q3bi;
reg  [23:0] q1p, q2p, q3p;
reg  [31:0] q1idx, q2idx, q3idx;
reg         q1v, q2v, q3v;
always @(posedge clk) begin
    if (rst) begin q1v <= 1'b0; q2v <= 1'b0; q3v <= 1'b0; end
    else begin q1v <= c2v; q2v <= q1v; q3v <= q2v; end
    // q1: sums
    s_pr <= ar + br; s_pi <= ai + bi; s_mr <= ar - br; s_mi <= ai - bi;
    q1ar <= ar; q1ai <= ai; q1br <= br; q1bi <= bi; q1p <= pp; q1idx <= c2idx;
    // q2: absolute values
    a_pr <= s_pr[24] ? -s_pr : s_pr; a_pi <= s_pi[24] ? -s_pi : s_pi;
    a_mr <= s_mr[24] ? -s_mr : s_mr; a_mi <= s_mi[24] ? -s_mi : s_mi;
    q2ar <= q1ar; q2ai <= q1ai; q2br <= q1br; q2bi <= q1bi; q2p <= q1p; q2idx <= q1idx;
    // q3: magnitudes
    mag_p <= (a_pr > a_pi) ? a_pr + (a_pi >> 2) + (a_pi >> 3) : a_pi + (a_pr >> 2) + (a_pr >> 3);
    mag_m <= (a_mr > a_mi) ? a_mr + (a_mi >> 2) + (a_mi >> 3) : a_mi + (a_mr >> 2) + (a_mr >> 3);
    q3ar <= q2ar; q3ai <= q2ai; q3br <= q2br; q3bi <= q2bi; q3p <= q2p; q3idx <= q2idx;
end
// stage 4: max, ratio products (registered), stage 5: compares
//   ratio test  M / (P*57/89) > thr/256   <=>   M*89*256 > thr*57*P
reg  [24:0] M5, M4;
reg  [23:0] P5;
reg  [47:0] lhs4, racq4, rtrk4;
reg  [13:0] tacq57, ttrk57;
reg  signed [23:0] a5r, a5i, b5r, b5i, a4r, a4i, b4r, b4i;
reg  [31:0] c5idx, c4idx;
reg         c5v, c4v;
always @(posedge clk) begin
    if (rst) begin c5v <= 1'b0; c4v <= 1'b0; end
    else begin c5v <= q3v; c4v <= c5v; end
    tacq57 <= thr_acq * 14'd57;
    ttrk57 <= thr_trk * 14'd57;
    // max of the two magnitudes
    M5 <= (mag_p > mag_m) ? mag_p : mag_m;
    P5 <= q3p;
    a5r <= q3ar; a5i <= q3ai; b5r <= q3br; b5i <= q3bi; c5idx <= q3idx;
    // ratio products
    M4 <= M5;
    lhs4  <= M5 * 48'd22784;
    racq4 <= P5 * tacq57;
    rtrk4 <= P5 * ttrk57;
    a4r <= a5r; a4i <= a5i; b4r <= b5r; b4i <= b5i; c4idx <= c5idx;
end
reg  [24:0] M3;
reg  [31:0] c3idx;
reg         c3v;
reg  signed [23:0] a3r, a3i, b3r, b3i;
reg         hacq, htrk;
always @(posedge clk) begin
    if (rst) c3v <= 1'b0; else c3v <= c4v;
    M3 <= M4; c3idx <= c4idx;
    a3r <= a4r; a3i <= a4i; b3r <= b4r; b3i <= b4i;
    hacq <= (lhs4 > racq4) && (c4idx >= 32'd89);
    htrk <= (lhs4 > rtrk4) && (c4idx >= 32'd89);
end

// ---------------------------------------------------------------- events
reg         pk_v;
reg  [31:0] pk_idx;
reg  [24:0] pk_M;
reg         pk_hit;
reg  signed [23:0] pk_ar, pk_ai, pk_br, pk_bi;
always @(posedge clk) begin
    if (rst) begin
        pk_v <= 1'b0; ev_valid <= 1'b0; ev_idx <= 0; ev_hit <= 1'b0;
        ev_ar <= 0; ev_ai <= 0; ev_br <= 0; ev_bi <= 0; pk_idx <= 0; pk_M <= 0; pk_hit <= 1'b0;
        pk_ar <= 0; pk_ai <= 0; pk_br <= 0; pk_bi <= 0;
    end else begin
        ev_valid <= 1'b0;
        if (c3v) begin
            if (!mode_track) begin
                if (hacq && (!pk_v || M3 > pk_M)) begin
                    pk_v <= 1'b1; pk_idx <= c3idx; pk_M <= M3; pk_hit <= 1'b1;
                    pk_ar <= a3r; pk_ai <= a3i; pk_br <= b3r; pk_bi <= b3i;
                end else if (pk_v && c3idx >= pk_idx + 32'd4) begin
                    ev_valid <= 1'b1; ev_idx <= pk_idx; ev_hit <= 1'b1;
                    ev_ar <= pk_ar; ev_ai <= pk_ai; ev_br <= pk_br; ev_bi <= pk_bi;
                    pk_v <= 1'b0;
                end
            end else begin
                if (c3idx + 32'd2 >= exp_end && c3idx <= exp_end + 32'd2) begin
                    if (c3idx + 32'd2 == exp_end || M3 > pk_M) begin
                        pk_idx <= c3idx; pk_M <= M3; pk_hit <= htrk;
                        pk_ar <= a3r; pk_ai <= a3i; pk_br <= b3r; pk_bi <= b3i;
                    end
                    if (c3idx == exp_end + 32'd2) begin
                        ev_valid <= 1'b1;
                        if (M3 > pk_M) begin
                            ev_idx <= c3idx; ev_hit <= htrk;
                            ev_ar <= a3r; ev_ai <= a3i; ev_br <= b3r; ev_bi <= b3i;
                        end else begin
                            ev_idx <= pk_idx; ev_hit <= pk_hit;
                            ev_ar <= pk_ar; ev_ai <= pk_ai; ev_br <= pk_br; ev_bi <= pk_bi;
                        end
                    end
                end
                pk_v <= 1'b0;
            end
        end
    end
end
endmodule
