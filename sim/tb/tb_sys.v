// tb_sys.v -- full loopback: dvbs2_tx -> ch_emu -> dvbs2_rx.  Runs until NOK good
// frames (or timeout) and reports synchronisation / FEC / BER statistics.
`timescale 1ns/1ps
module tb_sys;
parameter MODCOD = 4;
parameter PILOTS = 1;
parameter ROLLOFF = 0;
parameter DIV = 8;
parameter NOK = 8;
parameter integer PPM_STEP = 0;
parameter integer DELAY = 20000;
parameter integer CFO = 0;
parameter integer NOISE = 0;
parameter integer PHASE0 = 5000;
parameter PLL_EN = 1;
parameter MAXCYC = 6000000;
reg clk = 0, rst = 1;
always #5 clk = ~clk;
reg [7:0] dcnt = 0;
wire samp_stb = (dcnt == 0);
always @(posedge clk) dcnt <= (dcnt == DIV-1) ? 0 : dcnt + 1;

wire tx_v, sof; wire signed [15:0] tx_i, tx_q; wire [31:0] fe, fs, ds, uf; wire rdy;
dvbs2_tx u_tx (.clk(clk), .rst(rst), .enable(1'b1), .modcod(MODCOD[4:0]), .pilots(PILOTS[0]), .rolloff(ROLLOFF[1:0]),
    .src_stream(1'b0), .s_axis_tdata(8'd0), .s_axis_tvalid(1'b0), .s_axis_tready(rdy),
    .samp_stb(samp_stb), .out_valid(tx_v), .out_i(tx_i), .out_q(tx_q), .sym_sof(sof),
    .frames_encoded(fe), .frames_sent(fs), .dummy_sent(ds), .underflows(uf));
wire ch_v; wire signed [15:0] ch_i, ch_q;
ch_emu u_ch (.clk(clk), .rst(rst), .bypass(1'b0), .ppm_step(PPM_STEP), .delay_frac(DELAY[15:0]),
    .cfo_step(CFO), .phase0(PHASE0[15:0]), .noise_amp(NOISE[15:0]), .sig_gain(16'd16384),
    .in_valid(tx_v), .in_i(tx_i), .in_q(tx_q), .out_valid(ch_v), .out_i(ch_i), .out_q(ch_q));

wire m_v, m_last; wire [7:0] m_d;
wire [15:0] agc_g, sym_g, dfl, plsq; wire [3:0] fsst; wire lock, berlock, povf; wire [4:0] mc; wire [1:0] ty, stg;
wire signed [31:0] om; wire [31:0] nfr, nmiss, nplsf, ndec, ndrop, bcor, bfail, bok, bcrc, bbf, berr;
wire [5:0] iters; wire [7:0] mat; wire [47:0] bbits;
dvbs2_rx #(.P(45)) u_rx (
    .clk(clk), .rst(rst), .rolloff(ROLLOFF[1:0]), .agc_en(1'b1), .agc_target(16'd6000), .agc_mu(4'd12),
    .tim_k1s(5'd9), .tim_k2s(5'd18), .thr_acq(8'd141), .thr_trk(8'd90), .fll_n1(8'd2), .fll_n2(8'd32),
    .fll_kacq(4'd1), .fll_k1(4'd1), .fll_k3(4'd1), .pll_en(PLL_EN[0]), .pll_k1(4'd6), .pll_k2(4'd12),
    .llr_scale_qpsk(8'd24), .llr_scale_8psk(8'd16), .ldpc_max_iter(6'd25), .ldpc_alpha(3'd0),
    .ldpc_early_stop(1'b1), .clr_stats(1'b0),
    .in_valid(ch_v), .in_i(ch_i), .in_q(ch_q),
    .m_axis_tvalid(m_v), .m_axis_tdata(m_d), .m_axis_tlast(m_last), .m_axis_tready(1'b1),
    .st_agc_gain(agc_g), .st_fs_state(fsst), .st_locked(lock), .st_modcod(mc), .st_type(ty), .st_omega(om),
    .st_frames(nfr), .st_misses(nmiss), .st_plsfail(nplsf), .st_fll_stage(stg), .st_sym_gain(sym_g),
    .st_plsq(plsq), .st_ldpc_dec(ndec), .st_ldpc_drop(ndrop), .st_ldpc_iters(iters), .st_bch_corr(bcor),
    .st_bch_fail(bfail), .st_bb_ok(bok), .st_bb_crc(bcrc), .st_bb_bchfail(bbf), .st_dfl(dfl),
    .st_matype(mat), .st_ber_bits(bbits), .st_ber_errors(berr), .st_ber_lock(berlock), .st_pacer_ovf(povf));

integer cyc = 0;
reg [31:0] last_frames = 0;
// steady-state statistics: counted after the first SETTLE good frames
parameter SETTLE = 4;
reg        settled = 0;
reg [31:0] berr0 = 0, bbf0 = 0, bok0 = 0, bcrc0 = 0;
always @(posedge clk) if (!settled && bok >= SETTLE) begin
    settled <= 1; berr0 <= berr; bbf0 <= bbf; bok0 <= bok; bcrc0 <= bcrc;
end
initial #100 rst = 0;
always @(posedge clk) begin
    cyc = cyc + 1;
    if (nfr != last_frames) begin
        last_frames = nfr;
        $display("[%0d] frame %0d modcod=%0d type=%0d stage=%0d omega=%0d gain=%0d plsq=%0d | ldpc dec=%0d drop=%0d it=%0d | bch corr=%0d fail=%0d | bb ok=%0d crc=%0d | ber %0d/%0d lock=%0d miss=%0d plsfail=%0d",
            cyc, nfr, mc, ty, stg, om, sym_g, plsq, ndec, ndrop, iters, bcor, bfail, bok, bcrc, berr, bbits, berlock, nmiss, nplsf);
    end
    if ((settled && bok - bok0 >= NOK) || cyc >= MAXCYC) begin
        $display("SYS RESULT: modcod=%0d tx_sent=%0d rx_frames=%0d bb_ok=%0d crc=%0d bchfail=%0d ldpc_drop=%0d ber_err=%0d ber_bits=%0d ber_lock=%0d misses=%0d plsfail=%0d pacer_ovf=%0d cyc=%0d",
            MODCOD, fs, nfr, bok, bcrc, bbf, ndrop, berr, bbits, berlock, nmiss, nplsf, povf, cyc);
        $display("STEADY STATE: frames_ok=%0d bch_fail=%0d crc_err=%0d ber_errors=%0d (after %0d settling frames)",
            bok - bok0, bbf - bbf0, bcrc - bcrc0, berr - berr0, SETTLE);
        if (settled && bok - bok0 >= NOK && berr == berr0 && bbf == bbf0 && bcrc == bcrc0) $display("PASS");
        else $display("FAIL");
        $finish;
    end
end
endmodule
