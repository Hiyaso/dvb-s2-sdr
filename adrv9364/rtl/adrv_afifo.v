// adrv_afifo.v -- small asynchronous FIFO (gray-code pointers, 2-flop synchronisers),
// first-word-fall-through with a registered output in the read clock domain.
//
// Clock-domain crossings (constrained in adrv9364/hdl/dvbs2_adrv.xdc):
//   wptr_gray -> wptr_cdc0 (read clock), rptr_gray -> rptr_cdc0 (write clock),
//   mem (written on wclk) -> dout_cdc (read on rclk, guarded by the pointer synchronisers).
// wcount is the write-side fill level (may over-estimate by up to 3 entries).
`timescale 1ns/1ps
module adrv_afifo #(
    parameter W  = 32,
    parameter AW = 4
) (
    input  wire          wclk,
    input  wire          wrst,
    input  wire          wr,
    input  wire [W-1:0]  din,
    output wire          full,
    output wire [AW:0]   wcount,
    input  wire          rclk,
    input  wire          rrst,
    input  wire          rd,          // pop the current output word (ignored when empty)
    output wire [W-1:0]  dout,
    output wire          empty
);
function [AW:0] bin2gray; input [AW:0] b; bin2gray = b ^ (b >> 1); endfunction
function [AW:0] gray2bin; input [AW:0] g; integer i;
    begin
        gray2bin[AW] = g[AW];
        for (i = AW - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
    end
endfunction

reg [W-1:0] mem [0:(1<<AW)-1];

// ---------------------------------------------------------------- write side
reg [AW:0] wptr, wptr_gray;
(* ASYNC_REG = "TRUE" *) reg [AW:0] rptr_cdc0, rptr_cdc1;
wire [AW:0] rptr_w = gray2bin(rptr_cdc1);
assign wcount = wptr - rptr_w;
assign full   = (wcount == (1 << AW));
always @(posedge wclk) begin
    if (wr && !full) mem[wptr[AW-1:0]] <= din;
end
always @(posedge wclk) begin
    if (wrst) begin
        wptr <= {(AW+1){1'b0}}; wptr_gray <= {(AW+1){1'b0}};
        rptr_cdc0 <= {(AW+1){1'b0}}; rptr_cdc1 <= {(AW+1){1'b0}};
    end else begin
        if (wr && !full) begin
            wptr      <= wptr + 1'b1;
            wptr_gray <= bin2gray(wptr + 1'b1);
        end
        rptr_cdc0 <= rptr_gray;
        rptr_cdc1 <= rptr_cdc0;
    end
end

// ---------------------------------------------------------------- read side
reg [AW:0] rptr, rptr_gray;
(* ASYNC_REG = "TRUE" *) reg [AW:0] wptr_cdc0, wptr_cdc1;
reg [W-1:0] dout_cdc;
reg         dv;
wire        mem_empty = (rptr_gray == wptr_cdc1);
wire        load = !mem_empty && (!dv || rd);
assign dout  = dout_cdc;
assign empty = !dv;
always @(posedge rclk) begin
    if (load) dout_cdc <= mem[rptr[AW-1:0]];
end
always @(posedge rclk) begin
    if (rrst) begin
        rptr <= {(AW+1){1'b0}}; rptr_gray <= {(AW+1){1'b0}}; dv <= 1'b0;
        wptr_cdc0 <= {(AW+1){1'b0}}; wptr_cdc1 <= {(AW+1){1'b0}};
    end else begin
        wptr_cdc0 <= wptr_gray;
        wptr_cdc1 <= wptr_cdc0;
        if (load) begin
            rptr      <= rptr + 1'b1;
            rptr_gray <= bin2gray(rptr + 1'b1);
            dv        <= 1'b1;
        end else if (rd) dv <= 1'b0;
    end
end
endmodule
