`include "../defines.v"

/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for SOC 
//
// Language:  Verilog 2001
//
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

// ------------------------------------------------------------------------------
// 1. User requires to manually uncomment SOFT_TAP definition and reassign pin for
// soft jtag pins
// 2. User requires to manually edit SDC constraint for io_systemClk
// ------------------------------------------------------------------------------

`include "hyperram_controller_define.vh"
//`define SOFT_TAP 1
module top_soc_oob (
	//Clock Control
	input      io_systemClk,
	input      io_asyncReset,
	input      io_memoryClk,
	output	   io_memoryReset,
    output   wire  io_systemReset,
    input       in_vclk,
    input       out_vclk,
	input 		sd_base_clk,
	
    input 		vga_reset,
   
	//Memory Interface
	output              io_ddrA_arw_valid,
	input               io_ddrA_arw_ready,
	output     [`CFG_BITS_32-1:0]   io_ddrA_arw_payload_addr,
	output     [`CFG_BITS_8-1:0]    io_ddrA_arw_payload_id,
	output     [`CFG_BITS_4-1:0]    io_ddrA_arw_payload_region,
	output     [`CFG_BITS_8-1:0]    io_ddrA_arw_payload_len,
	output     [`CFG_BITS_3-1:0]    io_ddrA_arw_payload_size,
	output     [`CFG_BITS_2-1:0]    io_ddrA_arw_payload_burst,
	output     [`CFG_BITS_1-1:0]    io_ddrA_arw_payload_lock,
	output     [`CFG_BITS_4-1:0]    io_ddrA_arw_payload_cache,
	output     [`CFG_BITS_4-1:0]    io_ddrA_arw_payload_qos,
	output     [`CFG_BITS_3-1:0]    io_ddrA_arw_payload_prot,
	output              io_ddrA_arw_payload_write,
	output              io_ddrA_w_valid,
	input               io_ddrA_w_ready,
	output     [`CFG_SOC_OOB_TOP_SOC_OOB_V_RANGE_1]  io_ddrA_w_payload_data,
	output     [`CFG_BITS_16-1:0]   io_ddrA_w_payload_strb,
	output              io_ddrA_w_payload_last,
	input               io_ddrA_b_valid,
	output              io_ddrA_b_ready,
	input      [`CFG_BITS_8-1:0]    io_ddrA_b_payload_id,
	input      [`CFG_BITS_2-1:0]    io_ddrA_b_payload_resp,
	input               io_ddrA_r_valid,
	output              io_ddrA_r_ready,
	input      [`CFG_SOC_OOB_TOP_SOC_OOB_V_RANGE_2]  io_ddrA_r_payload_data,
	input      [`CFG_BITS_8-1:0]    io_ddrA_r_payload_id,
	input      [`CFG_BITS_2-1:0]    io_ddrA_r_payload_resp,
	input               io_ddrA_r_payload_last,
	output     [`CFG_BITS_8-1:0]    io_ddrA_w_payload_id,


	//user custom ports
	output	[`CFG_BITS_6-1:0]		o_LED,					//Bit [3:0]
	input	[`CFG_BITS_6-1:0]		i_switch,
	
	//Reg 2 RGB Gain Control
	output 	[`CFG_BITS_3-1:0]		o_red_gain,				//Bit [2:0]
	output 	[`CFG_BITS_3-1:0]		o_green_gain,			//Bit [6:4]
	output 	[`CFG_BITS_3-1:0]		o_blue_gain,				//Bit [10:8]
	
	//UVC Control
	input 	[`CFG_BITS_3-1:0]		i_uvc_status,
	output 	[`CFG_BITS_3-1:0]		o_uvc_control,
	output				o_uvc_resetn,
	
	output [`CFG_BITS_13-1:0]		o_uvc_X_START,
	output [`CFG_BITS_13-1:0]		o_uvc_X_WIN,
	output [`CFG_BITS_13-1:0]		o_uvc_Y_START,
	output [`CFG_BITS_13-1:0]		o_uvc_Y_WIN,
	
	
	//SOC Ports
  	output              system_uart_0_io_txd,
  	input               system_uart_0_io_rxd,
  	output         		system_spi_0_io_sclk_write,
  	output              system_spi_0_io_data_0_writeEnable,
  	input          		system_spi_0_io_data_0_read,
  	output         		system_spi_0_io_data_0_write,
  	output              system_spi_0_io_data_1_writeEnable,
  	input          		system_spi_0_io_data_1_read,
  	output         		system_spi_0_io_data_1_write,
  	output         		system_spi_0_io_ss,
	
	output              system_i2c_0_io_sda_write,
	input               system_i2c_0_io_sda_read,
	output              system_i2c_0_io_scl_write,
	input               system_i2c_0_io_scl_read,
	  
	  
	//Video Stream Input
	input [`CFG_BITS_11-1:0] 		in_0_x_wr,
	input [`CFG_BITS_11-1:0] 		in_0_y_wr,
	input				in_0_wr_en,
	input				in_0_vs,
	input				in_0_hs,
	input [`CFG_BITS_8-1:0]			in_0_wr_00,
	input [`CFG_BITS_8-1:0]			in_0_wr_01,
	input [`CFG_BITS_8-1:0]			in_0_wr_10,
	input [`CFG_BITS_8-1:0]			in_0_wr_11,
	
	//Video Stream Output
	output          	out_0_de,
	output				out_0_valid,
	output          	out_0_hsync,
	output          	out_0_vsync,
	output [`CFG_BITS_8-1:0] 		out_0_rd_00,
	output [`CFG_BITS_8-1:0] 		out_0_rd_01,
	output [`CFG_BITS_8-1:0] 		out_0_rd_10,
	output [`CFG_BITS_8-1:0] 		out_0_rd_11,
	
	
	//SD Interface
	output  wire           sd_clk_hi,
	output  wire           sd_clk_lo,
	input                  sd_cmd_i,
	output  wire           sd_cmd_o,
	output  wire           sd_cmd_oe,
	input           [`CFG_BITS_4-1:0]  sd_dat_i,
	output  wire    [`CFG_BITS_4-1:0]  sd_dat_o,
	output  wire    [`CFG_BITS_4-1:0]  sd_dat_oe,
	input                  sd_wp,
	input                  sd_cd_n,
	
	  
`ifndef SOFT_TAP
	input 				jtagCtrl_tck,
  	input 				jtagCtrl_tdi,
  	output				jtagCtrl_tdo,
  	input 				jtagCtrl_enable,
  	input 				jtagCtrl_capture,
  	input 				jtagCtrl_shift,
  	input 				jtagCtrl_update,
  	input 				jtagCtrl_reset
	
`else
  	input  				io_jtag_tms,
  	input  				io_jtag_tdi,
  	output 				io_jtag_tdo,
  	input  				io_jtag_tck
`endif
);
/////////////////////////////////////////////////////////////////////////////

parameter	MAX_HRES		= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_MAX_HRES;
parameter	MAX_VRES		= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_MAX_VRES;
parameter	HSP				= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_HSP;
parameter	HBP				= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_HBP;
parameter	HFP				= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_HFP;
parameter	VSP				= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_VSP;
parameter	VBP				= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_VBP;
parameter	VFP				= `CFG_SOC_OOB_TOP_SOC_OOB_V_PARAMETER_VFP;

localparam  VIDEOIN_WIDTH  = `CFG_SOC_OOB_TOP_SOC_OOB_V_LOCALPARAM_VIDEOIN_WIDTH;
localparam  VIDEOOUT_WIDTH =  `CFG_SOC_OOB_TOP_SOC_OOB_V_LOCALPARAM_VIDEOOUT_WIDTH;




endmodule

//////////////////////////////////////////////////////////////////////////////
// Copyright (C) 2013-2020 Efinix Inc. All rights reserved.
//
// This   document  contains  proprietary information  which   is
// protected by  copyright. All rights  are reserved.  This notice
// refers to original work by Efinix, Inc. which may be derivitive
// of other work distributed under license of the authors.  In the
// case of derivative work, nothing in this notice overrides the
// original author's license agreement.  Where applicable, the 
// original license agreement is included in it's original 
// unmodified form immediately below this header.
//
// WARRANTY DISCLAIMER.  
//     THE  DESIGN, CODE, OR INFORMATION ARE PROVIDED “AS IS” AND 
//     EFINIX MAKES NO WARRANTIES, EXPRESS OR IMPLIED WITH 
//     RESPECT THERETO, AND EXPRESSLY DISCLAIMS ANY IMPLIED WARRANTIES, 
//     INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF 
//     MERCHANTABILITY, NON-INFRINGEMENT AND FITNESS FOR A PARTICULAR 
//     PURPOSE.  SOME STATES DO NOT ALLOW EXCLUSIONS OF AN IMPLIED 
//     WARRANTY, SO THIS DISCLAIMER MAY NOT APPLY TO LICENSEE.
//
// LIMITATION OF LIABILITY.  
//     NOTWITHSTANDING ANYTHING TO THE CONTRARY, EXCEPT FOR BODILY 
//     INJURY, EFINIX SHALL NOT BE LIABLE WITH RESPECT TO ANY SUBJECT 
//     MATTER OF THIS AGREEMENT UNDER TORT, CONTRACT, STRICT LIABILITY 
//     OR ANY OTHER LEGAL OR EQUITABLE THEORY (I) FOR ANY INDIRECT, 
//     SPECIAL, INCIDENTAL, EXEMPLARY OR CONSEQUENTIAL DAMAGES OF ANY 
//     CHARACTER INCLUDING, WITHOUT LIMITATION, DAMAGES FOR LOSS OF 
//     GOODWILL, DATA OR PROFIT, WORK STOPPAGE, OR COMPUTER FAILURE OR 
//     MALFUNCTION, OR IN ANY EVENT (II) FOR ANY AMOUNT IN EXCESS, IN 
//     THE AGGREGATE, OF THE FEE PAID BY LICENSEE TO EFINIX HEREUNDER 
//     (OR, IF THE FEE HAS BEEN WAIVED, $100), EVEN IF EFINIX SHALL HAVE 
//     BEEN INFORMED OF THE POSSIBILITY OF SUCH DAMAGES.  SOME STATES DO 
//     NOT ALLOW THE EXCLUSION OR LIMITATION OF INCIDENTAL OR 
//     CONSEQUENTIAL DAMAGES, SO THIS LIMITATION AND EXCLUSION MAY NOT 
//     APPLY TO LICENSEE.
//
/////////////////////////////////////////////////////////////////////////////
