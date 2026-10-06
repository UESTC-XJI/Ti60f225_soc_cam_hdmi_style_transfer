`include "../defines.v"
// Unless otherwise specified, all "See X" references will refer to the HDMI v1.4a specification.

// See Section 5.3.4
// 2-channel L-PCM or IEC 61937 audio in IEC 60958 frames with consumer grade IEC 60958-3.
module audio_packet 
#(
    parameter CHANNEL_NUM = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_CHANNEL_NUM,
    // A thorough explanation of the below parameters can be found in IEC 60958-3 5.2, 5.3.

    // 0 = Consumer, 1 = Professional
    parameter bit GRADE = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_GRADE,

    // 0 = LPCM, 1 = IEC 61937 compressed
    parameter bit SAMPLE_WORD_TYPE = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_SAMPLE_WORD_TYPE,

    // 0 = asserted, 1 = not asserted
    parameter bit COPYRIGHT_NOT_ASSERTED = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_COPYRIGHT_NOT_ASSERTED,

    // 000 = no pre-emphasis, 001 = 50μs/15μs pre-emphasis
    parameter bit [`CFG_BITS_3-1:0] PRE_EMPHASIS = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_PRE_EMPHASIS,

    // Only one valid value
    parameter bit [`CFG_BITS_2-1:0] MODE = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_MODE,

    // Set to all 0s for general device.
    parameter bit [`CFG_BITS_8-1:0] CATEGORY_CODE = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_CATEGORY_CODE,

    // TODO: not really sure what this is...
    // 0 = "Do no take into account"
    parameter bit [`CFG_BITS_4-1:0] SOURCE_NUMBER = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_SOURCE_NUMBER,

    // 0000 = 44.1 kHz
    parameter bit [`CFG_BITS_4-1:0] SAMPLING_FREQUENCY = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_SAMPLING_FREQUENCY,

    // Normal accuracy: +/- 1000 * 10E-6 (00), High accuracy +/- 50 * 10E-6 (01)
    parameter bit [`CFG_BITS_2-1:0] CLOCK_ACCURACY = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_CLOCK_ACCURACY,

    // 3-bit representation of the number of bits to subtract (except 101 is actually subtract 0) with LSB first, followed by maxmium length of 20 bits (0) or 24 bits (1)
    parameter bit [`CFG_BITS_4-1:0] WORD_LENGTH = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_WORD_LENGTH,

    // Frequency prior to conversion in a consumer playback system. 0000 = not indicated.
    parameter bit [`CFG_BITS_4-1:0] ORIGINAL_SAMPLING_FREQUENCY = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_ORIGINAL_SAMPLING_FREQUENCY,

    // 2-channel = 0, >= 3-channel = 1
    parameter bit LAYOUT = `CFG_DVI_TX_AUDIO_PACKET_SV_PARAMETER_LAYOUT

)
(
    input wire clk,
    input wire rst_p,

    // See IEC 60958-1 4.4 and Annex A. 0 indicates the signal is suitable for decoding to an analog audio signal.
    input wire [`CFG_BITS_4-1:0] valid_bit_l,
    input wire [`CFG_BITS_4-1:0] valid_bit_r,
    // See IEC 60958-3 Section 6. 0 indicates that no user data is being sent
    input wire [`CFG_BITS_4-1:0] user_data_bit_l,
    input wire [`CFG_BITS_4-1:0] user_data_bit_r,
    input wire [`CFG_BITS_4-1:0] audio_word_length,
    input wire [`CFG_BITS_4-1:0] audio_sample_frequency,
    input wire       audio_valid,
    input wire [`CFG_BITS_24-1:0] audio_L0,
    input wire [`CFG_BITS_24-1:0] audio_L1,
    input wire [`CFG_BITS_24-1:0] audio_L2,
    input wire [`CFG_BITS_24-1:0] audio_L3,
    input wire [`CFG_BITS_24-1:0] audio_R0,
    input wire [`CFG_BITS_24-1:0] audio_R1,
    input wire [`CFG_BITS_24-1:0] audio_R2,
    input wire [`CFG_BITS_24-1:0] audio_R3,


    input wire [`CFG_BITS_4-1:0] audio_sample_word_present,

    output reg [`CFG_BITS_24-1:0] header,
    output reg [`CFG_BITS_56-1:0] sub0,
    output reg [`CFG_BITS_56-1:0] sub1,
    output reg [`CFG_BITS_56-1:0] sub2,
    output reg [`CFG_BITS_56-1:0] sub3,
    output reg pkt_valid
  
);

// Left/right channel for stereo audio
localparam  CHANNEL_LEFT = `CFG_DVI_TX_AUDIO_PACKET_SV_LOCALPARAM_CHANNEL_LEFT;
localparam  CHANNEL_RIGHT = `CFG_DVI_TX_AUDIO_PACKET_SV_LOCALPARAM_CHANNEL_RIGHT;
localparam  CHANNEL_STATUS_LENGTH = `CFG_DVI_TX_AUDIO_PACKET_SV_LOCALPARAM_CHANNEL_STATUS_LENGTH;
reg [`CFG_BITS_56-1:0] sub [`CFG_BITS_4-1:0];
wire [`CFG_BITS_24-1:0] w_header;
// See IEC 60958-1 5.1, Table 2
wire [`CFG_DVI_TX_AUDIO_PACKET_SV_RANGE_1] channel_status_left;
wire [`CFG_DVI_TX_AUDIO_PACKET_SV_RANGE_2] channel_status_right;
reg [`CFG_DVI_TX_AUDIO_PACKET_SV_RANGE_3] channel_status_left_r;
reg [`CFG_DVI_TX_AUDIO_PACKET_SV_RANGE_4] channel_status_right_r;
assign channel_status_left = {152'd0,
                                 ORIGINAL_SAMPLING_FREQUENCY, audio_word_length,//byte 4
                                2'b00,CLOCK_ACCURACY, audio_sample_frequency, //byte 3
                                CHANNEL_LEFT, SOURCE_NUMBER,              //byte 2
                                CATEGORY_CODE,                            //byte 1
                                 MODE, PRE_EMPHASIS, COPYRIGHT_NOT_ASSERTED, SAMPLE_WORD_TYPE, GRADE};//byte0
assign channel_status_right = {152'd0, 
                                ORIGINAL_SAMPLING_FREQUENCY, audio_word_length, //byte 4
                                2'b00,CLOCK_ACCURACY, audio_sample_frequency, //byte 3
                                CHANNEL_RIGHT, SOURCE_NUMBER,//byte 2
                                CATEGORY_CODE, //byte 1
                                 MODE, PRE_EMPHASIS, COPYRIGHT_NOT_ASSERTED, SAMPLE_WORD_TYPE, GRADE};//byte0


// See HDMI 1.4a Table 5-12: Audio Sample Packet Header.
assign w_header[19:12] = {4'b0000, {3'b000, LAYOUT}};
assign w_header[7:0] = 8'd2;
wire [`CFG_BITS_4-1:0] parity_bit_l;
wire [`CFG_BITS_4-1:0] parity_bit_r;
reg [`CFG_BITS_8-1:0] aligned_frame_counter [`CFG_BITS_4-1:0] = {8'd0,8'd0,8'd0,8'd0};
reg [`CFG_BITS_8-1:0] cnt = 'd0;
wire [`CFG_BITS_24-1:0] audio_R [`CFG_BITS_4-1:0];
wire [`CFG_BITS_24-1:0] audio_L [`CFG_BITS_4-1:0];

// initial begin
//     audio_R[0] = audio_R0;
//     audio_R[1] = audio_R1;
//     audio_R[2] = audio_R2;
//     audio_R[3] = audio_R3;

//     audio_L[0] = audio_L0;
//     audio_L[1] = audio_L1;
//     audio_L[2] = audio_L2;
//     audio_L[3] = audio_L3;

// end
assign audio_R[0] = audio_R0;
assign audio_R[1] = audio_R1;
assign audio_R[2] = audio_R2;
assign audio_R[3] = audio_R3;

assign audio_L[0] = audio_L0;
assign audio_L[1] = audio_L1;
assign audio_L[2] = audio_L2;
assign audio_L[3] = audio_L3;

always @( posedge clk or posedge rst_p )
begin
    if( rst_p )
        pkt_valid <= 1'b0;
    else 
        pkt_valid <= audio_valid;
end 

always @( posedge clk or posedge rst_p )
begin
    if( rst_p )
        cnt <= 'd0;
    else if( audio_valid )
        cnt <= (cnt >=CHANNEL_STATUS_LENGTH) ? 0 : cnt + CHANNEL_NUM/2;
end 
always @( posedge clk or posedge rst_p )
begin
    if( rst_p ) begin
        channel_status_left_r  <= 'd0;
        channel_status_right_r <= 'd0;
    end else if(cnt == 0 && audio_valid )begin
        channel_status_left_r  <= channel_status_left;
        channel_status_right_r <= channel_status_right;
    end else if( audio_valid ) begin
        channel_status_left_r  <= channel_status_left_r  >> CHANNEL_NUM/2;
        channel_status_right_r <= channel_status_right_r >> CHANNEL_NUM/2;
    end 
end

genvar i;
generate
    for (i = 0; i < 4; i++)
    begin: sample_based_assign
        always@(*)
        begin
            if (8'(cnt + i) >= CHANNEL_STATUS_LENGTH)
                aligned_frame_counter[i] = 8'(cnt + i - CHANNEL_STATUS_LENGTH);
            else
                aligned_frame_counter[i] = 8'(cnt + i);
        end
        assign w_header[23 - (3-i)] = aligned_frame_counter[i] == 8'd0 && audio_sample_word_present[i];
        assign w_header[11 - (3-i)] = audio_sample_word_present[i];
        assign parity_bit_l[i] = ^{channel_status_left_r[i], user_data_bit_l[i], valid_bit_l[i], audio_L[i]};
        assign parity_bit_r[i] = ^{channel_status_right_r[i], user_data_bit_r[i], valid_bit_r[i], audio_R[i]};
        // See HDMI 1.4a Table 5-13: Audio Sample Subpacket.
        always@(*)
        begin
            if (audio_sample_word_present[i])
                sub[i] = {{parity_bit_r[i], channel_status_right_r[i], user_data_bit_r[i], valid_bit_r[i], parity_bit_l[i], channel_status_left_r[i], user_data_bit_l[i], valid_bit_l[i]}, audio_R[i], audio_L[i]};
        end
    end
endgenerate
always @( posedge clk )
begin
    sub0 <= sub[0];
    sub1 <= sub[1];
    sub2 <= sub[2];
    sub3 <= sub[3];
    header <= w_header;
end 


endmodule
