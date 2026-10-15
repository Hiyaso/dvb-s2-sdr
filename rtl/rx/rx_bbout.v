// rx_bbout.v -- BB descrambler, BBHEADER check, data field output and BER meter.
//
// Input : corrected (still BB-scrambled) BBFRAME bytes from bch_dec.
// Output: DATA FIELD bytes on an AXI-Stream style interface (tlast per frame).
// BER   : the data field is compared with a PRBS-23 (x^23+x^18+1) reference that is
//         re-synchronised at the start of every data field (first 23 bits).
`timescale 1ns/1ps
module rx_bbout (
    input  wire        clk,
    input  wire        rst,
    input  wire        clr_stats,
    input  wire        i_valid,
    input  wire [7:0]  i_data,
    output wire        i_ready,
    input  wire        i_first,
    input  wire        i_last,
    input  wire        i_fail,       // BCH failure (valid with i_last)
    // data field output
    output reg         m_valid,
    output reg  [7:0]  m_data,
    output reg         m_last,
    input  wire        m_ready,
    // status
    output reg  [31:0] frames_ok,
    output reg  [31:0] frames_crc_err,
    output reg  [31:0] frames_bch_fail,
    output reg  [15:0] last_dfl,
    output reg  [7:0]  last_matype,
    output reg  [47:0] ber_bits,
    output reg  [31:0] ber_errors,
    output reg         ber_locked
);
// ------------------------------------------------------------ BB descrambler
reg  [14:0] scr;
// 8 scrambler bits for one byte (MSB first) and next state
reg  [7:0]  sbyte;
reg  [14:0] snext;
reg   [14:0] s_tmp;
reg          sb;
always @(*) begin : comb1
    integer t;
    s_tmp = i_first ? 15'h4A80 : scr;
    for (t = 7; t >= 0; t = t - 1) begin
        sb = s_tmp[0] ^ s_tmp[1];
        sbyte[t] = sb;
        s_tmp = {sb, s_tmp[14:1]};
    end
    snext = s_tmp;
end
wire [7:0] d = i_data ^ sbyte;

assign i_ready = !m_valid || m_ready;
wire take = i_valid && i_ready;

// ------------------------------------------------------------ header parsing
reg  [3:0]  bidx;          // byte index within header (0..9), 10 = data
reg  [7:0]  crc;
reg  [7:0]  matype;
reg  [15:0] dfl;
reg  [12:0] dcnt;          // data bytes left in data field
reg         crc_bad;
function [7:0] crc8_byte; input [7:0] c; input [7:0] b;
    integer q; reg [7:0] r;
    begin
        r = c;
        for (q = 7; q >= 0; q = q - 1)
            r = {r[6:0], 1'b0} ^ ((r[7] ^ b[q]) ? 8'hD5 : 8'h00);
        crc8_byte = r;
    end
endfunction

// ------------------------------------------------------------ PRBS checker
// Re-synchronised at every BBFRAME (robust to frames dropped upstream): the first
// 23 data bits load the reference register, the rest of the data field is
// compared with the free-running PRBS.  ber_locked = last frame had < 1/64 errors.
reg  [22:0] ps;
reg  [4:0]  ldcnt;          // reference bits still to load (23 -> 0)
reg  [22:0] ps_n;
reg  [4:0]  ldcnt_n;
reg  [3:0]  nerr, nchk;
reg  [15:0] ferr, fbits;    // errors / checked bits in the current frame
reg         pb, rb;
reg         pa_v, pl_v, pl_v2;     // pending count update / end of frame (pipelined)
reg  [3:0]  pa_e, pa_c;
always @(*) begin : comb2
    integer t;
    ps_n = ps; ldcnt_n = ldcnt; nerr = 4'd0; nchk = 4'd0;
    for (t = 7; t >= 0; t = t - 1) begin
        rb = d[t];
        if (ldcnt_n != 5'd0) begin
            ps_n = {ps_n[21:0], rb};
            ldcnt_n = ldcnt_n - 5'd1;
        end else begin
            pb = ps_n[22] ^ ps_n[17];
            if (pb != rb) nerr = nerr + 4'd1;
            nchk = nchk + 4'd1;
            ps_n = {ps_n[21:0], pb};
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        scr <= 15'h4A80; bidx <= 4'd0; crc <= 8'd0; matype <= 8'd0; dfl <= 16'd0; dcnt <= 13'd0;
        crc_bad <= 1'b0; m_valid <= 1'b0; m_data <= 8'd0; m_last <= 1'b0;
        frames_ok <= 32'd0; frames_crc_err <= 32'd0; frames_bch_fail <= 32'd0;
        last_dfl <= 16'd0; last_matype <= 8'd0;
        ps <= 23'd0; ldcnt <= 5'd23; ferr <= 16'd0; fbits <= 16'd0;
        ber_bits <= 48'd0; ber_errors <= 32'd0; ber_locked <= 1'b0;
        pa_v <= 1'b0; pa_e <= 4'd0; pa_c <= 4'd0; pl_v <= 1'b0; pl_v2 <= 1'b0;
    end else begin
        // registered error / checked-bit counts of the previous data byte
        pa_v <= 1'b0;
        pl_v <= 1'b0;
        pl_v2 <= pl_v;
        if (pa_v) begin
            ferr  <= ferr + {12'd0, pa_e};
            fbits <= fbits + {12'd0, pa_c};
            if (!clr_stats) begin
                ber_bits   <= ber_bits + {44'd0, pa_c};
                ber_errors <= ber_errors + {28'd0, pa_e};
            end
        end
        if (pl_v2) ber_locked <= (fbits != 16'd0) && ({ferr, 6'd0} < {6'd0, fbits});
        if (clr_stats) begin
            frames_ok <= 32'd0; frames_crc_err <= 32'd0; frames_bch_fail <= 32'd0;
            ber_bits <= 48'd0; ber_errors <= 32'd0;
        end
        if (m_valid && m_ready) begin m_valid <= 1'b0; m_last <= 1'b0; end
        if (take) begin
            scr <= snext;
            if (i_first) begin
                bidx <= 4'd1; crc <= crc8_byte(8'd0, d); matype <= d;
            end else if (bidx < 4'd9) begin
                bidx <= bidx + 4'd1;
                crc  <= crc8_byte(crc, d);
                if (bidx == 4'd4) dfl[15:8] <= d;
                if (bidx == 4'd5) dfl[7:0]  <= d;
            end else if (bidx == 4'd9) begin
                bidx    <= 4'd10;
                crc_bad <= (crc != d);
                dcnt    <= dfl[15:3];
                ldcnt   <= 5'd23; ferr <= 16'd0; fbits <= 16'd0;
            end else begin
                // data field byte
                if (dcnt != 13'd0) begin
                    dcnt    <= dcnt - 13'd1;
                    m_valid <= 1'b1;
                    m_data  <= d;
                    m_last  <= (dcnt == 13'd1);
                    // BER measurement
                    ps <= ps_n; ldcnt <= ldcnt_n;
                    pa_v <= 1'b1; pa_e <= nerr; pa_c <= nchk;
                end
            end
            if (i_last) begin
                last_dfl <= dfl; last_matype <= matype;
                pl_v <= 1'b1;
                if (i_fail)       frames_bch_fail <= frames_bch_fail + 32'd1;
                else if (crc_bad) frames_crc_err  <= frames_crc_err + 32'd1;
                else              frames_ok       <= frames_ok + 32'd1;
            end
        end
    end
end
endmodule
