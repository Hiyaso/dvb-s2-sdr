// tb_tx.v -- TX unit test: dumps PL-frame symbols and shaped samples for
// comparison with the Python reference (sim/check_tx.py).
`timescale 1ns/1ps
module tb_tx;
parameter MODCOD = 4;
parameter PILOTS = 1;
parameter ROLLOFF = 0;
parameter NFRAMES = 4;          // data frames to capture
parameter DIV = 4;              // clocks per sample
reg clk = 0, rst = 1;
always #5 clk = ~clk;
reg [7:0] div_cnt = 0;
wire samp_stb = (div_cnt == 0);
always @(posedge clk) div_cnt <= (div_cnt == DIV-1) ? 0 : div_cnt + 1;

wire out_valid, sof;
wire signed [15:0] oi, oq;
wire [31:0] fe, fs, ds, uf;
wire s_ready;
dvbs2_tx dut (
    .clk(clk), .rst(rst), .enable(1'b1), .modcod(MODCOD[4:0]), .pilots(PILOTS[0]), .rolloff(ROLLOFF[1:0]),
    .src_stream(1'b0), .s_axis_tdata(8'd0), .s_axis_tvalid(1'b0), .s_axis_tready(s_ready),
    .samp_stb(samp_stb), .out_valid(out_valid), .out_i(oi), .out_q(oq), .sym_sof(sof),
    .frames_encoded(fe), .frames_sent(fs), .dummy_sent(ds), .underflows(uf));

integer fsym, fsmp;
initial begin
    fsym = $fopen("tx_syms.txt", "w");
    fsmp = $fopen("tx_samples.txt", "w");
    #100 rst = 0;
end
always @(posedge clk) begin
    if (!rst && dut.sym_valid && dut.sym_ready)
        $fwrite(fsym, "%0d %0d\n", dut.sof, dut.sym_k);
    if (!rst && out_valid)
        $fwrite(fsmp, "%0d %0d\n", oi, oq);
    if (fs == NFRAMES + 1) begin
        $display("TX done: encoded=%0d sent=%0d dummy=%0d underflows=%0d time=%0t", fe, fs, ds, uf, $time);
        $fclose(fsym); $fclose(fsmp);
        $finish;
    end
end
endmodule
