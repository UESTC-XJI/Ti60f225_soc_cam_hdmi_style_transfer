`include "../defines.v"

module audio_infoframe_packet #(
    parameter bit [`CFG_BITS_3-1:0] AUDIO_CHANNEL_COUNT = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_PARAMETER_AUDIO_CHANNEL_COUNT, // 2 channels. See CEA-861-D table 17 for details.
    parameter bit [`CFG_BITS_8-1:0] CHANNEL_ALLOCATION = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_PARAMETER_CHANNEL_ALLOCATION, // Channel 0 = Front Left, Channel 1 = Front Right (0-indexed)
    parameter bit DOWN_MIX_INHIBITED = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_PARAMETER_DOWN_MIX_INHIBITED, // Permitted or no information about any assertion of this. The DM_INH field is to be set only for DVD-Audio applications.
    parameter bit [`CFG_BITS_4-1:0] LEVEL_SHIFT_VALUE = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_PARAMETER_LEVEL_SHIFT_VALUE, // 4-bit unsigned number from 0dB up to 15dB, used for downmixing.
    parameter bit [`CFG_BITS_2-1:0] LOW_FREQUENCY_EFFECTS_PLAYBACK_LEVEL = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_PARAMETER_LOW_FREQUENCY_EFFECTS_PLAYBACK_LEVEL // No information, LFE = bass-only info < 120Hz, used in Dolby Surround.
)
(
    output logic [`CFG_BITS_24-1:0] header,
 
    output logic [`CFG_BITS_56-1:0] sub0,
    output logic [`CFG_BITS_56-1:0] sub1,
    output logic [`CFG_BITS_56-1:0] sub2,
    output logic [`CFG_BITS_56-1:0] sub3
);

// NOTE—HDMI requires the coding type, sample size and sample frequency fields to be set to 0 ("Refer to Stream Header") as these items are carried in the audio stream
localparam bit [`CFG_BITS_4-1:0] AUDIO_CODING_TYPE = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_LOCALPARAM_AUDIO_CODING_TYPE; // Refer to stream header.
localparam bit [`CFG_BITS_3-1:0] SAMPLING_FREQUENCY = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_LOCALPARAM_SAMPLING_FREQUENCY; // Refer to stream header.
localparam bit [`CFG_BITS_2-1:0] SAMPLE_SIZE = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_LOCALPARAM_SAMPLE_SIZE; // Refer to stream header.

localparam bit [`CFG_BITS_5-1:0] LENGTH     = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_LOCALPARAM_LENGTH;
localparam bit [`CFG_BITS_8-1:0] VERSION    = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_LOCALPARAM_VERSION;
localparam bit [`CFG_BITS_7-1:0] TYPE       = `CFG_DVI_TX_AUDIO_INFOFRAME_PACKET_SV_LOCALPARAM_TYPE;

assign header = {{3'b0, LENGTH}, VERSION, TYPE};

// PB0-PB6 = sub0
// PB7-13 =  sub1
// PB14-20 = sub2
// PB21-27 = sub3
logic [`CFG_BITS_8-1:0] packet_bytes [`CFG_BITS_28-1:0];
logic [`CFG_BITS_56-1:0] sub [`CFG_BITS_4-1:0];
assign packet_bytes[0] = 8'd1 + ~(header[23:16] + header[15:8] + header[7:0] + packet_bytes[5] + packet_bytes[4] + packet_bytes[3] + packet_bytes[2] + packet_bytes[1]);
assign packet_bytes[1] = {AUDIO_CODING_TYPE, 1'b0, AUDIO_CHANNEL_COUNT};
assign packet_bytes[2] = {3'd0, SAMPLING_FREQUENCY, SAMPLE_SIZE};
assign packet_bytes[3] = 8'd0;
assign packet_bytes[4] = CHANNEL_ALLOCATION;
assign packet_bytes[5] = {DOWN_MIX_INHIBITED, LEVEL_SHIFT_VALUE, 1'b0, LOW_FREQUENCY_EFFECTS_PLAYBACK_LEVEL};

genvar i;
generate
    for (i = 6; i < 28; i++)
    begin: pb_reserved
        assign packet_bytes[i] = 8'd0;
    end
    for (i = 0; i < 4; i++)
    begin: pb_to_sub
        assign sub[i] = {packet_bytes[6 + i*7], packet_bytes[5 + i*7], packet_bytes[4 + i*7], packet_bytes[3 + i*7], packet_bytes[2 + i*7], packet_bytes[1 + i*7], packet_bytes[0 + i*7]};
    end
endgenerate
assign sub0 = sub[0];
assign sub1 = sub[1];
assign sub2 = sub[2];
assign sub3 = sub[3];

endmodule