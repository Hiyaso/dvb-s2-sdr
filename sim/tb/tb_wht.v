// tb_wht.v -- rx_pls_wht against a direct 64-point Walsh-Hadamard sum
// (random vectors, back-to-back and with gaps in the input enable).
`timescale 1ns/1ps
module tb_wht;
reg clk = 0;
always #5 clk = ~clk;
reg start = 0, en = 0;
reg signed [27:0] x;
wire ov; wire [5:0] ok; wire signed [27:0] of;
rx_pls_wht #(.W(28)) dut (.clk(clk), .start(start), .en(en), .x(x), .out_v(ov), .out_k(ok), .out_f(of));
reg signed [27:0] v [0:63];
reg signed [27:0] rf [0:63];
integer t, j, k, nout, nerr, seed, gaps;
reg [5:0] jk;
always @(posedge clk) if (ov) begin
    if (of !== rf[ok] || ok != nout[5:0]) begin
        nerr = nerr + 1;
        if (nerr < 5) $display("mismatch k=%0d got %0d want %0d (expected k %0d)", ok, of, rf[ok], nout);
    end
    nout = nout + 1;
end
initial begin
    nerr = 0; seed = 1;
    for (t = 0; t < 200; t = t + 1) begin
        for (j = 0; j < 64; j = j + 1)
            v[j] = (t % 3 == 0) ? (($random(seed) % 3) - 1) * 131071 : ($random(seed) % 262144);
        for (k = 0; k < 64; k = k + 1) begin
            rf[k] = 0;
            for (j = 0; j < 64; j = j + 1) begin
                jk = j & k;
                if (^jk) rf[k] = rf[k] - v[j]; else rf[k] = rf[k] + v[j];
            end
        end
        gaps = t % 2;
        nout = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        for (j = 0; j < 64; j = j + 1) begin
            en = 1; x = v[j]; @(negedge clk);
            if (gaps && ($random(seed) & 1)) begin en = 0; x = 28'sd12345; @(negedge clk); end
        end
        x = 0;
        while (nout < 64) begin en = 1; @(negedge clk); end
        en = 0; repeat (3) @(negedge clk);
    end
    if (nerr == 0) $display("PASS (200 transforms)"); else $display("FAIL %0d mismatches", nerr);
    $finish;
end
endmodule
