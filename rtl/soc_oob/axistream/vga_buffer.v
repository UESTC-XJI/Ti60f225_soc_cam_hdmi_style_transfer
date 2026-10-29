`include "../../defines.v"

/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2020 Efinix Inc. All rights reserved.
//
// Description:
// VGA Buffer 
//
// Language:  Verilog 2001
//
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////


module vga_buffer
    ( 
mem_wr_clk,  
mem_wr_rst_n,  
mem_rd_clk,  
mem_rd_rst_n,  
mem_wdata,  
mem_waddr,  
mem_raddr,  
mem_wr_en,
mem_rd_en,
mem_rdata 	 
     );

parameter DATA_WIDTH = `CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_PARAMETER_DATA_WIDTH;
parameter ADDR_WIDTH = `CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_PARAMETER_ADDR_WIDTH;
parameter RAM_DEPTH = `CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_PARAMETER_RAM_DEPTH;

input mem_wr_rst_n; 
input mem_wr_clk; 
input mem_rd_rst_n; 
input mem_rd_clk; 

input [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_1] mem_wdata;
input [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_2] mem_waddr;
input [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_3] mem_raddr;
input mem_wr_en;
input mem_rd_en;

output [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_4] mem_rdata;
reg [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_5] mem [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_6];
//integer i;

reg [`CFG_SOC_OOB_AXISTREAM_VGA_BUFFER_V_RANGE_7] mem_rdata;


always @(posedge mem_rd_clk)
  if(mem_rd_en)
    mem_rdata <= mem [mem_raddr];
/*
  always @(posedge mem_rd_clk)
  if (!mem_rd_rst_n) 
    mem_rdata <= 0;
  else if(mem_rd_en)
    mem_rdata <= mem [mem_raddr];
  else
    mem_rdata <= 0;
*/


always @(posedge mem_wr_clk)
/*  if (!mem_wr_rst_n) 
    begin
       for(i = 0;i <= RAM_DEPTH-1; i = i+ 1)
	 mem[i] <= 0;
    end */
  if(mem_wr_en)  
    mem[mem_waddr] <= mem_wdata;  
         
//initial begin
//   for(i = 0;i <= RAM_DEPTH-1; i = i+ 1)
//     mem[i] <= 0;
//end
   
endmodule


