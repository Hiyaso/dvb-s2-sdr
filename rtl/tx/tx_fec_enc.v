// tx_fec_enc.v -- DVB-S2 FEC encoder (BCH + LDPC, short FECFRAME) and frame controller.
//
//  * Pulls Kbch scrambled BBFRAME bits from tx_bbframe (it also issues bb_start).
//  * BCH: bit-serial LFSR with the 168-bit generator polynomial.
//  * LDPC: bit-serial parity accumulation (EN 302 307-1 5.3.2). For each info bit
//    equal to '1', every address x of its group row contributes
//    p[(x + (m mod 360) * q) mod M] ^= 1   (one read-modify-write per clock).
//    Afterwards p_i ^= p_{i-1} is applied while copying the parity bits out.
//  * The finished codeword (16200 bits, natural order) is stored in one half of
//    a ping-pong codeword buffer which the PL framer reads (cw_raddr/cw_rdata).
// Throughput: roughly (number of '1' info bits * row weight) + 16200 clocks/frame.
`timescale 1ns/1ps
module tx_fec_enc (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire [4:0]  modcod_in,       // requested MODCOD (sampled per frame)
    input  wire        pilots_in,
    // BBFRAME source
    output reg         bb_start,
    output wire [13:0] bb_kbch,
    input  wire        bb_bit,
    input  wire        bb_valid,
    output wire        bb_ready,
    // codeword buffer read side (PL framer)
    input  wire        cw_rbank,
    input  wire [13:0] cw_raddr,
    output wire        cw_rdata,
    output wire [1:0]  cw_full,
    output wire [4:0]  cw_modcod0,
    output wire [4:0]  cw_modcod1,
    output wire        cw_pilots0,
    output wire        cw_pilots1,
    input  wire        cw_release,       // framer finished bank cw_rel_bank
    input  wire        cw_rel_bank,
    // status
    output reg  [31:0] frames_encoded
);
// ---------------------------------------------------------------- parameters
reg  [4:0]  modcod_r;
reg         pilots_r;
wire        mc_valid, mc_8psk;
wire [3:0]  mc_code;
dvbs2_modcod_map u_map (.modcod(modcod_r), .valid(mc_valid), .is_8psk(mc_8psk), .code_id(mc_code));
wire [13:0] p_kbch, p_kldpc;
wire [5:0]  p_q, p_ngroups;
wire [2:0]  p_alpha;
dvbs2_code_params u_cp (.code_id(mc_code), .kbch(p_kbch), .kldpc(p_kldpc), .q(p_q),
                        .ngroups(p_ngroups), .alpha(p_alpha));
wire [13:0] p_m = 14'd16200 - p_kldpc;     // number of parity bits
assign bb_kbch = p_kbch;

// ---------------------------------------------------------------- state
localparam S_IDLE = 3'd0, S_START = 3'd1, S_INFO = 3'd2, S_TOG = 3'd3, S_BCHP = 3'd4,
           S_DRAIN = 3'd5, S_PAR = 3'd6, S_DONE = 3'd7;
reg  [2:0]  state;
reg  [13:0] idx;          // info bit index 0..Kldpc-1 (S_INFO..), parity read index (S_PAR)
reg  [8:0]  m;            // position in 360-bit group
reg  [13:0] mq;           // m*q  (< M)
reg  [5:0]  group;
reg  [3:0]  tcnt, cur_count;
reg  [7:0]  bchp_cnt;
reg         acc;

// ---------------------------------------------------------------- buffers
reg         wbank;
reg  [1:0]  full;
reg  [4:0]  meta_mc0, meta_mc1;
reg         meta_pl0, meta_pl1;
assign cw_full    = full;
assign cw_modcod0 = meta_mc0;
assign cw_modcod1 = meta_mc1;
assign cw_pilots0 = meta_pl0;
assign cw_pilots1 = meta_pl1;

reg         cw_we;
reg  [13:0] cw_waddr;
reg         cw_wdata;
ram_sdp #(.DW(1), .AW(15)) u_cwbuf (
    .clk(clk), .we(cw_we), .waddr({wbank, cw_waddr}), .wdata(cw_wdata),
    .re(1'b1), .raddr({cw_rbank, cw_raddr}), .rdata(cw_rdata));

// ---------------------------------------------------------------- ROMs
wire        take;
wire [5:0]  rom_group = (state == S_START) ? 6'd0 :
                        ((take && m == 9'd359) ? group + 6'd1 : group);
wire [10:0] row_start;
wire [3:0]  row_count;
ldpc_enc_rowrom u_rowrom (.clk(clk), .code_id(mc_code), .group(rom_group),
                          .start(row_start), .count(row_count));
reg  [10:0] xaddr;
wire [13:0] xval;
ldpc_enc_xrom u_xrom (.clk(clk), .addr(xaddr), .x(xval));

// ---------------------------------------------------------------- BCH
wire [167:0] gpoly;
bch_gen_poly u_g (.g(gpoly));
reg  [167:0] bch;

// ---------------------------------------------------------------- input selection
assign bb_ready = (state == S_INFO);
wire   take_bb   = (state == S_INFO) && bb_valid;
wire   take_bchp = (state == S_BCHP);
assign take      = take_bb || take_bchp;
wire   new_bit   = take_bb ? bb_bit : bch[167];

// ---------------------------------------------------------------- toggle pipeline
// t0: xaddr register valid      -> ROM read
// t1: xval valid, address computed, parity RAM read issued (combinational port)
// t2: RAM data valid, write back the inverted bit (combinational port)
reg         t0_v, t1_v, t2_v;
reg  [13:0] t0_mq, t1_mq;
reg  [13:0] t2_addr;
wire [14:0] tsum  = {1'b0, xval} + {1'b0, t1_mq};
wire [13:0] taddr = (tsum >= {1'b0, p_m}) ? (tsum - {1'b0, p_m}) : tsum[13:0];

// parity accumulator RAM (M <= 12960 bits)
reg         par_rd_v;
reg  [13:0] par_rd_idx;
wire        par_issue = (state == S_PAR) && (idx < p_m);
wire        pa_re    = t1_v || par_issue;
wire [13:0] pa_raddr = t1_v ? taddr : idx;
wire        pa_rdata_ram;
wire        pa_rdata;
wire        pa_we    = t2_v || par_rd_v;
wire [13:0] pa_waddr = t2_v ? t2_addr : par_rd_idx;
wire        pa_wdata = t2_v ? ~pa_rdata : 1'b0;
ram_sdp #(.DW(1), .AW(14)) u_parram (
    .clk(clk), .we(pa_we), .waddr(pa_waddr), .wdata(pa_wdata),
    .re(pa_re), .raddr(pa_raddr), .rdata(pa_rdata_ram));
// forwarding: a write and a read of the same address on the same clock edge
reg fwd_hit, fwd_data;
always @(posedge clk) begin
    fwd_hit  <= pa_we && pa_re && (pa_waddr == pa_raddr);
    fwd_data <= pa_wdata;
end
assign pa_rdata = fwd_hit ? fwd_data : pa_rdata_ram;

always @(posedge clk) begin
    if (rst) begin
        t1_v <= 1'b0; t2_v <= 1'b0; t1_mq <= 14'd0; t2_addr <= 14'd0;
    end else begin
        t1_v    <= t0_v;
        t1_mq   <= t0_mq;
        t2_v    <= t1_v;
        t2_addr <= taddr;
    end
end

// ---------------------------------------------------------------- control
always @(posedge clk) begin
    if (rst) begin
        state <= S_IDLE; wbank <= 1'b0; full <= 2'b00; bb_start <= 1'b0;
        modcod_r <= 5'd4; pilots_r <= 1'b1;
        meta_mc0 <= 5'd0; meta_mc1 <= 5'd0; meta_pl0 <= 1'b0; meta_pl1 <= 1'b0;
        cw_we <= 1'b0; cw_waddr <= 14'd0; cw_wdata <= 1'b0;
        t0_v <= 1'b0; t0_mq <= 14'd0; xaddr <= 11'd0;
        idx <= 14'd0; m <= 9'd0; mq <= 14'd0; group <= 6'd0; tcnt <= 4'd0; cur_count <= 4'd0;
        bch <= 168'd0; bchp_cnt <= 8'd0; acc <= 1'b0; par_rd_v <= 1'b0; par_rd_idx <= 14'd0;
        frames_encoded <= 32'd0;
    end else begin
        bb_start <= 1'b0;
        cw_we    <= 1'b0;
        t0_v     <= 1'b0;
        par_rd_v <= 1'b0;
        if (cw_release) full[cw_rel_bank] <= 1'b0;

        case (state)
        S_IDLE: begin
            if (enable && !full[wbank]) begin
                modcod_r <= modcod_in;
                pilots_r <= pilots_in;
                state    <= S_START;
            end
        end
        S_START: begin
            if (!mc_valid) begin
                state <= S_IDLE;              // unsupported MODCOD: idle (framer sends dummies)
            end else begin
                bb_start <= 1'b1;
                idx <= 14'd0; m <= 9'd0; mq <= 14'd0; group <= 6'd0;
                bch <= 168'd0; bchp_cnt <= 8'd0;
                state <= S_INFO;
            end
        end
        S_INFO, S_BCHP: begin
            if (take) begin
                cw_we    <= 1'b1;
                cw_waddr <= idx;
                cw_wdata <= new_bit;
                if (take_bb)
                    bch <= {bch[166:0], 1'b0} ^ ((bch[167] ^ bb_bit) ? gpoly : 168'd0);
                else
                    bch <= {bch[166:0], 1'b0};
                if (take_bchp) bchp_cnt <= bchp_cnt + 8'd1;
                // LDPC: first accumulator address of this row
                if (new_bit) begin
                    xaddr     <= row_start;
                    t0_v      <= 1'b1;
                    t0_mq     <= mq;
                    tcnt      <= 4'd1;
                    cur_count <= row_count;
                    state     <= S_TOG;
                end else begin
                    if (idx == p_kldpc - 14'd1)      state <= S_DRAIN;
                    else if (idx == p_kbch - 14'd1)  state <= S_BCHP;
                end
                // advance bit position
                idx <= idx + 14'd1;
                if (m == 9'd359) begin
                    m <= 9'd0; mq <= 14'd0; group <= group + 6'd1;
                end else begin
                    m <= m + 9'd1; mq <= mq + {8'd0, p_q};
                end
            end
        end
        S_TOG: begin
            // remaining accumulator addresses of the row for the current '1' bit
            xaddr <= xaddr + 11'd1;
            t0_v  <= 1'b1;
            tcnt  <= tcnt + 4'd1;
            if (tcnt == cur_count - 4'd1) begin
                if (idx == p_kldpc)       state <= S_DRAIN;
                else if (idx >= p_kbch)   state <= S_BCHP;
                else                      state <= S_INFO;
            end
        end
        S_DRAIN: begin
            if (!t0_v && !t1_v && !t2_v) begin
                state <= S_PAR; idx <= 14'd0; acc <= 1'b0;
            end
        end
        S_PAR: begin
            // read p[idx] (combinational port), next cycle: accumulate, store, clear
            if (par_issue) idx <= idx + 14'd1;
            par_rd_v   <= par_issue;
            par_rd_idx <= idx;
            if (par_rd_v) begin
                acc      <= acc ^ pa_rdata;
                cw_we    <= 1'b1;
                cw_waddr <= p_kldpc + par_rd_idx;
                cw_wdata <= acc ^ pa_rdata;
                if (par_rd_idx == p_m - 14'd1) state <= S_DONE;
            end
        end
        S_DONE: begin
            full[wbank] <= 1'b1;
            if (wbank) begin meta_mc1 <= modcod_r; meta_pl1 <= pilots_r; end
            else       begin meta_mc0 <= modcod_r; meta_pl0 <= pilots_r; end
            wbank          <= ~wbank;
            frames_encoded <= frames_encoded + 32'd1;
            state          <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end
endmodule
