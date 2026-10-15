// rx_demap.v -- soft demapper (QPSK / 8PSK max-log) and LLR stream to ldpc_dec.
//
// Input symbols are phase/amplitude corrected and PL-descrambled with a nominal
// constellation radius of 4096 (Q3.12).  LLR convention: positive => bit '0'.
//   QPSK : L(b0) = I*scale >> 12,  L(b1) = Q*scale >> 12
//   8PSK : L(b)  = (max_{s:b=0} Re{y s*} - max_{s:b=1} Re{y s*}) * scale >> 12
// 8PSK bit b of symbol j belongs to interleaver column order[b]; the LLR is sent
// on loader stream order[b] (order = 2,1,0 for rate 3/5, else 0,1,2).
// Pipeline: accept -> projections -> max-log -> scaling -> 2 or 3 LLR outputs
// (about 7 clocks per symbol; symbols arrive every >= 16 clocks).
`timescale 1ns/1ps
module rx_demap (
    input  wire               clk,
    input  wire               rst,
    input  wire [7:0]         scale_qpsk,     // default 24
    input  wire [7:0]         scale_8psk,     // default 16
    // symbols
    input  wire               s_valid,
    output wire               s_ready,
    input  wire signed [15:0] s_i,
    input  wire signed [15:0] s_q,
    input  wire               s_first,        // first data symbol of a frame
    input  wire               s_last,         // last data symbol of a frame
    input  wire [3:0]         s_code,
    input  wire               s_8psk,
    input  wire [15:0]        s_meta,
    // LLR loader interface (ldpc_dec)
    output reg                ld_start,
    output reg  [3:0]         ld_code,
    output reg  [15:0]        ld_meta,
    output reg                ld_valid,
    output reg  [1:0]         ld_stream,
    output reg  signed [6:0]  ld_llr,
    output reg                ld_end
);
function signed [6:0] sat7;
    input signed [31:0] v;
    sat7 = (v > 63) ? 7'sd63 : (v < -63) ? -7'sd63 : v[6:0];
endfunction
function [2:0] k_of; input [2:0] idx;   // bit pattern -> phase k (pi/4)
    case (idx) 3'd0: k_of = 3'd1; 3'd1: k_of = 3'd0; 3'd2: k_of = 3'd4; 3'd3: k_of = 3'd5;
               3'd4: k_of = 3'd2; 3'd5: k_of = 3'd7; 3'd6: k_of = 3'd3; default: k_of = 3'd6; endcase
endfunction
function signed [17:0] mx; input signed [17:0] a, b; mx = (a > b) ? a : b; endfunction

localparam P_IDLE = 3'd0, P_PROJ = 3'd1, P_MAX = 3'd2, P_SCL = 3'd3, P_OUT = 3'd4, P_END = 3'd5,
           P_SUM = 3'd6, P_DIF = 3'd7;
reg  [2:0]  ps;
reg  signed [17:0] ri, rq;
reg         r8, rlast, r35;
reg  signed [17:0] pr [0:7];
reg  signed [17:0] dl0, dl1, dl2;
reg  signed [6:0]  l0, l1, l2;
reg  [1:0]  cnt;
assign s_ready = (ps == P_IDLE);

// projections: sums registered in P_SUM, products in P_PROJ
reg  signed [17:0] sIQ, dIQ;
wire signed [35:0] m_s = sIQ * 18'sd23170;     // 1/sqrt(2), Q15
wire signed [35:0] m_d = dIQ * 18'sd23170;
// max-log: for bit b the 4 points with bit = 0 / bit = 1, balanced max trees
// (registered in P_MAX), differences in P_DIF
reg  signed [17:0] mz [0:2];
reg  signed [17:0] mo [0:2];
reg  signed [17:0] mzr [0:2];
reg  signed [17:0] mor [0:2];
always @(*) begin : maxlog
    integer b, x, nz, no;
    reg signed [17:0] vz [0:3];
    reg signed [17:0] vo [0:3];
    for (b = 0; b < 3; b = b + 1) begin
        nz = 0; no = 0;
        for (x = 0; x < 8; x = x + 1) begin
            if (((x >> (2 - b)) & 1) == 0) begin vz[nz] = pr[k_of(x)]; nz = nz + 1; end
            else                           begin vo[no] = pr[k_of(x)]; no = no + 1; end
        end
        mz[b] = mx(mx(vz[0], vz[1]), mx(vz[2], vz[3]));
        mo[b] = mx(mx(vo[0], vo[1]), mx(vo[2], vo[3]));
    end
end
wire signed [31:0] q0 = (ri * $signed({1'b0, scale_qpsk})) >>> 12;
wire signed [31:0] q1 = (rq * $signed({1'b0, scale_qpsk})) >>> 12;
wire signed [31:0] e0 = (dl0 * $signed({1'b0, scale_8psk})) >>> 12;
wire signed [31:0] e1 = (dl1 * $signed({1'b0, scale_8psk})) >>> 12;
wire signed [31:0] e2 = (dl2 * $signed({1'b0, scale_8psk})) >>> 12;

always @(posedge clk) begin
    if (rst) begin
        ps <= P_IDLE; cnt <= 2'd0; ld_start <= 1'b0; ld_valid <= 1'b0; ld_end <= 1'b0;
        ld_code <= 4'd0; ld_meta <= 16'd0; ld_stream <= 2'd0; ld_llr <= 7'sd0;
        ri <= 0; rq <= 0; r8 <= 1'b0; rlast <= 1'b0; r35 <= 1'b0;
        l0 <= 0; l1 <= 0; l2 <= 0; dl0 <= 0; dl1 <= 0; dl2 <= 0;
    end else begin
        ld_start <= 1'b0;
        ld_valid <= 1'b0;
        ld_end   <= 1'b0;
        case (ps)
        P_IDLE: if (s_valid) begin
            if (s_first) begin
                ld_start <= 1'b1; ld_code <= s_code; ld_meta <= s_meta;
            end
            ri <= s_i; rq <= s_q; r8 <= s_8psk; rlast <= s_last; r35 <= (s_code == 4'd4);
            ps <= P_SUM;
        end
        P_SUM: begin
            sIQ <= ri + rq; dIQ <= ri - rq;
            ps <= P_PROJ;
        end
        P_PROJ: begin
            pr[0] <= ri;  pr[1] <= m_s >>> 15;  pr[2] <= rq;  pr[3] <= -(m_d >>> 15);
            pr[4] <= -ri; pr[5] <= -(m_s >>> 15); pr[6] <= -rq; pr[7] <= m_d >>> 15;
            ps <= P_MAX;
        end
        P_MAX: begin
            mzr[0] <= mz[0]; mzr[1] <= mz[1]; mzr[2] <= mz[2];
            mor[0] <= mo[0]; mor[1] <= mo[1]; mor[2] <= mo[2];
            ps <= P_DIF;
        end
        P_DIF: begin
            dl0 <= mzr[0] - mor[0]; dl1 <= mzr[1] - mor[1]; dl2 <= mzr[2] - mor[2];
            ps <= P_SCL;
        end
        P_SCL: begin
            if (r8) begin l0 <= sat7(e0); l1 <= sat7(e1); l2 <= sat7(e2); end
            else    begin l0 <= sat7(q0); l1 <= sat7(q1); l2 <= 7'sd0; end
            cnt <= 2'd0;
            ps <= P_OUT;
        end
        P_OUT: begin
            ld_valid <= 1'b1;
            case (cnt)
                2'd0: begin ld_llr <= l0; ld_stream <= r8 ? (r35 ? 2'd2 : 2'd0) : 2'd0; end
                2'd1: begin ld_llr <= l1; ld_stream <= r8 ? 2'd1 : 2'd0; end
                default: begin ld_llr <= l2; ld_stream <= r35 ? 2'd0 : 2'd2; end
            endcase
            cnt <= cnt + 2'd1;
            if ((r8 && cnt == 2'd2) || (!r8 && cnt == 2'd1))
                ps <= rlast ? P_END : P_IDLE;
        end
        P_END: begin
            ld_end <= 1'b1;
            ps <= P_IDLE;
        end
        default: ps <= P_IDLE;
        endcase
    end
end
endmodule
