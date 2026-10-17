// adrv_fifo.v -- synchronous first-word-fall-through FIFO (block RAM for AW >= 9).
// (same as b210/rtl/b210_fifo.v; the board projects do not share RTL)
`timescale 1ns/1ps
module adrv_fifo #(
    parameter W  = 8,
    parameter AW = 11
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          wr,
    input  wire [W-1:0]  din,
    output wire          full,
    input  wire          rd,          // pop the current output word (ignored when empty)
    output reg  [W-1:0]  dout,
    output wire          empty,
    output wire [AW:0]   count
);
reg [W-1:0] mem [0:(1<<AW)-1];
reg [AW:0]  wp, rp;
reg         dv;
wire [AW:0] used = wp - rp;                 // words still in the RAM
wire        mem_empty = (used == {(AW+1){1'b0}});
wire        load = !mem_empty && (!dv || rd);
assign full  = (used == (1 << AW));
assign empty = !dv;
assign count = used + {{AW{1'b0}}, dv};
always @(posedge clk) begin
    if (wr && !full) mem[wp[AW-1:0]] <= din;
end
always @(posedge clk) begin
    if (load) dout <= mem[rp[AW-1:0]];
end
always @(posedge clk) begin
    if (rst) begin
        wp <= {(AW+1){1'b0}}; rp <= {(AW+1){1'b0}}; dv <= 1'b0;
    end else begin
        if (wr && !full) wp <= wp + 1'b1;
        if (load) begin rp <= rp + 1'b1; dv <= 1'b1; end
        else if (rd) dv <= 1'b0;
    end
end
endmodule
