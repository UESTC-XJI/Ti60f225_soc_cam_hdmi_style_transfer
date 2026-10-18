`include "../defines.v"

module packet_assembler (
    input wire clk,
    input wire rst_p,
    input wire data_island_period,
    input wire [`CFG_BITS_24-1:0] header, // See Table 5-8 Packet Types
    input wire [`CFG_BITS_56-1:0] sub0,
    input wire [`CFG_BITS_56-1:0] sub1,
    input wire [`CFG_BITS_56-1:0] sub2,
    input wire [`CFG_BITS_56-1:0] sub3,

    output wire packet_header,   
    output wire [`CFG_BITS_4-1:0] ch1_packet_data ,
    output wire [`CFG_BITS_4-1:0] ch2_packet_data,
    output reg  [`CFG_BITS_5-1:0] cnt
    
    // output wire [8:0] packet_data // See Figure 5-4 Data Island Packet and ECC Structure
);
wire [`CFG_BITS_56-1:0] sub [`CFG_BITS_4-1:0];

// BCH packets 0 to 3 are transferred two bits at a time, see Section 5.2.3.4 for further information.
wire [`CFG_BITS_6-1:0] counter_t2 = {cnt, 1'b0};
wire [`CFG_BITS_6-1:0] counter_t2_p1 = {cnt, 1'b1};

// Initialize parity bits to 0
reg [`CFG_BITS_8-1:0] parity [`CFG_BITS_5-1:0] = {8'd0, 8'd0, 8'd0, 8'd0, 8'd0};


wire [`CFG_BITS_64-1:0] bch [`CFG_BITS_4-1:0];

assign sub[0] = sub0;
assign sub[1] = sub1;
assign sub[2] = sub2;
assign sub[3] = sub3;

// 32 pixel wrap-around cnt. See Section 5.2.3.4 for further information.
always @(posedge clk)
begin
    if (rst_p)
        cnt <= 5'd0;
    else if (data_island_period)
        cnt <= cnt + 5'd1;
    else 
        cnt <= 'd0;
end

assign bch[0] = {parity[0], sub[0]};
assign bch[1] = {parity[1], sub[1]};
assign bch[2] = {parity[2], sub[2]};
assign bch[3] = {parity[3], sub[3]};
wire [`CFG_BITS_32-1:0] bch4 = {parity[4], header};
// assign packet_data = {bch[3][counter_t2_p1], bch[2][counter_t2_p1], bch[1][counter_t2_p1], bch[0][counter_t2_p1], bch[3][counter_t2], bch[2][counter_t2], bch[1][counter_t2], bch[0][counter_t2], bch4[cnt]};
assign packet_header   =  bch4[cnt];
assign ch1_packet_data = {bch[3][counter_t2]   , bch[2][counter_t2]   , bch[1][counter_t2]   , bch[0][counter_t2]   };
assign ch2_packet_data = {bch[3][counter_t2_p1], bch[2][counter_t2_p1], bch[1][counter_t2_p1], bch[0][counter_t2_p1]};


wire [`CFG_BITS_8-1:0] parity_next [`CFG_BITS_5-1:0];

// The parity needs to be calculated 2 bits at a time for blocks 0 to 3.
// There's 56 bits being sent 2 bits at a time over TMDS channels 1 & 2, so the parity bits wouldn't be ready in time otherwise.
wire [`CFG_BITS_8-1:0] parity_next_next [`CFG_BITS_4-1:0];

genvar i;
generate
    for(i = 0; i < 5; i++)
    begin: parity_calc
        if (i == 4)
            assign parity_next[i] = next_ecc(parity[i], header[cnt]);
        else
        begin
            assign parity_next[i] = next_ecc(parity[i], sub[i][counter_t2]);
            assign parity_next_next[i] = next_ecc(parity_next[i], sub[i][counter_t2_p1]);
        end
    end
endgenerate

always @(posedge clk)
begin
    if (rst_p)
        parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
    else if (data_island_period)
    begin
        if (cnt < 5'd28) // Compute ECC only on subpacket data, not on itself
        begin
            parity[3:0] <= parity_next_next;
            if (cnt < 5'd24) // Header only has 24 bits, whereas subpackets have 56 and 56 / 2 = 28.
                parity[4] <= parity_next[4];
        end
        else if (cnt == 5'd31)
            parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0}; // rst_p ECC for next packet
    end
    else
        parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
end



function [`CFG_BITS_8-1:0] next_ecc;
input [`CFG_BITS_8-1:0] ecc, next_bch_bit;
begin
    next_ecc = (ecc >> 1) ^ ((ecc[0] ^ next_bch_bit) ? 8'b10000011 : 8'd0);
end
endfunction

endmodule
