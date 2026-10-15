// tx_plframer.v -- bit interleaver + mapper + PL framing (EN 302 307-1 5.4, 5.5).
//
// Output symbols are given as a 3-bit phase index k (symbol = A*exp(j*k*pi/4)),
// which covers pi/2-BPSK, QPSK, 8PSK, pilots and PL scrambling (multiplication
// by j^Rn = adding 2*Rn to k).
//
// Per PL frame:  PLHEADER (SOF + PLS code, 90 pi/2-BPSK symbols, not scrambled)
//                slots of 90 symbols with 36-symbol pilot blocks after every 16
//                slots (if pilots on), all scrambled by the Gold sequence n=0.
// If no codeword is ready at a frame boundary, a DUMMY PLFRAME is sent
// (MODCOD 0, 36 slots of unmodulated symbols).
`timescale 1ns/1ps
module tx_plframer (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    // codeword buffer
    output reg         cw_rbank,
    output reg  [13:0] cw_raddr,
    input  wire        cw_rdata,
    input  wire [1:0]  cw_full,
    input  wire [4:0]  cw_modcod0,
    input  wire [4:0]  cw_modcod1,
    input  wire        cw_pilots0,
    input  wire        cw_pilots1,
    output reg         cw_release,
    output reg         cw_rel_bank,      // bank released by cw_release
    // symbol output
    output reg  [2:0]  sym_k,
    output reg         sym_valid,
    input  wire        sym_ready,
    output reg         sym_sof,          // first symbol of a PL frame
    // status
    output reg  [31:0] frames_sent,
    output reg  [31:0] dummy_sent
);
// SOF 0x18D2E82, MSB first
localparam [25:0] SOF = 26'h18D2E82;
localparam [63:0] PLS_SCR = 64'h719D83C953422DFA;

// ---------------------------------------------------------------- frame parameters
reg  [4:0]  f_modcod;
reg         f_pilots, f_dummy, f_8psk;
reg  [3:0]  f_code;
wire        mm_valid, mm_8psk;
wire [3:0]  mm_code;
dvbs2_modcod_map u_map (.modcod(f_modcod), .valid(mm_valid), .is_8psk(mm_8psk), .code_id(mm_code));

// PLS code (64 bit) from the 7 signalling bits {MODCOD, TYPE}
wire [6:0]  plsc = f_dummy ? 7'd0 : {f_modcod, 1'b1 /*short*/, f_pilots};
reg  [31:0] rm;
always @(*) begin
    rm = 32'd0;
    if (plsc[6]) rm = rm ^ 32'h55555555;
    if (plsc[5]) rm = rm ^ 32'h33333333;
    if (plsc[4]) rm = rm ^ 32'h0F0F0F0F;
    if (plsc[3]) rm = rm ^ 32'h00FF00FF;
    if (plsc[2]) rm = rm ^ 32'h0000FFFF;
    if (plsc[1]) rm = rm ^ 32'hFFFFFFFF;
end
reg  [63:0] pls_bits;
integer i;
always @(*) begin
    for (i = 0; i < 32; i = i + 1) begin
        pls_bits[63 - 2*i] = rm[31 - i];
        pls_bits[62 - 2*i] = rm[31 - i] ^ plsc[0];
    end
    pls_bits = pls_bits ^ PLS_SCR;
end
reg  [89:0] hdr_bits;     // latched at frame start, MSB = first symbol

// ---------------------------------------------------------------- Gold scrambler
reg  [17:0] gx, gy;
wire gxa = ^(gx & 18'h08050);
wire gxb = ^(gx & 18'h00081);
wire gya = ^(gy & 18'h004A1);
wire gyb = ^(gy & 18'h0FF60);
wire [1:0] rn = {gxa ^ gyb, gx[0] ^ gy[0]};

// ---------------------------------------------------------------- counters
localparam P_IDLE = 3'd0, P_HDR = 3'd1, P_DATA = 3'd2, P_PILOT = 3'd3, P_FETCH = 3'd4;
reg  [2:0]  ph;
reg  [6:0]  hcnt;          // header symbol 0..89
reg  [6:0]  scnt;          // symbol in slot 0..89 / pilot 0..35
reg  [6:0]  slot;          // slot index
reg  [6:0]  nslots;
reg  [3:0]  slot16;
reg  [12:0] sidx;          // data symbol index (QPSK 0..8099, 8PSK 0..5399)
reg  [2:0]  fetch_k;       // symbol (unscrambled) waiting for output
reg         have_sym;      // fetch_k valid

// interleaver column offsets (8PSK): rate 3/5 reads columns 2,1,0 else 0,1,2
wire        rate35 = (f_code == 4'd4);
wire [13:0] col0 = rate35 ? 14'd10800 : 14'd0;
wire [13:0] col1 = 14'd5400;
wire [13:0] col2 = rate35 ? 14'd0 : 14'd10800;

// QPSK index (b0 b1) -> phase {1,7,3,5}; 8PSK index (b0 b1 b2) -> {1,0,4,5,2,7,3,6}
function [2:0] qpsk_k; input [1:0] b;
    case (b) 2'd0: qpsk_k = 3'd1; 2'd1: qpsk_k = 3'd7; 2'd2: qpsk_k = 3'd3; default: qpsk_k = 3'd5; endcase
endfunction
function [2:0] psk8_k; input [2:0] b;
    case (b) 3'd0: psk8_k = 3'd1; 3'd1: psk8_k = 3'd0; 3'd2: psk8_k = 3'd4; 3'd3: psk8_k = 3'd5;
             3'd4: psk8_k = 3'd2; 3'd5: psk8_k = 3'd7; 3'd6: psk8_k = 3'd3; default: psk8_k = 3'd6; endcase
endfunction

wire out_free = !sym_valid || sym_ready;

// codeword bit fetch: RAM address is registered here and inside the RAM, so the
// data for an address issued at edge n is captured at edge n+2.
reg  [2:0]  fs;            // fetch step
reg  [1:0]  fb;            // first two fetched bits
wire [12:0] nsym = f_8psk ? 13'd5400 : 13'd8100;
wire        fetch_ok = !f_dummy && (ph == P_HDR || ph == P_DATA || ph == P_PILOT);

always @(posedge clk) begin
    if (rst) begin
        ph <= P_IDLE; sym_valid <= 1'b0; sym_k <= 3'd0; sym_sof <= 1'b0; cw_release <= 1'b0; cw_rel_bank <= 1'b0;
        cw_rbank <= 1'b0; cw_raddr <= 14'd0; f_modcod <= 5'd0; f_pilots <= 1'b0; f_dummy <= 1'b1;
        f_8psk <= 1'b0; f_code <= 4'd0; hdr_bits <= 90'd0;
        gx <= 18'd1; gy <= 18'h3FFFF; hcnt <= 7'd0; scnt <= 7'd0; slot <= 7'd0; nslots <= 7'd0;
        slot16 <= 4'd0; sidx <= 13'd0; fetch_k <= 3'd0; have_sym <= 1'b0; fs <= 3'd0; fb <= 2'd0;
        frames_sent <= 32'd0; dummy_sent <= 32'd0;
    end else begin
        cw_release <= 1'b0;
        if (sym_valid && sym_ready) begin sym_valid <= 1'b0; sym_sof <= 1'b0; end

        // ---------- background fetch of the next data symbol's bits
        if (!fetch_ok) begin
            fs <= 3'd0;
        end else begin
            case (fs)
            3'd0: if (!have_sym && sidx < nsym) begin
                      cw_raddr <= f_8psk ? (col0 + {1'b0, sidx}) : {sidx, 1'b0};
                      fs <= 3'd1;
                  end
            3'd1: begin
                      cw_raddr <= f_8psk ? (col1 + {1'b0, sidx}) : {sidx, 1'b1};
                      fs <= 3'd2;
                  end
            3'd2: begin
                      fb[1] <= cw_rdata;
                      if (f_8psk) cw_raddr <= col2 + {1'b0, sidx};
                      fs <= 3'd3;
                  end
            3'd3: begin
                      if (f_8psk) begin
                          fb[0] <= cw_rdata;
                          fs <= 3'd4;
                      end else begin
                          fetch_k  <= qpsk_k({fb[1], cw_rdata});
                          have_sym <= 1'b1;
                          sidx     <= sidx + 13'd1;
                          fs       <= 3'd0;
                      end
                  end
            default: begin
                      fetch_k  <= psk8_k({fb[1], fb[0], cw_rdata});
                      have_sym <= 1'b1;
                      sidx     <= sidx + 13'd1;
                      fs       <= 3'd0;
                  end
            endcase
        end

        case (ph)
        P_IDLE: begin
            if (enable) begin
                // choose data frame or dummy frame
                if (cw_full[cw_rbank]) begin
                    f_modcod <= cw_rbank ? cw_modcod1 : cw_modcod0;
                    f_pilots <= cw_rbank ? cw_pilots1 : cw_pilots0;
                    f_dummy  <= 1'b0;
                end else begin
                    f_modcod <= 5'd0; f_pilots <= 1'b0; f_dummy <= 1'b1;
                end
                ph <= P_FETCH;
            end
        end
        P_FETCH: begin
            // parameters of the new frame are now valid
            f_8psk   <= mm_8psk;
            f_code   <= mm_code;
            nslots   <= f_dummy ? 7'd36 : (mm_8psk ? 7'd60 : 7'd90);
            hdr_bits <= {SOF, pls_bits};
            hcnt <= 7'd0; scnt <= 7'd0; slot <= 7'd0; slot16 <= 4'd0;
            sidx <= 13'd0; have_sym <= 1'b0;
            gx <= 18'd1; gy <= 18'h3FFFF;
            ph <= P_HDR;
        end
        P_HDR: begin
            if (out_free) begin
                // pi/2-BPSK: even index 0->1 1->5, odd index 0->3 1->7
                sym_k     <= hcnt[0] ? (hdr_bits[89] ? 3'd7 : 3'd3) : (hdr_bits[89] ? 3'd5 : 3'd1);
                sym_valid <= 1'b1;
                sym_sof   <= (hcnt == 7'd0);
                hdr_bits  <= {hdr_bits[88:0], 1'b0};
                hcnt      <= hcnt + 7'd1;
                if (hcnt == 7'd89) begin
                    ph <= P_DATA; scnt <= 7'd0; slot <= 7'd0;
                end
            end
        end
        P_DATA: begin
            if (out_free && (f_dummy || have_sym)) begin
                sym_k     <= (f_dummy ? 3'd1 : fetch_k) + {rn, 1'b0};
                sym_valid <= 1'b1;
                have_sym  <= 1'b0;
                gx <= {gxb, gx[17:1]};
                gy <= {gya, gy[17:1]};
                if (scnt == 7'd89) begin
                    scnt   <= 7'd0;
                    slot   <= slot + 7'd1;
                    slot16 <= slot16 + 4'd1;
                    if (slot == nslots - 7'd1) begin
                        ph <= P_IDLE;
                        if (!f_dummy) begin
                            cw_release  <= 1'b1;
                            cw_rel_bank <= cw_rbank;
                            cw_rbank    <= ~cw_rbank;
                            frames_sent <= frames_sent + 32'd1;
                        end else begin
                            dummy_sent  <= dummy_sent + 32'd1;
                        end
                    end else if (f_pilots && slot16 == 4'd15) begin
                        ph <= P_PILOT;
                    end
                end else begin
                    scnt <= scnt + 7'd1;
                end
            end
        end
        P_PILOT: begin
            if (out_free) begin
                sym_k     <= 3'd1 + {rn, 1'b0};
                sym_valid <= 1'b1;
                gx <= {gxb, gx[17:1]};
                gy <= {gya, gy[17:1]};
                if (scnt == 7'd35) begin
                    scnt <= 7'd0; ph <= P_DATA;
                end else begin
                    scnt <= scnt + 7'd1;
                end
            end
        end
        default: ph <= P_IDLE;
        endcase
    end
end
endmodule
