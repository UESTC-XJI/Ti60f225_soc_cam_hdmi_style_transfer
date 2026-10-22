`include "ddr_address_map.svh"
module ddr_address_map_check #(
  parameter logic [31:0] CPU_BASE=`SOC_CPU_DDR_BASE,
  parameter logic [31:0] CPU_LENGTH=`SOC_CPU_DDR_LENGTH,
  parameter logic [31:0] VIDEO_BASE=`SOC_VIDEO_DDR_BASE,
  parameter logic [31:0] FRAME_BYTES=`SOC_VIDEO_FRAME_BYTES,
  parameter integer FRAME_COUNT=`SOC_VIDEO_FRAME_COUNT
)(
  output logic valid,
  output logic [31:0] frame0,frame1,frame2,video_end
);
  always_comb begin
    frame0=VIDEO_BASE;
    frame1=VIDEO_BASE+FRAME_BYTES;
    frame2=VIDEO_BASE+2*FRAME_BYTES;
    video_end=VIDEO_BASE+FRAME_COUNT*FRAME_BYTES;
    valid = (CPU_BASE+CPU_LENGTH <= VIDEO_BASE) &&
            (VIDEO_BASE % `SOC_DDR_AXI_DATA_BYTES == 0) &&
            (FRAME_BYTES % `SOC_DDR_AXI_DATA_BYTES == 0) &&
            (frame0 < frame1) && (frame1 < frame2) && (frame2 < video_end);
  end
`ifndef SYNTHESIS
  initial begin
    if (!(CPU_BASE+CPU_LENGTH <= VIDEO_BASE)) $fatal(1,"CPU and video DDR windows overlap");
    if ((VIDEO_BASE % `SOC_DDR_AXI_DATA_BYTES) != 0) $fatal(1,"Video base is not AXI aligned");
    if ((VIDEO_BASE + FRAME_BYTES*FRAME_COUNT) > 32'h1000_0000) $fatal(1,"Video allocation exceeds 256 MiB DDR");
  end
`endif
endmodule
