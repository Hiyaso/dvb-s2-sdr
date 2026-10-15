// dvbs2_regs.v -- AXI4-Lite register file for the DVB-S2 loopback system.
// Register map: see z7020/doc/register_map.md (offsets in bytes).
`timescale 1ns/1ps
module dvbs2_regs (
    input  wire        clk,
    input  wire        rstn,
    // AXI4-Lite slave
    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,
    // control registers
    output reg  [31:0] r_ctrl,
    output reg  [31:0] r_txcfg,
    output reg  [31:0] r_div,
    output reg  [31:0] r_ch_ppm,
    output reg  [31:0] r_ch_delay,
    output reg  [31:0] r_ch_cfo,
    output reg  [31:0] r_ch_phase,
    output reg  [31:0] r_ch_noise,
    output reg  [31:0] r_ch_gain,
    output reg  [31:0] r_rx_agc,
    output reg  [31:0] r_rx_tim,
    output reg  [31:0] r_rx_fs,
    output reg  [31:0] r_rx_fll,
    output reg  [31:0] r_rx_fec,
    // status (read only), 32 words starting at 0x080
    input  wire [32*32-1:0] status
);
localparam [31:0] ID      = 32'h44564232;     // "DVB2"
localparam [31:0] VERSION = 32'h00010000;     // 1.0

// defaults
localparam [31:0] D_CTRL   = 32'h0000_01C1;   // tx_en, pll_en, agc_en, early_stop
localparam [31:0] D_TXCFG  = 32'h0000_0104;   // QPSK 1/2, pilots on, rolloff 0.35
localparam [31:0] D_DIV    = 32'd10;          // 10 clocks/sample -> 5 Msym/s @100 MHz
localparam [31:0] D_GAIN   = 32'd16384;
localparam [31:0] D_AGC    = {12'd0, 4'd12, 16'd6000};
localparam [31:0] D_TIM    = {19'd0, 5'd18, 3'd0, 5'd9};
localparam [31:0] D_FS     = {8'd32, 8'd2, 8'd90, 8'd141};
localparam [31:0] D_FLL    = {12'd0, 4'd12, 4'd6, 4'd1, 4'd1, 4'd1};
localparam [31:0] D_FEC    = {5'd0, 3'd0, 2'd0, 6'd25, 8'd16, 8'd24};

// ---------------------------------------------------------------- write channel
reg [11:0] awaddr;
reg        aw_ok, w_ok;
reg [31:0] wdata;
reg [3:0]  wstrb;
function [31:0] mergew; input [31:0] old, d; input [3:0] st;
    mergew = {st[3] ? d[31:24] : old[31:24], st[2] ? d[23:16] : old[23:16],
              st[1] ? d[15:8] : old[15:8], st[0] ? d[7:0] : old[7:0]};
endfunction
always @(posedge clk) begin
    if (!rstn) begin
        s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
        aw_ok <= 1'b0; w_ok <= 1'b0; awaddr <= 12'd0; wdata <= 32'd0; wstrb <= 4'd0;
        r_ctrl <= D_CTRL; r_txcfg <= D_TXCFG; r_div <= D_DIV; r_ch_ppm <= 32'd0; r_ch_delay <= 32'd0;
        r_ch_cfo <= 32'd0; r_ch_phase <= 32'd0; r_ch_noise <= 32'd0; r_ch_gain <= D_GAIN;
        r_rx_agc <= D_AGC; r_rx_tim <= D_TIM; r_rx_fs <= D_FS; r_rx_fll <= D_FLL; r_rx_fec <= D_FEC;
    end else begin
        // self-clearing pulse bits: ctrl[3] (clear statistics)
        if (r_ctrl[3]) r_ctrl[3] <= 1'b0;
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        if (s_axi_awvalid && !aw_ok && !s_axi_awready) begin
            s_axi_awready <= 1'b1; awaddr <= s_axi_awaddr; aw_ok <= 1'b1;
        end
        if (s_axi_wvalid && !w_ok && !s_axi_wready) begin
            s_axi_wready <= 1'b1; wdata <= s_axi_wdata; wstrb <= s_axi_wstrb; w_ok <= 1'b1;
        end
        if (aw_ok && w_ok && !s_axi_bvalid) begin
            case (awaddr[11:2])
                10'h002: r_ctrl     <= mergew(r_ctrl, wdata, wstrb);
                10'h003: r_txcfg    <= mergew(r_txcfg, wdata, wstrb);
                10'h004: r_div      <= mergew(r_div, wdata, wstrb);
                10'h005: r_ch_ppm   <= mergew(r_ch_ppm, wdata, wstrb);
                10'h006: r_ch_delay <= mergew(r_ch_delay, wdata, wstrb);
                10'h007: r_ch_cfo   <= mergew(r_ch_cfo, wdata, wstrb);
                10'h008: r_ch_phase <= mergew(r_ch_phase, wdata, wstrb);
                10'h009: r_ch_noise <= mergew(r_ch_noise, wdata, wstrb);
                10'h00A: r_ch_gain  <= mergew(r_ch_gain, wdata, wstrb);
                10'h00C: r_rx_agc   <= mergew(r_rx_agc, wdata, wstrb);
                10'h00D: r_rx_tim   <= mergew(r_rx_tim, wdata, wstrb);
                10'h00E: r_rx_fs    <= mergew(r_rx_fs, wdata, wstrb);
                10'h00F: r_rx_fll   <= mergew(r_rx_fll, wdata, wstrb);
                10'h010: r_rx_fec   <= mergew(r_rx_fec, wdata, wstrb);
                default: ;
            endcase
            s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
            aw_ok <= 1'b0; w_ok <= 1'b0;
        end
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
end

// ---------------------------------------------------------------- read channel
always @(posedge clk) begin
    if (!rstn) begin
        s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00;
    end else begin
        s_axi_arready <= 1'b0;
        if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
            s_axi_arready <= 1'b1;
            s_axi_rvalid  <= 1'b1;
            s_axi_rresp   <= 2'b00;
            if (s_axi_araddr[11:7] == 5'd1)              // 0x080 .. 0x0FC status words
                s_axi_rdata <= status[s_axi_araddr[6:2]*32 +: 32];
            else case (s_axi_araddr[11:2])
                10'h000: s_axi_rdata <= ID;
                10'h001: s_axi_rdata <= VERSION;
                10'h002: s_axi_rdata <= r_ctrl;
                10'h003: s_axi_rdata <= r_txcfg;
                10'h004: s_axi_rdata <= r_div;
                10'h005: s_axi_rdata <= r_ch_ppm;
                10'h006: s_axi_rdata <= r_ch_delay;
                10'h007: s_axi_rdata <= r_ch_cfo;
                10'h008: s_axi_rdata <= r_ch_phase;
                10'h009: s_axi_rdata <= r_ch_noise;
                10'h00A: s_axi_rdata <= r_ch_gain;
                10'h00C: s_axi_rdata <= r_rx_agc;
                10'h00D: s_axi_rdata <= r_rx_tim;
                10'h00E: s_axi_rdata <= r_rx_fs;
                10'h00F: s_axi_rdata <= r_rx_fll;
                10'h010: s_axi_rdata <= r_rx_fec;
                default: s_axi_rdata <= 32'hDEADBEEF;
            endcase
        end
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
end
endmodule
