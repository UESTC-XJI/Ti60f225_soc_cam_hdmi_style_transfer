`include "defines.v"

/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//Ti60f225_sc431hai2hdmi_v6：
//使用了最新版本的framebuffer_v3;
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
// Include ISP modules here so GUI project-file saves cannot drop their sources.
// Included modules should not also be added as separate project design files.
`include "isp/isp_cdc_mailbox.v"
`include "isp/ae_frame_stats.v"
`include "isp/luma_color_suppress.v"
`include "isp/luma_tone_map.v"
`include "isp/hdmi_frame_histogram.v"
`include "isp/hdmi_info_overlay.v"
`include "soc_integration/osd_font8x16.sv"
`include "soc_integration/hdmi_startup_colorbar.sv"
`include "soc_integration/video_frame_diagnostics.sv"
`include "soc_integration/video_cfg_cdc.sv"
`include "isp/capture_frame_stats.sv"
`include "soc_integration/video_apb_ctrl.sv"
// `include "define.v"

module ti60f225_oob_top #(

	parameter                       RANK_RATIO         = `CFG_TI60F225_OOB_TOP_V_PARAMETER_RANK_RATIO,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `CFG_TI60F225_OOB_TOP_V_PARAMETER_ASYN_AXI_CLK,
	parameter                       RANKS              = `CFG_TI60F225_OOB_TOP_V_PARAMETER_RANKS,
	parameter                       CK_WIDTH           = `CFG_TI60F225_OOB_TOP_V_PARAMETER_CK_WIDTH,       // # of CK/CK# outputs to memory
	parameter                       CKE_WIDTH          = `CFG_TI60F225_OOB_TOP_V_PARAMETER_CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CFG_TI60F225_OOB_TOP_V_PARAMETER_CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `CFG_TI60F225_OOB_TOP_V_PARAMETER_BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `CFG_TI60F225_OOB_TOP_V_PARAMETER_ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `CFG_TI60F225_OOB_TOP_V_PARAMETER_COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `CFG_TI60F225_OOB_TOP_V_PARAMETER_ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))
	parameter                       DRAM_WIDTH         = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DRAM_WIDTH,       // # of DQ per DQS
	parameter                       DATA_WIDTH         = `CFG_TI60F225_OOB_TOP_V_PARAMETER_DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `CFG_TI60F225_OOB_TOP_V_PARAMETER_ADDR_WIDTH,
	parameter                       AXI_ID_WIDTH       = `CFG_TI60F225_OOB_TOP_V_PARAMETER_AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `CFG_TI60F225_OOB_TOP_V_PARAMETER_AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `CFG_TI60F225_OOB_TOP_V_PARAMETER_AXI_DATA_WIDTH
)
(

  (* syn_peri_port = 0 *) input jtag_inst1_CAPTURE,
  (* syn_peri_port = 0 *) input jtag_inst1_DRCK,
  (* syn_peri_port = 0 *) input jtag_inst1_RESET,
  (* syn_peri_port = 0 *) input jtag_inst1_RUNTEST,
  (* syn_peri_port = 0 *) input jtag_inst1_SEL,
  (* syn_peri_port = 0 *) input jtag_inst1_SHIFT,
  (* syn_peri_port = 0 *) input jtag_inst1_TCK,
  (* syn_peri_port = 0 *) input jtag_inst1_TDI,
  (* syn_peri_port = 0 *) input jtag_inst1_TMS,
  (* syn_peri_port = 0 *) input jtag_inst1_UPDATE,
  (* syn_peri_port = 0 *) output jtag_inst1_TDO,

  input wire system_uart_0_io_rxd,
  output wire system_uart_0_io_txd,
  input wire system_spi_0_io_data_0_IN,
  input wire system_spi_0_io_data_1_IN,
  output wire system_spi_0_io_ss,
  output wire system_spi_0_io_sclk_write,
  output wire system_spi_0_io_data_0_OUT,
  output wire system_spi_0_io_data_0_OE,
  output wire system_spi_0_io_data_1_OUT,
  output wire system_spi_0_io_data_1_OE,

   //Clocks
	input	wire	i_arstn,
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,

    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,

    input	wire	[`CFG_BITS_8-1:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,

    input 	wire	[`CFG_BITS_8-1:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,

    input 	wire	[`CFG_BITS_8-1:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,

    input 	wire	[`CFG_BITS_8-1:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,


	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // CORE CLK @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags
	output [`CFG_BITS_3-1:0]                       pll_shift,
	output [`CFG_BITS_5-1:0]                       pll_shift_sel,
	output                             pll_shift_ena,
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_1]             ddr_cke,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_2]             ddr_addr,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_3]            ddr_ba,
	output                             ddr_cas_n,

	output [`CFG_TI60F225_OOB_TOP_V_RANGE_4]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,

	input  [`CFG_TI60F225_OOB_TOP_V_RANGE_5]             ddr_dqs_in_hi,
	input  [`CFG_TI60F225_OOB_TOP_V_RANGE_6]             ddr_dqs_in_lo,
	input  [`CFG_TI60F225_OOB_TOP_V_RANGE_7]              ddr_dq_in_hi,
	input  [`CFG_TI60F225_OOB_TOP_V_RANGE_8]              ddr_dq_in_lo,

	output [`CFG_TI60F225_OOB_TOP_V_RANGE_9]             ddr_dqs_oe,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_10]             ddr_dqs_oe_n,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_11]              ddr_dq_oe,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_12]             ddr_dqs_out_hi,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_13]             ddr_dqs_out_lo,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_14]              ddr_dq_out_hi,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_15]              ddr_dq_out_lo,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_16]              ddr_dm_hi,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_17]              ddr_dm_lo,
	output [`CFG_TI60F225_OOB_TOP_V_RANGE_18]             ddr_odt,

       //LED
       output [`CFG_BITS_8-1:0] led,

       /* MIPI DSI and LCD ports are intentionally removed from this HDMI-only build.
       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,
       output	wire	                     mipi_dp_clk_LP_P_OUT		,
       output	wire	                     mipi_dp_clk_LP_N_OUT		,
       output	wire	[`CFG_BITS_8-1:0] 	              mipi_dp_clk_HS_OUT		,
       output	wire	                     mipi_dp_clk_HS_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OUT	,
       output	wire	                     mipi_dp_data2_LP_P_OUT	,
       output	wire	                     mipi_dp_data1_LP_P_OUT	,
       output	wire	                     mipi_dp_data0_LP_P_OUT	,
       output	wire	                     mipi_dp_data3_LP_N_OUT	,
       output	wire	                     mipi_dp_data2_LP_N_OUT	,
       output	wire	                     mipi_dp_data1_LP_N_OUT	,
       output	wire	                     mipi_dp_data0_LP_N_OUT	,
       output	wire	[`CFG_BITS_8-1:0] 	              mipi_dp_data0_HS_OUT	       ,
       output	wire	[`CFG_BITS_8-1:0] 	              mipi_dp_data1_HS_OUT	       ,
       output	wire	[`CFG_BITS_8-1:0] 	              mipi_dp_data2_HS_OUT	       ,
       output	wire	[`CFG_BITS_8-1:0] 	              mipi_dp_data3_HS_OUT	       ,
       output	wire	                     mipi_dp_data3_HS_OE		,
       output	wire	                     mipi_dp_data2_HS_OE		,
       output	wire	                     mipi_dp_data1_HS_OE		,
       output	wire	                     mipi_dp_data0_HS_OE		,

       output	wire	                     mipi_dp_clk_RST		,
       output	wire	                     mipi_dp_data0_RST		,
       output	wire	                     mipi_dp_data1_RST		,
       output	wire	                     mipi_dp_data2_RST		,
       output	wire	                     mipi_dp_data3_RST		,
       output	wire	                     mipi_dp_clk_LP_P_OE		,
       output	wire	                     mipi_dp_clk_LP_N_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OE	,
       output	wire	                     mipi_dp_data3_LP_N_OE	,
       output	wire	                     mipi_dp_data2_LP_P_OE	,
       output	wire	                     mipi_dp_data2_LP_N_OE	,
       output	wire	                     mipi_dp_data1_LP_P_OE	,
       output	wire	                     mipi_dp_data1_LP_N_OE	,
       output	wire	                     mipi_dp_data0_LP_P_OE	,
       output	wire	                     mipi_dp_data0_LP_N_OE	,

       input  wire	                     mipi_dp_data0_LP_P_IN	,
       input  wire	                     mipi_dp_data0_LP_N_IN	,
       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,
       */

       // hdmi interface

    output tmds_tx_clk_TX_OE,
    output [`CFG_BITS_10-1:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [`CFG_BITS_10-1:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [`CFG_BITS_10-1:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [`CFG_BITS_10-1:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST


);

function integer log2;
	input	integer	val;
	integer	i;
	begin
		log2 = 0;
		for (i=0; 2**i<val; i=i+1)
			log2 = i+1;
	end
endfunction


//===============================================================================
//localparam
//===============================================================================
localparam WR_FIFO_DEPTH  = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_WR_FIFO_DEPTH;
localparam RD_FIFO_DEPTH  = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_RD_FIFO_DEPTH;

// localparam	MAX_HRES		= 12'd1920;
// localparam	MAX_VRES		= 12'd1080;
// localparam	HSP			= 8'd2;
// localparam	HBP			= 8'd88;
// localparam	HFP			= 8'd120;
// localparam	VSP			= 8'd2;
// localparam	VBP			= 8'd20;
// localparam	VFP			= 8'd20;

localparam SOURCE_WIDTH = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_SOURCE_WIDTH;
localparam SOURCE_HEIGHT = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_SOURCE_HEIGHT;
localparam HACT     = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_HACT;
localparam HFP      = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_HFP;
localparam HSP      = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_HSP;
localparam HBP      = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_HBP;

localparam VACT     = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_VACT;
localparam VFP      = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_VFP;
localparam VSP      = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_VSP;
localparam VBP      = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_VBP;
//===============================================================================
//signal
//===============================================================================

wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
wire                              cal_done;

// Slave Interface Write Address Ports
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_19]           s_axi_awid;
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_20]         s_axi_awaddr;
wire [`CFG_BITS_8-1:0]                        s_axi_awlen;
wire [`CFG_BITS_3-1:0]                        s_axi_awsize;
wire [`CFG_BITS_2-1:0]                        s_axi_awburst;
wire [`CFG_BITS_1-1:0]                        s_axi_awlock;
wire [`CFG_BITS_4-1:0]                        s_axi_awcache;
wire [`CFG_BITS_3-1:0]                        s_axi_awprot;
wire                              s_axi_awvalid;
wire                              s_axi_awready;
// Slave Interface Write Data Ports
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_21]         s_axi_wdata;
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_22]     s_axi_wstrb;
wire                              s_axi_wlast;
wire                              s_axi_wvalid;
wire                              s_axi_wready;
// Slave Interface Write Response Ports
wire                              s_axi_bready;
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_23]           s_axi_bid;
wire [`CFG_BITS_2-1:0]                        s_axi_bresp;
wire                              s_axi_bvalid;
// Slave Interface Read Address Ports
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_24]           s_axi_arid;
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_25]         s_axi_araddr;
wire [`CFG_BITS_8-1:0]                        s_axi_arlen;
wire [`CFG_BITS_3-1:0]                        s_axi_arsize;
wire [`CFG_BITS_2-1:0]                        s_axi_arburst;
wire [`CFG_BITS_1-1:0]                        s_axi_arlock;
wire [`CFG_BITS_4-1:0]                        s_axi_arcache;
wire [`CFG_BITS_3-1:0]                        s_axi_arprot;
wire                              s_axi_arvalid;
wire                              s_axi_arready;
// Slave Interface Read Data Ports
wire                              s_axi_rready;
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_26]           s_axi_rid;
wire [`CFG_TI60F225_OOB_TOP_V_RANGE_27]         s_axi_rdata;
wire [`CFG_BITS_2-1:0]                        s_axi_rresp;
wire                              s_axi_rlast;
wire                              s_axi_rvalid;

// Frame-buffer AXI master before CPU/video arbitration.  The frame buffer
// uses six-bit IDs; the Sapphire CPU uses eight-bit IDs.  The shared bridge
// zero-extends frame IDs and preserves the CPU ID until B/R completion.
wire [5:0] fb_awid,fb_arid,fb_bid,fb_rid;
wire [31:0] fb_awaddr,fb_araddr;
wire [7:0] fb_awlen,fb_arlen; wire [2:0] fb_awsize,fb_arsize; wire [1:0] fb_awburst,fb_arburst;
wire [3:0] fb_awcache,fb_arcache; wire [2:0] fb_awprot,fb_arprot; wire fb_awlock,fb_arlock;
wire fb_awvalid,fb_awready,fb_wvalid,fb_wready,fb_wlast,fb_bvalid,fb_bready,fb_arvalid,fb_arready,fb_rvalid,fb_rready,fb_rlast;
wire [127:0] fb_wdata,fb_rdata; wire [15:0] fb_wstrb; wire [1:0] fb_bresp,fb_rresp;




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
// wire	w_sysclk_mcu_arstn;
// wire	w_sysclk_mcu_arst;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;

wire		       w_mipi_rx_vs;
wire		       w_mipi_rx_hs;
wire	       w_mipi_rx_de;
wire	[`CFG_BITS_64-1:0]			w_mipi_rx_data	;




//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign DDR3_PLL_RSTN 		= i_arstn;
reset_ctrl
#(
	.NUM_RST		(`CFG_TI60F225_OOB_TOP_V_INST_INST_RESET_CTRL_NUM_RST),
	.CYCLE			(`CFG_TI60F225_OOB_TOP_V_INST_INST_RESET_CTRL_CYCLE),
	.IN_RST_ACTIVE	(`CFG_TI60F225_OOB_TOP_V_INST_INST_RESET_CTRL_IN_RST_ACTIVE),
	.OUT_RST_ACTIVE	(`CFG_TI60F225_OOB_TOP_V_INST_INST_RESET_CTRL_OUT_RST_ACTIVE)
)
inst_reset_ctrl
(
	.i_arst		({2{w_arstn}}),//({{4{i_pll_locked}},                  {2{i_arstn}}}),
	.i_clk			({2{i_mipi_rx_pclk}}),
	.o_srst		({w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn})
);



reg [`CFG_BITS_26-1:0] cnt = 'd0;
always @( posedge core_clk)
begin
       cnt <= cnt + 1'b1;
end
assign led[0]  = cal_done ? cnt[24] : 1'b0;

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk = core_clk;

		assign	cam_d0_RST		= 1'b0;
		assign	cam_d1_RST		= 1'b0;
		assign  cam_d2_RST = 1'b0;
    assign  cam_d3_RST = 1'b0;

wire [`CFG_BITS_16-1:0] mipi_debug_out;


		csi_rx_controller inst_efx_csi2_rx
		(
              .reset_n			(i_arstn),
              .clk				(i_mipi_clk),
              .reset_byte_HS_n	(i_arstn),
              .clk_byte_HS		  (i_cam_ck_CLKOUT),
              .reset_pixel_n		(w_mipi_rx_pclk_arstn),
              .clk_pixel			  (i_mipi_rx_pclk),

              .Rx_LP_CLK_P		  (i_cam_ck_LP_P_IN),
              .Rx_LP_CLK_N		  (i_cam_ck_LP_N_IN),
              .Rx_HS_enable_C		(o_cam_ck_HS_ENA),
              .LVDS_termen_C		(o_cam_ck_HS_TERM),

              .Rx_LP_D_P			({cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN}),//(r_mipi_rx_data_LP_P_IN_2P),
              .Rx_LP_D_N			({cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN}),//(r_mipi_rx_data_LP_N_IN_2P),
              .Rx_HS_D_0			(cam_d0_HS_IN),//(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
              .Rx_HS_D_1			(cam_d1_HS_IN),//(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
              .Rx_HS_D_2			(cam_d2_HS_IN),
              .Rx_HS_D_3			(cam_d3_HS_IN),
              .Rx_HS_D_4			(),
              .Rx_HS_D_5			(),
              .Rx_HS_D_6			(),
              .Rx_HS_D_7			(),
              .Rx_HS_enable_D		({cam_d3_HS_ENA    ,cam_d2_HS_ENA    ,cam_d1_HS_ENA    ,cam_d0_HS_ENA    }),//( w_cam_d_HS_ENA),
              .LVDS_termen_D		({cam_d3_HS_TERM   ,cam_d2_HS_TERM   ,cam_d1_HS_TERM   ,cam_d0_HS_TERM   }),
              .fifo_rd_enable		({cam_d3_FIFO_RD   ,cam_d2_FIFO_RD   ,cam_d1_FIFO_RD   ,cam_d0_FIFO_RD   }),
              .fifo_rd_empty		({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
              .DLY_enable_D		       (),
              .DLY_inc_D			(),
              .u_dly_enable_D		(),
              .u_dly_inc_D		       (),

              .axi_clk			(1'b0),
              .axi_reset_n		       (1'b0),
              .axi_awaddr			(6'b0),
              .axi_awvalid		       (1'b0),
              .axi_awready		       (),
              .axi_wdata			(32'b0),
              .axi_wvalid			(1'b0),
              .axi_wready			(),

              .axi_bvalid			(),
              .axi_bready			(1'b0),
              .axi_araddr			(6'b0),
              .axi_arvalid		       (1'b0),
              .axi_arready		       (),
              .axi_rdata			(),
              .axi_rvalid			(),
              .axi_rready			(1'b1),

              .hsync_vc0			(w_mipi_rx_hs),
              .hsync_vc1			(),
              .hsync_vc2			(),
              .hsync_vc3			(),
              .vsync_vc0			(w_mipi_rx_vs),
              .vsync_vc1			(),
              .vsync_vc2			(),
              .vsync_vc3			(),
              .vc				(),
              .word_count			(),
              .shortpkt_data_field        (),
              .datatype			(),
              .pixel_per_clk		(),
              .pixel_data			(w_mipi_rx_data),
              .pixel_data_valid	       (w_mipi_rx_de),
              .irq				(),
              .mipi_debug_out(mipi_debug_out)
		);

//     wire		       w1_mipi_rx_vs;
// wire		       w1_mipi_rx_hs;
// wire	       w1_mipi_rx_de;
// wire	[39:0]			w1_mipi_rx_data	;
// sensor_clipper  sensor_clipper_inst (
//     .clk(i_mipi_rx_pclk),
//     .i_vs(w_mipi_rx_vs),
//     .i_hs(w_mipi_rx_hs),
//     .i_de(w_mipi_rx_de),
//     .i_dat(w_mipi_rx_data[39:0]),

//     .o_hs(w1_mipi_rx_hs),
//     .o_vs(w1_mipi_rx_vs),
//     .o_de(w1_mipi_rx_de),
//     .o_dat(w1_mipi_rx_data)

//   );


wire mdebug_pixel_fifo_full     = mipi_debug_out[0] ;
wire mdebug_pixel_fifo_empty    = mipi_debug_out[1] ;
wire mdebug_crc_error           = mipi_debug_out[2] ;
wire mdebug_ecc_1bit_error      = mipi_debug_out[3] ;
wire mdebug_ecc_2bit_error      = mipi_debug_out[4] ;
wire mdebug_undersize_pkt_error = mipi_debug_out[5] ;
wire mdebug_line_vc0_error      = mipi_debug_out[6] ;
wire mdebug_frame_vc0_error    = mipi_debug_out[10];
wire mdebug_receive_error      = mipi_debug_out[14];


//========================================================================================================
//
//========================================================================================================


assign o_cam_rst_p = ~w_arstn;

//=====================================================================================
//frame buffer
//=====================================================================================
// Capture processing uses vid_clk_dvi2 at 148.5 MHz; HDMI uses 74.25 MHz.
wire capture_vs,capture_de,capture_fault;
wire [`CFG_BITS_16-1:0] capture_raw;
wire resize_vs,resize_valid,resize_fault;
wire [`CFG_BITS_64-1:0] resize_data;
wire [`CFG_BITS_32-1:0] resize_completed_frames;
wire [`CFG_BITS_32-1:0] display_pixel;
wire ch0_vs,ch0_hs,ch0_de;
wire display_underflow;
wire capture_reset_n,display_reset_n;
// The HDMI test pattern and encoder do not wait for DDR or CPU startup.
wire hdmi_output_reset_n;
rst_n_piple #(.DLY(3)) hdmi_output_reset(
  .clk(hdmi_tx_slow_clk),.rst_n_i(w_arstn),.rst_n_o(hdmi_output_reset_n));
// DDR startup barrier: readiness is synchronized separately into the CPU and
// display domains; no AXI master is released on an asynchronous cal_done edge.
wire barrier_sys_reset_n,barrier_vid_reset_n,barrier_allow_sys,barrier_allow_vid,barrier_cpu_waiting;
ddr_startup_barrier ddr_startup(
  .sys_clk(core_clk), .vid_clk(hdmi_tx_slow_clk), .global_reset_n(w_arstn),
  .pll_locked(pll_locked), .ddr_cal_done(cal_done),
  .sys_reset_n(barrier_sys_reset_n), .vid_reset_n(barrier_vid_reset_n),
  .master_allow_sys(barrier_allow_sys), .master_allow_vid(barrier_allow_vid),
  .cpu_waiting(barrier_cpu_waiting));
// Wait for DDR calibration, then release resets synchronously in each domain.
wire vid_rst_n;
wire video_reset_n = vid_rst_n && barrier_vid_reset_n;
rst_n_piple #(.DLY(`CFG_TI60F225_OOB_TOP_V_INST_CAPTURE_RESET_DLY)) capture_reset(.clk(vid_clk_dvi2),.rst_n_i(video_reset_n),.rst_n_o(capture_reset_n));
rst_n_piple #(.DLY(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_RESET_DLY)) display_reset(.clk(hdmi_tx_slow_clk),.rst_n_i(video_reset_n),.rst_n_o(display_reset_n));
wire csi_reset_n;
rst_n_piple #(.DLY(`CFG_TI60F225_OOB_TOP_V_INST_CSI_RESET_DLY)) csi_reset(.clk(i_mipi_rx_pclk),.rst_n_i(video_reset_n),.rst_n_o(csi_reset_n));
camera_raw_gearbox #(.SOURCE_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_CAMERA_REPLAY_SOURCE_WIDTH),.SOURCE_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_CAMERA_REPLAY_SOURCE_HEIGHT)) camera_replay(
  .s_clk(i_mipi_rx_pclk),.s_rst_n(csi_reset_n),.s_vs(w_mipi_rx_vs),
  .s_valid(w_mipi_rx_de & w_mipi_rx_hs),
  .s_data({w_mipi_rx_data[39:32],w_mipi_rx_data[29:22],w_mipi_rx_data[19:12],w_mipi_rx_data[9:2]}),
  .d_clk(vid_clk_dvi2),.d_rst_n(capture_reset_n),
  .d_vs(capture_vs),.d_de(capture_de),.d_data(capture_raw),.fault(capture_fault)
);
assign resize_vs=rgb_vs;
assign resize_valid=1'b0;
assign resize_data=64'b0;
wire [`CFG_BITS_32-1:0] m_axis_tdata;
wire           m_axis_tvalid;
wire           m_axis_tready;
wire           m_axis_tlast;
wire           m_axis_tuser;
wire  fifo_rd_period;
// Sapphire CPU + shared DDR bridge.  The generated SoC uses USER1 hard JTAG;
// the Efinity auto debugger remains on USER2, so there is one owner per TAP.
wire [7:0] soc_vid_bid,soc_vid_rid; wire [1:0] soc_vid_bresp,soc_vid_rresp;
wire soc_vid_bvalid,soc_vid_rready,soc_vid_rvalid,soc_vid_rlast;
wire [127:0] soc_vid_rdata;
wire [15:0] soc_apb_paddr; wire soc_apb_psel,soc_apb_penable,soc_apb_pwrite; wire [31:0] soc_apb_pwdata;
wire [31:0] soc_apb_prdata; wire soc_apb_pready,soc_apb_pslverr;
wire soc_uart_txd,soc_i2c_scl_out,soc_i2c_sda_out,soc_system_reset,soc_memory_reset;
wire soc_spi_ss,soc_spi_sclk,soc_spi_d0_out,soc_spi_d0_oe,soc_spi_d1_out,soc_spi_d1_oe;
// Sapphire is the sole camera I2C master. A high write releases the pad;
// a low write drives it low (open drain).
assign io_cam_scl_OUT = soc_i2c_scl_out;
assign io_cam_sda_OUT = soc_i2c_sda_out;
assign io_cam_scl_OE = ~soc_i2c_scl_out;
assign io_cam_sda_OE = ~soc_i2c_sda_out;
wire [31:0] soc_axi_error_count;
wire osd_apb_enable; wire [11:0] osd_apb_x,osd_apb_y; wire [23:0] osd_apb_color;
wire osd_apb_char_we,osd_apb_char_page,osd_apb_commit_toggle,osd_apb_commit_page; wire [6:0] osd_apb_char_addr; wire [7:0] osd_apb_char_data;
wire osd_db_ack,osd_db_active,osd_db_busy,osd_video_ready;
// One-second capture/display statistics are exposed through the APB status
// register. Events are edge-qualified so level faults are counted once.
wire [31:0] status_capture_frames,status_display_frames,status_drop_count,status_underflow_count,status_error_count;
wire [15:0] status_capture_fps,status_display_fps,status_raw_fps;
reg [31:0] status_axi_error_d; reg [26:0] status_tick_count;
wire status_raw_event,status_capture_event,status_display_event;
wire status_reset_n=barrier_sys_reset_n && capture_reset_n && display_reset_n;

video_frame_diagnostics frame_diagnostics(
  .raw_clk(i_mipi_rx_pclk),.resize_clk(vid_clk_dvi2),.display_clk(hdmi_tx_slow_clk),
  .core_clk(core_clk),.rst_n(status_reset_n),.raw_vs(w_mipi_rx_vs),
  .resize_completed_frames(resize_completed_frames),.display_vs(ch0_vs),
  .raw_event(status_raw_event),.resize_event(status_capture_event),.display_event(status_display_event));
wire status_interval_tick = (status_tick_count == 27'd99_999_999);
wire status_axi_error_event = (soc_axi_error_count != status_axi_error_d);
always @(posedge core_clk or negedge status_reset_n) begin
  if(!status_reset_n) begin status_axi_error_d<=0; status_tick_count<=0; end
  else begin
    status_axi_error_d <= soc_axi_error_count;
    if(status_interval_tick) status_tick_count<=0; else status_tick_count<=status_tick_count+1'b1;
  end
end
(* ASYNC_REG="TRUE" *) reg [1:0] capture_fault_sync,underflow_sync;
always @(posedge core_clk or negedge status_reset_n)
  if(!status_reset_n)begin capture_fault_sync<=0;underflow_sync<=0;end
  else begin capture_fault_sync<={capture_fault_sync[0],capture_fault};underflow_sync<={underflow_sync[0],display_underflow};end
video_status_counters status_counters(
  .clk(core_clk),.rst_n(status_reset_n),.frame_start(status_capture_event),.raw_frame_start(status_raw_event),
  .display_frame_start(status_display_event),.capture_overflow(capture_fault_sync[1]),
  .display_underflow(underflow_sync[1]),.axi_error(status_axi_error_event),
  .interval_tick(status_interval_tick),.capture_frames(status_capture_frames),
  .display_frames(status_display_frames),.drop_count(status_drop_count),
  .underflow_count(status_underflow_count),.error_count(status_error_count),
  .capture_fps(status_capture_fps),.display_fps(status_display_fps),.raw_fps(status_raw_fps));

// Shared INT8 network and paired VGA video store, on the independent demo branch.
wire [31:0] style_prdata,video_prdata;
wire style_pready,style_pslverr,video_pready,video_pslverr,style_irq;
wire style_select=soc_apb_paddr[15:8]==8'h02;
assign soc_apb_prdata=style_select ? style_prdata:video_prdata;
assign soc_apb_pready=style_select ? style_pready:video_pready;
assign soc_apb_pslverr=style_select ? style_pslverr:video_pslverr;
style_video_system style_demo(
  .clk(core_clk),.cnn_clk(vid_clk_dvi2),.pix_clk(hdmi_tx_slow_clk),.rst_n(status_reset_n&&!soc_system_reset),
  .rgb_vs(rgb_vs),.rgb_de(rgb_de),.rgb_data(rgb_datax2),
  .psel(soc_apb_psel&&style_select),.penable(soc_apb_penable),.pwrite(soc_apb_pwrite),.paddr(soc_apb_paddr[7:0]),.pwdata(soc_apb_pwdata),
  .prdata(style_prdata),.pready(style_pready),.pslverr(style_pslverr),.irq(style_irq),
  .pixel(display_pixel),.hs(ch0_hs),.vs(ch0_vs),.de(ch0_de),.underflow(display_underflow),.capture_fault(resize_fault),.resized_frames(resize_completed_frames),
  .awid(fb_awid),.awaddr(fb_awaddr),.awlen(fb_awlen),.awsize(fb_awsize),.awburst(fb_awburst),.awvalid(fb_awvalid),.awready(fb_awready),
  .wdata(fb_wdata),.wstrb(fb_wstrb),.wlast(fb_wlast),.wvalid(fb_wvalid),.wready(fb_wready),.bid(fb_bid),.bresp(fb_bresp),.bvalid(fb_bvalid),.bready(fb_bready),
  .arid(fb_arid),.araddr(fb_araddr),.arlen(fb_arlen),.arsize(fb_arsize),.arburst(fb_arburst),.arvalid(fb_arvalid),.arready(fb_arready),
  .rid(fb_rid),.rdata(fb_rdata),.rresp(fb_rresp),.rlast(fb_rlast),.rvalid(fb_rvalid),.rready(fb_rready));



soc_video_ddr_integration soc_video_inst(
  .clk(core_clk),.rst_n(barrier_sys_reset_n),.allow_access(barrier_allow_sys),
  .vid_awid({2'b0,fb_awid}),.vid_awaddr(fb_awaddr),.vid_awlen(fb_awlen),.vid_awsize(fb_awsize),.vid_awburst(fb_awburst),.vid_awvalid(fb_awvalid),.vid_awready(fb_awready),
  .vid_wdata(fb_wdata),.vid_wstrb(fb_wstrb),.vid_wlast(fb_wlast),.vid_wvalid(fb_wvalid),.vid_wready(fb_wready),.vid_bid(soc_vid_bid),.vid_bresp(soc_vid_bresp),.vid_bvalid(soc_vid_bvalid),.vid_bready(fb_bready),
  .vid_arid({2'b0,fb_arid}),.vid_araddr(fb_araddr),.vid_arlen(fb_arlen),.vid_arsize(fb_arsize),.vid_arburst(fb_arburst),.vid_arvalid(fb_arvalid),.vid_arready(fb_arready),.vid_rid(soc_vid_rid),.vid_rdata(soc_vid_rdata),.vid_rresp(soc_vid_rresp),.vid_rlast(soc_vid_rlast),.vid_rvalid(soc_vid_rvalid),.vid_rready(fb_rready),
  .ddr_awid(s_axi_awid),.ddr_awaddr(s_axi_awaddr),.ddr_awlen(s_axi_awlen),.ddr_awsize(s_axi_awsize),.ddr_awburst(s_axi_awburst),.ddr_awvalid(s_axi_awvalid),.ddr_awready(s_axi_awready),.ddr_wdata(s_axi_wdata),.ddr_wstrb(s_axi_wstrb),.ddr_wlast(s_axi_wlast),.ddr_wvalid(s_axi_wvalid),.ddr_wready(s_axi_wready),.ddr_bid(s_axi_bid),.ddr_bresp(s_axi_bresp),.ddr_bvalid(s_axi_bvalid),.ddr_bready(s_axi_bready),.ddr_arid(s_axi_arid),.ddr_araddr(s_axi_araddr),.ddr_arlen(s_axi_arlen),.ddr_arsize(s_axi_arsize),.ddr_arburst(s_axi_arburst),.ddr_arvalid(s_axi_arvalid),.ddr_arready(s_axi_arready),.ddr_rid(s_axi_rid),.ddr_rdata(s_axi_rdata),.ddr_rresp(s_axi_rresp),.ddr_rlast(s_axi_rlast),.ddr_rvalid(s_axi_rvalid),.ddr_rready(s_axi_rready),
  .apb_paddr(soc_apb_paddr),.apb_psel(soc_apb_psel),.apb_penable(soc_apb_penable),.apb_pready(soc_apb_pready),.apb_pwrite(soc_apb_pwrite),.apb_pwdata(soc_apb_pwdata),.apb_prdata(soc_apb_prdata),.apb_pslverr(soc_apb_pslverr),
  .jtag_tck(jtag_inst1_TCK),.jtag_tdi(jtag_inst1_TDI),.jtag_capture(jtag_inst1_CAPTURE),.jtag_shift(jtag_inst1_SHIFT),.jtag_update(jtag_inst1_UPDATE),.jtag_reset(jtag_inst1_RESET),.jtag_enable(jtag_inst1_SEL),.jtag_tdo(jtag_inst1_TDO),
  .uart_txd(soc_uart_txd),.uart_rxd(system_uart_0_io_rxd),.i2c_scl_in(io_cam_scl_IN),.i2c_scl_out(soc_i2c_scl_out),.i2c_sda_in(io_cam_sda_IN),.i2c_sda_out(soc_i2c_sda_out),
  .spi_d0_in(system_spi_0_io_data_0_IN),.spi_d1_in(system_spi_0_io_data_1_IN),.spi_ss(soc_spi_ss),.spi_sclk(soc_spi_sclk),.spi_d0_out(soc_spi_d0_out),.spi_d0_oe(soc_spi_d0_oe),.spi_d1_out(soc_spi_d1_out),.spi_d1_oe(soc_spi_d1_oe),
  .soc_system_reset(soc_system_reset),.soc_memory_reset(soc_memory_reset),.axi_error_count(soc_axi_error_count),.style_irq(style_irq));
assign system_uart_0_io_txd=soc_uart_txd;
assign system_spi_0_io_ss=soc_spi_ss;
assign system_spi_0_io_sclk_write=soc_spi_sclk;
assign system_spi_0_io_data_0_OUT=soc_spi_d0_out;
assign system_spi_0_io_data_0_OE=soc_spi_d0_oe;
assign system_spi_0_io_data_1_OUT=soc_spi_d1_out;
assign system_spi_0_io_data_1_OE=soc_spi_d1_oe;
assign fb_bid=soc_vid_bid[5:0]; assign fb_rid=soc_vid_rid[5:0]; assign fb_bresp=soc_vid_bresp; assign fb_rresp=soc_vid_rresp; assign fb_bvalid=soc_vid_bvalid; assign fb_rvalid=soc_vid_rvalid; assign fb_rlast=soc_vid_rlast; assign fb_rdata=soc_vid_rdata;
wire [31:0] video_display_tone,video_display_lift;wire [2:0] video_display_hist;
reg [6:0] video_csi_sticky;
always @(posedge i_mipi_rx_pclk or negedge csi_reset_n)
  if(!csi_reset_n) video_csi_sticky<=0;
  else video_csi_sticky<=video_csi_sticky|{mdebug_receive_error,mdebug_frame_vc0_error,
    mdebug_line_vc0_error,mdebug_undersize_pkt_error,mdebug_ecc_2bit_error,mdebug_ecc_1bit_error,mdebug_crc_error};
video_apb_ctrl osd_apb(
  .capture_clk(vid_clk_dvi2),.display_clk(hdmi_tx_slow_clk),
  .raw_vs(capture_vs),.raw_de(capture_de),.raw_data(capture_raw),
  .rgb_vs(rgb_vs),.rgb_de(rgb_de),.rgb_data(rgb_datax2),.display_vs(ch0_vs),
  .capture_fault(capture_fault),.resize_fault(resize_fault),.raw_event(status_raw_event),
  .drop_count32(status_drop_count),.axi_errors32(soc_axi_error_count),.underflows32(status_underflow_count),
  .resize_frames32(status_capture_frames),.display_frames32(status_display_frames),.csi_errors(video_csi_sticky),
  .reset_status({display_reset_n,capture_reset_n,cal_done,pll_locked,barrier_sys_reset_n}),
  .display_stats_valid(display_stats_valid),.display_mean(display_stats_mean),
  .display_strength(effective_lift_strength),.display_at_max(1'b0),
  .gain_r(r_gain),.gain_g(g_gain),.gain_b(b_gain),
  .display_tone(video_display_tone),.display_lift(video_display_lift),.display_hist(video_display_hist),
  .i_raw_fps(status_raw_fps),
  .pclk(core_clk),.preset_n(status_reset_n && !soc_system_reset),.psel(soc_apb_psel&&!style_select),.penable(soc_apb_penable),.pwrite(soc_apb_pwrite),.paddr(soc_apb_paddr),.pwdata(soc_apb_pwdata),.prdata(video_prdata),.pready(video_pready),.pslverr(video_pslverr),
  .o_enable(osd_apb_enable),.o_x(osd_apb_x),.o_y(osd_apb_y),.o_color(osd_apb_color),.o_char_we(osd_apb_char_we),.o_char_addr(osd_apb_char_addr),.o_char_page(osd_apb_char_page),.o_char_data(osd_apb_char_data),.o_commit_toggle(osd_apb_commit_toggle),.o_commit_page(osd_apb_commit_page),.o_video_ready(osd_video_ready),.i_ack_toggle(osd_db_ack),.i_active_page(osd_db_active),.i_busy(osd_db_busy),.i_frame_count(status_display_fps),.i_capture_fps(status_capture_fps),.i_display_fps(status_display_fps),.i_drop_count(status_drop_count[15:0]),.i_error_count(status_error_count[15:0]));

wire db_vs,db_hs,db_de,db_char_pixel; wire [7:0] db_r,db_g,db_b;

ddr3_top                 u_ddr3_top
(

.axi_clk                (core_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (w_arstn             ),
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (s_axi_awsize      ),
.s_axi_awburst                  (s_axi_awburst     ),
.s_axi_awlock                   (s_axi_awlock      ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (4'h0              ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (s_axi_arlock      ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (4'h0              ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          )
);

//***************************************************************************
// debayer
//***************************************************************************


wire        rgb_vs;
wire        rgb_hs;
wire        rgb_de;
wire        rgb_valid;
wire [`CFG_BITS_48-1:0] rgb_datax2;
wire [`CFG_BITS_16-1:0] r_gain;
wire [`CFG_BITS_16-1:0] g_gain;
wire [`CFG_BITS_16-1:0] b_gain;
// Measured white RAW: the matched green samples are even/high and odd/low.
// Preserve pixel order and use BGGR processing for this camera configuration.
localparam CAM_RAW_GREEN_FIRST = `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_CAM_RAW_GREEN_FIRST;

debayer_top_2to1 #(
  .RAW_GREEN_FIRST(`CFG_TI60F225_OOB_TOP_V_INST_DEBAYER_TOP_RAW_GREEN_FIRST)
) debayer_top
(
	.in_pclk		  (vid_clk_dvi2),//(i_mipi_rx_pclk ),
	.in_rstn		  (capture_reset_n),

	.raw_vs_i		  (capture_vs),
	.raw_hs_i		  (capture_de),
	.raw_de_i		  (capture_de),
	.raw_valid_i	(capture_de),
	.raw_datax4_i	(capture_raw),
	.r_gain       (|r_gain? r_gain:255 ),
  .g_gain       (|g_gain? g_gain:255 ),
  .b_gain       (|b_gain? b_gain:255 ),
	.rgb_vs_o		  (rgb_vs         ),
	.rgb_hs_o		  (rgb_hs         ),
	.rgb_de_o		  (rgb_de         ),
	.rgb_valid_o	(rgb_valid      ),
	.rgb_datax2_o (rgb_datax2     ),//b,g,r,b,g,r
	.raw_row_odd_o ()
);
wire [`CFG_BITS_8-1:0] hdmi_tx_rdata = display_pixel[7:0];
wire [`CFG_BITS_8-1:0] hdmi_tx_gdata = display_pixel[15:8];
wire [`CFG_BITS_8-1:0] hdmi_tx_bdata = display_pixel[23:16];
wire hdmi_tx_vs = ch0_vs;
wire hdmi_tx_hs = ch0_hs;
wire hdmi_tx_de = ch0_de;
// Sticky diagnostics: press reset after overflow or malformed capture.
reg underflow_seen;
always @(posedge hdmi_tx_slow_clk or negedge display_reset_n)
  if(!display_reset_n) underflow_seen<=0;
  else if(display_underflow) underflow_seen<=1;
assign led[1] = capture_fault;
assign led[2] = resize_fault;
assign led[3] = underflow_seen;
assign led[7:4] = resize_completed_frames[3:0];
reg [`CFG_BITS_27-1:0] dly_cnt = 'd0;

always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
end

assign vid_rst_n = dly_cnt[26];




//=================================================================================
//hdmi tx ctrl
//=================================================================================
assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

wire [`CFG_BITS_10-1:0] tmds_data0;
wire [`CFG_BITS_10-1:0] tmds_data1;
wire [`CFG_BITS_10-1:0] tmds_data2;
wire [`CFG_BITS_10-1:0] tmds_clk ;

wire [`CFG_BITS_8-1:0] tone_rdata,tone_gdata,tone_bdata;
wire tone_vs,tone_hs,tone_de;
luma_color_suppress tone_adjustment(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_enable(video_display_tone[0]),
  .i_high_green(video_display_tone[15:8]),.i_dark_red(video_display_tone[23:16]),
  .i_vs(hdmi_tx_vs),.i_hs(hdmi_tx_hs),.i_de(hdmi_tx_de),
  .i_r(CAM_RAW_GREEN_FIRST ? hdmi_tx_bdata : hdmi_tx_rdata),.i_g(hdmi_tx_gdata),
  .i_b(CAM_RAW_GREEN_FIRST ? hdmi_tx_rdata : hdmi_tx_bdata),
  .o_vs(tone_vs),.o_hs(tone_hs),.o_de(tone_de),.o_r(tone_rdata),.o_g(tone_gdata),.o_b(tone_bdata)
);

wire [`CFG_BITS_8-1:0] lift_rdata,lift_gdata,lift_bdata;
wire lift_vs,lift_hs,lift_de;
wire display_stats_valid;
wire [`CFG_BITS_8-1:0] display_stats_mean,effective_lift_strength;
ae_frame_stats #(.FRAME_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_FRAME_WIDTH),.FRAME_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_FRAME_HEIGHT),.PIXELS_PER_CLOCK(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_PIXELS_PER_CLOCK),.MEAN_ONLY(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_MEAN_ONLY),.FULL_FRAME_MEAN(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_FULL_FRAME_MEAN)) display_meter(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_vs(lift_vs),.i_de(lift_de),
  .i_rgb({24'd0,lift_bdata,lift_gdata,lift_rdata}),.i_high_threshold(8'd232),
  .o_valid(display_stats_valid),.o_mean(display_stats_mean),.o_highlights(),.o_high_permille()
);
// Automatic lift is disabled by the APB contract; retain the old manual
// strength clamp without the inactive feedback controller.
assign effective_lift_strength = video_display_lift[15:8]>8'd128 ? 8'd128 : video_display_lift[15:8];
luma_tone_map #(.HIGHLIGHT_SAFE(`CFG_TI60F225_OOB_TOP_V_INST_LIFT_ADJUSTMENT_HIGHLIGHT_SAFE)) lift_adjustment(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_enable(video_display_lift[0]),.i_strength(effective_lift_strength),
  .i_vs(tone_vs),.i_hs(tone_hs),.i_de(tone_de),.i_r(tone_rdata),.i_g(tone_gdata),.i_b(tone_bdata),
  .o_vs(lift_vs),.o_hs(lift_hs),.o_de(lift_de),.o_r(lift_rdata),.o_g(lift_gdata),.o_b(lift_bdata)
);

// Separate feedback after lift, before overlay. Single-pixel HDMI clock domain.

wire osd_vs,osd_hs,osd_de;
wire [`CFG_BITS_8-1:0] osd_r,osd_g,osd_b;
// 2026-10-21 RAM subtraction: no histogram overlay / text OSD (keep AE, tone/lift).
assign osd_vs = lift_vs, osd_hs = lift_hs, osd_de = lift_de;
assign osd_r = lift_rdata, osd_g = lift_gdata, osd_b = lift_bdata;
assign db_vs = fp_vs, db_hs = fp_hs, db_de = fp_de, db_char_pixel = 1'b0;
assign db_r = fp_r, db_g = fp_g, db_b = fp_b;
assign osd_db_ack = 1'b0, osd_db_active = 1'b0, osd_db_busy = 1'b0;

// ---- 屏上 FPS：显示域 1s 计数（style IRQ 边沿），LUT 叠加，0 RAM ----
reg [27:0] fps_tick; reg [15:0] fps_cnt, style_fps_disp;
reg style_irq_s1, style_irq_s2;
wire fp_vs, fp_hs, fp_de; wire [7:0] fp_r, fp_g, fp_b;
always @(posedge hdmi_tx_slow_clk or negedge display_reset_n) begin
  if (!display_reset_n) begin
    fps_tick <= 0; fps_cnt <= 0; style_fps_disp <= 0;
    style_irq_s1 <= 0; style_irq_s2 <= 0;
  end else begin
    style_irq_s1 <= style_irq; style_irq_s2 <= style_irq_s1;
    if (style_irq_s1 && !style_irq_s2 && fps_cnt < 16'd999) fps_cnt <= fps_cnt + 1'b1;
    // hdmi_tx_slow_clk = 74.25 MHz (SDC period 13.468 ns): 74.25M cycles = 1 s.
    // The old 148.5M threshold made this a 2-second window, so the overlay
    // showed 2x the real frame rate.
    if (fps_tick == 28'd74_249_999) begin
      fps_tick <= 0; style_fps_disp <= fps_cnt; fps_cnt <= 0;
    end else fps_tick <= fps_tick + 1'b1;
  end
end
fps_overlay u_fps_overlay(
  .clk(hdmi_tx_slow_clk), .rst_n(display_reset_n),
  .i_vs(lift_vs), .i_hs(lift_hs), .i_de(lift_de),
  .i_r(lift_rdata), .i_g(lift_gdata), .i_b(lift_bdata),
  .i_fps(style_fps_disp),
  .o_vs(fp_vs), .o_hs(fp_hs), .o_de(fp_de),
  .o_r(fp_r), .o_g(fp_g), .o_b(fp_b));

// Histogram controls already belong to this HDMI clock domain after the
// display_config frame-boundary APPLY/ACK. Text is drawn by osd_db.

// Stable bars are shown until the CPU has initialized the camera and first
// OSD page. Switch only at a frame boundary in the HDMI clock domain.
wire bar_hs,bar_vs,bar_de;
wire [7:0] bar_r,bar_g,bar_b;

wire out_vs,out_hs,out_de;
wire [7:0] out_r,out_g,out_b;
assign out_vs=db_vs; assign out_hs=db_hs; assign out_de=db_de;
// pp_probe 已摘除（10-20）：pp 线降级为独立工程/空闲填充，不进合并图综合树。
// 备份：rtl/ti60f225_oob_top.v.pre_pp
assign out_r = db_r;
assign out_g = db_g;
assign out_b = db_b;


dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~hdmi_output_reset_n),// reset
	.i_bdata      		(out_b),
	.i_gdata     		(out_g),
	.i_rdata       		(out_r),
  .i_de            	(out_de),
	.i_hs         		(out_hs),
	.i_vs         		(out_vs),

  .video_format     (2'b00), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (7'd4),
	.audio_L			    (24'd0),
  .audio_R			    (24'd0),
  .audio_valid		  (1'b0),
  .audio_N                (6144),     //(20'h01880),//
  .audio_CTS              (74250),      //(20'h28488),//
  .audio_sample_frequency (audio_samp_freq),    //(3'b000),//
  .audio_word_length      ({audio_samp_word_len,audio_max_word_length}),//(4'b1011),//

	.tmds_data0    		(tmds_data0),
  .tmds_data1    		(tmds_data1),
  .tmds_data2    		(tmds_data2),
  .tmds_clk      	  (tmds_clk  )
);
assign tmds_tx_clk_TX_DATA   = ~tmds_clk;
assign tmds_tx_data0_TX_DATA = ~tmds_data0;
assign tmds_tx_data1_TX_DATA = ~tmds_data1;
assign tmds_tx_data2_TX_DATA = ~tmds_data2;

// Efinity auto-debug uses USER2; the Sapphire CPU owns USER1.

endmodule
