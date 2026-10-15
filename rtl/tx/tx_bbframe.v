// tx_bbframe.v -- DVB-S2 mode/stream adaptation: BBHEADER + DATA FIELD, BB scrambling.
//
// Generic Continuous Stream, single input stream, CCM (EN 302 307-1 5.1, 5.2).
// One BBFRAME of Kbch bits is produced after each `start` pulse, one bit per
// accepted out_valid/out_ready handshake, MSB first:
//   MATYPE-1, MATYPE-2, UPL(=0), DFL(=Kbch-80), SYNC(=0), SYNCD(=0), CRC-8, DATA
// The whole frame is XORed with the BB scrambler PRBS (1+X^14+X^15).
// Data source: PRBS-23 (x^23+x^18+1, free running across frames) or AXI-Stream
// bytes (MSB first); in stream mode the frame stalls while tvalid is low.
`timescale 1ns/1ps
module tx_bbframe (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,         // begin a new BBFRAME (ignored while busy)
    input  wire [13:0] kbch,
    input  wire [1:0]  rolloff,       // 0:0.35 1:0.25 2:0.20
    input  wire        src_stream,    // 0: PRBS-23, 1: s_axis bytes
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output wire        out_bit,
    output wire        out_valid,
    input  wire        out_ready,
    output reg         busy
);
reg  [13:0] cnt;            // bit index within frame
reg  [13:0] kb;
reg  [71:0] hdr;            // remaining header bits (MSB = next)
reg  [7:0]  crc;
reg  [14:0] scr;            // BB scrambler state
reg  [22:0] prbs;
reg  [7:0]  sbyte;
reg  [2:0]  sbit;
reg         sbyte_valid;

wire in_hdr  = (cnt < 14'd72);
wire in_crc  = (cnt >= 14'd72) && (cnt < 14'd80);
wire in_data = (cnt >= 14'd80);

// data source
wire prbs_bit   = prbs[22] ^ prbs[17];
wire data_avail = src_stream ? sbyte_valid : 1'b1;
wire data_bit   = src_stream ? sbyte[7] : prbs_bit;

wire raw_bit = in_hdr ? hdr[71] : (in_crc ? crc[7] : data_bit);
wire scr_bit = scr[0] ^ scr[1];
assign out_bit   = raw_bit ^ scr_bit;
assign out_valid = busy && (!in_data || data_avail);
wire   fire      = out_valid && out_ready;

// byte fetch: load a new byte when the register is empty
assign s_axis_tready = src_stream && busy && in_data && !sbyte_valid;

wire [7:0] matype1 = {2'b01, 1'b1, 1'b1, 1'b0, 1'b0, (rolloff == 2'd1) ? 2'b01 :
                      (rolloff == 2'd2) ? 2'b10 : 2'b00};
wire [15:0] dfl = kbch - 14'd80;

always @(posedge clk) begin
    if (rst) begin
        busy <= 1'b0; cnt <= 14'd0; kb <= 14'd0; hdr <= 72'd0; crc <= 8'd0;
        scr <= 15'h4A80; prbs <= 23'h7FFFFF; sbyte <= 8'd0; sbit <= 3'd0; sbyte_valid <= 1'b0;
    end else begin
        if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                cnt  <= 14'd0;
                kb   <= kbch;
                hdr  <= {matype1, 8'h00, 16'h0000, dfl, 8'h00, 16'h0000};
                crc  <= 8'd0;
                scr  <= 15'h4A80;
            end
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                sbyte <= s_axis_tdata; sbit <= 3'd0; sbyte_valid <= 1'b1;
            end
            if (fire) begin
                // BB scrambler
                scr <= {scr_bit, scr[14:1]};
                if (in_hdr) begin
                    hdr <= {hdr[70:0], 1'b0};
                    crc <= {crc[6:0], 1'b0} ^ ((crc[7] ^ hdr[71]) ? 8'hD5 : 8'h00);
                end else if (in_crc) begin
                    crc <= {crc[6:0], 1'b0};
                end else begin
                    if (src_stream) begin
                        sbyte <= {sbyte[6:0], 1'b0};
                        sbit  <= sbit + 3'd1;
                        if (sbit == 3'd7) sbyte_valid <= 1'b0;
                    end else begin
                        prbs <= {prbs[21:0], prbs_bit};
                    end
                end
                if (cnt == kb - 14'd1) busy <= 1'b0;
                cnt <= cnt + 14'd1;
            end
        end
    end
end
endmodule
