// ram_sdp.v -- simple dual-port RAM (1 write port, 1 synchronous read port).
// Inferred as block RAM by Vivado (or LUTRAM for small sizes).  Read-during-write
// to the same address returns the OLD data (read-first), which the users of this
// module account for explicitly.
`timescale 1ns/1ps
module ram_sdp #(
    parameter DW = 8,
    parameter AW = 10,
    parameter STYLE = "block"        // kept for compatibility (all users want block RAM)
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
(* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];
`ifndef SYNTHESIS
integer i;
initial begin
    for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
    rdata = {DW{1'b0}};
end
`endif
always @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
end
always @(posedge clk) begin
    if (re) rdata <= mem[raddr];
end
endmodule

// ram_sdp_be.v -- simple dual-port RAM with per-lane (byte) write enables.
// NB lanes of LW bits; Vivado infers byte-write BRAM for LW = 8 or 9.
module ram_sdp_be #(
    parameter NB = 45,
    parameter LW = 8,
    parameter AW = 9
) (
    input  wire             clk,
    input  wire [NB-1:0]    we,
    input  wire [AW-1:0]    waddr,
    input  wire [NB*LW-1:0] wdata,
    input  wire             re,
    input  wire [AW-1:0]    raddr,
    output wire [NB*LW-1:0] rdata
);
`ifdef SPARTAN6
// ISE/XST: groups of 4 lanes, each a 512 x 36 block RAM with 4 byte-write enables
// (the XST byte-write template); the last group may be narrower.
localparam NG = (NB + 3) / 4;
genvar gg;
generate for (gg = 0; gg < NG; gg = gg + 1) begin : g_grp
    if (4 * gg + 4 <= NB) begin : g_full
        ram_sdp_be4 #(.NL(4), .LW(LW), .AW(AW)) u_g (
            .clk(clk), .we(we[4*gg +: 4]), .waddr(waddr), .wdata(wdata[4*gg*LW +: 4*LW]),
            .re(re), .raddr(raddr), .rdata(rdata[4*gg*LW +: 4*LW]));
    end else begin : g_part
        ram_sdp_be4 #(.NL(NB - 4 * gg), .LW(LW), .AW(AW)) u_g (
            .clk(clk), .we(we[4*gg +: NB - 4*gg]), .waddr(waddr), .wdata(wdata[4*gg*LW +: (NB - 4*gg)*LW]),
            .re(re), .raddr(raddr), .rdata(rdata[4*gg*LW +: (NB - 4*gg)*LW]));
    end
end endgenerate
`else
(* ram_style = "block" *) reg [NB*LW-1:0] mem [0:(1<<AW)-1];
reg [NB*LW-1:0] rdata_r;
assign rdata = rdata_r;
`ifndef SYNTHESIS
integer i;
initial begin
    for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {(NB*LW){1'b0}};
    rdata_r = {(NB*LW){1'b0}};
end
`endif
// Vivado byte-write-enable template (UG901): one process, loop over lanes.
integer b;
always @(posedge clk) begin
    for (b = 0; b < NB; b = b + 1)
        if (we[b]) mem[waddr][b*LW +: LW] <= wdata[b*LW +: LW];
end
always @(posedge clk) begin
    if (re) rdata_r <= mem[raddr];
end
`endif
endmodule

// ram_sdp_be4.v -- up to 4 lanes with byte-write enables (XST template form)
module ram_sdp_be4 #(
    parameter NL = 4,
    parameter LW = 8,
    parameter AW = 9
) (
    input  wire             clk,
    input  wire [NL-1:0]    we,
    input  wire [AW-1:0]    waddr,
    input  wire [NL*LW-1:0] wdata,
    input  wire             re,
    input  wire [AW-1:0]    raddr,
    output reg  [NL*LW-1:0] rdata
);
(* ram_style = "block" *) reg [NL*LW-1:0] mem [0:(1<<AW)-1];
`ifndef SYNTHESIS
integer i;
initial begin
    for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {(NL*LW){1'b0}};
    rdata = {(NL*LW){1'b0}};
end
`endif
genvar b;
generate for (b = 0; b < NL; b = b + 1) begin : g_lane
    always @(posedge clk) if (we[b]) mem[waddr][b*LW +: LW] <= wdata[b*LW +: LW];
end endgenerate
always @(posedge clk) begin
    if (re) rdata <= mem[raddr];
end
endmodule
