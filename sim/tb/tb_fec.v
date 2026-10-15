// tb_fec.v -- FEC chain loopback at symbol level:
//   dvbs2_tx (RTL) -> data symbols (taken before PL scrambling) + AWGN (testbench)
//   -> rx_demap -> ldpc_dec -> bch_dec -> rx_bbout (BER on PRBS-23 payload)
`timescale 1ns/1ps
module tb_fec;
parameter MODCOD = 4;
parameter NFRAMES = 6;
parameter real ESN0 = 3.0;
parameter DIV = 8;          // same minimum as the hardware (>= 16 clocks per symbol)
reg clk = 0, rst = 1;
always #5 clk = ~clk;
reg [7:0] dcnt = 0;
wire samp_stb = (dcnt == 0);
always @(posedge clk) dcnt <= (dcnt == DIV-1) ? 0 : dcnt + 1;

wire tx_ov, tx_sof; wire signed [15:0] tx_i, tx_q; wire [31:0] fe, fs, ds, uf; wire str_rdy;
dvbs2_tx u_tx (.clk(clk), .rst(rst), .enable(1'b1), .modcod(MODCOD[4:0]), .pilots(1'b1), .rolloff(2'd0),
    .src_stream(1'b0), .s_axis_tdata(8'd0), .s_axis_tvalid(1'b0), .s_axis_tready(str_rdy),
    .samp_stb(samp_stb), .out_valid(tx_ov), .out_i(tx_i), .out_q(tx_q), .sym_sof(tx_sof),
    .frames_encoded(fe), .frames_sent(fs), .dummy_sent(ds), .underflows(uf));

// ---- tap data symbols (before scrambling) from the framer
wire tap = u_tx.u_pl.sym_valid && u_tx.u_pl.sym_ready;   // symbol leaving the framer
reg  in_data;           // previous accepted symbol was a data symbol of a data frame
// data symbol accepted when framer was in P_DATA of a non-dummy frame: capture at handshake
reg        d_v; reg [2:0] d_k; reg d_first, d_last; reg [3:0] d_code; reg d_8; reg [15:0] d_meta;
reg [12:0] d_idx; reg [15:0] fcount;
// framer outputs the scrambled symbol; the unscrambled one was fetch_k at load time.
// We mirror the framer: when it loads sym_k in P_DATA (non-dummy), fetch_k is the data symbol.
always @(posedge clk) begin
    d_v <= 1'b0;
    if (rst) begin d_idx <= 0; fcount <= 0; end
    else if (u_tx.u_pl.ph == 3'd2 && !u_tx.u_pl.f_dummy && (!u_tx.u_pl.sym_valid || u_tx.u_pl.sym_ready)
             && u_tx.u_pl.have_sym) begin
        d_v <= 1'b1; d_k <= u_tx.u_pl.fetch_k;
        d_first <= (d_idx == 0);
        d_last  <= (d_idx == (u_tx.u_pl.f_8psk ? 5399 : 8099));
        d_code  <= u_tx.u_pl.f_code; d_8 <= u_tx.u_pl.f_8psk; d_meta <= fcount;
        if (d_idx == (u_tx.u_pl.f_8psk ? 5399 : 8099)) begin d_idx <= 0; fcount <= fcount + 1; end
        else d_idx <= d_idx + 1;
    end
end

// ---- AWGN (Box-Muller)
real sig, u1, u2, rr, nI, nQ, ci, cq;
integer seed = 7;
reg signed [15:0] y_i, y_q;
reg y_v, y_first, y_last; reg [3:0] y_code; reg y_8; reg [15:0] y_meta;
initial sig = 4096.0 * $sqrt(0.5 / $pow(10.0, ESN0 / 10.0));
// symbol FIFO toward demapper
reg [53:0] fifo [0:1023]; reg [9:0] wp = 0, rp = 0;
wire       dm_ready;
always @(posedge clk) begin
    if (d_v) begin
        u1 = ($random(seed) & 32'h7fffffff) / 2147483648.0 + 1e-12;
        u2 = ($random(seed) & 32'h7fffffff) / 2147483648.0;
        rr = $sqrt(-2.0 * $ln(u1));
        nI = sig * rr * $cos(6.283185307 * u2);
        nQ = sig * rr * $sin(6.283185307 * u2);
        ci = 4096.0 * $cos(0.785398163 * d_k) + nI;
        cq = 4096.0 * $sin(0.785398163 * d_k) + nQ;
        if (ci > 32000) ci = 32000; if (ci < -32000) ci = -32000;
        if (cq > 32000) cq = 32000; if (cq < -32000) cq = -32000;
        y_i = $rtoi(ci); y_q = $rtoi(cq);
        fifo[wp] <= {y_i, y_q, d_first, d_last, d_code, d_8, d_meta[14:0]};
        wp <= wp + 1;
    end
end
wire        f_ne = (wp != rp);
wire [53:0] f_o = fifo[rp];
always @(posedge clk) if (f_ne && dm_ready) rp <= rp + 1;

wire ld_start, ld_valid, ld_end; wire [3:0] ld_code; wire [15:0] ld_meta; wire [1:0] ld_stream;
wire signed [6:0] ld_llr;
rx_demap u_dm (.clk(clk), .rst(rst), .scale_qpsk(8'd24), .scale_8psk(8'd16),
    .s_valid(f_ne), .s_ready(dm_ready), .s_i(f_o[53:38]), .s_q(f_o[37:22]), .s_first(f_o[21]),
    .s_last(f_o[20]), .s_code(f_o[19:16]), .s_8psk(f_o[15]), .s_meta({1'b0, f_o[14:0]}),
    .ld_start(ld_start), .ld_code(ld_code), .ld_meta(ld_meta), .ld_valid(ld_valid),
    .ld_stream(ld_stream), .ld_llr(ld_llr), .ld_end(ld_end));

wire o_valid, o_first, o_last, o_conv, o_ready, cbusy, can_start; wire [7:0] o_data; wire [3:0] o_code;
wire [15:0] o_meta; wire [5:0] o_iters; wire [31:0] fdrop, fdec;
ldpc_dec #(.P(45)) u_ldpc (.clk(clk), .rst(rst), .max_iter(6'd25), .alpha_override(3'd0), .early_stop(1'b1),
    .ld_start(ld_start), .ld_code(ld_code), .ld_meta(ld_meta), .ld_valid(ld_valid), .ld_stream(ld_stream),
    .ld_llr(ld_llr), .ld_end(ld_end), .o_valid(o_valid), .o_data(o_data), .o_ready(o_ready),
    .o_first(o_first), .o_last(o_last), .o_code(o_code), .o_meta(o_meta), .o_iters(o_iters), .o_conv(o_conv),
    .frames_dropped(fdrop), .frames_decoded(fdec), .core_busy(cbusy), .ld_can_start(can_start));

wire b_valid, b_first, b_last, b_fail, b_ready; wire [7:0] b_data; wire [3:0] b_ncorr, b_code;
wire [31:0] b_meta, cbits, ffail;
bch_dec u_bch (.clk(clk), .rst(rst), .i_valid(o_valid), .i_data(o_data), .i_ready(o_ready),
    .i_first(o_first), .i_last(o_last), .i_code(o_code), .i_meta({10'd0, o_iters, o_meta}),
    .o_valid(b_valid), .o_data(b_data), .o_ready(b_ready), .o_first(b_first), .o_last(b_last),
    .o_fail(b_fail), .o_ncorr(b_ncorr), .o_code(b_code), .o_meta(b_meta),
    .corrected_bits(cbits), .failed_frames(ffail));

wire m_valid, m_last; wire [7:0] m_data; wire [31:0] fok, fcrc, fbf, berr; wire [47:0] bbits;
wire [15:0] dfl; wire [7:0] mat; wire blk;
rx_bbout u_bb (.clk(clk), .rst(rst), .clr_stats(1'b0), .i_valid(b_valid), .i_data(b_data), .i_ready(b_ready),
    .i_first(b_first), .i_last(b_last), .i_fail(b_fail), .m_valid(m_valid), .m_data(m_data), .m_last(m_last),
    .m_ready(1'b1), .frames_ok(fok), .frames_crc_err(fcrc), .frames_bch_fail(fbf), .last_dfl(dfl),
    .last_matype(mat), .ber_bits(bbits), .ber_errors(berr), .ber_locked(blk));

always @(posedge clk) if (b_valid && b_ready && b_last)
    $display("frame meta=%0d iters=%0d bch_ncorr=%0d fail=%0d | ok=%0d crc=%0d bchfail=%0d ber %0d/%0d lock=%0d dfl=%0d matype=%h",
        b_meta[15:0], b_meta[21:16], b_ncorr, b_fail, fok, fcrc, fbf, berr, bbits, blk, dfl, mat);
initial begin
    #100 rst = 0;
    wait (fok + fcrc + fbf == NFRAMES);
    #1000;
    $display("FEC tb: frames ok=%0d crc_err=%0d bch_fail=%0d dropped=%0d ber_errors=%0d bits=%0d locked=%0d",
        fok, fcrc, fbf, fdrop, berr, bbits, blk);
    if (fok == NFRAMES && berr == 0 && blk) $display("PASS"); else $display("FAIL");
    $finish;
end
initial begin #3000000000; $display("TIMEOUT"); $finish; end
endmodule
