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
  /*o*/.scl_pad_o     (io_cam_scl_OUT),
  /*o*/.scl_padoen_o  (scl_padoen_o),
  /*i*/.sda_pad_i     (io_cam_sda_IN),
  /*o*/.sda_pad_o     (io_cam_sda_OUT),
  /*o*/.sda_padoen_o  (sda_padoen_o),
  .runtime_wr_en(ae_wr_en),.runtime_rd_en(ae_rd_en),.runtime_addr(ae_addr),.runtime_data(ae_write_data),
  .config_done(sensor_config_done),.runtime_wr_done(ae_wr_done),.runtime_rd_done(ae_rd_done),
  .runtime_wr_error(ae_wr_error),.runtime_rd_error(ae_rd_error),.runtime_read_data(ae_read_data)
  
  );
assign o_cam_rst_p = ~w_arstn;
assign io_cam_scl_OE = ~scl_padoen_o;
assign io_cam_sda_OE = ~sda_padoen_o;

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
// Wait for DDR calibration, then release resets synchronously in each domain.
wire video_reset_n = vid_rst_n && cal_done && user_pll_locked;
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
	

       .awid			(s_axi_awid	),      
       .awaddr		(s_axi_awaddr	),
       .awlen			(s_axi_awlen	),
       .awsize		(s_axi_awsize	),
       .awburst		(s_axi_awburst),
       .awprot    (s_axi_awprot ),
       .awcache   (s_axi_awcache),
       .awlock		(s_axi_awlock	),
       .awvalid		(s_axi_awvalid),
       .awready		(s_axi_awready),

       .arid			(s_axi_arid	  ),
       .araddr		(s_axi_araddr	),
       .arlen			(s_axi_arlen	),
       .arsize		(s_axi_arsize	),
       .arburst 	(s_axi_arburst),

       .arprot    (s_axi_arprot ),
       .arcache   (s_axi_arcache),
       .arlock 		(s_axi_arlock	),
       .arvalid		(s_axi_arvalid),
       .arready		(s_axi_arready),

       .wdata			(s_axi_wdata	),
       .wstrb			(s_axi_wstrb	),
       .wlast			(s_axi_wlast	),
       .wvalid		(s_axi_wvalid	),
       .wready		(s_axi_wready	),


       .rid			  (s_axi_rid	),
       .rdata			(s_axi_rdata	),
       .rlast			(s_axi_rlast	),
       .rvalid 		(s_axi_rvalid	),
       .rready		(s_axi_rready	),
       .rresp			(s_axi_rresp	),

       .bid			  (s_axi_bid	),
       .bvalid		(s_axi_bvalid	),
       .bready	  (s_axi_bready	)
);

		    
		    
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

dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~display_reset_n),// reset
	.i_bdata      		(osd_b),
	.i_gdata     		(osd_g),
	.i_rdata       		(osd_r),
  .i_de            	(osd_de),
	.i_hs         		(osd_hs),
	.i_vs         		(osd_vs),
	
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

debug_edb_top debug_edb_top_inst (
    .bscan_CAPTURE      ( jtag_inst1_CAPTURE  ),
    .bscan_DRCK         ( jtag_inst1_DRCK     ),
    .bscan_RESET        ( jtag_inst1_RESET    ),
    .bscan_RUNTEST      ( jtag_inst1_RUNTEST  ),
    .bscan_SEL          ( jtag_inst1_SEL      ),
    .bscan_SHIFT        ( jtag_inst1_SHIFT    ),
    .bscan_TCK          ( jtag_inst1_TCK      ),
    .bscan_TDI          ( jtag_inst1_TDI      ),
    .bscan_TMS          ( jtag_inst1_TMS      ),
    .bscan_UPDATE       ( jtag_inst1_UPDATE   ),
    .bscan_TDO          ( jtag_inst1_TDO      ),
    .vio0_clk           ( vid_clk_dvi2        ),
    .vio0_r_gain        ( r_gain              ),
    .vio0_g_gain        ( g_gain              ),
    .vio0_b_gain        ( b_gain              ),
    .vio0_osd_hist_enable (osd_hist_enable),
    .vio0_osd_hist_mode (osd_hist_mode),
    .vio0_osd_text_enable (osd_text_enable),
    .vio0_osd_hist_valid (osd_hist_valid),
    .vio0_osd_hist_samples (osd_hist_samples),
    .vio0_ae_enable     (ae_enable),
    .vio0_ae_target     (ae_target),
    .vio0_ae_high_protect (ae_high_protect),
    .vio0_ae_high_threshold (ae_high_threshold),
    .vio0_ae_high_limit  (ae_high_limit),
    .vio0_lift_auto_enable (lift_auto_enable),
    .vio0_lift_auto_max (lift_auto_max),
    .vio0_ae_display_mean (ae_display_mean),
    .vio0_ae_exposure_constrained (ae_exposure_constrained),
    .vio0_lift_actual_strength (lift_actual_strength),
    .vio0_lift_at_max (lift_at_max),
    .vio0_lift_enable   (lift_enable),
    .vio0_lift_strength (lift_strength),
    .vio0_tone_enable   (tone_enable),
    .vio0_high_green_strength (high_green_strength),
    .vio0_dark_red_strength   (dark_red_strength),
    .vio0_ae_ready      (ae_ready),
    .vio0_ae_fault      (ae_fault),
    .vio0_ae_at_limit   (ae_at_limit),
    .vio0_ae_at_min     (ae_at_min),
    .vio0_ae_at_max     (ae_at_max),
    .vio0_ae_highlights (ae_highlights),
    .vio0_ae_high_permille (ae_high_permille),
    .vio0_ae_highlight_limited (ae_highlight_limited),
    .vio0_ae_vts        (ae_vts),
    .vio0_ae_exposure   (ae_exposure),
    .vio0_ae_mean       (ae_mean),
    .la0_clk            ( vid_clk_dvi2        ),
    .la0_ch0_g          (capture_raw[7:0]),
    .la0_ch0_b          (capture_raw[15:8]),
    .la0_ch0_de         (capture_de),
    .la0_cal_done       ( cal_done            ),
    .la0_ch0_vs         (capture_vs),
    .la0_raw_row_odd    ( raw_row_odd         )
);

endmodule
