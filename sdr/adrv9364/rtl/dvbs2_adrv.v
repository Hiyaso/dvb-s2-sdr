// dvbs2_adrv.v -- DVB-S2 TX + RX for the ADRV9364-Z7020 SOM, between the axi_ad9361
// core and ADI's DMA path, controlled by the ARM over AXI4-Lite (M_AXI_GP0, 0x44A00000).
// Pure Verilog-2001, used as a module reference in the block design (sdr/adrv9364/hdl).
//
//   clk   (sys_cpu_clk, 100 MHz): AXI-Lite, modem, payload FIFOs
//   s_clk (axi_ad9361 l_clk): adc_valid / dac_valid at the sample rate Fs
//   Fs = 2 * Rs, clk / Fs >= 8  (Fs <= 12.5 MS/s, Rs <= 6.25 Msym/s)
//
//   RX  adc_data -> async FIFO -> dvbs2_rx -> data field bytes -> RX FIFO -> ARM (RXLEN/RXDATA)
//       The ADC samples also keep going to ADI's DMA (IIO) unchanged.
//   TX  ARM (TXDATA) -> payload FIFO -> dvbs2_tx -> async FIFO -> dac_data (tx_en = 1)
//       tx_en = 0: dac_data = DMA data (normal IIO operation).  The axi_ad9361 DAC
//       channels must select "DMA" as data source (the host program sets it).
//
// Register map (byte offsets):
//   0x000 + 4n  control register n (read/write), n = 0..8 as in sdr/b210/rtl/dvbs2_b210.v:
//               0 CTRL, 1 TXCFG, 2 AGC, 3 TIM, 4 FS, 5 FLL, 6 FEC, 7 CLR (write 1), 8 CAP (write 1)
//               CAP [0] = 1 starts a capture, [1] = source: 0 ADC samples (spectrum),
//               1 data symbols after carrier recovery (constellation, radius 4096, only while locked)
//   0x100 + 4k  status word k (k = 0..63, read only); 0..31 as on the B210, 32.. see below
//   0x200       TXDATA  write: 4 payload bytes, bits [7:0] first
//   0x204       RXLEN   read: pops the length of the next complete frame in the RX FIFO
//                       {1'b1, 15'd0, bytes[15:0]}, 0 = no complete frame
//   0x208       RXDATA  read: pops one word (4 bytes, bits [7:0] first; the last word of a
//                       frame holds 1..4 bytes)
//   0x20C       LEVELS  {TX FIFO free words, RX FIFO used words} (16 kB each)
//   0x1000 + 4i snapshot sample / symbol i (i = 0..1023) {I, Q}; status word 29:
//               [31] done, [30] busy, [29] source of the capture
`timescale 1ns/1ps
module dvbs2_adrv #(
    parameter LDPC_P = 45
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET rstn" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rstn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        rstn,
    // AXI4-Lite slave
    input  wire [15:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [15:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,
    // sample interface (axi_ad9361 l_clk domain)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET s_rst" *)
    input  wire        s_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire        s_rst,
    input  wire        adc_valid,
    input  wire [15:0] adc_data_i,
    input  wire [15:0] adc_data_q,
    input  wire        dac_valid,
    input  wire [15:0] dma_data_i,      // from ADI's DAC FIFO (util_rfifo)
    input  wire [15:0] dma_data_q,
    output wire [15:0] dac_data_i,      // to axi_ad9361
    output wire [15:0] dac_data_q
);
localparam [31:0] ID      = 32'h44564232;   // "DVB2"
localparam [31:0] VERSION = 32'h00030001;   // 3.1 (ADRV9364-Z7020, AXI-Lite, constellation snapshot)

assign s_axi_bresp = 2'b00;
assign s_axi_rresp = 2'b00;

reg rst;
always @(posedge clk) rst <= !rstn;

// ---------------------------------------------------------------- control registers
localparam [31:0] D_CTRL  = 32'h0000_01C0;  // pll_en, agc_en, early_stop
localparam [31:0] D_TXCFG = 32'h0000_0104;  // QPSK 1/2, pilots, roll-off 0.35
localparam [31:0] D_AGC   = {12'd0, 4'd12, 16'd6000};
localparam [31:0] D_TIM   = {19'd0, 5'd18, 3'd0, 5'd9};
localparam [31:0] D_FS    = {8'd32, 8'd2, 8'd90, 8'd141};
localparam [31:0] D_FLL   = {12'd0, 4'd12, 4'd6, 4'd1, 4'd1, 4'd1};
localparam [31:0] D_FEC   = {5'd0, 3'd0, 2'd0, 6'd25, 8'd16, 8'd24};
reg [31:0] r_ctrl, r_txcfg, r_agc, r_tim, r_fs, r_fll, r_fec;
reg        clr, cap_start, cap_src;

// AXI write channel: address and data may arrive in any order
reg [15:0] awaddr;
reg [31:0] wdata;
reg        aw_ok, w_ok;
wire       wr_go   = aw_ok && w_ok && !s_axi_bvalid;
wire       wr_txd  = wr_go && awaddr[15:2] == 14'h0080;       // 0x200
always @(posedge clk) begin
    if (rst) begin
        s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
        aw_ok <= 1'b0; w_ok <= 1'b0; awaddr <= 16'd0; wdata <= 32'd0;
        r_ctrl <= D_CTRL; r_txcfg <= D_TXCFG; r_agc <= D_AGC; r_tim <= D_TIM;
        r_fs <= D_FS; r_fll <= D_FLL; r_fec <= D_FEC; clr <= 1'b0; cap_start <= 1'b0;
        cap_src <= 1'b0;
    end else begin
        clr <= 1'b0;
        cap_start <= 1'b0;
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        if (s_axi_awvalid && !aw_ok && !s_axi_awready) begin
            s_axi_awready <= 1'b1; awaddr <= s_axi_awaddr; aw_ok <= 1'b1;
        end
        if (s_axi_wvalid && !w_ok && !s_axi_wready) begin
            s_axi_wready <= 1'b1; wdata <= s_axi_wdata; w_ok <= 1'b1;
        end
        if (wr_go) begin
            if (awaddr[15:6] == 10'd0) case (awaddr[5:2])
                4'd0: r_ctrl  <= wdata;
                4'd1: r_txcfg <= wdata;
                4'd2: r_agc   <= wdata;
                4'd3: r_tim   <= wdata;
                4'd4: r_fs    <= wdata;
                4'd5: r_fll   <= wdata;
                4'd6: r_fec   <= wdata;
                4'd7: clr     <= wdata[0];
                4'd8: begin cap_start <= wdata[0]; if (wdata[0]) cap_src <= wdata[1]; end
                default: ;
            endcase
            s_axi_bvalid <= 1'b1;
            aw_ok <= 1'b0; w_ok <= 1'b0;
        end
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
end
wire tx_en   = r_ctrl[0];
wire rx_en   = r_ctrl[1];
wire tx_data = r_ctrl[2];
wire rx_data = r_ctrl[3];
wire pll_en  = r_ctrl[6];
wire agc_en  = r_ctrl[7];
wire es_en   = r_ctrl[8];

// resets of the modem: high fanout, replicated by synthesis
(* max_fanout = 64 *) reg rst_tx;
(* max_fanout = 64 *) reg rst_rx;
always @(posedge clk) begin
    rst_tx <= rst | !tx_en;
    rst_rx <= rst | !rx_en;
end

// enables / resets in the sample clock domain
(* ASYNC_REG = "TRUE" *) reg [1:0] s_txon_cdc0, s_rxon_cdc0;
reg s_txon, s_rxon, s_rst_tx, s_rst_rx;
always @(posedge s_clk) begin
    s_txon_cdc0 <= {s_txon_cdc0[0], tx_en};
    s_rxon_cdc0 <= {s_rxon_cdc0[0], rx_en};
    s_txon   <= s_txon_cdc0[1];
    s_rxon   <= s_rxon_cdc0[1];
    s_rst_tx <= s_rst | !s_txon_cdc0[1];
    s_rst_rx <= s_rst | !s_rxon_cdc0[1];
end

// ---------------------------------------------------------------- TX payload (ARM -> modem)
wire        txw_full, txw_empty;
wire [31:0] txw_dout;
wire [12:0] txw_count;
reg  [1:0]  txb;                 // byte of the current word
wire        pl_rd;
adrv_fifo #(.W(32), .AW(12)) u_txw (
    .clk(clk), .rst(rst_tx), .wr(wr_txd), .din(wdata), .full(txw_full),
    .rd(pl_rd && txb == 2'd3), .dout(txw_dout), .empty(txw_empty), .count(txw_count));
wire [7:0] pl_byte = txw_dout >> {txb, 3'b000};
always @(posedge clk) begin
    if (rst_tx) txb <= 2'd0;
    else if (pl_rd && !txw_empty) txb <= txb + 2'd1;
end

// ---------------------------------------------------------------- TX modem + sample FIFO to the DAC
reg        stb;
reg  [3:0] gap;
reg  [4:0] inflight;
wire       t_v;
wire signed [15:0] t_i, t_q;
wire [31:0] tx_enc, tx_sent, tx_dummy, tx_uf;
wire       tx_sof;
wire       sf_full, sf_empty;
wire [5:0] sf_count;
wire [31:0] sf_dout;
wire       dac_take = dac_valid && !sf_empty;
dvbs2_tx u_tx (
    .clk(clk), .rst(rst_tx), .enable(1'b1), .modcod(r_txcfg[4:0]), .pilots(r_txcfg[8]),
    .rolloff(r_txcfg[13:12]), .src_stream(tx_data),
    .s_axis_tdata(pl_byte), .s_axis_tvalid(!txw_empty), .s_axis_tready(pl_rd),
    .samp_stb(stb), .out_valid(t_v), .out_i(t_i), .out_q(t_q), .sym_sof(tx_sof),
    .frames_encoded(tx_enc), .frames_sent(tx_sent), .dummy_sent(tx_dummy), .underflows(tx_uf));
adrv_afifo #(.W(32), .AW(5)) u_cdc_tx (
    .wclk(clk), .wrst(rst_tx), .wr(t_v), .din({t_i, t_q}), .full(sf_full), .wcount(sf_count),
    .rclk(s_clk), .rrst(s_rst_tx), .rd(dac_take), .dout(sf_dout), .empty(sf_empty));
// sample generation, paced so that the CDC FIFO always holds a few samples for the DAC
always @(posedge clk) begin
    if (rst_tx) begin
        stb <= 1'b0; gap <= 4'd0; inflight <= 5'd0;
    end else begin
        stb <= 1'b0;
        if (gap != 4'd0) gap <= gap - 4'd1;
        if (!stb && gap == 4'd0 && ({1'b0, sf_count} + {2'b0, inflight}) < 7'd16) begin
            stb <= 1'b1; gap <= 4'd7;           // >= 8 clocks between samples
        end
        inflight <= inflight + (stb ? 5'd1 : 5'd0) - (t_v ? 5'd1 : 5'd0);
    end
end
// DAC side (s_clk): one sample per dac_valid, zero when the FIFO ran empty
reg [31:0] dac_hold;
reg        dac_unf_tog;
always @(posedge s_clk) begin
    if (s_rst_tx) begin
        dac_hold <= 32'd0; dac_unf_tog <= 1'b0;
    end else if (dac_valid) begin
        dac_hold <= sf_empty ? 32'd0 : sf_dout;
        if (sf_empty) dac_unf_tog <= ~dac_unf_tog;
    end
end
assign dac_data_i = s_txon ? dac_hold[31:16] : dma_data_i;
assign dac_data_q = s_txon ? dac_hold[15:0]  : dma_data_q;

// ---------------------------------------------------------------- RX: ADC samples -> modem
wire        rf_full, rf_empty;
wire [31:0] rf_dout;
reg         adc_ovf_tog;
reg         r_pop_q, r_valid;
reg [31:0]  r_sample;
reg  [3:0]  rgap;
wire        r_pop = !rf_empty && rgap == 4'd0 && !r_pop_q;
// 12-bit ADC samples (sign-extended to 16 bits by the core) -> full-scale 16 bits
adrv_afifo #(.W(32), .AW(4)) u_cdc_rx (
    .wclk(s_clk), .wrst(s_rst_rx), .wr(adc_valid), .din({adc_data_i[11:0], 4'd0, adc_data_q[11:0], 4'd0}),
    .full(rf_full), .wcount(),
    .rclk(clk), .rrst(rst_rx), .rd(r_pop), .dout(rf_dout), .empty(rf_empty));
always @(posedge s_clk) begin
    if (s_rst_rx) adc_ovf_tog <= 1'b0;
    else if (adc_valid && rf_full) adc_ovf_tog <= ~adc_ovf_tog;
end
// one sample to the modem at most every 8 clocks
always @(posedge clk) begin
    if (rst_rx) begin
        r_pop_q <= 1'b0; r_valid <= 1'b0; r_sample <= 32'd0; rgap <= 4'd0;
    end else begin
        r_pop_q <= r_pop;
        r_valid <= r_pop;
        if (r_pop) begin r_sample <= rf_dout; rgap <= 4'd7; end
        else if (rgap != 4'd0) rgap <= rgap - 4'd1;
    end
end

wire [7:0]  m_d;
wire        m_v, m_l, m_rdy;
wire [15:0] st_agc, st_sgain, st_dfl, st_plsq;
wire [3:0]  st_fs; wire st_lock, st_berlock, st_povf; wire [4:0] st_mc; wire [1:0] st_ty, st_stage;
wire signed [31:0] st_om;
wire [31:0] st_frames, st_miss, st_plsf, st_dec, st_drop, st_bcor, st_bfail, st_ok, st_crc, st_bbf, st_berr;
wire [5:0]  st_iters; wire [7:0] st_mat; wire [47:0] st_bbits;
wire        sym_v; wire [15:0] sym_i, sym_q;
dvbs2_rx #(.P(LDPC_P)) u_rx (
    .clk(clk), .rst(rst_rx), .rolloff(r_txcfg[13:12]),
    .agc_en(agc_en), .agc_target(r_agc[15:0]), .agc_mu(r_agc[19:16]),
    .tim_k1s(r_tim[4:0]), .tim_k2s(r_tim[12:8]),
    .thr_acq(r_fs[7:0]), .thr_trk(r_fs[15:8]), .fll_n1(r_fs[23:16]), .fll_n2(r_fs[31:24]),
    .fll_kacq(r_fll[3:0]), .fll_k1(r_fll[7:4]), .fll_k3(r_fll[11:8]),
    .pll_en(pll_en), .pll_k1(r_fll[15:12]), .pll_k2(r_fll[19:16]),
    .llr_scale_qpsk(r_fec[7:0]), .llr_scale_8psk(r_fec[15:8]), .ldpc_max_iter(r_fec[21:16]),
    .ldpc_alpha(r_fec[26:24]), .ldpc_early_stop(es_en), .clr_stats(clr),
    .in_valid(r_valid), .in_i(r_sample[31:16]), .in_q(r_sample[15:0]),
    .m_axis_tvalid(m_v), .m_axis_tdata(m_d), .m_axis_tlast(m_l), .m_axis_tready(m_rdy),
    .st_agc_gain(st_agc), .st_fs_state(st_fs), .st_locked(st_lock), .st_modcod(st_mc), .st_type(st_ty),
    .st_omega(st_om), .st_frames(st_frames), .st_misses(st_miss), .st_plsfail(st_plsf),
    .st_fll_stage(st_stage), .st_sym_gain(st_sgain), .st_plsq(st_plsq), .st_ldpc_dec(st_dec),
    .st_ldpc_drop(st_drop), .st_ldpc_iters(st_iters), .st_bch_corr(st_bcor), .st_bch_fail(st_bfail),
    .st_bb_ok(st_ok), .st_bb_crc(st_crc), .st_bb_bchfail(st_bbf), .st_dfl(st_dfl), .st_matype(st_mat),
    .st_ber_bits(st_bbits), .st_ber_errors(st_berr), .st_ber_lock(st_berlock), .st_pacer_ovf(st_povf),
    .sym_valid(sym_v), .sym_i(sym_i), .sym_q(sym_q));

// ---------------------------------------------------------------- RX payload (modem -> ARM)
// bytes packed into words (bits [7:0] first); the length of each frame goes to a second
// FIFO when its last byte is in, so the ARM only reads complete frames
wire        rxw_full, rxw_empty, rxl_full, rxl_empty;
wire [31:0] rxw_dout;
wire [15:0] rxl_dout;
wire [12:0] rxw_count;
wire [4:0]  rxl_count;
reg  [31:0] pk;
reg  [1:0]  pn;
reg  [15:0] fbytes;
reg         rxw_wr, rxl_wr;
reg  [31:0] rxw_din;
reg  [15:0] rxl_din;
wire        rd_rxlen, rd_rxdata;
// registered "not almost full" (one word / frame length per clock at most, frames >= 374 bytes)
reg         m_rdy_r;
always @(posedge clk) m_rdy_r <= !rx_data || (rxw_count < 13'd4080 && rxl_count < 5'd14);
assign m_rdy = m_rdy_r;
wire        m_take = m_v && m_rdy && rx_data;
wire [31:0] pk_next = pk | ({24'd0, m_d} << {pn, 3'b000});
always @(posedge clk) begin
    if (rst_rx) begin
        pk <= 32'd0; pn <= 2'd0; fbytes <= 16'd0; rxw_wr <= 1'b0; rxl_wr <= 1'b0;
        rxw_din <= 32'd0; rxl_din <= 16'd0;
    end else begin
        rxw_wr <= 1'b0;
        rxl_wr <= 1'b0;
        if (m_take) begin
            if (pn == 2'd3 || m_l) begin
                rxw_wr <= 1'b1; rxw_din <= pk_next; pk <= 32'd0; pn <= 2'd0;
            end else begin
                pk <= pk_next; pn <= pn + 2'd1;
            end
            if (m_l) begin
                rxl_wr <= 1'b1; rxl_din <= fbytes + 16'd1; fbytes <= 16'd0;
            end else fbytes <= fbytes + 16'd1;
        end
    end
end
adrv_fifo #(.W(32), .AW(12)) u_rxw (
    .clk(clk), .rst(rst_rx), .wr(rxw_wr), .din(rxw_din), .full(rxw_full),
    .rd(rd_rxdata), .dout(rxw_dout), .empty(rxw_empty), .count(rxw_count));
adrv_fifo #(.W(16), .AW(4)) u_rxl (
    .clk(clk), .rst(rst_rx), .wr(rxl_wr), .din(rxl_din), .full(rxl_full),
    .rd(rd_rxlen), .dout(rxl_dout), .empty(rxl_empty), .count(rxl_count));

// ---------------------------------------------------------------- snapshot (spectrum / constellation)
// 1024 consecutive ADC samples (as given to the modem) or data symbols, read at 0x1000 + 4 i
wire        cap_v = cap_src ? sym_v : r_valid;
wire [31:0] cap_d = cap_src ? {sym_i, sym_q} : r_sample;
reg        cap_busy, cap_done;
reg [9:0]  cap_cnt;
wire [31:0] cap_q;
wire [9:0] cap_raddr;
always @(posedge clk) begin
    if (rst) begin
        cap_busy <= 1'b0; cap_done <= 1'b0; cap_cnt <= 10'd0;
    end else if (cap_start) begin
        cap_busy <= 1'b1; cap_done <= 1'b0; cap_cnt <= 10'd0;
    end else if (cap_busy && cap_v) begin
        cap_cnt <= cap_cnt + 10'd1;
        if (cap_cnt == 10'd1023) begin cap_busy <= 1'b0; cap_done <= 1'b1; end
    end
end
ram_sdp #(.DW(32), .AW(10)) u_capram (
    .clk(clk), .we(cap_busy && cap_v), .waddr(cap_cnt), .wdata(cap_d),
    .re(1'b1), .raddr(cap_raddr), .rdata(cap_q));

// ---------------------------------------------------------------- event counters
// toggles from the sample clock domain
(* ASYNC_REG = "TRUE" *) reg [1:0] unf_cdc0, ovf_cdc0;
reg unf_q, ovf_q;
always @(posedge clk) begin
    unf_cdc0 <= {unf_cdc0[0], dac_unf_tog};
    ovf_cdc0 <= {ovf_cdc0[0], adc_ovf_tog};
    unf_q <= unf_cdc0[1];
    ovf_q <= ovf_cdc0[1];
end
wire dac_unf_ev = unf_q != unf_cdc0[1];
wire adc_ovf_ev = ovf_q != ovf_cdc0[1];
reg [31:0] c_txbytes, c_txovf, c_rxbytes, c_dacuf, c_rxsamp, c_txsamp, c_adcovf, c_rxframes;
always @(posedge clk) begin
    if (rst || clr) begin
        c_txbytes <= 32'd0; c_txovf <= 32'd0; c_rxbytes <= 32'd0; c_dacuf <= 32'd0;
        c_rxsamp <= 32'd0; c_txsamp <= 32'd0; c_adcovf <= 32'd0; c_rxframes <= 32'd0;
    end else begin
        if (wr_txd && tx_en && !txw_full) c_txbytes <= c_txbytes + 32'd4;
        if (wr_txd && tx_en && txw_full)  c_txovf   <= c_txovf + 32'd1;
        if (m_take)                       c_rxbytes <= c_rxbytes + 32'd1;
        if (rxl_wr)                       c_rxframes <= c_rxframes + 32'd1;
        if (dac_unf_ev && tx_en)          c_dacuf   <= c_dacuf + 32'd1;
        if (adc_ovf_ev && rx_en)          c_adcovf  <= c_adcovf + 32'd1;
        if (r_valid)                      c_rxsamp  <= c_rxsamp + 32'd1;
        if (t_v)                          c_txsamp  <= c_txsamp + 32'd1;
    end
end

// ---------------------------------------------------------------- status words
wire [64*32-1:0] status;
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
assign status[22*32 +: 32] = {3'd0, txw_count, 3'd0, rxw_count};
assign status[23*32 +: 32] = c_txbytes;
assign status[24*32 +: 32] = c_txovf;
assign status[25*32 +: 32] = c_rxbytes;
assign status[26*32 +: 32] = c_dacuf;
assign status[27*32 +: 32] = c_rxsamp;
assign status[28*32 +: 32] = c_txsamp;
assign status[29*32 +: 32] = {cap_done, cap_busy, cap_src, r_ctrl[28:0]};
assign status[30*32 +: 32] = ID;
assign status[31*32 +: 32] = VERSION;
assign status[32*32 +: 32] = c_adcovf;
assign status[33*32 +: 32] = c_rxframes;
assign status[34*32 +: 32] = {27'd0, rxl_count};
assign status[35*32 +: 32] = {26'd0, sf_count};
assign status[36*32 +: 32*28] = {(32*28){1'b0}};

// ---------------------------------------------------------------- AXI read channel
// accept -> 1 clock (snapshot RAM read) -> rvalid; RXLEN / RXDATA pop their FIFO on accept
reg  [15:0] araddr;
reg  [1:0]  rphase;
reg  [31:0] rpop;
wire        ar_go = s_axi_arvalid && !s_axi_arready && rphase == 2'd0 && !s_axi_rvalid;
assign rd_rxlen  = ar_go && s_axi_araddr[15:2] == 14'h0081;      // 0x204
assign rd_rxdata = ar_go && s_axi_araddr[15:2] == 14'h0082;      // 0x208
assign cap_raddr = araddr[11:2];
wire [15:0] txw_free = 16'd4097 - {3'd0, txw_count};
always @(posedge clk) begin
    if (rst) begin
        s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0;
        araddr <= 16'd0; rphase <= 2'd0; rpop <= 32'd0;
    end else begin
        s_axi_arready <= 1'b0;
        if (ar_go) begin
            s_axi_arready <= 1'b1;
            araddr <= s_axi_araddr;
            rphase <= 2'd1;
            rpop   <= rd_rxlen  ? (rxl_empty ? 32'd0 : {1'b1, 15'd0, rxl_dout}) :
                      rd_rxdata ? (rxw_empty ? 32'd0 : rxw_dout) : 32'd0;
        end
        if (rphase == 2'd1) rphase <= 2'd2;            // snapshot RAM read
        if (rphase == 2'd2) begin
            rphase <= 2'd0;
            s_axi_rvalid <= 1'b1;
            if (araddr[15:12] == 4'h1)
                s_axi_rdata <= cap_q;
            else if (araddr[15:8] == 8'h01)
                s_axi_rdata <= status[araddr[7:2]*32 +: 32];
            else if (araddr[15:6] == 10'd0) case (araddr[5:2])
                4'd0: s_axi_rdata <= r_ctrl;
                4'd1: s_axi_rdata <= r_txcfg;
                4'd2: s_axi_rdata <= r_agc;
                4'd3: s_axi_rdata <= r_tim;
                4'd4: s_axi_rdata <= r_fs;
                4'd5: s_axi_rdata <= r_fll;
                4'd6: s_axi_rdata <= r_fec;
                default: s_axi_rdata <= 32'd0;
            endcase
            else case (araddr[15:2])
                14'h0081, 14'h0082: s_axi_rdata <= rpop;
                14'h0083: s_axi_rdata <= {(tx_en ? txw_free : 16'd0), 3'd0, rxw_count};
                default:  s_axi_rdata <= 32'd0;
            endcase
        end
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
end
endmodule
