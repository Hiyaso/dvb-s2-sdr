// tb_ldpc.v -- LDPC decoder unit test: LLR frames from ldpc_in.txt, decoded
// bytes + iteration counts to ldpc_out.txt (compared by sim/tools/check_ldpc.py).
`timescale 1ns/1ps
module tb_ldpc;
parameter MAXIT = 25;
parameter GAP = 0;            // idle cycles between LLRs
reg clk = 0, rst = 1;
always #5 clk = ~clk;

reg        ld_start = 0, ld_valid = 0, ld_end = 0;
reg [3:0]  ld_code = 0;
reg [15:0] ld_meta = 0;
reg [1:0]  ld_stream = 0;
reg signed [6:0] ld_llr = 0;
wire       o_valid, o_first, o_last, o_conv, cbusy;
wire [7:0] o_data;
wire [3:0] o_code;
wire [15:0] o_meta;
wire [5:0] o_iters;
wire [31:0] fdrop, fdec;
wire can_start;
reg [5:0] maxit_r = MAXIT;
initial if (!$value$plusargs("maxit=%d", maxit_r)) maxit_r = MAXIT;
ldpc_dec #(.P(45)) dut (
    .clk(clk), .rst(rst), .max_iter(maxit_r), .alpha_override(3'd0), .early_stop(1'b1),
    .ld_start(ld_start), .ld_code(ld_code), .ld_meta(ld_meta), .ld_valid(ld_valid),
    .ld_stream(ld_stream), .ld_llr(ld_llr), .ld_end(ld_end),
    .o_valid(o_valid), .o_data(o_data), .o_ready(1'b1), .o_first(o_first), .o_last(o_last),
    .o_code(o_code), .o_meta(o_meta), .o_iters(o_iters), .o_conv(o_conv),
    .frames_dropped(fdrop), .frames_decoded(fdec), .core_busy(cbusy), .ld_can_start(can_start));

integer fin, fout, r, code, fno, n, i, st, v, nframes_in, nframes_out;
reg [8*4-1:0] tag;
initial begin
    fin = $fopen("ldpc_in.txt", "r");
    fout = $fopen("ldpc_out.txt", "w");
    nframes_in = 0; nframes_out = 0;
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (5) @(posedge clk);
    while (1) begin
        r = $fscanf(fin, "%s", tag);
        if (tag == "E") begin
            // wait for all frames
            while (nframes_out < nframes_in) @(posedge clk);
            repeat (20) @(posedge clk);
            $display("LDPC tb done: in=%0d out=%0d dropped=%0d time=%0t", nframes_in, nframes_out, fdrop, $time);
            $fclose(fout);
            $finish;
        end
        r = $fscanf(fin, "%d %d %d", code, fno, n);
        while (!can_start) @(negedge clk);
        @(negedge clk);
        ld_start = 1; ld_code = code; ld_meta = fno;
        @(negedge clk);
        ld_start = 0;
        for (i = 0; i < n; i = i + 1) begin
            r = $fscanf(fin, "%d %d", st, v);
            ld_valid = 1; ld_stream = st; ld_llr = v;
            @(negedge clk);
            ld_valid = 0;
            repeat (GAP) @(negedge clk);
        end
        ld_end = 1;
        @(negedge clk);
        ld_end = 0;
        nframes_in = nframes_in + 1;
    end
end
always @(posedge clk) begin
    if (o_valid) begin
        if (o_first) $fwrite(fout, "F %0d %0d %0d\n", o_meta, o_iters, o_conv);
        $fwrite(fout, "%0d ", o_data);
        if (o_last) begin $fwrite(fout, "\n"); nframes_out = nframes_out + 1; end
    end
end
// safety timeout
initial begin
    #2000000000;
    $display("TIMEOUT");
    $finish;
end
endmodule
