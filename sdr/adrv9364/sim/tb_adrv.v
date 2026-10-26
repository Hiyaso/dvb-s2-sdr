// tb_adrv.v -- two ADRV9364 SOMs running dvbs2_adrv (board A transmits, board B receives),
// driven over AXI4-Lite like the ARM program does it.
//
//   board A: ARM writes payload words (TXDATA, flow control via LEVELS) -> dvbs2_adrv -> 12-bit DAC
//   channel: ch_emu (CFO, clock offset, AWGN) between the two sample clocks
//   board B: 12-bit ADC -> dvbs2_adrv -> ARM reads complete frames (RXLEN + RXDATA)
//
// clk = 100 MHz (AXI + modem) on both boards; each board has its own AD9364 interface
// clock s_clk = 2 Fs (1R1T), adc_valid / dac_valid on every other s_clk edge.
// DATA=1: payload bytes (LFSR) are checked at board B; DATA=0: internal PRBS, BER from the status.
`timescale 1ns/1ps
module tb_adrv;
parameter MODCOD = 13;
parameter PILOTS = 1;
parameter DATA = 1;
parameter integer NOISE = 4487;     // Es/N0 10 dB
parameter integer CFO = 4294967;    // 0.2 % Rs
parameter integer PPM_STEP = 85899; // +20 ppm
parameter integer NOK = 8;          // good frames after lock
parameter integer MAXCYC = 8000000;
parameter real    S_HALF = 21.0;    // s_clk half period (ns): Fs = 1 / (4 S_HALF) = 11.9 MS/s

reg clk = 0, rstn = 0;
always #5 clk = ~clk;
reg sclk_a = 0, sclk_b = 0;
always #(S_HALF) sclk_a = ~sclk_a;
initial begin #3.7; forever #(S_HALF) sclk_b = ~sclk_b; end
integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

// ---------------------------------------------------------------- AXI4-Lite masters
reg  [15:0] a_awaddr = 0, a_araddr = 0, b_awaddr = 0, b_araddr = 0;
reg  [31:0] a_wdata = 0, b_wdata = 0;
reg         a_awvalid = 0, a_wvalid = 0, a_arvalid = 0, b_awvalid = 0, b_wvalid = 0, b_arvalid = 0;
wire        a_awready, a_wready, a_bvalid, a_arready, a_rvalid;
wire        b_awready, b_wready, b_bvalid, b_arready, b_rvalid;
wire [31:0] a_rdata, b_rdata;
reg  [31:0] ra, rb;
task wr_a(input [15:0] ad, input [31:0] d);
begin
    @(negedge clk); a_awaddr = ad; a_wdata = d; a_awvalid = 1; a_wvalid = 1;
    while (a_awvalid || a_wvalid) begin
        @(posedge clk); #1;
        if (a_awready) a_awvalid = 0;
        if (a_wready) a_wvalid = 0;
    end
    while (!a_bvalid) begin @(posedge clk); #1; end
    @(negedge clk);
end
endtask
task rd_a(input [15:0] ad);
begin
    @(negedge clk); a_araddr = ad; a_arvalid = 1;
    while (a_arvalid) begin @(posedge clk); #1; if (a_arready) a_arvalid = 0; end
    while (!a_rvalid) begin @(posedge clk); #1; end
    ra = a_rdata;
    @(negedge clk);
end
endtask
task wr_b(input [15:0] ad, input [31:0] d);
begin
    @(negedge clk); b_awaddr = ad; b_wdata = d; b_awvalid = 1; b_wvalid = 1;
    while (b_awvalid || b_wvalid) begin
        @(posedge clk); #1;
        if (b_awready) b_awvalid = 0;
        if (b_wready) b_wvalid = 0;
    end
    while (!b_bvalid) begin @(posedge clk); #1; end
    @(negedge clk);
end
endtask
task rd_b(input [15:0] ad);
begin
    @(negedge clk); b_araddr = ad; b_arvalid = 1;
    while (b_arvalid) begin @(posedge clk); #1; if (b_arready) b_arvalid = 0; end
    while (!b_rvalid) begin @(posedge clk); #1; end
    rb = b_rdata;
    @(negedge clk);
end
endtask

// ---------------------------------------------------------------- board A (TX)
reg  dv_a = 0;
always @(posedge sclk_a) dv_a <= ~dv_a;
wire [15:0] dac_i, dac_q;
dvbs2_adrv u_a (.clk(clk), .rstn(rstn),
    .s_axi_awaddr(a_awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(a_awvalid), .s_axi_awready(a_awready),
    .s_axi_wdata(a_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(a_wvalid), .s_axi_wready(a_wready),
    .s_axi_bresp(), .s_axi_bvalid(a_bvalid), .s_axi_bready(1'b1),
    .s_axi_araddr(a_araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(a_arvalid), .s_axi_arready(a_arready),
    .s_axi_rdata(a_rdata), .s_axi_rresp(), .s_axi_rvalid(a_rvalid), .s_axi_rready(1'b1),
    .s_clk(sclk_a), .s_rst(!rstn), .adc_valid(1'b0), .adc_data_i(16'd0), .adc_data_q(16'd0),
    .dac_valid(dv_a), .dma_data_i(16'h1234), .dma_data_q(16'h5678), .dac_data_i(dac_i), .dac_data_q(dac_q));

// "air": DAC samples (12 bits, as the AD9364 uses dac_data[15:4]) -> queue -> channel -> queue -> ADC
reg [31:0] q1 [0:4095];
reg [31:0] q2 [0:4095];
integer q1w = 0, q1r = 0, q2w = 0, q2r = 0;
always @(posedge sclk_a) if (dv_a && rstn) begin
    q1[q1w % 4096] = {dac_i[15:4], 4'd0, dac_q[15:4], 4'd0};
    q1w = q1w + 1;
end
reg  ch_in_v = 0; reg signed [15:0] ch_in_i = 0, ch_in_q = 0;
reg  [3:0] chgap = 0;
always @(posedge clk) begin
    ch_in_v <= 1'b0;
    if (chgap != 0) chgap <= chgap - 1;
    else if (q1r < q1w) begin
        ch_in_v <= 1'b1; ch_in_i <= q1[q1r % 4096][31:16]; ch_in_q <= q1[q1r % 4096][15:0];
        q1r = q1r + 1; chgap <= 7;
    end
end
wire ch_v; wire signed [15:0] ch_i, ch_q;
ch_emu u_ch (.clk(clk), .rst(!rstn), .bypass(1'b0), .ppm_step(PPM_STEP), .delay_frac(16'd20000),
    .cfo_step(CFO), .phase0(16'd5000), .noise_amp(NOISE[15:0]), .sig_gain(16'd16384),
    .in_valid(ch_in_v), .in_i(ch_in_i), .in_q(ch_in_q), .out_valid(ch_v), .out_i(ch_i), .out_q(ch_q));
always @(posedge clk) if (ch_v) begin
    q2[q2w % 4096] = {ch_i, ch_q};
    q2w = q2w + 1;
end

// ---------------------------------------------------------------- board B (RX)
reg  dv_b = 0, adc_started = 0;
reg  [15:0] adc_i = 0, adc_q = 0;
integer adc_unf = 0;
always @(posedge sclk_b) begin
    dv_b <= ~dv_b;
    if (!dv_b) begin            // next edge carries adc_valid: present a sample
        if (!adc_started && q2w - q2r >= 64) adc_started = 1;
        if (adc_started && q2r < q2w) begin
            // 12-bit ADC, sign-extended to 16 bits by axi_ad9361
            adc_i <= {{4{q2[q2r % 4096][31]}}, q2[q2r % 4096][31:20]};
            adc_q <= {{4{q2[q2r % 4096][15]}}, q2[q2r % 4096][15:4]};
            q2r = q2r + 1;
        end else begin
            adc_i <= 0; adc_q <= 0;
            if (adc_started) adc_unf = adc_unf + 1;
        end
    end
end
dvbs2_adrv u_b (.clk(clk), .rstn(rstn),
    .s_axi_awaddr(b_awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(b_awvalid), .s_axi_awready(b_awready),
    .s_axi_wdata(b_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(b_wvalid), .s_axi_wready(b_wready),
    .s_axi_bresp(), .s_axi_bvalid(b_bvalid), .s_axi_bready(1'b1),
    .s_axi_araddr(b_araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(b_arvalid), .s_axi_arready(b_arready),
    .s_axi_rdata(b_rdata), .s_axi_rresp(), .s_axi_rvalid(b_rvalid), .s_axi_rready(1'b1),
    .s_clk(sclk_b), .s_rst(!rstn), .adc_valid(dv_b), .adc_data_i(adc_i), .adc_data_q(adc_q),
    .dac_valid(1'b0), .dma_data_i(16'd0), .dma_data_q(16'd0), .dac_data_i(), .dac_data_q());

// ---------------------------------------------------------------- board A "ARM": payload writer
reg  [7:0] lfsr = 8'h5A;            // payload source (x^8+x^6+x^5+x^4+1)
integer    nsent = 0, w, nfree, by;
reg  [7:0] sent [0:524287];
reg [31:0] word;
reg        a_started = 0, done = 0, a_pause = 0, a_idle = 0;
initial begin : writer
    wait (a_started);
    while (!done && DATA) begin
        if (a_pause) begin a_idle = 1; wait (!a_pause); a_idle = 0; end
        rd_a(16'h020C);
        nfree = ra[31:16];
        for (w = 0; w < nfree && w < 64 && nsent < 524000; w = w + 1) begin
            for (by = 0; by < 4; by = by + 1) begin
                word[8*by +: 8] = lfsr;
                sent[nsent] = lfsr;
                nsent = nsent + 1;
                lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            end
            wr_a(16'h0200, word);
        end
        repeat (500) @(posedge clk);
    end
end

// ---------------------------------------------------------------- board B "ARM": frame reader
integer nrecv = 0, nframes = 0, len, k, badlen = 0;
reg [7:0] recv [0:524287];
reg       b_started = 0;
reg       rx_busy = 0;
task read_frames;
begin
    rx_busy = 1;
    rd_b(16'h0204);
    while (rb[31]) begin
        len = rb[15:0];
        if (len < 1 || len > 1769) badlen = badlen + 1;
        for (k = 0; k < (len + 3) / 4; k = k + 1) begin
            rd_b(16'h0208);
            for (by = 0; by < 4; by = by + 1)
                if (4 * k + by < len && nrecv < 524288) begin recv[nrecv] = rb[8*by +: 8]; nrecv = nrecv + 1; end
        end
        nframes = nframes + 1;
        rd_b(16'h0204);
    end
    rx_busy = 0;
end
endtask

// ---------------------------------------------------------------- constellation check
// symbol {I, Q} (radius 4096): distance to the nearest ideal point, radius, power
real    c_err, c_rad, c_mer;
integer c_n, c_ok, c_m;
task const_add(input [31:0] w);
    real yi, yq, a, d, dm;
    begin
        yi = $itor($signed(w[31:16])); yq = $itor($signed(w[15:0]));
        dm = 1.0e30;
        for (c_m = 0; c_m < (MODCOD >= 12 ? 8 : 4); c_m = c_m + 1) begin
            a = (MODCOD >= 12 ? c_m : 2 * c_m + 1) * 3.14159265358979 / 4.0;   // 8PSK k pi/4, QPSK (2k+1) pi/4
            d = (yi - 4096.0 * $cos(a)) * (yi - 4096.0 * $cos(a)) + (yq - 4096.0 * $sin(a)) * (yq - 4096.0 * $sin(a));
            if (d < dm) dm = d;
        end
        c_err = c_err + dm;
        c_rad = c_rad + $sqrt(yi * yi + yq * yq);
        c_n   = c_n + 1;
    end
endtask

// ---------------------------------------------------------------- control + checks
reg [31:0] ok0, st0;
integer i, nb, settle_bytes, cap_nz, cap_ok, base, nerr, txovf, dacuf, adcovf, rxfr;
initial begin
    repeat (20) @(posedge clk);
    rstn = 1;
    repeat (10) @(posedge clk);
    rd_b(16'h0178); $display("RX board ID %h", rb);
    rd_b(16'h017C); $display("RX board version %h", rb);
    // board A: TX on (payload from the ARM when DATA = 1)
    wr_a(16'h0004, {18'd0, 2'd0, 3'd0, PILOTS[0], 3'd0, MODCOD[4:0]});
    wr_a(16'h0000, 32'h0000_01C1 | (DATA ? 32'h4 : 32'h0));
    a_started = 1;
    // board B: RX on
    wr_b(16'h0004, {18'd0, 2'd0, 3'd0, PILOTS[0], 3'd0, MODCOD[4:0]});
    wr_b(16'h0000, 32'h0000_01C2 | (DATA ? 32'h8 : 32'h0));
    // wait for lock + a few good frames, then clear statistics
    begin : waitlock
        forever begin
            repeat (20000) @(posedge clk);
            if (DATA) read_frames;
            rd_b(16'h0100); st0 = rb;
            rd_b(16'h0128); ok0 = rb;
            if (cyc % 200000 < 25000)
                $display("[%0d] RX status=%h lock=%0d modcod=%0d stage=%0d bb_ok=%0d rx bytes=%0d", cyc, st0, st0[4],
                         st0[9:5], st0[13:12], ok0, nrecv);
            if (ok0 >= 6 && st0[13:12] == 2'd3 || ok0 >= 14) disable waitlock;
            if (cyc > MAXCYC) disable waitlock;
        end
    end
    settle_bytes = nrecv;
    wr_b(16'h001C, 32'd1);          // clear statistics (both boards)
    a_pause = 1; if (DATA) wait (a_idle);
    wr_a(16'h001C, 32'd1);
    a_pause = 0;
    $display("[%0d] statistics cleared (bb_ok was %0d, %0d bytes received so far)", cyc, ok0, nrecv);
    begin : run
        forever begin
            repeat (20000) @(posedge clk);
            if (DATA) read_frames;
            rd_b(16'h0128);
            if (rb >= NOK || cyc > MAXCYC) disable run;
        end
    end
    // constellation snapshot (TX still sending data frames): 1024 data symbols after carrier recovery
    wr_b(16'h0020, 32'd3);
    c_ok = 0; c_n = 0; c_err = 0.0; c_rad = 0.0;
    for (i = 0; i < 100 && !c_ok; i = i + 1) begin
        repeat (5000) @(posedge clk);
        if (DATA) read_frames;
        rd_b(16'h0174); c_ok = rb[31] && rb[29];
    end
    for (i = 0; i < 1024 && c_ok; i = i + 1) begin
        rd_b(16'h1000 + 4 * i);
        const_add(rb);
    end
    c_mer = c_n ? 10.0 * $log10(c_n * 4096.0 * 4096.0 / c_err) : 0.0;
    $display("constellation snapshot: done=%0d, %0d symbols, mean radius %0.0f, MER %0.1f dB", c_ok, c_n,
             c_n ? c_rad / c_n : 0.0, c_mer);
    if (DATA) read_frames;
    a_pause = 1; if (DATA) wait (a_idle);
    done = 1;
    // ---- report
    rd_b(16'h0128); $display("bb_ok=%0d", rb);
    rd_b(16'h012C); $display("bb_crc=%0d", rb);
    rd_b(16'h0130); $display("bb_bchfail=%0d", rb);
    rd_b(16'h0124); $display("bch_fail=%0d", rb);
    rd_b(16'h0138); $display("ber_bits=%0d", rb);
    rd_b(16'h0140); $display("ber_errors=%0d", rb);
    rd_b(16'h011C); $display("ldpc drop=%0d", rb);
    rd_a(16'h0160); txovf = ra;
    rd_a(16'h0168); dacuf = ra;
    rd_a(16'h0148); $display("TX board: frames sent=%0d, payload overflow=%0d, DAC underflow=%0d", ra, txovf, dacuf);
    rd_a(16'h014C); $display("TX board: dummy frames=%0d", ra);
    rd_b(16'h0180); adcovf = rb;
    rd_b(16'h0184); rxfr = rb;
    $display("RX board: ADC CDC overflow=%0d, frames to ARM=%0d, ADC queue underflow (tb)=%0d", adcovf, rxfr, adc_unf);
    // spectrum snapshot
    wr_b(16'h0020, 32'd1);
    repeat (1024 * 9 + 200) @(posedge clk);
    rd_b(16'h0174); cap_ok = rb[31];
    cap_nz = 0;
    for (i = 0; i < 1024; i = i + 1) begin
        rd_b(16'h1000 + 4 * i);
        if (rb != 0) cap_nz = cap_nz + 1;
    end
    $display("spectrum snapshot: done=%0d, %0d of 1024 samples non-zero", cap_ok, cap_nz);
    // payload check: align the first bytes after settling with the sent sequence
    nerr = 0; nb = 0; base = -1;
    if (DATA) begin
        for (k = 0; k < nsent - 8 && base < 0; k = k + 1) begin
            if (sent[k] == recv[settle_bytes] && sent[k+1] == recv[settle_bytes+1] && sent[k+2] == recv[settle_bytes+2] &&
                sent[k+3] == recv[settle_bytes+3] && sent[k+4] == recv[settle_bytes+4] && sent[k+5] == recv[settle_bytes+5])
                base = k;
        end
        if (base < 0) $display("payload: could not align (%0d sent, %0d received)", nsent, nrecv);
        else begin
            for (i = settle_bytes; i < nrecv; i = i + 1) begin
                nb = nb + 1;
                if (recv[i] !== sent[base + i - settle_bytes]) nerr = nerr + 1;
            end
            $display("payload: %0d bytes sent, %0d received in %0d frames (%0d after settling), %0d byte errors, bad lengths %0d",
                     nsent, nrecv, nframes, nb, nerr, badlen);
        end
    end
    rd_b(16'h0128); ok0 = rb;
    rd_b(16'h012C);
    if (cap_ok && cap_nz >= 1000 && c_n == 1024 && c_rad / c_n > 3300.0 && c_rad / c_n < 5000.0
        && c_mer > (MODCOD >= 12 ? 8.0 : 3.0)
        && ok0 >= NOK && rb == 0 && txovf == 0 && dacuf == 0 && adcovf == 0
        && (DATA ? (base >= 0 && nerr == 0 && nb > 1000 && badlen == 0) : 1)) begin
        rd_b(16'h0130); if (rb == 0) $display("PASS"); else $display("FAIL (bch failures)");
    end else $display("FAIL");
    $finish;
end
endmodule
