// ldpc_dec_core.v -- layered normalized min-sum LDPC decoder core (DVB-S2 short frames).
//
// Bit-exact with python/ldpc_fixed.py.  Organisation:
//  * P lanes (P = 45 or 90), S = 360/P sub-layers per layer.  A layer is one of the
//    q check groups; sub-layer w of layer r processes checks r + q*(w + k*S), k<P.
//  * Variable memory (APP "Q", 8 bit/lane) word {g, u} holds positions u + k*S of
//    variable group g (info groups 0..K/360-1, then the q parity groups).
//  * Input phase (one circulant edge per clock):   V2C = sat(Q - Rold)
//    CNU tracks min1/min2/index/sign; output phase: Rnew = sign*((min*alpha)>>3)
//    and the APP update is a read-modify-write  Q = sat(Q + Rnew - Rold)
//    (delta form => several circulants of the same variable group in one layer
//    are handled exactly).
//  * A per-word pending-write scoreboard stalls reads of words whose update from
//    an earlier sub-layer is still in flight, so the result equals strictly
//    sequential layered decoding.
//  * Early termination: an iteration where every check saw even parity of the
//    hard decisions it read and no hard decision flipped.
//
// The Q memory (one bank) is outside: port A = input-phase reads, port B = RMW
// reads, the write port updates both copies.
`timescale 1ns/1ps
module ldpc_dec_core #(
    parameter P  = 45,
    parameter AW = 9             // Q word address bits (16200/P words)
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire [3:0]        code_id,
    input  wire [5:0]        max_iter,
    input  wire [2:0]        alpha,
    input  wire              early_stop,
    output reg               busy,
    output reg               done,          // 1-cycle pulse
    output reg  [5:0]        iters,
    output reg               converged,
    // Q memory (selected bank)
    output wire              qa_re,
    output wire [AW-1:0]     qa_raddr,
    input  wire [P*8-1:0]    qa_rdata,
    output wire              qb_re,
    output wire [AW-1:0]     qb_raddr,
    input  wire [P*8-1:0]    qb_rdata,
    output wire              q_we,
    output wire [AW-1:0]     q_waddr,
    output wire [P*8-1:0]    q_wdata
);
localparam S   = 360 / P;
localparam LS  = (S == 8) ? 3 : (S == 4) ? 2 : (S == 2) ? 1 : 0;
localparam RB  = 7;              // rotation amount width (P <= 90)
localparam NW  = 16200 / P;
localparam RMAX = 63;

// ===================================================================== sequencer
reg  [5:0]  lay;
reg  [LS-1:0] w;
reg  [4:0]  e;
reg  [5:0]  it;
reg         seq_on;
wire [10:0] lstart;
wire [4:0]  ldc;
ldpc_dec_lrom u_lrom (.code_id(code_id), .layer(lay), .start(lstart), .dc(ldc));
// edge-table address kept in a register (caddr = lstart(lay) + e), so the
// table ROM is driven directly by a flip-flop
wire [5:0]  nq;      // number of layers = q
wire [5:0]  lay_n = (lay == nq - 6'd1) ? 6'd0 : lay + 6'd1;
wire [10:0] lstart_n, lstart_0;
wire [4:0]  ldc_n, ldc_0;
ldpc_dec_lrom u_lrom_n (.code_id(code_id), .layer(lay_n), .start(lstart_n), .dc(ldc_n));
ldpc_dec_lrom u_lrom_0 (.code_id(code_id), .layer(6'd0),  .start(lstart_0), .dc(ldc_0));
reg  [10:0] caddr;
wire [20:0] ent_c;
ldpc_dec_crom u_crom (.addr(caddr), .ent(ent_c));
wire [13:0] cp_kbch, cp_kldpc;
wire [5:0]  cp_ng;
wire [2:0]  cp_alpha;
dvbs2_code_params u_cp (.code_id(code_id), .kbch(cp_kbch), .kldpc(cp_kldpc), .q(nq),
                        .ngroups(cp_ng), .alpha(cp_alpha));

// s0: registered ROM entry of the edge (lay, w, e) and its position flags
reg            s0_v;
reg  [20:0]    ent;
reg  [LS-1:0]  s0_w;
reg  [4:0]     s0_e;
reg            s0_first, s0_last, s0_itlast;
wire           s1_load;
wire           s0_load = seq_on && (!s0_v || s1_load);
wire [6:0]  e_g   = ent[20:14];
wire [8:0]  e_sh  = ent[13:5];
wire [1:0]  e_dup = (S == 8) ? ent[4:3] : ent[2:1];
wire        e_sp  = ent[0];
wire [LS-1:0] e_b = e_sh[LS-1:0];
wire [8:0]  e_a   = e_sh >> LS;
wire        wge   = (s0_w >= e_b);
wire [LS-1:0] e_u = s0_w - e_b;                    // mod S
wire [8:0]  e_r1  = wge ? e_a : (e_a + 9'd1);
wire [RB-1:0] e_rot = (e_r1 == P) ? {RB{1'b0}} : e_r1[RB-1:0];
wire [AW-1:0] e_word = {e_g, e_u};                 // g*S + u
wire        e_mask = e_sp && (s0_w == {LS{1'b0}});
wire        e_last  = (e == ldc - 5'd1);           // sequencer position (before s0)

// s1: candidate edge waiting for issue
reg            s1_v;
reg [AW-1:0]   s1_word;
reg [RB-1:0]   s1_rot;
reg [1:0]      s1_dup;
reg            s1_mask, s1_first, s1_last, s1_itlast;
reg [4:0]      s1_e;

// ===================================================================== scoreboard
reg  [2*NW-1:0] pend;
wire        issue;
wire        d_commit;
wire [AW-1:0] d_word;
integer gp;
always @(posedge clk) begin
    if (rst) pend <= {(2*NW){1'b0}};
    else for (gp = 0; gp < NW; gp = gp + 1) begin
        if (issue && (s1_word == gp) && !(d_commit && (d_word == gp)))
            pend[2*gp +: 2] <= pend[2*gp +: 2] + 2'd1;
        else if (d_commit && (d_word == gp) && !(issue && (s1_word == gp)))
            pend[2*gp +: 2] <= pend[2*gp +: 2] - 2'd1;
    end
end
wire [1:0]  pend_s1 = pend[2*s1_word +: 2];

// output-phase bookkeeping
reg  [4:0]  out_rem;     // edges of the OUT set still to be emitted
wire        out_ok_for_last = (out_rem <= 5'd3);
assign issue = s1_v && (pend_s1 == s1_dup) && (!s1_last || out_ok_for_last);
assign s1_load = s0_v && (!s1_v || issue);

// ===================================================================== R memory
reg  [10:0] rptr_in, rptr_out;
wire [P*7-1:0] r_rdata;
reg            r_we;
reg  [10:0]    r_waddr;
reg  [P*7-1:0] r_wdata;
ram_sdp #(.DW(P*7), .AW(11)) u_rmem (
    .clk(clk), .we(r_we), .waddr(r_waddr), .wdata(r_wdata),
    .re(1'b1), .raddr(rptr_in), .rdata(r_rdata));    // data used only after an issue

assign qa_re    = 1'b1;
assign qa_raddr = s1_word;

// ===================================================================== input pipeline
reg            i1_v, i1_mask, i1_first, i1_last, i1_itlast, i1_it0;
reg [RB-1:0]   i1_rot;
reg [AW-1:0]   i1_word;
reg [4:0]      i1_e;
wire [P*8-1:0] q_rot;
ldpc_rot #(.P(P), .W(8), .RB(RB), .DIR(0)) u_rrot (.din(qa_rdata), .r(i1_rot), .dout(q_rot));

reg            i2_v, i2_mask, i2_first, i2_last, i2_itlast;
reg [RB-1:0]   i2_rot;
reg [AW-1:0]   i2_word;
reg [4:0]      i2_e;
reg [P*8-1:0]  i2_q;
reg [P*7-1:0]  i2_rold;

// CNU accumulate set
reg [6*P-1:0]  acc_min1, acc_min2;
reg [5*P-1:0]  acc_idx;
reg [P-1:0]    acc_sgn, acc_par;
// CNU output set
reg [6*P-1:0]  out_min1, out_min2;
reg [5*P-1:0]  out_idx;
reg [P-1:0]    out_sgn;

// FIFO between phases: {rold, sgn, mask, word, rot, itlast}
localparam FW = P*7 + P + 1 + AW + RB + 1;
reg  [FW-1:0]  fifo [0:63];
reg  [5:0]     f_wp, f_rp;

// per-lane V2C / CNU next state
reg  [6*P-1:0] n_min1, n_min2;
reg  [5*P-1:0] n_idx;
reg  [P-1:0]   n_sgn, n_par, v_sgn;
reg signed [7:0]  ql;
reg signed [6:0]  rl;
reg signed [9:0]  dv;
reg signed [7:0]  vv;
reg        [6:0]  vm;
reg        [5:0]  mg;
reg               hb;
always @(*) begin : comb1
    integer l;
    for (l = 0; l < P; l = l + 1) begin
        ql = i2_q[l*8 +: 8];
        rl = i2_rold[l*7 +: 7];
        dv = ql - rl;
        vv = (dv > 127) ? 8'sd127 : (dv < -127) ? -8'sd127 : dv[7:0];
        hb = ql[7];
        if (i2_mask && l == 0) begin vv = 8'sd63; hb = 1'b0; end
        vm = vv[7] ? -vv : vv;
        mg = (vm > RMAX) ? RMAX[5:0] : vm[5:0];
        v_sgn[l] = vv[7];
        if (i2_first) begin
            n_min1[l*6 +: 6] = mg;
            n_min2[l*6 +: 6] = RMAX[5:0];
            n_idx[l*5 +: 5]  = 5'd0;
            n_sgn[l]         = vv[7];
            n_par[l]         = hb;
        end else begin
            if (mg < acc_min1[l*6 +: 6]) begin
                n_min1[l*6 +: 6] = mg;
                n_min2[l*6 +: 6] = acc_min1[l*6 +: 6];
                n_idx[l*5 +: 5]  = i2_e;
            end else begin
                n_min1[l*6 +: 6] = acc_min1[l*6 +: 6];
                n_min2[l*6 +: 6] = (mg < acc_min2[l*6 +: 6]) ? mg : acc_min2[l*6 +: 6];
                n_idx[l*5 +: 5]  = acc_idx[l*5 +: 5];
            end
            n_sgn[l] = acc_sgn[l] ^ vv[7];
            n_par[l] = acc_par[l] ^ hb;
        end
    end
end

// ===================================================================== output pipeline
reg  [4:0]     out_e;
reg  [P-1:0]   iter_bad_parity;     // any lane parity failed this iteration (OR-reduced)
reg            it_bad, it_changed;
wire [FW-1:0]  f_rd = fifo[f_rp];
wire [P*7-1:0] fa_rold = f_rd[FW-1 -: P*7];
wire [P-1:0]   fa_sgn  = f_rd[FW-1-P*7 -: P];
wire           fa_mask = f_rd[AW+RB+1];
wire [AW-1:0]  fa_word = f_rd[RB+1 +: AW];
wire [RB-1:0]  fa_rot  = f_rd[1 +: RB];

reg  [P*8-1:0] a_delta;
reg  [P*7-1:0] a_rnew;
reg  [5:0]     am;
reg  [8:0]     ap;
reg  [5:0]     ams;
reg signed [6:0] arn;
reg signed [6:0] aro;
reg signed [7:0] adl;
always @(*) begin : comb2
    integer l;
    for (l = 0; l < P; l = l + 1) begin
        am  = (out_idx[l*5 +: 5] == out_e) ? out_min2[l*6 +: 6] : out_min1[l*6 +: 6];
        // am * alpha as shift-add (keeps 45 tiny multipliers out of DSP blocks)
        ap  = (alpha[0] ? {3'd0, am} : 9'd0) + (alpha[1] ? {2'd0, am, 1'b0} : 9'd0) +
              (alpha[2] ? {1'd0, am, 2'b00} : 9'd0);
        ams = ap[8:3];
        arn = (out_sgn[l] ^ fa_sgn[l]) ? -$signed({1'b0, ams}) : $signed({1'b0, ams});
        aro = fa_rold[l*7 +: 7];
        adl = arn - aro;
        if (fa_mask && l == 0) begin arn = 7'sd0; adl = 8'sd0; end
        a_rnew[l*7 +: 7]  = arn;
        a_delta[l*8 +: 8] = adl;
    end
end

reg            b_v; reg [AW-1:0] b_word; reg [RB-1:0] b_rot; reg [P*8-1:0] b_delta;
wire [P*8-1:0] b_dmem;
ldpc_rot #(.P(P), .W(8), .RB(RB), .DIR(1)) u_wrot (.din(b_delta), .r(b_rot), .dout(b_dmem));
reg            c_v; reg [AW-1:0] c_word; reg [P*8-1:0] c_dmem;
reg            d_v; reg [AW-1:0] d_wd;   reg [P*8-1:0] d_dmem;
assign qb_re    = c_v;
assign qb_raddr = c_word;
// forwarding: RMW read and write of the same word on the same edge
reg            fwd_hit;
reg [P*8-1:0]  fwd_data;
wire [P*8-1:0] d_qrd = fwd_hit ? fwd_data : qb_rdata;
reg  [P*8-1:0] d_qnew;
reg            d_chg;
reg signed [7:0] dq, dd;
reg signed [8:0] ds;
always @(*) begin : comb3
    integer l;
    d_chg = 1'b0;
    for (l = 0; l < P; l = l + 1) begin
        dq = d_qrd[l*8 +: 8];
        dd = d_dmem[l*8 +: 8];
        ds = dq + dd;
        d_qnew[l*8 +: 8] = (ds > 127) ? 8'sd127 : (ds < -127) ? -8'sd127 : ds[7:0];
        if (d_qnew[l*8 + 7] != dq[7]) d_chg = 1'b1;
    end
end
assign q_we     = d_v;
assign q_waddr  = d_wd;
assign q_wdata  = d_qnew;
assign d_commit = d_v;
assign d_word   = d_wd;
always @(posedge clk) begin
    fwd_hit  <= d_v && c_v && (d_wd == c_word);
    fwd_data <= d_qnew;
end

// FIFO storage (distributed RAM, no reset)
always @(posedge clk) begin
    if (i2_v) fifo[f_wp] <= {i2_rold, v_sgn, i2_mask, i2_word, i2_rot, i2_itlast};
end

// ===================================================================== control
localparam C_IDLE = 2'd0, C_RUN = 2'd1, C_DRAIN = 2'd2;
reg  [1:0] cst;
wire pipe_empty = !s0_v && !s1_v && !i1_v && !i2_v && (out_rem == 5'd0) && !b_v && !c_v && !d_v;

always @(posedge clk) begin
    if (rst) begin
        cst <= C_IDLE; busy <= 1'b0; done <= 1'b0; iters <= 6'd0; converged <= 1'b0;
        seq_on <= 1'b0; lay <= 6'd0; w <= {LS{1'b0}}; e <= 5'd0; it <= 6'd0; caddr <= 11'd0;
        s0_v <= 1'b0; ent <= 21'd0; s0_w <= {LS{1'b0}}; s0_e <= 5'd0;
        s0_first <= 1'b0; s0_last <= 1'b0; s0_itlast <= 1'b0;
        s1_v <= 1'b0; s1_word <= {AW{1'b0}}; s1_rot <= {RB{1'b0}}; s1_dup <= 2'd0;
        s1_mask <= 1'b0; s1_first <= 1'b0; s1_last <= 1'b0; s1_itlast <= 1'b0; s1_e <= 5'd0;
        i1_v <= 1'b0; i2_v <= 1'b0; b_v <= 1'b0; c_v <= 1'b0; d_v <= 1'b0;
        rptr_in <= 11'd0; rptr_out <= 11'd0; r_we <= 1'b0;
        out_rem <= 5'd0; out_e <= 5'd0; f_wp <= 6'd0; f_rp <= 6'd0;
        it_bad <= 1'b0; it_changed <= 1'b0;
    end else begin
        done <= 1'b0;
        r_we <= 1'b0;

        // ------------------------------------------------ s0 -> s1
        if (s1_load) begin
            s1_v      <= 1'b1;
            s1_word   <= e_word;
            s1_rot    <= e_rot;
            s1_dup    <= e_dup;
            s1_mask   <= e_mask;
            s1_first  <= s0_first;
            s1_last   <= s0_last;
            s1_itlast <= s0_itlast;
            s1_e      <= s0_e;
        end else if (issue) begin
            s1_v <= 1'b0;
        end
        // ------------------------------------------------ sequencer -> s0
        if (s0_load) begin
            s0_v      <= 1'b1;
            ent       <= ent_c;
            s0_w      <= w;
            s0_e      <= e;
            s0_first  <= (e == 5'd0);
            s0_last   <= e_last;
            s0_itlast <= e_last && (w == S-1) && (lay == nq - 6'd1);
            caddr <= e_last ? ((w == S-1) ? lstart_n : lstart) : caddr + 11'd1;
            if (e_last) begin
                e <= 5'd0;
                if (w == S-1) begin
                    w <= {LS{1'b0}};
                    if (lay == nq - 6'd1) begin
                        lay <= 6'd0;
                        seq_on <= 1'b0;          // end of iteration
                    end else lay <= lay + 6'd1;
                end else w <= w + 1'b1;
            end else e <= e + 5'd1;
        end else if (s1_load) begin
            s0_v <= 1'b0;
        end

        // ------------------------------------------------ issue -> I1
        i1_v <= issue;
        if (issue) begin
            i1_rot <= s1_rot; i1_word <= s1_word; i1_e <= s1_e; i1_mask <= s1_mask;
            i1_first <= s1_first; i1_last <= s1_last; i1_itlast <= s1_itlast;
            i1_it0 <= (it == 6'd0);
            rptr_in <= rptr_in + 11'd1;
        end
        // ------------------------------------------------ I1 -> I2
        i2_v <= i1_v;
        if (i1_v) begin
            i2_q <= q_rot; i2_rold <= i1_it0 ? {(P*7){1'b0}} : r_rdata;
            i2_rot <= i1_rot; i2_word <= i1_word; i2_e <= i1_e; i2_mask <= i1_mask;
            i2_first <= i1_first; i2_last <= i1_last; i2_itlast <= i1_itlast;
        end
        // ------------------------------------------------ I2: CNU update, FIFO write
        if (i2_v) begin
            acc_min1 <= n_min1; acc_min2 <= n_min2; acc_idx <= n_idx;
            acc_sgn  <= n_sgn;  acc_par  <= n_par;
            f_wp <= f_wp + 6'd1;
        end

        // ------------------------------------------------ output stage A
        if (out_rem != 5'd0) begin
            r_we    <= 1'b1;
            r_waddr <= rptr_out;
            r_wdata <= a_rnew;
            rptr_out <= rptr_out + 11'd1;
            f_rp    <= f_rp + 6'd1;
            out_e   <= out_e + 5'd1;
            out_rem <= out_rem - 5'd1;
        end
        b_v <= (out_rem != 5'd0);
        b_word <= fa_word; b_rot <= fa_rot; b_delta <= a_delta;
        // load OUT set at the last edge of a sub-layer (after A used the old set)
        if (i2_v && i2_last) begin
            out_min1 <= n_min1; out_min2 <= n_min2; out_idx <= n_idx; out_sgn <= n_sgn;
            out_rem  <= i2_e + 5'd1;
            out_e    <= 5'd0;
            if (|n_par) it_bad <= 1'b1;
        end
        // ------------------------------------------------ B -> C -> D
        c_v <= b_v; c_word <= b_word; c_dmem <= b_dmem;
        d_v <= c_v; d_wd   <= c_word; d_dmem <= c_dmem;
        if (d_v && d_chg) it_changed <= 1'b1;

        // ------------------------------------------------ control FSM
        case (cst)
        C_IDLE: begin
            if (start) begin
                busy <= 1'b1; cst <= C_RUN; seq_on <= 1'b1;
                lay <= 6'd0; w <= {LS{1'b0}}; e <= 5'd0; it <= 6'd0; caddr <= lstart_0;
                rptr_in <= 11'd0; rptr_out <= 11'd0; it_bad <= 1'b0; it_changed <= 1'b0;
                f_wp <= 6'd0; f_rp <= 6'd0;
            end
        end
        C_RUN: begin
            if (!seq_on) cst <= C_DRAIN;
        end
        C_DRAIN: begin
            if (pipe_empty) begin
                if ((early_stop && !it_bad && !it_changed) || (it == max_iter - 6'd1)) begin
                    cst <= C_IDLE; busy <= 1'b0; done <= 1'b1;
                    iters <= it + 6'd1;
                    converged <= !it_bad && !it_changed;
                end else begin
                    it <= it + 6'd1; seq_on <= 1'b1; cst <= C_RUN; caddr <= lstart_0;
                    rptr_in <= 11'd0; rptr_out <= 11'd0; it_bad <= 1'b0; it_changed <= 1'b0;
                end
            end
        end
        default: cst <= C_IDLE;
        endcase
    end
end
endmodule
