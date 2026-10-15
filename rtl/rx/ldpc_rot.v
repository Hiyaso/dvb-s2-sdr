// ldpc_rot.v -- cyclic lane rotator for the LDPC decoder (barrel shifter, mod P).
//   DIR = 0 (read) : out[k] = in[(k - r) mod P]
//   DIR = 1 (write): out[k] = in[(k + r) mod P]
// P need not be a power of two: stage j rotates by (2^j mod P).
`timescale 1ns/1ps
module ldpc_rot #(
    parameter P   = 45,
    parameter W   = 8,
    parameter RB  = 6,          // rotation amount bits (2^RB >= P)
    parameter DIR = 0
) (
    input  wire [P*W-1:0] din,
    input  wire [RB-1:0]  r,
    output wire [P*W-1:0] dout
);
wire [P*W-1:0] st [0:RB];
assign st[0] = din;
genvar j, k;
generate
for (j = 0; j < RB; j = j + 1) begin : g_stage
    localparam integer SH = (1 << j) % P;
    for (k = 0; k < P; k = k + 1) begin : g_lane
        localparam integer SRC = (DIR == 0) ? ((k - SH + P) % P) : ((k + SH) % P);
        assign st[j+1][k*W +: W] = r[j] ? st[j][SRC*W +: W] : st[j][k*W +: W];
    end
end
endgenerate
assign dout = st[RB];
endmodule
