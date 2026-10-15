// tb_b210.v -- two "B210 radios" running dvbs2_b210 (TX board and RX board),
// connected by the channel emulator, controlled like the host program does it
// (user settings registers, payload bytes inside the host sample streams).
//
//   board A: host TX stream -> dvbs2_b210 (tx_en, tx_data) -> "DUC"
//   channel: ch_emu (CFO, clock offset, AWGN)
//   board B: "DDC" -> dvbs2_b210 (rx_en, rx_data) -> host RX stream
//
// DATA=1: payload bytes (LFSR) are sent through the host streams and checked at
// the RX host side; DATA=0: internal PRBS, BER checked through the readback.
`timescale 1ns/1ps
module tb_b210;
parameter MODCOD = 13;
parameter PILOTS = 1;
parameter D = 8;                    // radio clocks per sample (interpolation / decimation)
parameter DATA = 1;
parameter integer NOISE = 4487;     // Es/N0 10 dB
parameter integer CFO = 4294967;    // 0.2 % Rs
parameter integer PPM_STEP = 85899; // +20 ppm
parameter integer NOK = 8;          // good frames after lock
parameter integer MAXCYC = 6000000;
parameter integer BYTE_EVERY = 10;  // host inserts one payload byte every N samples

reg clk = 0, rst = 1;
always #5 clk = ~clk;
integer cyc = 0;

// ---------------------------------------------------------------- settings tasks
reg        a_stb = 0, b_stb = 0;
reg [7:0]  a_addr = 0, b_addr = 0, b_rbaddr = 0;
reg [31:0] a_data = 0, b_data = 0;
task wr_a(input [7:0] ad, input [31:0] d);
begin @(negedge clk); a_stb = 1; a_addr = ad; a_data = d; @(negedge clk); a_stb = 0; end
endtask
task wr_b(input [7:0] ad, input [31:0] d);
begin @(negedge clk); b_stb = 1; b_addr = ad; b_data = d; @(negedge clk); b_stb = 0; end
endtask
wire [63:0] a_rb, b_rb;
reg  [63:0] rbv;
task rd_b(input [7:0] ad);
begin @(negedge clk); b_rbaddr = ad; repeat (3) @(negedge clk); rbv = b_rb; end
endtask

// ---------------------------------------------------------------- board A (TX)
reg  [7:0] dcnt = 0;
wire duc_stb = (dcnt == 0);
always @(posedge clk) dcnt <= (dcnt == D - 1) ? 0 : dcnt + 1;
reg  [31:0] host_tx;
reg  [7:0]  lfsr = 8'h5A;            // payload source (x^8+x^6+x^5+x^4+1)
integer     nsent = 0, scnt = 0;
reg  [7:0]  sent [0:262143];
wire [31:0] duc_in;
dvbs2_b210 u_a (.clk(clk), .rst(rst), .set_stb(a_stb), .set_addr(a_addr), .set_data(a_data),
    .rb_addr(8'd0), .rb_data(a_rb),
    .tx_host_sample(host_tx), .tx_strobe(duc_stb), .tx_run(1'b1), .tx_duc_sample(duc_in),
    .rx_ddc_sample(32'd0), .rx_strobe(1'b0), .rx_run(1'b0), .rx_host_sample());
// host TX stream: a word is consumed on every DUC strobe
always @(posedge clk) begin
    if (rst) begin host_tx <= 32'd0; scnt = 0; end
    else if (duc_stb) begin
        scnt = scnt + 1;
        if (DATA && scnt % BYTE_EVERY == 0 && nsent < 262144) begin
            host_tx <= {7'd0, 1'b1, lfsr, 16'd0};
            sent[nsent] = lfsr;
            nsent = nsent + 1;
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
        end else host_tx <= 32'd0;
    end
end
// the host word presented while duc_stb is high is the one consumed: the
// register above changes right after the strobe, i.e. one word per strobe.

// ---------------------------------------------------------------- channel
reg  ch_in_v; reg signed [15:0] ch_in_i, ch_in_q;
always @(posedge clk) begin
    ch_in_v <= duc_stb && !rst;
    ch_in_i <= duc_in[31:16]; ch_in_q <= duc_in[15:0];
end
wire ch_v; wire signed [15:0] ch_i, ch_q;
ch_emu u_ch (.clk(clk), .rst(rst), .bypass(1'b0), .ppm_step(PPM_STEP), .delay_frac(16'd20000),
    .cfo_step(CFO), .phase0(16'd5000), .noise_amp(NOISE[15:0]), .sig_gain(16'd16384),
    .in_valid(ch_in_v), .in_i(ch_in_i), .in_q(ch_in_q), .out_valid(ch_v), .out_i(ch_i), .out_q(ch_q));

// ---------------------------------------------------------------- board B (RX)
wire [31:0] host_rx;
dvbs2_b210 u_b (.clk(clk), .rst(rst), .set_stb(b_stb), .set_addr(b_addr), .set_data(b_data),
    .rb_addr(b_rbaddr), .rb_data(b_rb),
    .tx_host_sample(32'd0), .tx_strobe(1'b0), .tx_run(1'b0), .tx_duc_sample(),
    .rx_ddc_sample({ch_i, ch_q}), .rx_strobe(ch_v), .rx_run(1'b1), .rx_host_sample(host_rx));
// host RX stream: payload bytes, matched against the sent sequence
integer nrecv = 0, base = -1, nerr = 0, k, nlast = 0, seq_err = 0;
reg [7:0]  recv [0:262143];
reg [15:0] last_seq = 0;
reg        seq_init = 0;
always @(posedge clk) begin
    if (!rst && ch_v && host_rx[24] && nrecv < 262144) begin
        recv[nrecv] = host_rx[23:16];
        nrecv = nrecv + 1;
        if (host_rx[25]) nlast = nlast + 1;
        if (seq_init && host_rx[15:0] != last_seq + 16'd1) seq_err = seq_err + 1;
        last_seq = host_rx[15:0]; seq_init = 1;
    end
end

// ---------------------------------------------------------------- control + checks
reg [31:0] ok0;
integer i, nb, settle_bytes, cap_nz, cap_ok;
initial begin
    repeat (20) @(posedge clk);
    rst = 0;
    repeat (10) @(posedge clk);
    // board A: TX on (payload from the host stream when DATA = 1)
    wr_a(8'd1, {18'd0, 2'd0, 3'd0, PILOTS[0], 3'd0, MODCOD[4:0]});
    wr_a(8'd0, 32'h0000_01C1 | (DATA ? 32'h4 : 32'h0));
    // board B: RX on
    wr_b(8'd1, {18'd0, 2'd0, 3'd0, PILOTS[0], 3'd0, MODCOD[4:0]});
    wr_b(8'd0, 32'h0000_01C2 | (DATA ? 32'h8 : 32'h0));
    rd_b(8'd15);
    $display("RX board ID/version: %h", rbv);
    // wait for lock + a few good frames, then clear statistics
    begin : waitlock
        forever begin
            repeat (100000) @(posedge clk);
            rd_b(8'd0);
            $display("[%0d] RX status=%h lock=%0d modcod=%0d stage=%0d omega=%0d", cyc, rbv[31:0], rbv[4],
                     rbv[9:5], rbv[13:12], $signed(rbv[63:32]));
            rd_b(8'd5); ok0 = rbv[31:0];
            if (ok0 >= 6 && rbv[13:12] == 2'd3 || ok0 >= 14) disable waitlock;
            if (cyc > MAXCYC) disable waitlock;
        end
    end
    settle_bytes = nrecv;
    wr_b(8'd7, 32'd1);          // clear statistics
    $display("[%0d] statistics cleared (bb_ok was %0d, %0d bytes received so far)", cyc, ok0, nrecv);
    begin : run
        forever begin
            repeat (100000) @(posedge clk);
            rd_b(8'd5);
            if (rbv[31:0] >= NOK || cyc > MAXCYC) disable run;
        end
    end
    // ---- report
    rd_b(8'd5);  $display("bb_ok=%0d bb_crc=%0d", rbv[31:0], rbv[63:32]);
    rd_b(8'd6);  $display("bb_bchfail=%0d dfl/matype=%h", rbv[31:0], rbv[63:32]);
    rd_b(8'd7);  $display("ber_bits=%0d", rbv[31:0]);
    rd_b(8'd8);  $display("ber_errors=%0d tx_frames(rx board)=%0d", rbv[31:0], rbv[63:32]);
    rd_b(8'd12); $display("rx bytes to host=%0d", rbv[63:32]);
    rd_b(8'd3);  $display("ldpc dec=%0d drop=%0d", rbv[31:0], rbv[63:32]);
    rd_b(8'd9);  $display("tx dummy frames (rx board)=%0d", rbv[63:32]);
    // spectrum snapshot: 1024 DDC samples, read back through rb_addr[7]
    wr_b(8'd8, 32'd1);
    repeat (1024 * D + 200) @(posedge clk);
    rd_b(8'd14); cap_ok = rbv[63];
    cap_nz = 0;
    for (i = 0; i < 4; i = i + 1) begin
        wr_b(8'd8, i << 8);
        for (k = 0; k < 128; k = k + 1) begin
            rd_b(8'd128 + k[7:0]);
            if (rbv[31:0] != 0) cap_nz = cap_nz + 1;
            if (rbv[63:32] != 0) cap_nz = cap_nz + 1;
        end
    end
    $display("spectrum snapshot: done=%0d, %0d of 1024 samples non-zero", cap_ok, cap_nz);
    // payload check: align the first byte after settling with the sent sequence
    nerr = 0; nb = 0; base = -1;
    for (k = 0; k < nsent - 8 && base < 0; k = k + 1) begin
        if (sent[k] == recv[settle_bytes] && sent[k+1] == recv[settle_bytes+1] && sent[k+2] == recv[settle_bytes+2] &&
            sent[k+3] == recv[settle_bytes+3] && sent[k+4] == recv[settle_bytes+4] && sent[k+5] == recv[settle_bytes+5])
            base = k;
    end
    if (DATA) begin
        if (base < 0) $display("payload: could not align (%0d sent, %0d received)", nsent, nrecv);
        else begin
            for (i = settle_bytes; i < nrecv; i = i + 1) begin
                nb = nb + 1;
                if (recv[i] !== sent[base + i - settle_bytes]) nerr = nerr + 1;
            end
            $display("payload: %0d bytes sent, %0d received (%0d after settling), %0d byte errors, %0d frame ends, seq gaps %0d",
                     nsent, nrecv, nb, nerr, nlast, seq_err);
        end
    end
    rd_b(8'd5);
    if (cap_ok && cap_nz >= 1000 && rbv[31:0] >= NOK && rbv[63:32] == 0 && (DATA ? (base >= 0 && nerr == 0 && nb > 1000 && seq_err == 0) : 1)) begin
        rd_b(8'd6); if (rbv[31:0] == 0) $display("PASS"); else $display("FAIL (bch failures)");
    end else $display("FAIL");
    $finish;
end
always @(posedge clk) cyc <= cyc + 1;
endmodule
