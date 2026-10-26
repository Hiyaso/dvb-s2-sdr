// dvbs2_loopback_top.v -- DVB-S2 baseband TX -> channel emulator -> RX in the PL of
// a Zynq-7020, controlled through AXI4-Lite (PS M_AXI_GP0).  Pure Verilog-2001 so
// it can be dropped into an IP Integrator block design as a module reference.
//
//   sample rate = f_clk / SAMPLE_DIV,  symbol rate = sample rate / 2
//   (default f_clk 100 MHz, SAMPLE_DIV 10 -> 5 Msym/s; SAMPLE_DIV >= 8, i.e. <= 6.25 Msym/s)
`timescale 1ns/1ps
module dvbs2_loopback_top #(
    parameter LDPC_P = 45
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis_tx:m_axis_rx, ASSOCIATED_RESET aresetn" *)
    input  wire        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,
    // AXI4-Lite control
    input  wire [11:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    // optional user data in (TX, used when CTRL.src_stream = 1)
    input  wire [7:0]  s_axis_tx_tdata,
    input  wire        s_axis_tx_tvalid,
    output wire        s_axis_tx_tready,
    // decoded data field out (RX)
    output wire [7:0]  m_axis_rx_tdata,
    output wire        m_axis_rx_tvalid,
    output wire        m_axis_rx_tlast,
    input  wire        m_axis_rx_tready,
    // LEDs: 0 frame lock, 1 BER-checker lock, 2 frame activity, 3 heartbeat
    output wire [3:0]  led
);
// ---------------------------------------------------------------- registers
wire [31:0] r_ctrl, r_txcfg, r_div, r_ch_ppm, r_ch_delay, r_ch_cfo, r_ch_phase, r_ch_noise, r_ch_gain;
wire [31:0] r_rx_agc, r_rx_tim, r_rx_fs, r_rx_fll, r_rx_fec;
wire [32*32-1:0] status;
dvbs2_regs u_regs (
    .clk(aclk), .rstn(aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .r_ctrl(r_ctrl), .r_txcfg(r_txcfg), .r_div(r_div), .r_ch_ppm(r_ch_ppm), .r_ch_delay(r_ch_delay),
    .r_ch_cfo(r_ch_cfo), .r_ch_phase(r_ch_phase), .r_ch_noise(r_ch_noise), .r_ch_gain(r_ch_gain),
    .r_rx_agc(r_rx_agc), .r_rx_tim(r_rx_tim), .r_rx_fs(r_rx_fs), .r_rx_fll(r_rx_fll), .r_rx_fec(r_rx_fec),
    .status(status));

// CTRL bits
wire tx_en      = r_ctrl[0];
wire rx_soft_rst= r_ctrl[1];
wire tx_soft_rst= r_ctrl[2];
wire clr_stats  = r_ctrl[3];
wire ch_bypass  = r_ctrl[4];
wire src_stream = r_ctrl[5];
wire pll_en     = r_ctrl[6];
wire agc_en     = r_ctrl[7];
wire early_stop = r_ctrl[8];

// synchronous resets (registered, active high)
reg rst_sys, rst_tx, rst_rx;
always @(posedge aclk) begin
    rst_sys <= !aresetn;
    rst_tx  <= !aresetn || tx_soft_rst;
    rst_rx  <= !aresetn || rx_soft_rst;
end

// ---------------------------------------------------------------- sample clock enable
reg [7:0] dcnt;
wire [7:0] div = (r_div[7:0] < 8'd8) ? 8'd8 : r_div[7:0];
wire samp_stb = (dcnt == 8'd0);
always @(posedge aclk) begin
    if (rst_sys) dcnt <= 8'd0;
    else dcnt <= (dcnt >= div - 8'd1) ? 8'd0 : dcnt + 8'd1;
end

// ---------------------------------------------------------------- TX
wire tx_v, tx_sof; wire signed [15:0] tx_i, tx_q;
wire [31:0] tx_enc, tx_sent, tx_dummy, tx_uf;
dvbs2_tx u_tx (
    .clk(aclk), .rst(rst_tx), .enable(tx_en), .modcod(r_txcfg[4:0]), .pilots(r_txcfg[8]),
    .rolloff(r_txcfg[13:12]), .src_stream(src_stream), .s_axis_tdata(s_axis_tx_tdata),
    .s_axis_tvalid(s_axis_tx_tvalid), .s_axis_tready(s_axis_tx_tready), .samp_stb(samp_stb),
    .out_valid(tx_v), .out_i(tx_i), .out_q(tx_q), .sym_sof(tx_sof),
    .frames_encoded(tx_enc), .frames_sent(tx_sent), .dummy_sent(tx_dummy), .underflows(tx_uf));

// ---------------------------------------------------------------- channel
wire ch_v; wire signed [15:0] ch_i, ch_q;
ch_emu u_ch (
    .clk(aclk), .rst(rst_tx), .bypass(ch_bypass), .ppm_step(r_ch_ppm), .delay_frac(r_ch_delay[15:0]),
    .cfo_step(r_ch_cfo), .phase0(r_ch_phase[15:0]), .noise_amp(r_ch_noise[15:0]), .sig_gain(r_ch_gain[15:0]),
    .in_valid(tx_v), .in_i(tx_i), .in_q(tx_q), .out_valid(ch_v), .out_i(ch_i), .out_q(ch_q));

// ---------------------------------------------------------------- RX
wire [15:0] st_agc, st_sgain, st_dfl, st_plsq;
wire [3:0]  st_fs; wire st_lock, st_berlock, st_povf; wire [4:0] st_mc; wire [1:0] st_ty, st_stage;
wire signed [31:0] st_om;
wire [31:0] st_frames, st_miss, st_plsf, st_dec, st_drop, st_bcor, st_bfail, st_ok, st_crc, st_bbf, st_berr;
wire [5:0]  st_iters; wire [7:0] st_mat; wire [47:0] st_bbits;
dvbs2_rx #(.P(LDPC_P)) u_rx (
    .clk(aclk), .rst(rst_rx), .rolloff(r_txcfg[13:12]),
    .agc_en(agc_en), .agc_target(r_rx_agc[15:0]), .agc_mu(r_rx_agc[19:16]),
    .tim_k1s(r_rx_tim[4:0]), .tim_k2s(r_rx_tim[12:8]),
    .thr_acq(r_rx_fs[7:0]), .thr_trk(r_rx_fs[15:8]), .fll_n1(r_rx_fs[23:16]), .fll_n2(r_rx_fs[31:24]),
    .fll_kacq(r_rx_fll[3:0]), .fll_k1(r_rx_fll[7:4]), .fll_k3(r_rx_fll[11:8]),
    .pll_en(pll_en), .pll_k1(r_rx_fll[15:12]), .pll_k2(r_rx_fll[19:16]),
    .llr_scale_qpsk(r_rx_fec[7:0]), .llr_scale_8psk(r_rx_fec[15:8]), .ldpc_max_iter(r_rx_fec[21:16]),
    .ldpc_alpha(r_rx_fec[26:24]), .ldpc_early_stop(early_stop), .clr_stats(clr_stats),
    .in_valid(ch_v), .in_i(ch_i), .in_q(ch_q),
    .m_axis_tvalid(m_axis_rx_tvalid), .m_axis_tdata(m_axis_rx_tdata), .m_axis_tlast(m_axis_rx_tlast),
    .m_axis_tready(m_axis_rx_tready),
    .st_agc_gain(st_agc), .st_fs_state(st_fs), .st_locked(st_lock), .st_modcod(st_mc), .st_type(st_ty),
    .st_omega(st_om), .st_frames(st_frames), .st_misses(st_miss), .st_plsfail(st_plsf),
    .st_fll_stage(st_stage), .st_sym_gain(st_sgain), .st_plsq(st_plsq), .st_ldpc_dec(st_dec),
    .st_ldpc_drop(st_drop), .st_ldpc_iters(st_iters), .st_bch_corr(st_bcor), .st_bch_fail(st_bfail),
    .st_bb_ok(st_ok), .st_bb_crc(st_crc), .st_bb_bchfail(st_bbf), .st_dfl(st_dfl), .st_matype(st_mat),
    .st_ber_bits(st_bbits), .st_ber_errors(st_berr), .st_ber_lock(st_berlock), .st_pacer_ovf(st_povf));

// ---------------------------------------------------------------- status words (0x080 + 4*n)
assign status[ 0*32 +: 32] = {10'd0, st_iters, st_povf, st_berlock, st_stage, st_ty, st_mc, st_lock, st_fs};
assign status[ 1*32 +: 32] = st_om;
assign status[ 2*32 +: 32] = st_frames;
assign status[ 3*32 +: 32] = st_miss;
assign status[ 4*32 +: 32] = st_plsf;
assign status[ 5*32 +: 32] = {st_sgain, st_agc};
assign status[ 6*32 +: 32] = st_dec;
assign status[ 7*32 +: 32] = st_drop;
assign status[ 8*32 +: 32] = st_bcor;
assign status[ 9*32 +: 32] = st_bfail;
assign status[10*32 +: 32] = st_ok;
assign status[11*32 +: 32] = st_crc;
assign status[12*32 +: 32] = st_bbf;
assign status[13*32 +: 32] = {8'd0, st_mat, st_dfl};
assign status[14*32 +: 32] = st_bbits[31:0];
assign status[15*32 +: 32] = {16'd0, st_bbits[47:32]};
assign status[16*32 +: 32] = st_berr;
assign status[17*32 +: 32] = tx_enc;
assign status[18*32 +: 32] = tx_sent;
assign status[19*32 +: 32] = tx_dummy;
assign status[20*32 +: 32] = tx_uf;
assign status[21*32 +: 32] = {16'd0, st_plsq};
genvar g;
generate for (g = 22; g < 32; g = g + 1) begin : g_rsv
    assign status[g*32 +: 32] = 32'd0;
end endgenerate

// ---------------------------------------------------------------- LEDs
reg [26:0] hb;
reg [22:0] act;
reg [31:0] last_ok;
always @(posedge aclk) begin
    if (rst_sys) begin
        hb <= 27'd0; act <= 23'd0; last_ok <= 32'd0;
    end else begin
        hb <= hb + 27'd1;
        last_ok <= st_ok;
        if (st_ok != last_ok) act <= 23'h7FFFFF;
        else if (act != 0) act <= act - 23'd1;
    end
end
assign led = {hb[26], act != 0, st_berlock, st_lock};
endmodule
