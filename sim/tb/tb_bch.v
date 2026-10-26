// tb_bch.v -- BCH decoder unit test (vectors from sim/tools/gen_bch_vec.py).
`timescale 1ns/1ps
module tb_bch;
reg clk = 0, rst = 1;
always #5 clk = ~clk;
reg        i_valid = 0, i_first = 0, i_last = 0;
reg [7:0]  i_data = 0;
reg [3:0]  i_code = 0;
reg [31:0] i_meta = 0;
wire       i_ready, o_valid, o_first, o_last, o_fail;
wire [7:0] o_data;
wire [3:0] o_ncorr, o_code;
wire [31:0] o_meta, cb, ff;
reg        o_ready = 1;
bch_dec dut (.clk(clk), .rst(rst), .i_valid(i_valid), .i_data(i_data), .i_ready(i_ready),
    .i_first(i_first), .i_last(i_last), .i_code(i_code), .i_meta(i_meta),
    .o_valid(o_valid), .o_data(o_data), .o_ready(o_ready), .o_first(o_first), .o_last(o_last),
    .o_fail(o_fail), .o_ncorr(o_ncorr), .o_code(o_code), .o_meta(o_meta),
    .corrected_bits(cb), .failed_frames(ff));
// random output back-pressure
always @(posedge clk) o_ready <= ($random & 3) != 0;
integer fin, fout, r, code, fno, n, i, v, nin, nout;
reg [8*4-1:0] tag;
initial begin
    fin = $fopen("bch_in.txt", "r"); fout = $fopen("bch_out.txt", "w");
    nin = 0; nout = 0;
    repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
    while (1) begin
        r = $fscanf(fin, "%s", tag);
        if (tag == "E") begin
            while (nout < nin) @(posedge clk);
            $display("BCH tb done: frames=%0d corrected_bits=%0d failed=%0d", nout, cb, ff);
            $fclose(fout); $finish;
        end
        r = $fscanf(fin, "%d %d %d", code, fno, n);
        for (i = 0; i < n; i = i + 1) begin
            r = $fscanf(fin, "%d", v);
            @(negedge clk);
            while (!i_ready) @(negedge clk);
            i_valid = 1; i_data = v; i_first = (i == 0); i_last = (i == n-1); i_code = code; i_meta = fno;
            @(negedge clk);
            i_valid = 0; i_first = 0; i_last = 0;
        end
        nin = nin + 1;
    end
end
always @(posedge clk) if (o_valid && o_ready) begin
    if (o_first) $fwrite(fout, "F %0d ", o_meta);
    $fwrite(fout, "%0d ", o_data);
    if (o_last) begin $fwrite(fout, "\nS %0d %0d\n", o_fail, o_ncorr); nout = nout + 1; end
end
initial begin #500000000; $display("TIMEOUT"); $finish; end
endmodule
