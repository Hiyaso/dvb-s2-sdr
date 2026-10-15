// tb_top.v -- top-level test through the AXI4-Lite register interface, the way
// the PS software drives the design (see z7020/sw/dvbs2_demo.c).
`timescale 1ns/1ps
module tb_top;
reg clk = 0, rstn = 0;
always #5 clk = ~clk;
reg  [11:0] awaddr = 0, araddr = 0; reg awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
reg  [31:0] wdata = 0;
wire awready, wready, bvalid, arready, rvalid; wire [1:0] bresp, rresp; wire [31:0] rdata;
wire [7:0] rx_d; wire rx_v, rx_l, tx_rdy; wire [3:0] led;
dvbs2_loopback_top dut (
    .aclk(clk), .aresetn(rstn),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .s_axis_tx_tdata(8'd0), .s_axis_tx_tvalid(1'b0), .s_axis_tx_tready(tx_rdy),
    .m_axis_rx_tdata(rx_d), .m_axis_rx_tvalid(rx_v), .m_axis_rx_tlast(rx_l), .m_axis_rx_tready(1'b1),
    .led(led));

task axi_wr(input [11:0] a, input [31:0] d);
begin
    @(negedge clk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
    while (!(awready && wready)) begin
        @(negedge clk);
        if (awready) awvalid = 0;
        if (wready) wvalid = 0;
    end
    @(negedge clk); awvalid = 0; wvalid = 0;
    while (!bvalid) @(negedge clk);
end
endtask
reg [31:0] rd;
task axi_rd(input [11:0] a);
begin
    @(negedge clk); araddr = a; arvalid = 1;
    // the slave may assert RVALID in the same cycle as ARREADY
    while (!rvalid) begin
        @(negedge clk);
        if (arready) arvalid = 0;
    end
    arvalid = 0;
    rd = rdata;
    @(negedge clk);
end
endtask

integer i;
reg cleared = 0;
reg [31:0] ok, crc, bf, berr, bits, st;
initial begin
    repeat (20) @(posedge clk);
    rstn = 1;
    repeat (10) @(posedge clk);
    axi_rd(12'h000); $display("ID = %h", rd);
    if (rd != 32'h44564232) begin $display("FAIL: bad ID"); $finish; end
    // 8PSK 2/3, pilots, rolloff 0.25, 4 clocks/sample, Es/N0 ~ 9 dB, CFO 0.3% Rs
    axi_wr(12'h008, 32'h0000_01C5);          // hold TX in reset while configuring
    axi_wr(12'h00C, 32'h0000_110D);          // modcod 13, pilots, rolloff 1
    axi_wr(12'h010, 32'd8);
    axi_wr(12'h01C, 32'd12884902);           // cfo per sample 0.003 cycles
    axi_wr(12'h024, 32'd5033);               // noise amplitude
    axi_wr(12'h008, 32'h0000_01C1);          // release, TX enable
    for (i = 0; i < 60; i = i + 1) begin
        repeat (100000) @(posedge clk);
        axi_rd(12'h080); st = rd;
        axi_rd(12'h0A8); ok = rd;
        axi_rd(12'h0AC); crc = rd;
        axi_rd(12'h0B0); bf = rd;
        axi_rd(12'h0C0); berr = rd;
        axi_rd(12'h0B8); bits = rd;
        $display("[%0d] status=%h lock=%0d modcod=%0d stage=%0d | bb_ok=%0d crc=%0d bchfail=%0d | ber %0d/%0d led=%b",
            i, st, st[4], st[9:5], st[13:12], ok, crc, bf, berr, bits, led);
        // like the software: clear the statistics once the receiver has settled
        if (!cleared && ok >= 4) begin
            axi_wr(12'h008, 32'h0000_01C9);      // ctrl | clr_stats (self clearing)
            cleared = 1;
            $display("statistics cleared");
        end else if (cleared && ok >= 8) begin
            if (berr == 0 && crc == 0 && bf == 0 && bits > 0) $display("PASS"); else $display("FAIL");
            $finish;
        end
    end
    $display("FAIL: timeout");
    $finish;
end
endmodule
