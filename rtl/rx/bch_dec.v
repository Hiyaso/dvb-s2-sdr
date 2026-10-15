// bch_dec.v -- DVB-S2 short-frame BCH decoder (GF(2^14), t = 12).
//
// Input : BCH codeword (Nbch = Kldpc bits) as bytes, MSB first (from ldpc_dec).
// Output: the Kbch information bits (= scrambled BBFRAME) as bytes, corrected,
//         with o_fail / o_ncorr reported together with the last byte.
// Algorithm (python/bch_hw_model.py):
//   odd syndromes S1..S23 by Horner (8 bits/clock) while the frame is buffered,
//   even syndromes by squaring, simplified inversionless Berlekamp-Massey
//   (t iterations, one/two serial GF multipliers), Chien search 1 bit/clock over
//   all Nbch positions.  Error-free frames skip BM/Chien.
// Two frame buffers allow input of frame n+1 while frame n is corrected.
`timescale 1ns/1ps
module bch_dec (
    input  wire        clk,
    input  wire        rst,
    // input bytes
    input  wire        i_valid,
    input  wire [7:0]  i_data,
    output wire        i_ready,
    input  wire        i_first,
    input  wire        i_last,
    input  wire [3:0]  i_code,
    input  wire [31:0] i_meta,
    // output bytes (Kbch/8 per frame)
    output reg         o_valid,
    output reg  [7:0]  o_data,
    input  wire        o_ready,
    output reg         o_first,
    output reg         o_last,
    output reg         o_fail,
    output reg  [3:0]  o_ncorr,
    output reg  [3:0]  o_code,
    output reg  [31:0] o_meta,
    // status
    output reg  [31:0] corrected_bits,
    output reg  [31:0] failed_frames
);
localparam [13:0] GPOLY = 14'h002B;    // x^14 + x^5 + x^3 + x + 1

// ---------------------------------------------------------------- GF(2^14) helpers
function [13:0] mul_a;           // a * alpha
    input [13:0] a;
    mul_a = {a[12:0], 1'b0} ^ (a[13] ? GPOLY : 14'd0);
endfunction
function [13:0] mul_an;          // a * alpha^n  (n constant -> XOR network)
    input [13:0] a;
    input integer n;
    integer q;
    begin
        mul_an = a;
        for (q = 0; q < n; q = q + 1) mul_an = mul_a(mul_an);
    end
endfunction
function [13:0] gfmul;
    input [13:0] a, b;
    integer q;
    begin
        gfmul = 14'd0;
        for (q = 13; q >= 0; q = q - 1)
            gfmul = mul_a(gfmul) ^ (b[q] ? a : 14'd0);
    end
endfunction
function [13:0] gfsq;            // a^2 (linear map)
    input [13:0] a;
    reg   [26:0] t;
    integer q;
    begin
        t = 27'd0;
        for (q = 0; q < 14; q = q + 1) t[2*q] = a[q];
        for (q = 26; q >= 14; q = q - 1)
            if (t[q]) t = t ^ (27'd1 << q) ^ ({13'd0, GPOLY} << (q - 14));
        gfsq = t[13:0];
    end
endfunction
function [13:0] horner8;         // s * alpha^(8j) + sum r_b alpha^(j(7-b))
    input [13:0] s;
    input [7:0]  r;
    input integer j;
    integer q;
    begin
        horner8 = s;
        for (q = 7; q >= 0; q = q - 1)
            horner8 = mul_an(horner8, j) ^ {13'd0, r[q]};
    end
endfunction

// ---------------------------------------------------------------- frame buffers
reg         ibank, dbank;
reg  [1:0]  full;
reg  [10:0] iaddr;
reg  [13:0] syn_in [0:11];       // running odd syndromes
reg  [13:0] syn_q  [0:1][0:11];  // latched per bank
reg  [3:0]  q_code [0:1];
reg  [31:0] q_meta [0:1];
wire [13:0] ip_kbch, ip_kldpc;
wire [5:0]  ip_q, ip_ng;
wire [2:0]  ip_al;
reg  [3:0]  icode;
reg  [31:0] imeta;
dvbs2_code_params u_cpi (.code_id(i_first ? i_code : icode), .kbch(ip_kbch), .kldpc(ip_kldpc),
                         .q(ip_q), .ngroups(ip_ng), .alpha(ip_al));
assign i_ready = !full[ibank];
wire   i_take  = i_valid && i_ready;

reg         b_re;
reg  [10:0] b_raddr;
wire [7:0]  b_rdata;
ram_sdp #(.DW(8), .AW(12)) u_buf (
    .clk(clk), .we(i_take && ((i_first ? 11'd0 : iaddr) < ip_kbch[13:3])),
    .waddr({ibank, i_first ? 11'd0 : iaddr}), .wdata(i_data),
    .re(b_re), .raddr({dbank, b_raddr}), .rdata(b_rdata));

integer k;
always @(posedge clk) begin
    if (rst) begin
        ibank <= 1'b0; iaddr <= 11'd0; icode <= 4'd0; imeta <= 32'd0;
        for (k = 0; k < 12; k = k + 1) syn_in[k] <= 14'd0;
    end else if (i_take) begin
        if (i_first) begin
            icode <= i_code; imeta <= i_meta; iaddr <= 11'd1;
            for (k = 0; k < 12; k = k + 1) syn_in[k] <= horner8(14'd0, i_data, 2*k+1);
        end else begin
            iaddr <= iaddr + 11'd1;
            for (k = 0; k < 12; k = k + 1) syn_in[k] <= horner8(syn_in[k], i_data, 2*k+1);
        end
        if (i_last) begin
            ibank <= ~ibank;
            q_code[ibank] <= i_first ? i_code : icode;
            q_meta[ibank] <= i_first ? i_meta : imeta;
            for (k = 0; k < 12; k = k + 1)
                syn_q[ibank][k] <= horner8(i_first ? 14'd0 : syn_in[k], i_data, 2*k+1);
        end
    end
end

// ---------------------------------------------------------------- decode side
localparam D_IDLE = 4'd0, D_SYN = 4'd1, D_DELTA = 4'd2, D_UPD = 4'd3, D_STEP = 4'd4,
           D_CINIT = 4'd5, D_PRE0 = 4'd6, D_PRE1 = 4'd7, D_RUN = 4'd8, D_FLUSH = 4'd9,
           D_DONE = 4'd10;
reg  [3:0]  dst;
reg  [13:0] S   [1:24];
reg  [13:0] lam [0:12];
reg  [13:0] bb  [0:12];
reg  [13:0] nl  [0:12];
reg  [13:0] gam, del;
reg  [4:0]  L;
reg  [4:0]  r;               // 0,2,..,22
reg  [3:0]  jj;
reg         noerr;
reg  [3:0]  dcode;
wire [13:0] dp_kbch, dp_kldpc;
wire [5:0]  dp_q, dp_ng;
wire [2:0]  dp_al;
dvbs2_code_params u_cpd (.code_id(dcode), .kbch(dp_kbch), .kldpc(dp_kldpc), .q(dp_q),
                         .ngroups(dp_ng), .alpha(dp_al));
wire [13:0] cc;
bch_chien_rom u_crom (.code_id(dcode), .j(jj), .c(cc));
reg  [13:0] term [0:12];
reg  [3:0]  deg;
reg  [4:0]  roots;
reg  [13:0] bi;              // bit index
reg  [2:0]  bitc;
reg  [7:0]  cur, nxt, ob;
reg  [10:0] byte_i;
reg         hold_last;
reg  [7:0]  last_byte;

// serial GF multipliers for BM.  The operands of index jj are registered first
// (opl, ops, opx, opc); the loops run jj = 0..13 and consume index jj-1.
wire [3:0]  jc   = (jj > 4'd12) ? 4'd12 : jj;
wire [4:0]  sidx = r + 5'd1 - {1'b0, jc};        // syndrome index for delta
wire        sval = (r + 5'd1 >= {1'b0, jc});
reg  [13:0] opl, ops, opx, opc;
always @(posedge clk) begin
    opl <= lam[jc];
    ops <= sval ? S[sidx] : 14'd0;
    opx <= (jc == 4'd0) ? 14'd0 : bb[jc - 4'd1];
    opc <= cc;
end
wire [3:0]  jp      = jj - 4'd1;                  // index being consumed
wire [13:0] m_delta = gfmul(opl, ops);
wire [13:0] m_new   = gfmul(gam, opl) ^ gfmul(del, opx);
wire [13:0] m_cinit = gfmul(opl, opc);

// Chien evaluation
reg  [13:0] tsum;
always @(*) begin
    tsum = 14'd0;
    for (k = 0; k <= 12; k = k + 1) tsum = tsum ^ term[k];
end
wire chien_root = (tsum == 14'd0) && !noerr;
wire out_blocked = o_valid && !o_ready;
wire in_info  = (bi < dp_kbch);
wire emit_now = in_info && (bitc == 3'd7);
wire is_last_info = (bi == dp_kbch - 14'd1);
wire adv = (dst == D_RUN) && !(emit_now && !is_last_info && out_blocked);

always @(posedge clk) begin
    if (rst) begin
        dst <= D_IDLE; dbank <= 1'b0; full <= 2'b00; o_valid <= 1'b0; o_first <= 1'b0; o_last <= 1'b0;
        o_fail <= 1'b0; o_ncorr <= 4'd0; o_code <= 4'd0; o_meta <= 32'd0; o_data <= 8'd0;
        corrected_bits <= 32'd0; failed_frames <= 32'd0; b_re <= 1'b0; b_raddr <= 11'd0;
        gam <= 14'd1; del <= 14'd0; L <= 5'd0; r <= 5'd0; jj <= 4'd0; noerr <= 1'b0; dcode <= 4'd0;
        deg <= 4'd0; roots <= 5'd0; bi <= 14'd0; bitc <= 3'd0; cur <= 8'd0; nxt <= 8'd0; ob <= 8'd0;
        byte_i <= 11'd0; hold_last <= 1'b0; last_byte <= 8'd0;
    end else begin
        b_re <= 1'b0;
        if (o_valid && o_ready) begin o_valid <= 1'b0; o_first <= 1'b0; o_last <= 1'b0; end
        if (i_take && i_last) full[ibank] <= 1'b1;

        case (dst)
        D_IDLE: begin
            if (full[dbank]) begin
                dcode <= q_code[dbank];
                for (k = 1; k <= 12; k = k + 1) S[2*k-1] <= syn_q[dbank][k-1];
                dst <= D_SYN;
            end
        end
        D_SYN: begin
            // even syndromes S_2j = S_j^2 (in increasing order, dependencies resolved
            // because S_j for j<=12 odd are known and S_2j uses S_j)
            S[2]  <= gfsq(S[1]);
            S[4]  <= gfsq(gfsq(S[1]));
            S[6]  <= gfsq(S[3]);
            S[8]  <= gfsq(gfsq(gfsq(S[1])));
            S[10] <= gfsq(S[5]);
            S[12] <= gfsq(gfsq(S[3]));
            S[14] <= gfsq(S[7]);
            S[16] <= gfsq(gfsq(gfsq(gfsq(S[1]))));
            S[18] <= gfsq(S[9]);
            S[20] <= gfsq(gfsq(S[5]));
            S[22] <= gfsq(S[11]);
            S[24] <= gfsq(gfsq(gfsq(S[3])));
            noerr <= (S[1] == 0) && (S[3] == 0) && (S[5] == 0) && (S[7] == 0) && (S[9] == 0) &&
                     (S[11] == 0) && (S[13] == 0) && (S[15] == 0) && (S[17] == 0) && (S[19] == 0) &&
                     (S[21] == 0) && (S[23] == 0);
            for (k = 0; k <= 12; k = k + 1) begin lam[k] <= (k == 0) ? 14'd1 : 14'd0;
                                                   bb[k]  <= (k == 0) ? 14'd1 : 14'd0; end
            gam <= 14'd1; L <= 5'd0; r <= 5'd0; jj <= 4'd0; del <= 14'd0;
            dst <= D_DELTA;
        end
        D_DELTA: begin
            if (noerr) begin
                dst <= D_CINIT; jj <= 4'd0;
            end else begin
                // delta = sum_j lam_j * S_(r+1-j), one product per clock
                if (jj == 4'd1) del <= m_delta;
                else if (jj != 4'd0) del <= del ^ m_delta;
                if (jj == 4'd13) begin jj <= 4'd0; dst <= D_UPD; end
                else jj <= jj + 4'd1;
            end
        end
        D_UPD: begin
            // new_lam_j = gamma*lam_j + delta*(x*B)_j
            if (jj != 4'd0) nl[jp] <= m_new;
            if (jj == 4'd13) begin jj <= 4'd0; dst <= D_STEP; end
            else jj <= jj + 4'd1;
        end
        D_STEP: begin
            if (del != 14'd0 && {L, 1'b0} <= {1'b0, r}) begin
                bb[0] <= 14'd0;
                for (k = 1; k <= 12; k = k + 1) bb[k] <= lam[k-1];
                L   <= r + 5'd1 - L;
                gam <= del;
            end else begin
                bb[0] <= 14'd0; bb[1] <= 14'd0;
                for (k = 2; k <= 12; k = k + 1) bb[k] <= bb[k-2];
            end
            for (k = 0; k <= 12; k = k + 1) lam[k] <= nl[k];
            if (r == 5'd22) begin dst <= D_CINIT; jj <= 4'd0; end
            else begin r <= r + 5'd2; dst <= D_DELTA; end
        end
        D_CINIT: begin
            // term_j = lam_j * alpha^(-j(n-1)); degree of lambda
            if (jj == 4'd1) begin
                term[0] <= noerr ? 14'd1 : opl;
                deg <= 4'd0;
            end else if (jj != 4'd0) begin
                term[jp] <= noerr ? 14'd0 : m_cinit;
                if (!noerr && opl != 14'd0) deg <= jp;
            end
            if (jj == 4'd13) begin
                dst <= D_PRE0; jj <= 4'd0;
                b_re <= 1'b1; b_raddr <= 11'd0;
            end else jj <= jj + 4'd1;
        end
        D_PRE0: begin
            // byte 0 requested in D_CINIT, available now; request byte 1
            dst <= D_PRE1;
            b_re <= 1'b1; b_raddr <= 11'd1;
        end
        D_PRE1: begin
            cur <= b_rdata;
            bi <= 14'd0; bitc <= 3'd0; byte_i <= 11'd1; roots <= 5'd0; hold_last <= 1'b0;
            dst <= D_RUN;
        end
        D_RUN: begin
            if (adv) begin
                if (chien_root) roots <= roots + 5'd1;
                for (k = 1; k <= 12; k = k + 1) term[k] <= mul_an(term[k], k);
                if (in_info) begin
                    ob   <= {ob[6:0], cur[7 - bitc] ^ chien_root};
                    bitc <= bitc + 3'd1;
                    if (bitc == 3'd0) begin
                        b_re <= 1'b1; b_raddr <= byte_i;
                    end
                    if (bitc == 3'd7) begin
                        cur    <= b_rdata;       // byte_i, requested at bitc 0
                        byte_i <= byte_i + 11'd1;
                        if (is_last_info) begin
                            last_byte <= {ob[6:0], cur[0] ^ chien_root};
                            hold_last <= 1'b1;
                        end else begin
                            o_valid <= 1'b1;
                            o_data  <= {ob[6:0], cur[0] ^ chien_root};
                            o_first <= (byte_i == 11'd1);
                            o_code  <= dcode;
                            o_meta  <= q_meta[dbank];
                        end
                    end
                end
                bi <= bi + 14'd1;
                if ((noerr && is_last_info) || bi == dp_kldpc - 14'd1) dst <= D_FLUSH;
            end
        end
        D_FLUSH: begin
            if (!o_valid || o_ready) begin
                o_valid <= 1'b1;
                o_data  <= last_byte;
                o_first <= 1'b0;
                o_last  <= 1'b1;
                o_code  <= dcode;
                o_meta  <= q_meta[dbank];
                if (noerr) begin
                    o_fail <= 1'b0; o_ncorr <= 4'd0;
                end else if (roots == {1'b0, deg}) begin
                    o_fail <= 1'b0; o_ncorr <= deg;
                    corrected_bits <= corrected_bits + {28'd0, deg};
                end else begin
                    o_fail <= 1'b1; o_ncorr <= 4'd0;
                    failed_frames <= failed_frames + 32'd1;
                end
                dst <= D_DONE;
            end
        end
        D_DONE: begin
            full[dbank] <= 1'b0;
            dbank <= ~dbank;
            dst <= D_IDLE;
        end
        default: dst <= D_IDLE;
        endcase
    end
end
endmodule
