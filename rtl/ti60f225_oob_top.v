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
// These four modules should not also be added as separate project design files.
`include "isp/isp_cdc_mailbox.v"
`include "isp/ae_frame_stats.v"
`include "isp/sc431hai_auto_exposure.v"
`include "isp/luma_color_suppress.v"
`include "isp/luma_tone_map.v"
`include "isp/auto_tone_lift.v"
`include "isp/hdmi_frame_histogram.v"
`include "isp/hdmi_info_overlay.v"
`include "soc_integration/osd_font8x16.sv"
`include "soc_integration/osd_fixed_text.sv"
`include "soc_integration/hdmi_startup_colorbar.sv"
`include "soc_integration/video_frame_diagnostics.sv"
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
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire    pll_inst4_RSTN,
	input   wire    pll_inst4_LOCKED,
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

wire					io_systemReset;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign mipi_dsi_tx_pll_RSTN 	= i_arstn;
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
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;

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


//*************** imx219 config********************/
// mipi_config_imx219_top u_config_imx219(
// 										.i_sys_clk(CLK_5M)    	,    /////48M
// 										.sys_rstn(vid_rst_n )    ,
// 										.o_sen_rst_n(o_cam_rstn)  	,

										// .o_iic_sda_OE(io_cam_sda_OE) ,
										// .i_iic_sda(io_cam_sda_IN)   	,
										// .o_iic_sda(io_cam_sda_OUT)   	,
										// .o_iic_scl(io_cam_scl)
										// );

wire scl_padoen_o;
wire sda_padoen_o;
wire legacy_i2c_scl_out, legacy_i2c_sda_out;
wire legacy_i2c_scl_oe, legacy_i2c_sda_oe;


reg [`CFG_BITS_13-1:0] i2c_rst_cnt = '0;

always @( posedge CLK_5M or negedge w_arstn )
begin
    if( !w_arstn )
       i2c_rst_cnt <= 'd0;
    else
       i2c_rst_cnt <= i2c_rst_cnt[12] ? i2c_rst_cnt : i2c_rst_cnt + 1'b1;
end
wire i2c_rst_n = i2c_rst_cnt[12];

// Runtime exposure control. All camera register traffic stays in CLK_5M.
wire ae_enable,tone_enable;
wire [`CFG_BITS_8-1:0] ae_target,high_green_strength,dark_red_strength;
wire ae_high_protect,lift_enable,lift_auto_enable;
wire [`CFG_BITS_8-1:0] lift_auto_max,ae_display_mean,lift_actual_strength;
wire lift_at_max;
wire [`CFG_BITS_8-1:0] ae_high_threshold,ae_high_limit,lift_strength;
wire sensor_config_done,ae_wr_en,ae_rd_en,ae_wr_done,ae_rd_done,ae_wr_error,ae_rd_error;
wire [`CFG_BITS_16-1:0] ae_addr;
wire [`CFG_BITS_8-1:0] ae_write_data,ae_read_data;
wire [`CFG_BITS_16-1:0] ae_exposure_i2c,ae_vts_i2c;
wire [`CFG_BITS_8-1:0] ae_mean_i2c;
wire ae_ready_i2c,ae_fault_i2c,ae_limit_i2c;
wire stats_valid,stats_hot;
wire [`CFG_BITS_8-1:0] stats_mean;
wire [`CFG_BITS_10-1:0] stats_high_permille;
wire ae_highlight_limited_i2c,ae_exposure_constrained_i2c;
wire ae_stats_valid;
wire [`CFG_BITS_36-1:0] ae_stats_message;
(* ASYNC_REG="TRUE" *) reg ae_enable_meta,ae_enable_i2c;
reg sensor_vs_d,sensor_frame_toggle;
(* ASYNC_REG="TRUE" *) reg sensor_fs_meta,sensor_fs_sync;
reg sensor_fs_seen;
wire sensor_frame_start=sensor_fs_sync^sensor_fs_seen;
always @(posedge i_mipi_rx_pclk or negedge w_arstn) begin
  if(!w_arstn) begin sensor_vs_d<=0;sensor_frame_toggle<=0;end
  else begin
    sensor_vs_d<=w_mipi_rx_vs;
    if(sensor_vs_d && !w_mipi_rx_vs) sensor_frame_toggle<=~sensor_frame_toggle;
  end
end
always @(posedge CLK_5M or negedge i2c_rst_n) begin
  if(!i2c_rst_n) begin
    ae_enable_meta<=0;ae_enable_i2c<=0;sensor_fs_meta<=0;sensor_fs_sync<=0;sensor_fs_seen<=0;
  end else begin
    ae_enable_meta<=ae_enable;ae_enable_i2c<=ae_enable_meta;
    sensor_fs_meta<=sensor_frame_toggle;sensor_fs_sync<=sensor_fs_meta;sensor_fs_seen<=sensor_fs_sync;
  end
end
isp_cdc_mailbox #(.WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_AE_STATISTICS_MAILBOX_WIDTH)) ae_statistics_mailbox(
  .s_clk(vid_clk_dvi2),.s_rst_n(w_arstn),.s_valid(stats_valid),
  .s_data({ae_high_protect,ae_high_limit,ae_target,stats_hot,stats_high_permille,stats_mean}),.s_ready(),
  .d_clk(CLK_5M),.d_rst_n(w_arstn),.d_valid(ae_stats_valid),.d_data(ae_stats_message)
);
sc431hai_auto_exposure ae_controller(
  .clk(CLK_5M),.rst_n(i2c_rst_n),.i_config_done(sensor_config_done),
  .i_enable(ae_enable_i2c),.i_sensor_frame_start(sensor_frame_start),
  .i_stats_valid(ae_stats_valid),.i_highlights(ae_stats_message[18]),
  .i_mean(ae_stats_message[7:0]),.i_target(ae_stats_message[26:19]),
  .i_high_protect(ae_stats_message[35]),.i_high_limit(ae_stats_message[34:27]),
  .i_high_permille(ae_stats_message[17:8]),.o_highlight_limited(ae_highlight_limited_i2c),
  .o_exposure_constrained(ae_exposure_constrained_i2c),
  .o_wr_en(ae_wr_en),.o_rd_en(ae_rd_en),.o_addr(ae_addr),.o_data(ae_write_data),
  .i_wr_done(ae_wr_done),.i_rd_done(ae_rd_done),.i_wr_error(ae_wr_error),.i_rd_error(ae_rd_error),
  .i_read_data(ae_read_data),.o_exposure(ae_exposure_i2c),.o_vts(ae_vts_i2c),
  .o_mean(ae_mean_i2c),.o_ready(ae_ready_i2c),.o_at_limit(ae_limit_i2c),.o_error(ae_fault_i2c)
);
wire ae_ready,ae_fault,ae_at_limit,ae_highlights;
wire [`CFG_BITS_16-1:0] ae_exposure,ae_vts;
wire [`CFG_BITS_8-1:0] ae_mean;
wire [`CFG_BITS_10-1:0] ae_high_permille;
wire ae_highlight_limited,ae_exposure_constrained;
wire ae_at_min=ae_ready && ae_exposure<=16'd4;
wire [`CFG_BITS_17-1:0] ae_maximum={ae_vts,1'b0}-17'd11;
wire ae_at_max=ae_ready && {1'b0,ae_exposure}>=ae_maximum;
reg ae_hot_i2c;
reg [`CFG_BITS_10-1:0] ae_high_permille_i2c;
always @(posedge CLK_5M or negedge i2c_rst_n) begin
  if(!i2c_rst_n) begin ae_hot_i2c<=0;ae_high_permille_i2c<=0;end
  else if(ae_stats_valid) begin
    ae_hot_i2c<=ae_stats_message[18];ae_high_permille_i2c<=ae_stats_message[17:8];
  end
end
wire [`CFG_BITS_56-1:0] ae_status={ae_exposure_constrained_i2c,ae_highlight_limited_i2c,ae_high_permille_i2c,ae_ready_i2c,ae_fault_i2c,ae_limit_i2c,ae_hot_i2c,ae_vts_i2c,ae_exposure_i2c,ae_mean_i2c};
reg [`CFG_BITS_56-1:0] ae_status_sent;
wire status_ready;
wire [`CFG_BITS_56-1:0] ae_status_video;
always @(posedge CLK_5M or negedge i2c_rst_n) begin
  if(!i2c_rst_n) ae_status_sent<=0;
  else if(status_ready && ae_status!=ae_status_sent) ae_status_sent<=ae_status;
end
isp_cdc_mailbox #(.WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_AE_STATUS_MAILBOX_WIDTH)) ae_status_mailbox(
  .s_clk(CLK_5M),.s_rst_n(w_arstn),.s_valid(ae_status!=ae_status_sent),.s_data(ae_status),.s_ready(status_ready),
  .d_clk(vid_clk_dvi2),.d_rst_n(w_arstn),.d_valid(),.d_data(ae_status_video)
);
assign {ae_exposure_constrained,ae_highlight_limited,ae_high_permille,ae_ready,ae_fault,ae_at_limit,ae_highlights,ae_vts,ae_exposure,ae_mean}=ae_status_video;

i2c_master_ctrl_top #(.RUNTIME_ENABLE(`CFG_TI60F225_OOB_TOP_V_INST_U2_I2C_MASTER_CTRL_TOP_RUNTIME_ENABLE)) u2_i2c_master_ctrl_top(
  /*i*/.clk			(CLK_5M		),
  /*i*/.rst_n			(i2c_rst_n		),
  /*i*/.scl_pad_i     (io_cam_scl_IN),//(1'b1),
  /*o*/.scl_pad_o     (legacy_i2c_scl_out),
  /*o*/.scl_padoen_o  (scl_padoen_o),
  /*i*/.sda_pad_i     (io_cam_sda_IN),
  /*o*/.sda_pad_o     (legacy_i2c_sda_out),
  /*o*/.sda_padoen_o  (sda_padoen_o),
  .runtime_wr_en(ae_wr_en),.runtime_rd_en(ae_rd_en),.runtime_addr(ae_addr),.runtime_data(ae_write_data),
  .config_done(sensor_config_done),.runtime_wr_done(ae_wr_done),.runtime_rd_done(ae_rd_done),
  .runtime_wr_error(ae_wr_error),.runtime_rd_error(ae_rd_error),.runtime_read_data(ae_read_data)

  );
assign o_cam_rst_p = ~w_arstn;
assign legacy_i2c_scl_oe = ~scl_padoen_o;
assign legacy_i2c_sda_oe = ~sda_padoen_o;

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
rgb_area_resize_3to2 #(.SOURCE_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_AREA_RESIZE_SOURCE_WIDTH),.SOURCE_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_AREA_RESIZE_SOURCE_HEIGHT)) area_resize(
  .clk(vid_clk_dvi2),.rst_n(capture_reset_n),.i_vs(rgb_vs),.i_de(rgb_de),.i_rgb(rgb_datax2),
  .o_vs(resize_vs),.o_valid(resize_valid),.o_data(resize_data),
  .fault(resize_fault),.completed_frames(resize_completed_frames)
);
wire [`CFG_BITS_32-1:0] m_axis_tdata;
wire           m_axis_tvalid;
wire           m_axis_tready;
wire           m_axis_tlast;
wire           m_axis_tuser;
wire  fifo_rd_period;
// SC431HAI resized XBGR8888 frame buffer.
  frame_buffer #(
.I_VID_WIDTH         (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_I_VID_WIDTH),
.O_VID_WIDTH         (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_O_VID_WIDTH),
.START_ADDR          (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_START_ADDR        ),
.AXI_DATA_WIDTH      ( `CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( `CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	      ( `CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_WR_FIFO_DEPTH		),
.RD_FIFO_DEPTH 	      ( `CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_RD_FIFO_DEPTH 	),
.BURST_LEN  	        (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_BURST_LEN),
.FB_NUM	              (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_FB_NUM),
.MAX_VID_WIDTH	      (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_MAX_VID_WIDTH) ,
.MAX_VID_HIGHT	      (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_MAX_VID_HIGHT),
.O_FRAME_WIDTH      (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_O_FRAME_WIDTH),
.O_FRAME_HEIGHT     (`CFG_TI60F225_OOB_TOP_V_INST_CHECKER0_O_FRAME_HEIGHT)

)checker0(
       .axi_clk		(core_clk 	        ),
       .rst_n			(video_reset_n),

/*i*/.i_clk			(vid_clk_dvi2),
/*i*/.i_vs			(resize_vs),
/*i*/.i_de			(resize_valid && !capture_fault && !resize_fault),
/*i*/.vin 			(resize_data),

/*i*/.o_clk			(hdmi_tx_slow_clk),//(i_mipi_rx_pclk	),
/*i*/.fifo_rd_period(fifo_rd_period),//(fifo_rd_period  ),

    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tuser  (m_axis_tuser),
    .m_axis_tlast  (m_axis_tlast),


       .awid			(fb_awid	),
       .awaddr		(fb_awaddr	),
       .awlen			(fb_awlen	),
       .awsize		(fb_awsize	),
       .awburst		(fb_awburst),
       .awprot    (fb_awprot ),
       .awcache   (fb_awcache),
       .awlock		(fb_awlock	),
       .awvalid		(fb_awvalid),
       .awready		(fb_awready),

       .arid			(fb_arid	  ),
       .araddr		(fb_araddr	),
       .arlen			(fb_arlen	),
       .arsize		(fb_arsize	),
       .arburst 	(fb_arburst),

       .arprot    (fb_arprot ),
       .arcache   (fb_arcache),
       .arlock 		(fb_arlock	),
       .arvalid		(fb_arvalid),
       .arready		(fb_arready),

       .wdata			(fb_wdata	),
       .wstrb			(fb_wstrb	),
       .wlast			(fb_wlast	),
       .wvalid		(fb_wvalid	),
       .wready		(fb_wready	),


       .rid			  (fb_rid	),
       .rdata			(fb_rdata	),
       .rlast			(fb_rlast	),
       .rvalid 		(fb_rvalid	),
       .rready		(fb_rready	),
       .rresp			(fb_rresp	),

       .bid			  (fb_bid	),
       .bvalid		(fb_bvalid	),
       .bready	  (fb_bready	)
);



// Sapphire CPU + shared DDR bridge.  The generated SoC uses USER1 hard JTAG;
// the Efinity auto debugger remains on USER2, so there is one owner per TAP.
wire [7:0] soc_vid_bid,soc_vid_rid; wire [1:0] soc_vid_bresp,soc_vid_rresp;
wire soc_vid_bvalid,soc_vid_rready,soc_vid_rvalid,soc_vid_rlast;
wire [127:0] soc_vid_rdata;
wire [15:0] soc_apb_paddr; wire soc_apb_psel,soc_apb_penable,soc_apb_pwrite; wire [31:0] soc_apb_pwdata;
wire [31:0] soc_apb_prdata; wire soc_apb_pready,soc_apb_pslverr;
wire soc_uart_txd,soc_i2c_scl_out,soc_i2c_sda_out,soc_system_reset,soc_memory_reset;
wire soc_spi_ss,soc_spi_sclk,soc_spi_d0_out,soc_spi_d0_oe,soc_spi_d1_out,soc_spi_d1_oe;
// CPU Sapphire I2C is the default camera owner.  The mux disconnects the
// legacy RTL master from the pads while preserving it for simulation hooks.
wire soc_i2c_owner = 1'b1;
i2c_owner_mux camera_i2c_owner_mux(
  .cpu_owner(soc_i2c_owner), .cpu_scl_write(soc_i2c_scl_out), .cpu_sda_write(soc_i2c_sda_out),
  .legacy_scl_out(legacy_i2c_scl_out), .legacy_sda_out(legacy_i2c_sda_out),
  .legacy_scl_oe(legacy_i2c_scl_oe), .legacy_sda_oe(legacy_i2c_sda_oe),
  .scl_out(io_cam_scl_OUT), .sda_out(io_cam_sda_OUT), .scl_oe(io_cam_scl_OE), .sda_oe(io_cam_sda_OE));
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
video_status_counters status_counters(
  .clk(core_clk),.rst_n(status_reset_n),.frame_start(status_capture_event),.raw_frame_start(status_raw_event),
  .display_frame_start(status_display_event),.capture_overflow(capture_fault),
  .display_underflow(display_underflow),.axi_error(status_axi_error_event),
  .interval_tick(status_interval_tick),.capture_frames(status_capture_frames),
  .display_frames(status_display_frames),.drop_count(status_drop_count),
  .underflow_count(status_underflow_count),.error_count(status_error_count),
  .capture_fps(status_capture_fps),.display_fps(status_display_fps),.raw_fps(status_raw_fps));
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
  .soc_system_reset(soc_system_reset),.soc_memory_reset(soc_memory_reset),.axi_error_count(soc_axi_error_count));
assign system_uart_0_io_txd=soc_uart_txd;
assign system_spi_0_io_ss=soc_spi_ss;
assign system_spi_0_io_sclk_write=soc_spi_sclk;
assign system_spi_0_io_data_0_OUT=soc_spi_d0_out;
assign system_spi_0_io_data_0_OE=soc_spi_d0_oe;
assign system_spi_0_io_data_1_OUT=soc_spi_d1_out;
assign system_spi_0_io_data_1_OE=soc_spi_d1_oe;
assign fb_bid=soc_vid_bid[5:0]; assign fb_rid=soc_vid_rid[5:0]; assign fb_bresp=soc_vid_bresp; assign fb_rresp=soc_vid_rresp; assign fb_bvalid=soc_vid_bvalid; assign fb_rvalid=soc_vid_rvalid; assign fb_rlast=soc_vid_rlast; assign fb_rdata=soc_vid_rdata;
osd_apb_regs osd_apb(
  .i_raw_fps(status_raw_fps),
  .pclk(core_clk),.preset_n(w_arstn && barrier_sys_reset_n && !soc_system_reset),.psel(soc_apb_psel),.penable(soc_apb_penable),.pwrite(soc_apb_pwrite),.paddr(soc_apb_paddr),.pwdata(soc_apb_pwdata),.prdata(soc_apb_prdata),.pready(soc_apb_pready),.pslverr(soc_apb_pslverr),
  .o_enable(osd_apb_enable),.o_x(osd_apb_x),.o_y(osd_apb_y),.o_color(osd_apb_color),.o_char_we(osd_apb_char_we),.o_char_addr(osd_apb_char_addr),.o_char_page(osd_apb_char_page),.o_char_data(osd_apb_char_data),.o_commit_toggle(osd_apb_commit_toggle),.o_commit_page(osd_apb_commit_page),.o_video_ready(osd_video_ready),.i_ack_toggle(osd_db_ack),.i_active_page(osd_db_active),.i_busy(osd_db_busy),.i_frame_count(status_display_fps),.i_capture_fps(status_capture_fps),.i_display_fps(status_display_fps),.i_drop_count(status_drop_count[15:0]),.i_error_count(status_error_count[15:0]));

wire db_vs,db_hs,db_de,db_char_pixel; wire [7:0] db_r,db_g,db_b;
osd_text_double_buffer #(.FRAME_WIDTH(1280),.FRAME_HEIGHT(720),.PAGE_SIZE(80)) osd_db(
  .wr_clk(core_clk),.pix_clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.wr_en(osd_apb_char_we),.wr_page(osd_apb_char_page),.wr_addr(osd_apb_char_addr),.wr_data(osd_apb_char_data),.wr_commit(osd_apb_commit_toggle),.wr_commit_page(osd_apb_commit_page),.wr_enable(osd_apb_enable),.wr_x(osd_apb_x),.wr_y(osd_apb_y),.wr_color(osd_apb_color),
  .i_vs(osd_vs),.i_hs(osd_hs),.i_de(osd_de),.i_r(osd_r),.i_g(osd_g),.i_b(osd_b),.o_vs(db_vs),.o_hs(db_hs),.o_de(db_de),.o_r(db_r),.o_g(db_g),.o_b(db_b),.o_char_pixel(db_char_pixel),.ack_toggle(osd_db_ack),.active_page(osd_db_active),.busy(osd_db_busy));

cvo_axi # (
    .SYMBOL_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_SYMBOL_WIDTH),
    .SYMBOL_NUM(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_SYMBOL_NUM),
    .PIXEL_NUM(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_PIXEL_NUM),
    .HSYNC_POL(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_HSYNC_POL),
    .VSYNC_POL(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_VSYNC_POL),
    .FIFO_DEPTH(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_FIFO_DEPTH),
    .FIFO_ALMOST_FULL(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_FIFO_ALMOST_FULL),
    .MAX_H_VALID(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_MAX_H_VALID),
    .MAX_V_VALID(`CFG_TI60F225_OOB_TOP_V_INST_CVO_AXI_INST_MAX_V_VALID)
  )
  cvo_axi_inst (
    .o_clk          (hdmi_tx_slow_clk),
    .rst_n          (display_reset_n),
    .fifo_rd_period (fifo_rd_period ),
    .fifo_rd_underflow(display_underflow),
    .s_axi_clk      (hdmi_tx_slow_clk),
    .s_axis_tdata   (m_axis_tdata   ),
    .s_axis_tvalid  (m_axis_tvalid  ),
    .s_axis_tready  (m_axis_tready  ),
    .s_axis_tlast   (m_axis_tlast   ),
    .s_axis_tuser   (m_axis_tuser   ),
    .H_FRONT_PORCH  (HFP            ),
    .H_SYNC         (HSP            ),
    .H_VALID        (HACT           ),
    .H_BACK_PORCH   (HBP            ),
    .V_FRONT_PORCH  (VFP            ),
    .V_SYNC         (VSP            ),
    .V_VALID        (VACT           ),
    .V_BACK_PORCH   (VBP            ),
     .vout          (display_pixel),
    .o_hs           (ch0_hs         ),
    .o_vs           (ch0_vs         ),
    .o_de           (ch0_de         )
  );


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
// RAW input row phase from the gain selector; sampled with capture RAW.
wire raw_row_odd;
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
	.raw_row_odd_o (raw_row_odd   )
);
ae_frame_stats #(.FRAME_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_AE_METER_FRAME_WIDTH),.FRAME_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_AE_METER_FRAME_HEIGHT),.FULL_FRAME_MEAN(`CFG_TI60F225_OOB_TOP_V_INST_AE_METER_FULL_FRAME_MEAN)) ae_meter(
  .clk(vid_clk_dvi2),.rst_n(capture_reset_n),.i_vs(rgb_vs),.i_de(rgb_de),.i_rgb(rgb_datax2),
  .i_high_threshold(ae_high_threshold),.o_high_permille(stats_high_permille),
  .o_valid(stats_valid),.o_mean(stats_mean),.o_highlights(stats_hot)
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
//==============================================================================
// MIPI DSI
//==============================================================================
// signal

reg		[`CFG_BITS_26-1:0]	r_rst_cnt;

wire	[`CFG_BITS_32-1:0]	w_axi_rdata;
wire			w_axi_awready;
wire			w_axi_wready;
wire			w_axi_arready;
wire			w_axi_rvalid;
wire			w_axi_bvalid;

wire	[`CFG_BITS_7-1:0]	w_axi_awaddr;
wire			w_axi_awvalid;
wire	[`CFG_BITS_32-1:0]	w_axi_wdata;
wire			w_axi_wvalid;
wire			w_axi_bready;
wire	[`CFG_BITS_7-1:0]	w_axi_araddr;
wire			w_axi_arvalid;
wire			w_axi_rready;

wire			w_confdone;
assign w_confdone = 1'b1;

assign  LCD_POWER 			= i_arstn;
assign	LCD_RST_P	      = ~w_arstn;//~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复位
assign	mipi_dp_clk_RST		= ~i_arstn;
assign	mipi_dp_data0_RST	= ~i_arstn;
assign	mipi_dp_data1_RST	= ~i_arstn;
assign	mipi_dp_data2_RST	= ~i_arstn;
assign	mipi_dp_data3_RST	= ~i_arstn;
////////////////////////////////////////////////////////////////
always@(posedge i_mipi_clk or  negedge w_arstn )
begin
  if ( !w_arstn ) begin
    r_rst_cnt	<= 'd0;
  end else
    r_rst_cnt	<= r_rst_cnt[25] ? r_rst_cnt :r_rst_cnt + 1'b1;
end

wire axi_rst_n = r_rst_cnt[25];

reg [`CFG_BITS_27-1:0] dly_cnt = 'd0;

always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else if( w_confdone )
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
  else
    dly_cnt <= 'd0;
end

assign vid_rst_n = dly_cnt[26];




wire hs;
wire vs;
wire de;
wire [`CFG_BITS_8-1:0] rgb_r;
wire [`CFG_BITS_8-1:0] rgb_g;
wire [`CFG_BITS_8-1:0] rgb_b;

  // color_bar_rgb #(
  // .HS_POLORY 		(1'b1		),
  // .VS_POLORY 		(1'b1		),
  // .H_FRONT_PORCH 	(HFP		),///2
  // .H_SYNC 		(HSP		),//
  // .H_VALID 		(MAX_HRES	),//
  // .H_BACK_PORCH 	(HBP		),//
  // .V_FRONT_PORCH 	(VFP		),
  // .V_SYNC 		(VSP		),
  // .V_VALID 		(MAX_VRES	),
  // .V_BACK_PORCH 	(VBP		),
  // .TEST_MODE 		(2'd2)
  // )u_color_bar_rgb1(
  // /*i*/.clk	(vid_clk_dvi2),//(vid_clk),
  // /*i*/.rst_n	(vid_rst_n),
  // /*o*/.hs	(hs),
  // /*o*/.vs	(vs),
  // /*o*/.de	(de),
  // // /*O*/.h_cnt (h_cnt),
  // // /*O*/.v_cnt (v_cnt),
  // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分量
  // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分量
  // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分量

  // );

//=================================================================================
//hdmi tx ctrl
//=================================================================================
wire                            video_hs;
wire                            video_vs;
wire                            video_de;
wire[`CFG_BITS_8-1:0]                       video_r;
wire[`CFG_BITS_8-1:0]                       video_g;
wire[`CFG_BITS_8-1:0]                       video_b;

assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

// 	  color_bar color_bar_m0(
// 	.clk(hdmi_tx_slow_clk),
// 	.rst(~vid_rst_n),
// 	.hs(video_hs),
// 	.vs(video_vs),
// 	.de(video_de),
// 	.rgb_r(video_r),
// 	.rgb_g(video_g),
// 	.rgb_b(video_b)
// );

wire [`CFG_BITS_10-1:0] tmds_data0;
wire [`CFG_BITS_10-1:0] tmds_data1;
wire [`CFG_BITS_10-1:0] tmds_data2;
wire [`CFG_BITS_10-1:0] tmds_clk ;

wire [`CFG_BITS_8-1:0] con_rdata ;
wire [`CFG_BITS_8-1:0] con_gdata ;
wire [`CFG_BITS_8-1:0] con_bdata ;
wire con_de;
wire con_hs;
wire con_vs;
wire con_sel;

wire [`CFG_BITS_8-1:0] BRIGHT_SIG    ;
wire CONTRAST_SIG_G;
wire CONTRAST_SIG_R;
wire [`CFG_BITS_8-1:0] CONTRAST_G    ;
wire CONTRAST_SIG_B;
wire [`CFG_BITS_8-1:0] BRIGHT        ;
wire [`CFG_BITS_8-1:0] CONTRAST_R    ;


wire CONTRAST_B    ;


wire [`CFG_BITS_8-1:0] tone_rdata,tone_gdata,tone_bdata;
wire tone_vs,tone_hs,tone_de;
wire [`CFG_BITS_46-1:0] tone_controls;
isp_cdc_mailbox #(.WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_TONE_CONTROL_MAILBOX_WIDTH)) tone_control_mailbox(
  .s_clk(vid_clk_dvi2),.s_rst_n(w_arstn),.s_valid(1'b1),
  .s_data({ae_exposure_constrained,ae_enable,ae_high_protect,lift_auto_enable,lift_auto_max,ae_target,lift_enable,lift_strength,tone_enable,high_green_strength,dark_red_strength}),.s_ready(),
  .d_clk(hdmi_tx_slow_clk),.d_rst_n(w_arstn),.d_valid(),.d_data(tone_controls)
);
luma_color_suppress tone_adjustment(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_enable(tone_controls[16]),
  .i_high_green(tone_controls[15:8]),.i_dark_red(tone_controls[7:0]),
  .i_vs(hdmi_tx_vs),.i_hs(hdmi_tx_hs),.i_de(hdmi_tx_de),
  .i_r(CAM_RAW_GREEN_FIRST ? hdmi_tx_bdata : hdmi_tx_rdata),.i_g(hdmi_tx_gdata),
  .i_b(CAM_RAW_GREEN_FIRST ? hdmi_tx_rdata : hdmi_tx_bdata),
  .o_vs(tone_vs),.o_hs(tone_hs),.o_de(tone_de),.o_r(tone_rdata),.o_g(tone_gdata),.o_b(tone_bdata)
);

wire [`CFG_BITS_8-1:0] lift_rdata,lift_gdata,lift_bdata;
wire lift_vs,lift_hs,lift_de;
wire display_stats_valid;
wire [`CFG_BITS_8-1:0] display_stats_mean,effective_lift_strength;
wire automatic_lift_at_max;
wire automatic_lift_enabled=tone_controls[44] && tone_controls[43] && tone_controls[42] && tone_controls[25];
auto_tone_lift automatic_lift(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_enable(automatic_lift_enabled),.i_can_lift(tone_controls[45]),
  .i_valid(display_stats_valid),.i_mean(display_stats_mean),.i_target(tone_controls[33:26]),
  .i_max_strength(tone_controls[41:34]),.i_manual_strength(tone_controls[24:17]),
  .o_strength(effective_lift_strength),.o_at_max(automatic_lift_at_max)
);
luma_tone_map #(.HIGHLIGHT_SAFE(`CFG_TI60F225_OOB_TOP_V_INST_LIFT_ADJUSTMENT_HIGHLIGHT_SAFE)) lift_adjustment(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_enable(tone_controls[25]),.i_strength(effective_lift_strength),
  .i_vs(tone_vs),.i_hs(tone_hs),.i_de(tone_de),.i_r(tone_rdata),.i_g(tone_gdata),.i_b(tone_bdata),
  .o_vs(lift_vs),.o_hs(lift_hs),.o_de(lift_de),.o_r(lift_rdata),.o_g(lift_gdata),.o_b(lift_bdata)
);

// Separate feedback after lift, before overlay. Single-pixel HDMI clock domain.
ae_frame_stats #(.FRAME_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_FRAME_WIDTH),.FRAME_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_FRAME_HEIGHT),.PIXELS_PER_CLOCK(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_PIXELS_PER_CLOCK),.MEAN_ONLY(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_MEAN_ONLY),.FULL_FRAME_MEAN(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_METER_FULL_FRAME_MEAN)) display_meter(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),.i_vs(lift_vs),.i_de(lift_de),
  .i_rgb({24'd0,lift_bdata,lift_gdata,lift_rdata}),.i_high_threshold(8'd232),
  .o_valid(display_stats_valid),.o_mean(display_stats_mean),.o_highlights(),.o_high_permille()
);
wire [`CFG_BITS_17-1:0] display_status;
isp_cdc_mailbox #(.WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_DISPLAY_STATUS_MAILBOX_WIDTH)) display_status_mailbox(
  .s_clk(hdmi_tx_slow_clk),.s_rst_n(w_arstn),.s_valid(display_stats_valid),
  .s_data({automatic_lift_at_max,effective_lift_strength,display_stats_mean}),.s_ready(),
  .d_clk(vid_clk_dvi2),.d_rst_n(w_arstn),.d_valid(),.d_data(display_status)
);
assign {lift_at_max,lift_actual_strength,ae_display_mean}=display_status;


// Replace these Debugger sources with APB register outputs in the CPU revision.
// Bits: [3] text enable, [2:1] histogram mode Y/R/G/B, [0] histogram enable.
wire osd_hist_enable,osd_text_enable;
wire [`CFG_BITS_2-1:0] osd_hist_mode;
wire [`CFG_BITS_4-1:0] osd_controls;
isp_cdc_mailbox #(.WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_OSD_CONTROL_MAILBOX_WIDTH)) osd_control_mailbox(
  .s_clk(vid_clk_dvi2),.s_rst_n(w_arstn),.s_valid(1'b1),
  .s_data({osd_text_enable,osd_hist_mode,osd_hist_enable}),.s_ready(),
  .d_clk(hdmi_tx_slow_clk),.d_rst_n(w_arstn),.d_valid(),.d_data(osd_controls)
);
wire osd_vs,osd_hs,osd_de,osd_hist_valid_hdmi,osd_hist_valid;
wire [`CFG_BITS_8-1:0] osd_r,osd_g,osd_b;
wire [`CFG_BITS_16-1:0] osd_hist_samples_hdmi,osd_hist_samples;
hdmi_info_overlay #(.FRAME_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_INFORMATION_OVERLAY_FRAME_WIDTH),.FRAME_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_INFORMATION_OVERLAY_FRAME_HEIGHT)) information_overlay(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),
  .i_vs(lift_vs),.i_hs(lift_hs),
  .i_de(lift_de),
  .i_r(lift_rdata),.i_g(lift_gdata),
  .i_b(lift_bdata),
  .i_hist_enable(osd_controls[0]),.i_hist_mode(osd_controls[2:1]),.i_text_enable(osd_controls[3]),
  .i_text_valid(1'b0),.i_text_rgb(24'd0),.o_x(),.o_y(),
  .o_hist_valid(osd_hist_valid_hdmi),.o_hist_samples(osd_hist_samples_hdmi),
  .o_vs(osd_vs),.o_hs(osd_hs),.o_de(osd_de),.o_r(osd_r),.o_g(osd_g),.o_b(osd_b)
);
isp_cdc_mailbox #(.WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_OSD_STATUS_MAILBOX_WIDTH)) osd_status_mailbox(
  .s_clk(hdmi_tx_slow_clk),.s_rst_n(w_arstn),.s_valid(1'b1),
  .s_data({osd_hist_valid_hdmi,osd_hist_samples_hdmi}),.s_ready(),
  .d_clk(vid_clk_dvi2),.d_rst_n(w_arstn),.d_valid(),.d_data({osd_hist_valid,osd_hist_samples})
);

// Fixed text is rendered in the final single-pixel HDMI domain.  The enable
// comes from the coherent OSD control mailbox; the APB revision can replace
// that source without changing the dvi_encoder interface.
wire fixed_osd_vs,fixed_osd_hs,fixed_osd_de,fixed_osd_char_pixel;
wire [`CFG_BITS_8-1:0] fixed_osd_r,fixed_osd_g,fixed_osd_b;
osd_fixed_text #(
  .FRAME_WIDTH(`CFG_TI60F225_OOB_TOP_V_INST_INFORMATION_OVERLAY_FRAME_WIDTH),
  .FRAME_HEIGHT(`CFG_TI60F225_OOB_TOP_V_INST_INFORMATION_OVERLAY_FRAME_HEIGHT),
  .BASE_X(16),.BASE_Y(16),.TEXT_LEN(9),.FG_RGB(24'h20ff40)
) fixed_text_osd(
  .clk(hdmi_tx_slow_clk),.rst_n(display_reset_n),
  .i_vs(osd_vs),.i_hs(osd_hs),.i_de(osd_de),
  // The fixed-text acceptance image is enabled by default.  APB control in
  // the integrated SoC revision replaces this constant after milestone 9.
  .i_r(osd_r),.i_g(osd_g),.i_b(osd_b),.i_enable(osd_apb_enable),
  .o_vs(fixed_osd_vs),.o_hs(fixed_osd_hs),.o_de(fixed_osd_de),
  .o_r(fixed_osd_r),.o_g(fixed_osd_g),.o_b(fixed_osd_b),.o_char_pixel(fixed_osd_char_pixel)
);

// Stable bars are shown until the CPU has initialized the camera and first
// OSD page. Switch only at a frame boundary in the HDMI clock domain.
wire bar_hs,bar_vs,bar_de;
wire [7:0] bar_r,bar_g,bar_b;
hdmi_startup_colorbar #(.HACT(HACT),.HFP(HFP),.HSP(HSP),.HBP(HBP),
  .VACT(VACT),.VFP(VFP),.VSP(VSP),.VBP(VBP)) startup_bars(
  .clk(hdmi_tx_slow_clk),.rst_n(hdmi_output_reset_n),.hs(bar_hs),.vs(bar_vs),.de(bar_de),
  .r(bar_r),.g(bar_g),.b(bar_b));
wire out_vs,out_hs,out_de;
wire [7:0] out_r,out_g,out_b;
hdmi_startup_select startup_select(
  .clk(hdmi_tx_slow_clk),.rst_n(hdmi_output_reset_n),
  .ready_async(osd_video_ready && barrier_vid_reset_n && display_reset_n),
  .bar_vs(bar_vs),.bar_hs(bar_hs),.bar_de(bar_de),.bar_r(bar_r),.bar_g(bar_g),.bar_b(bar_b),
  .cam_vs(db_vs),.cam_hs(db_hs),.cam_de(db_de),.cam_r(db_r),.cam_g(db_g),.cam_b(db_b),
  .out_vs(out_vs),.out_hs(out_hs),.out_de(out_de),.out_r(out_r),.out_g(out_g),.out_b(out_b));

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

// USER1 is owned by the Sapphire hard-JTAG channel.  The former manual
// VIO/LA instance was removed to avoid a second USER1 TAP; Efinity auto-debug
// probes use USER2 and the control values below are deterministic defaults.
// Preserve the baseline VIO calibration when the CPU owns USER1.
assign r_gain=16'h0168; assign g_gain=16'h0100; assign b_gain=16'h01a9;
assign osd_hist_enable=1'b0; assign osd_hist_mode=2'b0; assign osd_text_enable=osd_apb_enable;
// Legacy AE cannot control the sensor while the CPU owns the I2C pads.
assign ae_enable=1'b0; assign ae_target=8'd96; assign ae_high_protect=1'b1;
assign ae_high_threshold=8'd232; assign ae_high_limit=8'd10;
assign lift_auto_enable=1'b0; assign lift_auto_max=8'd0;
assign lift_enable=1'b1; assign lift_strength=8'd32; assign tone_enable=1'b1;
assign high_green_strength=8'd32; assign dark_red_strength=8'd32;

endmodule
