`include "../defines.v"
module audio_clock_regeneration_packet #(
    parameter real VIDEO_RATE = `CFG_DVI_TX_AUDIO_CLOCK_REGENERATION_PACKET_SV_PARAMETER_VIDEO_RATE,
    parameter TIME_CNT = `CFG_DVI_TX_AUDIO_CLOCK_REGENERATION_PACKET_SV_PARAMETER_TIME_CNT
)(
    input logic clk,
    input logic clk_audio,
    input logic [`CFG_BITS_20-1:0] N ,
    input logic [`CFG_BITS_20-1:0] CTS,
    output logic [`CFG_BITS_24-1:0] header,
    output logic [`CFG_BITS_56-1:0] sub0,
    output logic [`CFG_BITS_56-1:0] sub1,
    output logic [`CFG_BITS_56-1:0] sub2,
    output logic [`CFG_BITS_56-1:0] sub3,
    output logic pkt_valid
);
logic [`CFG_BITS_56-1:0] sub [`CFG_BITS_4-1:0];
genvar i;
generate
    for (i = 0; i < 4; i++)
    begin: same_packet
        assign sub[i] = {N[7:0], N[15:8], {4'd0, N[19:16]}, CTS[7:0], CTS[15:8], {4'd0, CTS[19:16]}, 8'd0};
    end
endgenerate

assign sub0 = sub[0];
assign sub1 = sub[1];
assign sub2 = sub[2];
assign sub3 = sub[3];


// `ifdef MODEL_TECH
assign header = {8'd0, 8'd0, 8'd1};
// `else
// assign header = {8'dX, 8'dX, 8'd1};
// `endif
reg [`CFG_BITS_24-1:0] cnt = 'd0;
always @( posedge clk )
begin
    if( cnt == TIME_CNT-1)
        cnt <= 0;
    else 
        cnt <= cnt + 1'b1;
end 
always @( posedge clk )
begin
    pkt_valid <= cnt == TIME_CNT-1;
end 

endmodule
