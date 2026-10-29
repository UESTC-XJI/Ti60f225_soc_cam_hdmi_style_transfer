// Byte-addressed shared DDR layout.  The Sapphire linker keeps the normal
// firmware image in on-chip RAM at 0x1000..0x1FFFF; the DDR scratch window is
// reserved separately from the video banks.
`ifndef SOC_DDR_ADDRESS_MAP_SVH
`define SOC_DDR_ADDRESS_MAP_SVH
`define SOC_CPU_DDR_BASE       32'h0100_0000
`define SOC_CPU_DDR_LENGTH     32'h0010_0000
`define SOC_VIDEO_DDR_BASE     32'h0400_0000
// bank_switch adds a 0x200 guard/alignment gap to every frame stride.
`define SOC_VIDEO_FRAME_BYTES  32'h0038_4200 // payload 0x00384000 + guard
`define SOC_VIDEO_FRAME_COUNT  3
`define SOC_VIDEO_DDR_END      (`SOC_VIDEO_DDR_BASE + `SOC_VIDEO_FRAME_BYTES*`SOC_VIDEO_FRAME_COUNT)
`define SOC_DDR_AXI_DATA_BYTES 16
`endif
