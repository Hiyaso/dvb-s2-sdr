// ldpc_dec.v -- DVB-S2 short-frame LDPC decoder with two frame banks.
//
//  LLR loader  : accepts channel LLRs (7 bit, positive = '0') of the next frame
//                as up to three sequential column streams (QPSK: stream 0 only,
//                8PSK: one stream per interleaver column starting at codeword
//                bit 0 / 5400 / 10800) and scatters them into a free bank.
//  core        : ldpc_dec_core decodes READY banks in arrival order.
//  output      : hard decisions of the Kldpc information bits (= BCH codeword)
//                as a byte stream, MSB first, with per-frame metadata.
// A frame that arrives while both banks are busy is dropped (counted).
`timescale 1ns/1ps
module ldpc_dec #(
    parameter P = 45
) (
    input  wire              clk,
    input  wire              rst,
    // configuration
    input  wire [5:0]        max_iter,
    input  wire [2:0]        alpha_override,   // 0: per-code default
    input  wire              early_stop,
    // LLR input
    input  wire              ld_start,          // first LLR of a frame follows
    input  wire [3:0]        ld_code,
    input  wire [15:0]       ld_meta,
    input  wire              ld_valid,
    input  wire [1:0]        ld_stream,
    input  wire signed [6:0] ld_llr,
    input  wire              ld_end,            // frame complete
    // decoded information bits
    output reg               o_valid,
    output reg  [7:0]        o_data,
    input  wire              o_ready,
    output reg               o_first,
    output reg               o_last,
    output reg  [3:0]        o_code,
    output reg  [15:0]       o_meta,
    output reg  [5:0]        o_iters,
    output reg               o_conv,
    // status
    output reg  [31:0]       frames_dropped,
    output reg  [31:0]       frames_decoded,
    output wire              core_busy,
    output wire              ld_can_start      // a bank is free for the next frame
);
localparam S  = 360 / P;
localparam LS = (S == 8) ? 3 : (S == 4) ? 2 : (S == 2) ? 1 : 0;
localparam AW = 9;
localparam B_FREE = 3'd0, B_LOAD = 3'd1, B_READY = 3'd2, B_DEC = 3'd3, B_DONE = 3'd4, B_OUT = 3'd5;

reg  [2:0]  bst   [0:1];
reg  [3:0]  bcode [0:1];
reg  [15:0] bmeta [0:1];
reg  [5:0]  biter [0:1];
reg         bconv [0:1];
reg  [1:0]  bseq;              // load order: bseq[b] = 1 if bank b loaded after the other

// ===================================================================== bank memories
// copy A: read port A (core input phase / output reader), copy B: RMW read port
reg  [P-1:0]   wen   [0:1];
reg  [AW-1:0]  waddr [0:1];
reg  [P*8-1:0] wdata [0:1];
reg            rea   [0:1];
reg  [AW-1:0]  raddra[0:1];
reg            reb   [0:1];
reg  [AW-1:0]  raddrb[0:1];
wire [P*8-1:0] rda   [0:1];
wire [P*8-1:0] rdb   [0:1];
genvar gb;
generate for (gb = 0; gb < 2; gb = gb + 1) begin : g_bank
    ram_sdp_be #(.NB(P), .LW(8), .AW(AW)) u_qa (
        .clk(clk), .we(wen[gb]), .waddr(waddr[gb]), .wdata(wdata[gb]),
        .re(rea[gb]), .raddr(raddra[gb]), .rdata(rda[gb]));
    ram_sdp_be #(.NB(P), .LW(8), .AW(AW)) u_qb (
        .clk(clk), .we(wen[gb]), .waddr(waddr[gb]), .wdata(wdata[gb]),
        .re(reb[gb]), .raddr(raddrb[gb]), .rdata(rdb[gb]));
end endgenerate

// ===================================================================== core
reg         ld_on;
reg         dec_bank;
reg         core_start;
reg  [3:0]  core_code;
wire        cbusy, cdone, cconv;
wire [5:0]  citers;
wire        c_qa_re, c_qb_re, c_q_we;
wire [AW-1:0] c_qa_addr, c_qb_addr, c_q_waddr;
wire [P*8-1:0] c_q_wdata;
wire [13:0] cp_kbch, cp_kldpc;
wire [5:0]  cp_q, cp_ng;
wire [2:0]  cp_alpha;
dvbs2_code_params u_cpc (.code_id(core_code), .kbch(cp_kbch), .kldpc(cp_kldpc), .q(cp_q),
                         .ngroups(cp_ng), .alpha(cp_alpha));
ldpc_dec_core #(.P(P), .AW(AW)) u_core (
    .clk(clk), .rst(rst), .start(core_start), .code_id(core_code), .max_iter(max_iter),
    .alpha(alpha_override != 3'd0 ? alpha_override : cp_alpha), .early_stop(early_stop),
    .busy(cbusy), .done(cdone), .iters(citers), .converged(cconv),
    .qa_re(c_qa_re), .qa_raddr(c_qa_addr), .qa_rdata(rda[dec_bank]),
    .qb_re(c_qb_re), .qb_raddr(c_qb_addr), .qb_rdata(rdb[dec_bank]),
    .q_we(c_q_we), .q_waddr(c_q_waddr), .q_wdata(c_q_wdata));
assign core_busy = cbusy;
assign ld_can_start = !ld_on && (bst[0] == B_FREE || bst[1] == B_FREE);

// ===================================================================== loader
reg         ld_bank;
reg  [3:0]  ldc;
reg         s_par [0:2];
reg  [5:0]  s_a   [0:2];
reg  [8:0]  s_b   [0:2];
wire [13:0] lp_kbch, lp_kldpc;
wire [5:0]  lp_q, lp_ng;
wire [2:0]  lp_alpha;
dvbs2_code_params u_cpl (.code_id(ld_start ? ld_code : ldc), .kbch(lp_kbch), .kldpc(lp_kldpc),
                         .q(lp_q), .ngroups(lp_ng), .alpha(lp_alpha));
wire        i1_par, i2_par;
wire [5:0]  i1_a, i2_a;
wire [8:0]  i1_b, i2_b;
ldpc_llr_init u_li1 (.code_id(ld_code), .sel(2'd1), .par(i1_par), .a(i1_a), .b(i1_b));
ldpc_llr_init u_li2 (.code_id(ld_code), .sel(2'd2), .par(i2_par), .a(i2_a), .b(i2_b));

wire [1:0]  ls = ld_stream;
wire        cur_par = s_par[ls];
wire [5:0]  cur_a   = s_a[ls];
wire [8:0]  cur_b   = s_b[ls];
wire [6:0]  cur_g   = cur_par ? ({1'b0, lp_ng} + {1'b0, cur_a}) : {1'b0, cur_a};
wire [AW-1:0] ld_word = {cur_g, cur_b[LS-1:0]};
wire [6:0]  ld_lane = cur_b >> LS;
wire        ld_wr   = ld_on && ld_valid;

// ===================================================================== output reader
localparam O_IDLE = 3'd0, O_RD = 3'd1, O_EMIT = 3'd2, O_FIN = 3'd3;
reg  [2:0]  ost;
reg         out_bank;
reg  [5:0]  og;
reg  [LS:0] ou;
reg         ord_v;
reg  [LS-1:0] ord_u;
reg  [359:0] hv;
reg  [5:0]  obyte;
reg  [5:0]  o_ng;

// ===================================================================== port muxing
integer bi;
always @(*) begin
    for (bi = 0; bi < 2; bi = bi + 1) begin
        wen[bi] = {P{1'b0}}; waddr[bi] = {AW{1'b0}}; wdata[bi] = {(P*8){1'b0}};
        rea[bi] = 1'b0; raddra[bi] = {AW{1'b0}}; reb[bi] = 1'b0; raddrb[bi] = {AW{1'b0}};
        if (bst[bi] == B_LOAD && ld_bank == bi) begin
            wen[bi]   = ld_wr ? ({{(P-1){1'b0}}, 1'b1} << ld_lane) : {P{1'b0}};
            waddr[bi] = ld_word;
            wdata[bi] = {P{ld_llr[6], ld_llr}};
        end
        if (bst[bi] == B_DEC && dec_bank == bi) begin
            wen[bi]    = {P{c_q_we}};
            waddr[bi]  = c_q_waddr;
            wdata[bi]  = c_q_wdata;
            rea[bi]    = c_qa_re;
            raddra[bi] = c_qa_addr;
            reb[bi]    = c_qb_re;
            raddrb[bi] = c_qb_addr;
        end
        if (bst[bi] == B_OUT && out_bank == bi) begin
            rea[bi]    = (ost == O_RD) && !ou[LS];
            raddra[bi] = {og, ou[LS-1:0]};
        end
    end
end

// ===================================================================== control
integer k;
always @(posedge clk) begin
    if (rst) begin
        bst[0] <= B_FREE; bst[1] <= B_FREE; bseq <= 2'b00;
        bcode[0] <= 4'd0; bcode[1] <= 4'd0; bmeta[0] <= 16'd0; bmeta[1] <= 16'd0;
        biter[0] <= 6'd0; biter[1] <= 6'd0; bconv[0] <= 1'b0; bconv[1] <= 1'b0;
        ld_on <= 1'b0; ld_bank <= 1'b0; ldc <= 4'd0;
        for (k = 0; k < 3; k = k + 1) begin s_par[k] <= 1'b0; s_a[k] <= 6'd0; s_b[k] <= 9'd0; end
        dec_bank <= 1'b0; core_start <= 1'b0; core_code <= 4'd0;
        ost <= O_IDLE; out_bank <= 1'b0; og <= 6'd0; ou <= 0; ord_v <= 1'b0; ord_u <= 0;
        hv <= 360'd0; obyte <= 6'd0; o_ng <= 6'd0;
        o_valid <= 1'b0; o_data <= 8'd0; o_first <= 1'b0; o_last <= 1'b0;
        o_code <= 4'd0; o_meta <= 16'd0; o_iters <= 6'd0; o_conv <= 1'b0;
        frames_dropped <= 32'd0; frames_decoded <= 32'd0;
    end else begin
        core_start <= 1'b0;

        // -------------------------------------------- loader
        if (ld_start) begin
            if (ld_on) begin
                // previous frame was never completed: overwrite the same bank
                frames_dropped <= frames_dropped + 32'd1;
            end else if (bst[0] == B_FREE) begin
                ld_on <= 1'b1; ld_bank <= 1'b0; bst[0] <= B_LOAD;
            end else if (bst[1] == B_FREE) begin
                ld_on <= 1'b1; ld_bank <= 1'b1; bst[1] <= B_LOAD;
            end else begin
                frames_dropped <= frames_dropped + 32'd1;
            end
            ldc <= ld_code;
            s_par[0] <= 1'b0;   s_a[0] <= 6'd0; s_b[0] <= 9'd0;
            s_par[1] <= i1_par; s_a[1] <= i1_a; s_b[1] <= i1_b;
            s_par[2] <= i2_par; s_a[2] <= i2_a; s_b[2] <= i2_b;
        end else if (ld_wr) begin
            if (!cur_par) begin
                if (cur_b == 9'd359) begin
                    s_b[ls] <= 9'd0;
                    if (cur_a == lp_ng - 6'd1) begin s_par[ls] <= 1'b1; s_a[ls] <= 6'd0; end
                    else s_a[ls] <= cur_a + 6'd1;
                end else s_b[ls] <= cur_b + 9'd1;
            end else begin
                if (cur_a == lp_q - 6'd1) begin s_a[ls] <= 6'd0; s_b[ls] <= cur_b + 9'd1; end
                else s_a[ls] <= cur_a + 6'd1;
            end
        end
        if (ld_end && ld_on && !ld_start) begin
            ld_on <= 1'b0;
            bst[ld_bank]   <= B_READY;
            bcode[ld_bank] <= ldc;
            bmeta[ld_bank] <= ld_meta;
            bseq[ld_bank]  <= 1'b1;
            bseq[~ld_bank] <= 1'b0;
        end

        // -------------------------------------------- core scheduling
        if (!cbusy && !core_start && !(bst[dec_bank] == B_DEC)) begin
            if (bst[0] == B_READY && (bst[1] != B_READY || !bseq[0])) begin
                dec_bank <= 1'b0; core_code <= bcode[0]; bst[0] <= B_DEC; core_start <= 1'b1;
            end else if (bst[1] == B_READY) begin
                dec_bank <= 1'b1; core_code <= bcode[1]; bst[1] <= B_DEC; core_start <= 1'b1;
            end
        end
        if (cdone) begin
            bst[dec_bank]   <= B_DONE;
            biter[dec_bank] <= citers;
            bconv[dec_bank] <= cconv;
            frames_decoded  <= frames_decoded + 32'd1;
        end

        // -------------------------------------------- output reader
        if (o_valid && o_ready) begin o_valid <= 1'b0; o_first <= 1'b0; o_last <= 1'b0; end
        ord_v <= 1'b0;
        if (ord_v) begin
            for (k = 0; k < P; k = k + 1)
                hv[ord_u + k*S] <= rda[out_bank][k*8 + 7];
        end
        case (ost)
        O_IDLE: begin
            if (bst[0] == B_DONE && (bst[1] != B_DONE || !bseq[0])) begin
                out_bank <= 1'b0; bst[0] <= B_OUT; ost <= O_RD; og <= 6'd0; ou <= 0; o_ng <= ng_of(bcode[0]);
                o_code <= bcode[0]; o_meta <= bmeta[0]; o_iters <= biter[0]; o_conv <= bconv[0];
            end else if (bst[1] == B_DONE) begin
                out_bank <= 1'b1; bst[1] <= B_OUT; ost <= O_RD; og <= 6'd0; ou <= 0; o_ng <= ng_of(bcode[1]);
                o_code <= bcode[1]; o_meta <= bmeta[1]; o_iters <= biter[1]; o_conv <= bconv[1];
            end
        end
        O_RD: begin
            // issue S reads (port A, combinational address), capture 1 cycle later
            if (!ou[LS]) begin
                ord_v <= 1'b1; ord_u <= ou[LS-1:0];
                ou <= ou + 1'b1;
            end else if (!ord_v) begin
                ost <= O_EMIT; obyte <= 6'd0;
            end
        end
        O_EMIT: begin
            if (!o_valid || o_ready) begin
                o_valid <= 1'b1;
                o_data  <= {hv[0], hv[1], hv[2], hv[3], hv[4], hv[5], hv[6], hv[7]};
                hv      <= hv >> 8;
                o_first <= (og == 6'd0) && (obyte == 6'd0);
                o_last  <= (og == o_ng - 6'd1) && (obyte == 6'd44);
                obyte   <= obyte + 6'd1;
                if (obyte == 6'd44) begin
                    if (og == o_ng - 6'd1) ost <= O_FIN;
                    else begin og <= og + 6'd1; ou <= 0; ost <= O_RD; end
                end
            end
        end
        O_FIN: begin
            if (!o_valid || o_ready) begin
                bst[out_bank] <= B_FREE;
                ost <= O_IDLE;
            end
        end
        default: ost <= O_IDLE;
        endcase
    end
end

function [5:0] ng_of;
    input [3:0] c;
    case (c)
        4'd0: ng_of = 6'd9;  4'd1: ng_of = 6'd15; 4'd2: ng_of = 6'd18; 4'd3: ng_of = 6'd20;
        4'd4: ng_of = 6'd27; 4'd5: ng_of = 6'd30; 4'd6: ng_of = 6'd33; 4'd7: ng_of = 6'd35;
        4'd8: ng_of = 6'd37; default: ng_of = 6'd40;
    endcase
endfunction
endmodule
