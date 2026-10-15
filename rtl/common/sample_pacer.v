// sample_pacer.v -- small FIFO that re-times a bursty sample stream so that
// consecutive output samples are at least MIN_GAP clocks apart (the channel
// emulator can emit two samples in adjacent clocks when it resamples).
`timescale 1ns/1ps
module sample_pacer #(
    parameter MIN_GAP = 3,
    parameter AW = 4
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output reg                out_valid,
    output reg  signed [15:0] out_i,
    output reg  signed [15:0] out_q,
    output reg                overflow
);
reg [31:0] mem [0:(1<<AW)-1];
reg [AW:0] wp, rp;
reg [3:0]  gap;
wire empty = (wp == rp);
wire full  = (wp - rp) == (1 << AW);
always @(posedge clk) begin
    if (rst) begin
        wp <= 0; rp <= 0; gap <= 4'd0; out_valid <= 1'b0; out_i <= 0; out_q <= 0; overflow <= 1'b0;
    end else begin
        out_valid <= 1'b0;
        if (in_valid) begin
            if (!full) begin mem[wp[AW-1:0]] <= {in_i, in_q}; wp <= wp + 1'b1; end
            else overflow <= 1'b1;
        end
        if (gap != 4'd0) gap <= gap - 4'd1;
        if (!empty && gap == 4'd0) begin
            out_valid <= 1'b1;
            {out_i, out_q} <= mem[rp[AW-1:0]];
            rp <= rp + 1'b1;
            gap <= MIN_GAP - 1;
        end
    end
end
endmodule
