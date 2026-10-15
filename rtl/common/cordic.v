// cordic.v -- pipelined CORDIC units (16 iterations).
//
// Angles are 16-bit two's complement fractions of a full turn (32768 = pi).
//
// cordic_rot : (x, y) rotated by +ang.  Output gain is K = 1.64676 (not removed).
// cordic_vec : angle = atan2(y, x), mag = K * |(x, y)|.
// Both accept one input per clock (LAT = 18 clocks) and pass a user tag along.
`timescale 1ns/1ps
module cordic_rot #(
    parameter W  = 18,          // data width (inputs must leave 1 bit headroom for K)
    parameter TW = 1            // tag width
) (
    input  wire                clk,
    input  wire                in_v,
    input  wire signed [W-1:0] in_x,
    input  wire signed [W-1:0] in_y,
    input  wire        [15:0]  in_ang,
    input  wire        [TW-1:0] in_tag,
    output wire                out_v,
    output wire signed [W-1:0] out_x,
    output wire signed [W-1:0] out_y,
    output wire        [TW-1:0] out_tag
);
localparam N = 16;
// atan(2^-i) in units of 2^16 per turn
function [15:0] atanc; input integer i;
    case (i)
        0: atanc = 16'd8192;  1: atanc = 16'd4836;  2: atanc = 16'd2555;  3: atanc = 16'd1297;
        4: atanc = 16'd651;   5: atanc = 16'd326;   6: atanc = 16'd163;   7: atanc = 16'd81;
        8: atanc = 16'd41;    9: atanc = 16'd20;    10: atanc = 16'd10;   11: atanc = 16'd5;
        12: atanc = 16'd3;    13: atanc = 16'd1;    14: atanc = 16'd1;    default: atanc = 16'd0;
    endcase
endfunction
reg signed [W:0] xs [0:N];
reg signed [W:0] ys [0:N];
reg        [15:0] zs [0:N];
reg        [N:0]  vs;
reg        [TW-1:0] ts [0:N];
integer i;
// pre-rotation into [-pi/2, pi/2]
always @(posedge clk) begin
    vs[0] <= in_v;
    ts[0] <= in_tag;
    case (in_ang[15:14])
        2'b01: begin xs[0] <= -in_y; ys[0] <=  in_x; zs[0] <= in_ang - 16'h4000; end  // +90
        2'b10: begin xs[0] <=  in_y; ys[0] <= -in_x; zs[0] <= in_ang + 16'h4000; end  // -90 (ang in [-pi,-pi/2))
        default: begin xs[0] <= in_x; ys[0] <= in_y; zs[0] <= in_ang; end
    endcase
    // iterations (one process for the whole array: XST-friendly)
    for (i = 0; i < N; i = i + 1) begin
        vs[i+1] <= vs[i];
        ts[i+1] <= ts[i];
        if (!zs[i][15]) begin       // remaining angle >= 0: rotate +
            xs[i+1] <= xs[i] - (ys[i] >>> i);
            ys[i+1] <= ys[i] + (xs[i] >>> i);
            zs[i+1] <= zs[i] - atanc(i);
        end else begin
            xs[i+1] <= xs[i] + (ys[i] >>> i);
            ys[i+1] <= ys[i] - (xs[i] >>> i);
            zs[i+1] <= zs[i] + atanc(i);
        end
    end
end
reg signed [W-1:0] ox, oy;
reg ov; reg [TW-1:0] ot;
function signed [W-1:0] sat; input signed [W:0] v;
    sat = (v > $signed({2'b00, {(W-1){1'b1}}})) ? {1'b0, {(W-1){1'b1}}} :
          (v < -$signed({2'b00, {(W-1){1'b1}}})) ? {1'b1, {(W-2){1'b0}}, 1'b1} : v[W-1:0];
endfunction
always @(posedge clk) begin
    ov <= vs[N]; ot <= ts[N];
    ox <= sat(xs[N]); oy <= sat(ys[N]);
end
assign out_v = ov; assign out_x = ox; assign out_y = oy; assign out_tag = ot;
endmodule

module cordic_vec #(
    parameter W  = 24,
    parameter TW = 1
) (
    input  wire                clk,
    input  wire                in_v,
    input  wire signed [W-1:0] in_x,
    input  wire signed [W-1:0] in_y,
    input  wire        [TW-1:0] in_tag,
    output wire                out_v,
    output wire        [15:0]  out_ang,
    output wire        [W:0]   out_mag,     // K * magnitude
    output wire        [TW-1:0] out_tag
);
localparam N = 16;
function [15:0] atanc; input integer i;
    case (i)
        0: atanc = 16'd8192;  1: atanc = 16'd4836;  2: atanc = 16'd2555;  3: atanc = 16'd1297;
        4: atanc = 16'd651;   5: atanc = 16'd326;   6: atanc = 16'd163;   7: atanc = 16'd81;
        8: atanc = 16'd41;    9: atanc = 16'd20;    10: atanc = 16'd10;   11: atanc = 16'd5;
        12: atanc = 16'd3;    13: atanc = 16'd1;    14: atanc = 16'd1;    default: atanc = 16'd0;
    endcase
endfunction
reg signed [W+1:0] xs [0:N];
reg signed [W+1:0] ys [0:N];
reg        [15:0]  zs [0:N];
reg        [N:0]   vs;
reg        [TW-1:0] ts [0:N];
integer i;
always @(posedge clk) begin
    vs[0] <= in_v;
    ts[0] <= in_tag;
    if (in_x < 0) begin
        // rotate by +-90 so that x >= 0
        if (in_y >= 0) begin xs[0] <=  in_y; ys[0] <= -in_x; zs[0] <= 16'h4000; end
        else           begin xs[0] <= -in_y; ys[0] <=  in_x; zs[0] <= 16'hC000; end
    end else begin
        xs[0] <= in_x; ys[0] <= in_y; zs[0] <= 16'h0000;
    end
    for (i = 0; i < N; i = i + 1) begin
        vs[i+1] <= vs[i];
        ts[i+1] <= ts[i];
        if (ys[i] >= 0) begin       // rotate -
            xs[i+1] <= xs[i] + (ys[i] >>> i);
            ys[i+1] <= ys[i] - (xs[i] >>> i);
            zs[i+1] <= zs[i] + atanc(i);
        end else begin
            xs[i+1] <= xs[i] - (ys[i] >>> i);
            ys[i+1] <= ys[i] + (xs[i] >>> i);
            zs[i+1] <= zs[i] - atanc(i);
        end
    end
end
assign out_v = vs[N];
assign out_ang = zs[N];
assign out_mag = xs[N][W:0];
assign out_tag = ts[N];
endmodule
