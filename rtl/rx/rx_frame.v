// rx_frame.v -- DVB-S2 frame synchronisation, PLS decoding and carrier recovery
// (pilot/header aided), PL descrambling and amplitude normalisation.
// Algorithm reference: python/frame_model.py.
//
//  rx_frame_front : NCO derotation, symbol buffer write, differential correlator,
//                   header peak events.
//  this module    : sequential processing per header event
//     SEARCH  peak -> coarse residual (angle of A+-B) -> PLS decode -> TRACK
//     TRACK   header expected every frame (window +-2 symbols); on each confirmed
//             header the previous frame is processed:
//               reference blocks (header, pilots, next header) -> phases,
//               FLL stage 1 (coarse, lag 1) / 2 (L&R, 16 lags on the header) /
//               3 (phase difference across the frame, pilots only),
//               phase interpolation between blocks (pilots: header, pilot blocks,
//               next header; no pilots: header to header, plus a decision-directed
//               PLL), descrambling, gain.
//     Output symbols (radius 4096) go to rx_demap.
`timescale 1ns/1ps
module rx_frame (
    input  wire               clk,
    input  wire               rst,
    // configuration
    input  wire [7:0]         thr_acq,      // default 141 (0.55)
    input  wire [7:0]         thr_trk,      // default 90  (0.35)
    input  wire [7:0]         n1,           // frames in FLL stage 1 (default 2)
    input  wire [7:0]         n2,           // frames in FLL stage 2 (default 32)
    input  wire [3:0]         k_acq_s,      // acquisition update shift (default 1)
    input  wire [3:0]         k1s,          // stage 1 gain shift (default 1)
    input  wire [3:0]         k3s,          // stage 3 gain shift (default 1)
    input  wire               pll_en,       // DD-PLL for frames without pilots
    input  wire [3:0]         pll_k1s,      // default 6
    input  wire [3:0]         pll_k2s,      // default 12
    // decoder feedback: in FLL stage 3, 4 consecutive failed frames send the
    // loop back to stage 2 (protects against locking onto a pilot alias)
    input  wire               fec_good,
    input  wire               fec_bad,
    // symbols from timing recovery
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    // corrected data symbols to the demapper
    output wire               s_valid,
    input  wire               s_ready,
    output wire signed [15:0] s_i,
    output wire signed [15:0] s_q,
    output wire               s_first,
    output wire               s_last,
    output wire [3:0]         s_code,
    output wire               s_8psk,
    output wire [15:0]        s_meta,
    // status
    output reg  [3:0]         st_state,
    output wire               st_locked,
    output reg  [4:0]         st_modcod,
    output reg  [1:0]         st_type,
    output wire signed [31:0] st_omega,
    output reg  [31:0]        st_frames,
    output reg  [31:0]        st_misses,
    output reg  [31:0]        st_plsfail,
    output reg  [1:0]         st_stage,
    output reg  [15:0]        st_gain,
    output reg  [15:0]        st_plsq
);
// ===================================================================== front end
reg         mode_track;
reg  [31:0] exp_end;
reg         om_set, om_now;
reg  signed [31:0] om_new;
reg  [31:0] om_at;
wire signed [31:0] omega;
wire        bwe;
wire [13:0] bwaddr;
wire [23:0] bwdata;
wire [31:0] nwr;
wire        ev_valid, ev_hit;
wire [31:0] ev_idx;
wire signed [23:0] ev_ar, ev_ai, ev_br, ev_bi;
rx_frame_front u_front (
    .clk(clk), .rst(rst), .thr_acq(thr_acq), .thr_trk(thr_trk),
    .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
    .omega(omega), .om_set(om_set), .om_now(om_now), .om_new(om_new), .om_at(om_at),
    .buf_we(bwe), .buf_waddr(bwaddr), .buf_wdata(bwdata), .nwr(nwr),
    .mode_track(mode_track), .exp_end(exp_end),
    .ev_valid(ev_valid), .ev_idx(ev_idx), .ev_hit(ev_hit),
    .ev_ar(ev_ar), .ev_ai(ev_ai), .ev_br(ev_br), .ev_bi(ev_bi));
assign st_omega = omega;

// symbol buffer (16K x 24): {I[11:0], Q[11:0]}
reg  [13:0] braddr;
wire [23:0] brdata;
ram_sdp #(.DW(24), .AW(14)) u_buf (.clk(clk), .we(bwe), .waddr(bwaddr), .wdata(bwdata),
    .re(1'b1), .raddr(braddr), .rdata(brdata));
wire signed [11:0] bzi = brdata[23:12];
wire signed [11:0] bzq = brdata[11:0];

// ===================================================================== shared CORDICs
reg         pr_v;
reg  signed [17:0] pr_x, pr_y;
reg  [15:0] pr_a;
reg  [9:0]  pr_tag;
wire        po_v;
wire signed [17:0] po_x, po_y;
wire [9:0]  po_tag;
cordic_rot #(.W(18), .TW(10)) u_prot (.clk(clk), .in_v(pr_v), .in_x(pr_x), .in_y(pr_y),
    .in_ang(pr_a), .in_tag(pr_tag), .out_v(po_v), .out_x(po_x), .out_y(po_y), .out_tag(po_tag));
reg         pv_v;
reg  signed [23:0] pv_x, pv_y;
reg  [3:0]  pv_tag;
wire        vo_v;
wire [15:0] vo_ang;
wire [24:0] vo_mag;
wire [3:0]  vo_tag;
cordic_vec #(.W(24), .TW(4)) u_pvec (.clk(clk), .in_v(pv_v), .in_x(pv_x), .in_y(pv_y), .in_tag(pv_tag),
    .out_v(vo_v), .out_ang(vo_ang), .out_mag(vo_mag), .out_tag(vo_tag));

// ===================================================================== helpers
// z * conj(exp(j k pi/4)) * sqrt(2), k odd
function [27:0] cconj;    // {re[13:0], im[13:0]}
    input signed [11:0] x, y;
    input [2:0] k;
    reg signed [13:0] a, b;
    begin
        a = x + y; b = y - x;                     // z * (1 - j)
        case (k[2:1])                             // times (-j)^((k-1)/2)
            2'd0: cconj = {a, b};
            2'd1: cconj = {b, -a};
            2'd2: cconj = {-a, -b};
            default: cconj = {-b, a};
        endcase
    end
endfunction
// PLS code bits (64, MSB = first) from the 7 signalling bits
function [63:0] plsbits; input [6:0] c;
    reg [31:0] rm; integer i;
    begin
        rm = 32'd0;
        if (c[6]) rm = rm ^ 32'h55555555;
        if (c[5]) rm = rm ^ 32'h33333333;
        if (c[4]) rm = rm ^ 32'h0F0F0F0F;
        if (c[3]) rm = rm ^ 32'h00FF00FF;
        if (c[2]) rm = rm ^ 32'h0000FFFF;
        if (c[1]) rm = rm ^ 32'hFFFFFFFF;
        for (i = 0; i < 32; i = i + 1) begin
            plsbits[63 - 2*i] = rm[31 - i];
            plsbits[62 - 2*i] = rm[31 - i] ^ c[0];
        end
        plsbits = plsbits ^ 64'h719D83C953422DFA;
    end
endfunction
localparam [25:0] SOFB = 26'h18D2E82;
localparam [63:0] PSCR = 64'h719D83C953422DFA;
// phase index of known header symbol n (pi/2-BPSK)
function [2:0] hdr_k; input [6:0] n; input [63:0] pb;
    reg bit_;
    begin
        bit_ = (n < 26) ? SOFB[25 - n] : pb[63 - (n - 26)];
        hdr_k = (n[0] ? 3'd3 : 3'd1) + (bit_ ? 3'd4 : 3'd0);
    end
endfunction
// frame parameters from the PLS
function [13:0] flen; input [6:0] c;      // header + body
    reg is8; reg pil;
    begin
        is8 = (c[6:2] >= 5'd12); pil = c[0];
        if (c[6:2] == 5'd0) flen = 14'd3330;
        else if (is8) flen = pil ? 14'd5598 : 14'd5490;
        else flen = pil ? 14'd8370 : 14'd8190;
    end
endfunction
function plsc_ok; input [6:0] c;
    plsc_ok = (c[6:2] == 5'd0) ||
              (c[1] && ((c[6:2] >= 5'd1 && c[6:2] <= 5'd10) || (c[6:2] >= 5'd12 && c[6:2] <= 5'd16)));
endfunction
function [31:0] recip_len; input [13:0] L;  // 2^32 / L
    case (L)
        14'd8370: recip_len = 32'd513138;  14'd5598: recip_len = 32'd767232;
        14'd8190: recip_len = 32'd524416;  14'd5490: recip_len = 32'd782326;
        default:  recip_len = 32'd1289780;
    endcase
endfunction
function signed [11:0] s12; input signed [17:0] v;
    s12 = (v > 18'sd2047) ? 12'sd2047 : (v < -18'sd2047) ? -12'sd2047 : v[11:0];
endfunction

// ===================================================================== state
localparam S_SEARCH = 5'd0,  S_SRES = 5'd1,  S_PLS = 5'd2,  S_TRACK = 5'd3,  S_TRES = 5'd4,
           S_MISS = 5'd5,  S_PROC = 5'd6,  S_OUT = 5'd7,  S_ACQDONE = 5'd8, S_PLSDONE = 5'd9,
           S_NEXT = 5'd10;
reg  [4:0]  st;
reg  [1:0]  pls_ret;                 // 0: from search, 1: track centre 0, 2: track centre res
reg  [31:0] ev_i_l;
reg  signed [24:0] dre, dim;
reg  [15:0] res;                     // coarse residual (2^16 = turn / symbol)
reg  [31:0] H, Hn;
reg  [6:0]  plsc, nplsc;
reg  [7:0]  nlock;
reg  [3:0]  misses;
reg  [15:0] fcount;
reg  [2:0]  badrun;
assign st_locked = (st != S_SEARCH) && (st != S_SRES) && !(st == S_PLS && pls_ret == 2'd0);

// ---------------------------------------------------------- PLS decoder
reg  [13:0] pls_h;
reg  signed [31:0] pls_c;            // centre frequency
reg  [3:0]  pg;                      // grid index 0..8
reg  [3:0]  pst;                     // PLS sub-state
reg  [6:0]  pcnt;                    // issue counter
reg  [6:0]  pcol;                    // collected outputs
reg  signed [31:0] pw, pacc;
reg  signed [23:0] csr, csi;
reg  signed [17:0] hzx [0:63];
reg  signed [17:0] hzy [0:63];
reg  signed [21:0] sv  [0:63];
reg  [27:0] sabs;
reg  signed [27:0] f0 [0:31];
reg  signed [27:0] f1 [0:31];
reg  [2:0]  fst;
reg  [6:0]  mj;
reg  [27:0] cur_best;
reg  [4:0]  cur_u;
reg         cur_p, cur_neg;
reg  [27:0] bb_abs, bb_sabs;
reg  [6:0]  bb_plsc;
reg  [15:0] theta;
reg         rd1, rd2;                // buffer read issued 1 / 2 cycles ago (data valid at rd2)
reg  [6:0]  rd1_tag, rd2_tag;
reg         pls_ok;
reg  [6:0]  pls_res;
// frequency hypotheses for PLS decoding: centre + k * 0.02 rad/symbol, k = -4..4
wire signed [31:0] grid = $signed({28'd0, pg}) * 32'sd13671306 - 32'sd54685224;

// ---------------------------------------------------------- frame processing
reg  [4:0]  fpst;
reg  [13:0] fcnt;
reg  [2:0]  fblk;
reg  [63:0] pb_cur, pb_nxt;
reg  signed [21:0] chr, chi, cnr, cni;
reg  signed [21:0] cpr [0:4];
reg  signed [21:0] cpi [0:4];
reg  signed [13:0] ur [0:89];
reg  signed [13:0] ui [0:89];
reg  signed [47:0] lrr, lri;
reg  [4:0]  lm;
reg  [6:0]  ln;
reg  [15:0] ang [0:7];               // 0: header, 1..np: pilots, np+1: next header, 7: L&R
reg  [24:0] mag_hdr;
reg  [3:0]  nang;                    // angles collected
reg  [3:0]  nissue;
reg  signed [23:0] TH [0:6];         // unwrapped block phases (2^16 per turn)
reg  [2:0]  np;                      // pilot blocks in this frame
reg  [13:0] L;                       // frame length
reg         is8, pil, dummy;
reg  [3:0]  code;
reg  [1:0]  stage;
reg  signed [31:0] dlt [0:5];        // per-symbol phase slope of segments 1..np+1
reg  signed [31:0] sph [0:5];        // phase at the first data symbol of each segment
reg  [31:0] div_n, div_q;
reg  [32:0] div_r;
reg  [24:0] div_d;
reg  [5:0]  div_c;
reg  [15:0] gain;                    // Q4.12

// ---------------------------------------------------------- output pass
reg  [13:0] op;                      // body index (data + pilot positions)
reg  [13:0] ndat;                    // data symbols issued
reg  [2:0]  seg;                     // phase segment
reg  [10:0] pdist;                   // body positions until the next pilot block
reg  [5:0]  pleft;                   // pilot symbols left in the current block (0 = data)
reg  [2:0]  pblk;                    // pilot blocks passed
reg  signed [31:0] phacc;
reg  [17:0] gx, gy;
wire gxa = ^(gx & 18'h08050);
wire gxb = ^(gx & 18'h00081);
wire gya = ^(gy & 18'h004A1);
wire gyb = ^(gy & 18'h0FF60);
wire [1:0] grn = {gxa ^ gyb, gx[0] ^ gy[0]};
reg         o_rd, o_rd2;             // buffer read issued 1 / 2 cycles ago
reg  [15:0] o_ang1, o_ang2;          // rotation angle (without PLL) of the issued symbol
reg  [1:0]  o_tag1, o_tag2;          // {first, last}
reg  [6:0]  inflight;
reg  [1:0]  pace;
reg  signed [31:0] pll_th, pll_nu;
wire [13:0] nbody = L - 14'd90;
wire        at_pilot = pil && (pleft != 6'd0);

// output FIFO {I, Q, first, last, code, 8psk, meta}
reg  [56:0] ofifo [0:63];
reg  [6:0]  owp, orp;
wire [6:0]  ocount = owp - orp;
wire        ofull_soon = (ocount + inflight) >= 7'd52;
assign s_valid = (owp != orp);
wire [56:0] oh = ofifo[orp[5:0]];
assign s_i     = oh[56:41];
assign s_q     = oh[40:25];
assign s_first = oh[24];
assign s_last  = oh[23];
assign s_code  = oh[22:19];
assign s_8psk  = oh[18];
assign s_meta  = oh[15:0];
reg  [3:0]  o_code;
reg         o_8psk;
reg  [15:0] o_meta;

// pilot Gold ROM
wire [1:0] pgr;
reg  [13:0] pbase;
pilot_gold_rom u_pg (.blk(fblk), .m(rd2_tag[5:0]), .r(pgr));

// event pipeline: D = A+B or A-B, whichever has the larger power (5 registered steps)
reg         e1v, e2v, e3v, e4v, evd_valid;
reg  [31:0] e1i, e2i, e3i, e4i, evd_idx;
reg         e1h, e2h, e3h, e4h, evd_hit;
reg  signed [24:0] e1pr, e1pi, e1mr, e1mi, e2pr, e2pi, e2mr, e2mi;
reg  signed [24:0] e3pr, e3pi, e3mr, e3mi, e4pr, e4pi, e4mr, e4mi;
reg  signed [49:0] e2ppr, e2ppi, e2pmr, e2pmi, e3ppr, e3ppi, e3pmr, e3pmi;
reg  signed [49:0] e4pp, e4pm;
reg  signed [24:0] evd_x, evd_y;
always @(posedge clk) begin
    if (rst) begin
        e1v <= 1'b0; e2v <= 1'b0; e3v <= 1'b0; e4v <= 1'b0; evd_valid <= 1'b0;
    end else begin
        e1v <= ev_valid; e2v <= e1v; e3v <= e2v; e4v <= e3v; evd_valid <= e4v;
    end
    e1i <= ev_idx; e2i <= e1i; e3i <= e2i; e4i <= e3i; evd_idx <= e4i;
    e1h <= ev_hit; e2h <= e1h; e3h <= e2h; e4h <= e3h; evd_hit <= e4h;
    e1m <= mode_track; e2m <= e1m; e3m <= e2m; e4m <= e3m; evd_mode <= e4m;
    e1pr <= ev_ar + ev_br; e1pi <= ev_ai + ev_bi; e1mr <= ev_ar - ev_br; e1mi <= ev_ai - ev_bi;
    e2pr <= e1pr; e2pi <= e1pi; e2mr <= e1mr; e2mi <= e1mi;
    e3pr <= e2pr; e3pi <= e2pi; e3mr <= e2mr; e3mi <= e2mi;
    e4pr <= e3pr; e4pi <= e3pi; e4mr <= e3mr; e4mi <= e3mi;
    e2ppr <= e1pr * e1pr; e2ppi <= e1pi * e1pi; e2pmr <= e1mr * e1mr; e2pmi <= e1mi * e1mi;
    e3ppr <= e2ppr; e3ppi <= e2ppi; e3pmr <= e2pmr; e3pmi <= e2pmi;   // DSP output registers
    e4pp <= e3ppr + e3ppi; e4pm <= e3pmr + e3pmi;
    evd_x <= (e4pp >= e4pm) ? e4pr : e4mr;
    evd_y <= (e4pp >= e4pm) ? e4pi : e4mi;
end

// registered copy of the rotator output for the PLS decoder (with the SOF
// symbol already multiplied by the conjugate of its known phase)
reg         pq_v;
reg  signed [17:0] pq_x, pq_y;
reg  [9:0]  pq_tag;
reg  [27:0] pq_cc;
// registered symbol-buffer read data for the reference-block accumulations
reg         rd3;
reg  [6:0]  rd3_tag;
reg  signed [11:0] b3i, b3q;
reg  [2:0]  hk3;
reg  [1:0]  pgr3;
// Luise-Reggiannini MAC pipeline
reg         lv1, lv2;
reg  signed [13:0] la_r, la_i, lb_r, lb_i;
reg  signed [27:0] lp1, lp2, lp3, lp4;
// FLL / segment arithmetic operands
reg  signed [23:0] thd;
reg  signed [15:0] a7;
reg  [31:0] rl;
reg  [3:0]  k2s_r;
reg  signed [47:0] fprod;
reg  signed [31:0] p2;
reg  [1:0]  sub;
reg  signed [31:0] sprod;
reg  signed [31:0] fsub, finc, last_dlt;
reg  signed [47:0] fprod_p;          // DSP pipeline stage of fprod
reg  signed [31:0] sprod_p;
reg         gq_v;                    // gain product pipeline (output pass)
reg  signed [33:0] gq_i, gq_q;
reg  [1:0]  gq_t;
reg         pe_v;                    // DD-PLL phase error, registered
reg  signed [15:0] pe_r;
reg         e1m, e2m, e3m, e4m, evd_mode;   // correlator mode of the event (0 search, 1 track)
reg  [31:0] last_at;
// FHT maximum search pipeline
reg         fb_v;
reg  signed [27:0] fbq;
reg  [5:0]  fb_j;
// output FIFO write port
reg         ofifo_we;
reg  [56:0] ofifo_wd;
integer i;
reg [15:0] dang;
reg signed [47:0] wide;
reg [27:0] cc;
reg signed [27:0] fa, fb;

// gain multiply of rotated output
wire signed [33:0] gyi = po_x * $signed({1'b0, gain});
wire signed [33:0] gyq = po_y * $signed({1'b0, gain});
function signed [15:0] sat16; input signed [33:0] v;
    sat16 = (v > 34'sd32767) ? 16'sd32767 : (v < -34'sd32767) ? -16'sd32767 : v[15:0];
endfunction

// DD-PLL phase error from vectoring the output symbol (angle domain)
wire [15:0] e8 = vo_ang + 16'd4096;
wire signed [15:0] pe8 = $signed({3'b000, e8[12:0]}) - 16'sd4096;     // nearest k*pi/4
wire [15:0] e4 = vo_ang;                                                // QPSK: points at odd pi/4
wire signed [15:0] pe4 = $signed({2'b00, e4[13:0]}) - 16'sd8192;      // nearest pi/4 + k*pi/2

always @(posedge clk) begin
    if (rst) begin
        st <= S_SEARCH; mode_track <= 1'b0; exp_end <= 32'd0; om_set <= 1'b0; om_now <= 1'b0;
        om_new <= 0; om_at <= 0; pls_ret <= 0; ev_i_l <= 0; dre <= 0; dim <= 0; res <= 0;
        H <= 0; Hn <= 0; plsc <= 0; nplsc <= 0; nlock <= 0; misses <= 0; fcount <= 0;
        pr_v <= 1'b0; pv_v <= 1'b0; pr_x <= 0; pr_y <= 0; pr_a <= 0; pr_tag <= 0; pv_x <= 0; pv_y <= 0; pv_tag <= 0;
        braddr <= 0; pst <= 0; fpst <= 0; rd1 <= 1'b0; o_rd <= 1'b0; inflight <= 0; owp <= 0; orp <= 0;
        st_state <= 0; st_modcod <= 0; st_type <= 0; st_frames <= 0; st_misses <= 0; st_plsfail <= 0;
        st_stage <= 0; st_gain <= 0; st_plsq <= 0; gain <= 16'd4096; pll_th <= 0; pll_nu <= 0;
        o_code <= 0; o_8psk <= 0; o_meta <= 0; stage <= 0; pace <= 0; badrun <= 0;
        ofifo_we <= 1'b0; gq_v <= 1'b0; pe_v <= 1'b0; fb_v <= 1'b0; lv1 <= 1'b0; lv2 <= 1'b0; rd3 <= 1'b0; sub <= 2'd0;
        last_dlt <= 32'sd0; last_at <= 32'd0;
    end else begin
        om_set <= 1'b0;
        pr_v   <= 1'b0;
        pv_v   <= 1'b0;
        rd1    <= 1'b0;
        rd2    <= rd1;
        rd2_tag <= rd1_tag;
        o_rd   <= 1'b0;
        o_rd2  <= o_rd;
        o_ang2 <= o_ang1; o_tag2 <= o_tag1;
        st_state <= st[3:0];
        if (s_valid && s_ready) orp <= orp + 7'd1;
        if (ofifo_we) owp <= owp + 7'd1;
        ofifo_we <= 1'b0;
        gq_v   <= 1'b0;
        pe_v   <= 1'b0;
        fb_v   <= 1'b0;
        lv1    <= 1'b0;
        // registered buffer data for the reference-block accumulations
        rd3 <= rd2; rd3_tag <= rd2_tag; b3i <= bzi; b3q <= bzq; pgr3 <= pgr;
        hk3 <= hdr_k(rd2_tag, (fpst == 5'd3) ? pb_nxt : pb_cur);

        case (st)
        // ================================================================ SEARCH
        S_SEARCH: begin
            mode_track <= 1'b0;
            pll_nu <= 32'sd0;
            if (evd_valid && !evd_mode) begin
                ev_i_l <= evd_idx;
                pv_x <= evd_x; pv_y <= evd_y;      // D = A+B or A-B, whichever is larger
                pv_v <= 1'b1; pv_tag <= 4'd15;
                st <= S_SRES;
            end
        end
        S_SRES, S_TRES: begin
            if (vo_v && vo_tag == 4'd15) begin
                res <= vo_ang;
                pls_h <= ev_i_l[13:0] - 14'd89;
                pls_c <= (st == S_SRES) ? {vo_ang, 16'd0} : 32'sd0;
                pls_ret <= (st == S_SRES) ? 2'd0 : 2'd1;
                pg <= 4'd0; pst <= 4'd0;
                bb_abs <= 0; bb_sabs <= 0; bb_plsc <= 0;
                st <= S_PLS;
            end
        end
        // ================================================================ PLS decode
        S_PLS: begin
            case (pst)
            4'd0: begin   // start grid point
                pw   <= pls_c + grid;
                pcnt <= 7'd0; pcol <= 7'd0; csr <= 0; csi <= 0;
                pst  <= 4'd1;
            end
            4'd1: begin   // init derotation phase = 44.5 * w
                pacc <= (pw * 32'sd89) >>> 1;
                pst  <= 4'd2;
            end
            4'd2: begin   // read 90 header symbols and derotate
                if (pcnt < 7'd90) begin
                    braddr <= pls_h + pcnt;
                    rd1 <= 1'b1; rd1_tag <= pcnt;
                    pcnt <= pcnt + 7'd1;
                end
                if (rd2) begin
                    pr_v <= 1'b1; pr_x <= {{6{bzi[11]}}, bzi}; pr_y <= {{6{bzq[11]}}, bzq};
                    pr_a <= pacc[31:16]; pr_tag <= {3'd0, rd2_tag};
                    pacc <= pacc - pw;
                end
                if (pq_v) begin
                    if (pq_tag[6:0] < 7'd26) begin
                        csr <= csr + $signed(pq_cc[27:14]);
                        csi <= csi + $signed(pq_cc[13:0]);
                    end else begin
                        hzx[pq_tag[6:0] - 7'd26] <= pq_x;
                        hzy[pq_tag[6:0] - 7'd26] <= pq_y;
                    end
                    pcol <= pcol + 7'd1;
                    if (pcol == 7'd89) pst <= 4'd3;
                end
            end
            4'd3: begin   // SOF phase
                pv_v <= 1'b1; pv_x <= csr; pv_y <= csi; pv_tag <= 4'd14;
                pst <= 4'd4;
            end
            4'd4: begin
                if (vo_v && vo_tag == 4'd14) begin
                    theta <= vo_ang; pcnt <= 7'd0; pcol <= 7'd0; sabs <= 0; pst <= 4'd5;
                end
            end
            4'd5: begin   // rotate the 64 PLSC symbols by -theta, soft values
                if (pcnt < 7'd64) begin
                    pr_v <= 1'b1; pr_x <= hzx[pcnt[5:0]] >>> 1; pr_y <= hzy[pcnt[5:0]] >>> 1;
                    pr_a <= -theta; pr_tag <= {3'd0, pcnt};
                    pcnt <= pcnt + 7'd1;
                end
                if (pq_v) begin
                    // header index n = 26 + i: even -> Re{y e^{-j pi/4}} ~ x+y ; odd -> y-x
                    fa = pq_tag[0] ? (pq_y - pq_x) : (pq_x + pq_y);
                    if (PSCR[63 - pq_tag[5:0]]) fa = -fa;
                    sv[pq_tag[5:0]] <= fa;
                    sabs <= sabs + (fa[27] ? -fa : fa);
                    pcol <= pcol + 7'd1;
                    if (pcol == 7'd63) pst <= 4'd6;
                end
            end
            4'd6: begin   // pair combination
                for (i = 0; i < 32; i = i + 1) begin
                    f0[i] <= sv[2*i] + sv[2*i+1];
                    f1[i] <= sv[2*i] - sv[2*i+1];
                end
                fst <= 3'd0; pst <= 4'd7;
            end
            4'd7: begin   // fast Hadamard transform, one stage per clock (constant strides)
                case (fst)
                3'd0: for (i = 0; i < 32; i = i + 1) if ((i & 1) == 0) begin
                          f0[i] <= f0[i] + f0[i + 1];  f0[i + 1] <= f0[i] - f0[i + 1];
                          f1[i] <= f1[i] + f1[i + 1];  f1[i + 1] <= f1[i] - f1[i + 1];
                      end
                3'd1: for (i = 0; i < 32; i = i + 1) if ((i & 2) == 0) begin
                          f0[i] <= f0[i] + f0[i + 2];  f0[i + 2] <= f0[i] - f0[i + 2];
                          f1[i] <= f1[i] + f1[i + 2];  f1[i + 2] <= f1[i] - f1[i + 2];
                      end
                3'd2: for (i = 0; i < 32; i = i + 1) if ((i & 4) == 0) begin
                          f0[i] <= f0[i] + f0[i + 4];  f0[i + 4] <= f0[i] - f0[i + 4];
                          f1[i] <= f1[i] + f1[i + 4];  f1[i + 4] <= f1[i] - f1[i + 4];
                      end
                3'd3: for (i = 0; i < 32; i = i + 1) if ((i & 8) == 0) begin
                          f0[i] <= f0[i] + f0[i + 8];  f0[i + 8] <= f0[i] - f0[i + 8];
                          f1[i] <= f1[i] + f1[i + 8];  f1[i + 8] <= f1[i] - f1[i + 8];
                      end
                default: for (i = 0; i < 16; i = i + 1) begin
                          f0[i] <= f0[i] + f0[i + 16]; f0[i + 16] <= f0[i] - f0[i + 16];
                          f1[i] <= f1[i] + f1[i + 16]; f1[i + 16] <= f1[i] - f1[i + 16];
                      end
                endcase
                if (fst == 3'd4) begin pst <= 4'd8; mj <= 7'd0; cur_best <= 0; end
                fst <= fst + 3'd1;
            end
            4'd8: begin   // maximum |F|: select (registered), then compare
                if (mj < 7'd64) begin
                    fb_v <= 1'b1; fb_j <= mj[5:0];
                    fbq <= mj[5] ? f1[mj[4:0]] : f0[mj[4:0]];
                    mj <= mj + 7'd1;
                end
                if (fb_v) begin
                    if ((fbq[27] ? -fbq : fbq) > cur_best) begin
                        cur_best <= fbq[27] ? -fbq : fbq;
                        cur_u <= fb_j[4:0]; cur_p <= fb_j[5]; cur_neg <= fbq[27];
                    end
                    if (fb_j == 6'd63) pst <= 4'd9;
                end
            end
            4'd9: begin   // keep the best grid point
                if (cur_best > bb_abs) begin
                    bb_abs  <= cur_best;
                    bb_sabs <= sabs;
                    bb_plsc <= {cur_u[0], cur_u[1], cur_u[2], cur_u[3], cur_u[4], cur_neg, cur_p};
                end
                if (pg == 4'd8) pst <= 4'd10;
                else begin pg <= pg + 4'd1; pst <= 4'd0; end
            end
            default: begin   // decision
                pls_ok  <= ({bb_abs, 1'b0} >= bb_sabs) && plsc_ok(bb_plsc);
                pls_res <= bb_plsc;
                st_plsq <= bb_abs[27:12];
                st <= S_PLSDONE;
            end
            endcase
        end
        S_PLSDONE: begin
            if (pls_ret == 2'd0) begin
                // acquisition: apply coarse frequency now
                om_set <= 1'b1; om_now <= 1'b1;
                om_new <= omega + ($signed({res, 16'd0}) >>> k_acq_s);
                last_dlt <= 32'sd0; last_at <= ev_i_l;
                if (pls_ok) begin
                    H <= ev_i_l - 32'd89;
                    plsc <= pls_res; nlock <= 8'd0; misses <= 4'd0;
                    exp_end <= ev_i_l + {18'd0, flen(pls_res)};
                    mode_track <= 1'b1;
                    st <= S_TRACK;
                end else begin
                    st_plsfail <= st_plsfail + 32'd1;
                    st <= S_SEARCH;
                end
            end else if (pls_ok) begin
                Hn <= ev_i_l - 32'd89;
                nplsc <= pls_res;
                fpst <= 4'd0;
                st <= S_PROC;
            end else if (pls_ret == 2'd1) begin
                // retry around the coarse residual
                pls_c <= {res, 16'd0}; pls_ret <= 2'd2; pg <= 4'd0; pst <= 4'd0;
                bb_abs <= 0; bb_sabs <= 0; bb_plsc <= 0;
                st <= S_PLS;
            end else begin
                st_plsfail <= st_plsfail + 32'd1;
                st <= S_MISS;
            end
        end
        // ================================================================ TRACK
        S_TRACK: begin
            mode_track <= 1'b1;
            if (evd_valid && evd_mode) begin
                ev_i_l <= evd_idx;
                if (evd_hit) begin
                    pv_x <= evd_x; pv_y <= evd_y;
                    pv_v <= 1'b1; pv_tag <= 4'd15;
                    st <= S_TRES;
                end else begin
                    st <= S_MISS;
                end
            end
        end
        S_MISS: begin
            st_misses <= st_misses + 32'd1;
            if (misses >= 4'd2) begin
                misses <= 4'd0; mode_track <= 1'b0; st <= S_SEARCH;
            end else begin
                misses <= misses + 4'd1;
                H <= H + {18'd0, flen(plsc)};
                exp_end <= H + {18'd0, flen(plsc)} + {18'd0, flen(plsc)} + 32'd89;
                st <= S_TRACK;
            end
        end
        // ================================================================ frame processing
        S_PROC: begin
            case (fpst)
            4'd0: begin
                is8   <= (plsc[6:2] >= 5'd12);
                pil   <= plsc[0] && (plsc[6:2] != 5'd0);
                dummy <= (plsc[6:2] == 5'd0);
                L     <= flen(plsc);
                np    <= (plsc[0] && plsc[6:2] != 5'd0) ? ((plsc[6:2] >= 5'd12) ? 3'd3 : 3'd5) : 3'd0;
                pb_cur <= plsbits(plsc);
                pb_nxt <= plsbits(nplsc);
                chr <= 0; chi <= 0; cnr <= 0; cni <= 0;
                for (i = 0; i < 5; i = i + 1) begin cpr[i] <= 0; cpi[i] <= 0; end
                fcnt <= 14'd0; misses <= 4'd0; pbase <= 14'd0;
                stage <= (nlock < n1) ? 2'd1 : ((nlock < n1 + n2) || !(plsc[0] && plsc[6:2] != 5'd0)) ? 2'd2 : 2'd3;
                fpst <= 4'd1;
            end
            4'd1: begin   // header block of the current frame
                if (fcnt < 14'd90) begin
                    braddr <= H[13:0] + fcnt; rd1 <= 1'b1; rd1_tag <= fcnt[6:0]; fcnt <= fcnt + 14'd1;
                end
                if (rd3) begin
                    cc = cconj(b3i, b3q, hk3);
                    ur[rd3_tag] <= cc[27:14]; ui[rd3_tag] <= cc[13:0];
                    chr <= chr + $signed(cc[27:14]); chi <= chi + $signed(cc[13:0]);
                    if (rd3_tag == 7'd89) begin fpst <= 4'd2; fcnt <= 14'd0; fblk <= 3'd0; end
                end
            end
            4'd2: begin   // pilot blocks
                if (fblk >= np) begin
                    fpst <= 4'd3; fcnt <= 14'd0;
                end else begin
                    if (fcnt < 14'd36) begin
                        braddr <= H[13:0] + 14'd1530 + pbase + fcnt;
                        rd1 <= 1'b1; rd1_tag <= fcnt[6:0]; fcnt <= fcnt + 14'd1;
                    end
                    if (rd3) begin
                        cc = cconj(b3i, b3q, {pgr3, 1'b1});
                        cpr[fblk] <= cpr[fblk] + $signed(cc[27:14]);
                        cpi[fblk] <= cpi[fblk] + $signed(cc[13:0]);
                        if (rd3_tag == 7'd35) begin fblk <= fblk + 3'd1; fcnt <= 14'd0; pbase <= pbase + 14'd1476; end
                    end
                end
            end
            4'd3: begin   // next header
                if (fcnt < 14'd90) begin
                    braddr <= Hn[13:0] + fcnt; rd1 <= 1'b1; rd1_tag <= fcnt[6:0]; fcnt <= fcnt + 14'd1;
                end
                if (rd3) begin
                    cc = cconj(b3i, b3q, hk3);
                    cnr <= cnr + $signed(cc[27:14]); cni <= cni + $signed(cc[13:0]);
                    if (rd3_tag == 7'd89) begin fpst <= 5'd4; lm <= 5'd1; ln <= 7'd0; lrr <= 0; lri <= 0; end
                end
            end
            5'd4: begin   // Luise-Reggiannini: sum_m sum_n u[n+m] conj(u[n]), m = 1..16
                // operand fetch here, products and accumulation in the MAC pipeline below
                lv1 <= 1'b1;
                la_r <= ur[ln + lm]; la_i <= ui[ln + lm]; lb_r <= ur[ln]; lb_i <= ui[ln];
                if (ln + lm == 7'd89) begin
                    ln <= 7'd0;
                    if (lm == 5'd16) fpst <= 5'd10;
                    lm <= lm + 5'd1;
                end else ln <= ln + 7'd1;
            end
            5'd10: begin  // drain the MAC pipeline
                if (!lv1 && !lv2) begin fpst <= 5'd5; nissue <= 4'd0; nang <= 4'd0; end
            end
            4'd5: begin   // angles of all blocks (pipelined vectoring CORDIC)
                if (nissue <= {1'b0, np} + 4'd2) begin
                    pv_v <= 1'b1;
                    if (nissue == 4'd0) begin pv_x <= chr; pv_y <= chi; pv_tag <= 4'd0; end
                    else if (nissue <= {1'b0, np}) begin
                        pv_x <= cpr[nissue - 4'd1]; pv_y <= cpi[nissue - 4'd1]; pv_tag <= nissue;
                    end else if (nissue == {1'b0, np} + 4'd1) begin
                        pv_x <= cnr; pv_y <= cni; pv_tag <= nissue;
                    end else begin
                        pv_x <= lrr >>> 16; pv_y <= lri >>> 16; pv_tag <= 4'd7;
                    end
                    nissue <= nissue + 4'd1;
                end
                if (vo_v) begin
                    ang[vo_tag[2:0]] <= vo_ang;
                    if (vo_tag == 4'd0) mag_hdr <= vo_mag;
                    nang <= nang + 4'd1;
                    if (nang == {1'b0, np} + 4'd2) fpst <= 4'd6;
                end
            end
            4'd6: begin   // unwrap block phases
                TH[0] <= $signed(ang[0]);
                fcnt <= 14'd1;
                fpst <= 4'd7;
            end
            4'd7: begin   // sequential unwrap: TH[b] = TH[b-1] + wrap16(ang[b] - ang[b-1])
                if (fcnt <= {11'd0, np} + 14'd1) begin
                    dang = ang[fcnt[2:0]] - ang[fcnt[2:0] - 3'd1];
                    TH[fcnt[2:0]] <= TH[fcnt[2:0] - 3'd1] + $signed(dang);
                    fcnt <= fcnt + 14'd1;
                end else begin
                    fpst <= 4'd8;
                end
            end
            4'd8: begin   // FLL update, scheduled for the start of the frame after next
`ifdef RXF_DEBUG
                $display("RXF H=%0d stage=%0d omega=%0d res=%0d angLR=%0d e2=%0d TH0=%0d THn=%0d np=%0d mag=%0d",
                    H, stage, omega, $signed(res), $signed(ang[7]), ($signed(ang[7]) * 32'sd7710),
                    TH[0], TH[np + 3'd1], np, mag_hdr);
`endif
                thd <= TH[np + 3'd1] - TH[0];
                a7  <= $signed(ang[7]);
                rl  <= recip_len(L);
                k2s_r <= k2_shift(nlock - n1);
                fpst <= 5'd16;
            end
            5'd16: begin  // FLL products
                p2    <= a7 * 32'sd7710;                               // 2^16/8.5
                fprod_p <= thd * $signed({1'b0, rl});
                // stages 2 and 3 measure on the header / body of the current frame,
                // which was derotated before the previous update took effect:
                // that update is subtracted from the estimate (loop-delay compensation)
                fsub  <= ($signed(H - last_at) < 0) ? last_dlt : 32'sd0;
                fpst  <= 5'd19;
            end
            5'd19: begin  // DSP output register stage
                fprod <= fprod_p;
                fpst  <= 5'd17;
            end
            5'd17: begin  // frequency increment
                case (stage)
                    2'd1:    finc <= $signed({res, 16'd0}) >>> k1s;
                    2'd2:    finc <= (p2 - fsub) >>> k2s_r;
                    default: finc <= ((fprod >>> 16) - fsub) >>> k3s;
                endcase
                fpst <= 5'd18;
            end
            5'd18: begin  // FLL update, scheduled for the start of the frame after next
                om_set <= 1'b1; om_now <= 1'b0;
                om_at  <= Hn + {18'd0, flen(nplsc)};
                om_new <= omega + finc;
                last_dlt <= finc;
                last_at  <= Hn + {18'd0, flen(nplsc)};
                st_stage <= stage;
                // gain = 521345*4096 / mag_hdr
                div_n <= 32'd2135429120; div_d <= (mag_hdr == 0) ? 25'd1 : mag_hdr; div_q <= 32'd0; div_r <= 33'd0; div_c <= 6'd0;
                fpst <= 5'd9;
            end
            5'd9: begin   // restoring division div_n / div_d, 32 iterations
                if (div_c < 6'd32) begin
                    if ({div_r[31:0], div_n[31]} >= {8'd0, div_d}) begin
                        div_r <= {div_r[31:0], div_n[31]} - {8'd0, div_d};
                        div_q <= {div_q[30:0], 1'b1};
                    end else begin
                        div_r <= {div_r[31:0], div_n[31]};
                        div_q <= {div_q[30:0], 1'b0};
                    end
                    div_n <= {div_n[30:0], 1'b0};
                    div_c <= div_c + 6'd1;
                end else fpst <= 4'd11;
            end
            4'd11: begin
                gain <= (div_q > 32'd65535) ? 16'hFFFF : div_q[15:0];
                st_gain <= (div_q > 32'd65535) ? 16'hFFFF : div_q[15:0];
                // segment slopes (2^32 per turn per symbol)
                for (i = 0; i < 6; i = i + 1) begin
                    dlt[i] <= 32'sd0;
                    sph[i] <= {TH[0][15:0], 16'd0};
                end
                fcnt <= 14'd0; sub <= 2'd0;
                fpst <= dummy ? 5'd13 : 5'd12;   // segments: pilots, or header to header
            end
            4'd12: begin  // pilot segments: b = 1..np+1
                if (fcnt <= {11'd0, np}) begin
                    case (sub)
                    2'd0: begin
                        thd <= TH[fcnt[2:0] + 3'd1] - TH[fcnt[2:0]];
                        rl  <= (np == 3'd0) ? recip_len(L) : seg_recip(fcnt[2:0], np, is8);
                        sub <= 2'd1;
                    end
                    2'd1: begin fprod_p <= thd * $signed({1'b0, rl}); sub <= 2'd2; end
                    2'd2: begin fprod <= fprod_p; sub <= 2'd3; end
                    default: begin
                        dlt[fcnt[2:0]] <= fprod >>> 16;
                        fcnt <= fcnt + 14'd1; sub <= 2'd0;
                    end
                    endcase
                end else begin
                    fcnt <= 14'd0; sub <= 2'd0;
                    fpst <= 5'd14;
                end
            end
            4'd14: begin  // start phases: after header 45.5*dlt, after pilot 18.5*dlt
                if (fcnt <= {11'd0, np}) begin
                    if (sub == 2'd0) begin
                        sprod_p <= dlt[fcnt[2:0]] * ((fcnt == 14'd0) ? 32'sd91 : 32'sd37);
                        sub <= 2'd1;
                    end else if (sub == 2'd1) begin
                        sprod <= sprod_p;
                        sub <= 2'd2;
                    end else begin
                        sph[fcnt[2:0]] <= $signed({TH[fcnt[2:0]][15:0], 16'd0}) + (sprod >>> 1);
                        fcnt <= fcnt + 14'd1; sub <= 2'd0;
                    end
                end else fpst <= 5'd13;
            end
            default: begin   // start output pass
                op <= 14'd0; ndat <= 14'd0; seg <= 3'd0; pblk <= 3'd0;
                pdist <= 11'd1440; pleft <= 6'd0;
                phacc <= sph[0];
                gx <= 18'd1; gy <= 18'h3FFFF;
                pll_th <= 32'sd0;               // phase restarts from the header phase,
                                                // the frequency term (pll_nu) is kept
                o_code <= code_of(plsc); o_8psk <= (plsc[6:2] >= 5'd12); o_meta <= fcount;
                st <= dummy ? S_NEXT : S_OUT;
            end
            endcase
        end
        // ================================================================ output pass
        S_OUT: begin
            // one body position per clock (pilots are skipped, Gold sequence always advances)
            if (op < nbody && !ofull_soon && pace == 2'd0) begin
                gx <= {gxb, gx[17:1]};
                gy <= {gya, gy[17:1]};
                op <= op + 14'd1;
                if (at_pilot) begin
                    pleft <= pleft - 6'd1;
                    if (pleft == 6'd1) begin            // last pilot symbol of the block
                        seg   <= seg + 3'd1;
                        phacc <= sph[seg + 3'd1];
                        pblk  <= pblk + 3'd1;
                        pdist <= 11'd1440;
                    end
                end else begin
                    braddr <= H[13:0] + 14'd90 + op;
                    o_rd   <= 1'b1;
                    o_ang1 <= -phacc[31:16] - {grn, 14'd0};
                    o_tag1 <= {ndat == 14'd0, ndat == (is8 ? 14'd5399 : 14'd8099)};
                    ndat   <= ndat + 14'd1;
                    phacc  <= phacc + dlt[seg];
                    if (pll_en && !pil) pace <= 2'd3;
                    if (pil && pblk < np) begin
                        if (pdist == 11'd1) pleft <= 6'd36;
                        pdist <= pdist - 11'd1;
                    end
                end
            end else if (pace != 2'd0) pace <= pace - 2'd1;
            if (o_rd2) begin
                pr_v <= 1'b1; pr_x <= {{6{bzi[11]}}, bzi}; pr_y <= {{6{bzq[11]}}, bzq};
                pr_a <= o_ang2 - pll_th[31:16];
                pr_tag <= {8'd0, o_tag2};
            end
            if (po_v) begin
                gq_v <= 1'b1; gq_i <= gyi; gq_q <= gyq; gq_t <= po_tag[1:0];
                if (pll_en && !pil) begin
                    pv_v <= 1'b1; pv_x <= {{6{po_x[17]}}, po_x}; pv_y <= {{6{po_y[17]}}, po_y}; pv_tag <= 4'd9;
                end
            end
            if (vo_v && vo_tag == 4'd9) begin
                pe_v <= 1'b1; pe_r <= is8 ? pe8 : pe4;
            end
            if (pe_v) begin
                pll_nu <= pll_nu + (pe_r <<< (16 - pll_k2s));
                pll_th <= pll_th + (pe_r <<< (16 - pll_k1s)) + pll_nu;
            end
            if (op >= nbody && inflight == 7'd0 && !o_rd && !o_rd2 && !pr_v) st <= S_NEXT;
        end
        S_NEXT: begin
            // the confirmed header becomes the current frame
            H <= Hn; plsc <= nplsc;
            exp_end <= Hn + {18'd0, flen(nplsc)} + 32'd89;
            if (badrun >= 3'd4 && stage == 2'd3) begin
                nlock <= n1 + 8'd8;            // re-run stage 2 with gain 1/8
            end else if (nlock != 8'hFF) nlock <= nlock + 8'd1;
            st_frames <= st_frames + 32'd1;
            st_modcod <= nplsc[6:2]; st_type <= nplsc[1:0];
            fcount <= fcount + 16'd1;
            st <= S_TRACK;
        end
        default: st <= S_SEARCH;
        endcase

        // output FIFO write (gain product registered first)
        if (gq_v) begin
            ofifo_we <= 1'b1;
            ofifo_wd <= {sat16(gq_i >>> 12), sat16(gq_q >>> 12), gq_t[1], gq_t[0],
                         o_code, o_8psk, 2'b00, o_meta};
        end
        // Luise-Reggiannini MAC: products registered, then accumulated
        lv2 <= lv1;
        lp1 <= la_r * lb_r; lp2 <= la_i * lb_i; lp3 <= la_i * lb_r; lp4 <= la_r * lb_i;
        if (lv2) begin
            lrr <= lrr + lp1 + lp2;
            lri <= lri + lp3 - lp4;
        end
        if (fec_good) badrun <= 3'd0;
        else if (fec_bad && badrun != 3'd7) badrun <= badrun + 3'd1;
        if (st == S_NEXT && badrun >= 3'd4 && stage == 2'd3) badrun <= 3'd0;
        // in-flight counter for the output rotator
        if (pr_v && st == S_OUT && !(po_v && st == S_OUT)) inflight <= inflight + 7'd1;
        else if (!(pr_v && st == S_OUT) && po_v && st == S_OUT) inflight <= inflight - 7'd1;
    end
end

// output FIFO storage (distributed RAM, no reset)
always @(posedge clk) begin
    if (ofifo_we) ofifo[owp[5:0]] <= ofifo_wd;
end
// registered rotator output for the PLS decoder
always @(posedge clk) begin
    if (rst) pq_v <= 1'b0;
    else     pq_v <= po_v;
    pq_x <= po_x; pq_y <= po_y; pq_tag <= po_tag;
    pq_cc <= cconj(s12(po_x >>> 1), s12(po_y >>> 1), hdr_k(po_tag[6:0], 64'd0));
end

function [3:0] k2_shift; input [7:0] j;   // stage-2 gain schedule 1/2, 1/4, 1/8, then 1/16
    k2_shift = (j < 8'd4) ? 4'd1 : (j < 8'd8) ? 4'd2 : (j < 8'd16) ? 4'd3 : 4'd4;
endfunction
function [31:0] seg_recip; input [2:0] b; input [2:0] npb; input e8;
    if (b == 3'd0)       seg_recip = 32'd2857596;                       // 1503
    else if (b == npb)   seg_recip = e8 ? 32'd3757627 : 32'd4459987;    // 1143 / 963
    else                 seg_recip = 32'd2909869;                       // 1476
endfunction
function [3:0] code_of; input [6:0] c;
    case (c[6:2])
        5'd1: code_of = 4'd0; 5'd2: code_of = 4'd1; 5'd3: code_of = 4'd2; 5'd4: code_of = 4'd3;
        5'd5: code_of = 4'd4; 5'd6: code_of = 4'd5; 5'd7: code_of = 4'd6; 5'd8: code_of = 4'd7;
        5'd9: code_of = 4'd8; 5'd10: code_of = 4'd9;
        5'd12: code_of = 4'd4; 5'd13: code_of = 4'd5; 5'd14: code_of = 4'd6; 5'd15: code_of = 4'd8;
        default: code_of = 4'd9;
    endcase
endfunction
endmodule
