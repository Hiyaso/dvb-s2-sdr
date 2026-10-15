// tx_shaper.v -- symbol -> I/Q mapping and RRC pulse shaping (interpolation by 2).
//
// On every sample strobe the FIR delay line receives either the next symbol
// (even sample) or zero (odd sample).  Symbol amplitude is AMP (Q1.15, radius).
`timescale 1ns/1ps
module tx_shaper #(
    parameter AMP = 16384            // 0.5 full scale
) (
    input  wire               clk,
    input  wire               rst,
    input  wire [1:0]         rolloff,
    input  wire               samp_stb,    // sample-rate strobe (2 per symbol)
    input  wire [2:0]         sym_k,
    input  wire               sym_valid,
    output wire               sym_ready,
    output wire               out_valid,
    output wire signed [15:0] out_i,
    output wire signed [15:0] out_q,
    output reg  [31:0]        underflows
);
localparam signed [15:0] A  = AMP;
localparam signed [15:0] AD = (AMP * 46341 + 32768) / 65536;   // AMP/sqrt(2)

reg phase;              // 0: symbol sample, 1: zero sample
reg signed [15:0] xi, xq;
reg               xv;
assign sym_ready = samp_stb && !phase;

always @(*) begin
    case (sym_k)
        3'd0: begin xi =  A;  xq = 16'sd0; end
        3'd1: begin xi =  AD; xq =  AD;    end
        3'd2: begin xi = 16'sd0; xq = A;   end
        3'd3: begin xi = -AD; xq =  AD;    end
        3'd4: begin xi = -A;  xq = 16'sd0; end
        3'd5: begin xi = -AD; xq = -AD;    end
        3'd6: begin xi = 16'sd0; xq = -A;  end
        default: begin xi = AD; xq = -AD;  end
    endcase
end

reg signed [15:0] fi, fq;
reg               fv;
always @(posedge clk) begin
    if (rst) begin
        phase <= 1'b0; fv <= 1'b0; fi <= 16'sd0; fq <= 16'sd0; underflows <= 32'd0;
    end else begin
        fv <= 1'b0;
        if (samp_stb) begin
            fv    <= 1'b1;
            phase <= ~phase;
            if (!phase) begin
                if (sym_valid) begin fi <= xi; fq <= xq; end
                else begin fi <= 16'sd0; fq <= 16'sd0; underflows <= underflows + 32'd1; end
            end else begin
                fi <= 16'sd0; fq <= 16'sd0;
            end
        end
    end
end

fir_sym33 #(.OUT_SHL(0)) u_fir (
    .clk(clk), .rst(rst), .rolloff(rolloff),
    .in_valid(fv), .in_i(fi), .in_q(fq),
    .out_valid(out_valid), .out_i(out_i), .out_q(out_q));
endmodule
