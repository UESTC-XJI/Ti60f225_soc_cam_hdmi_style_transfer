`include "defines.v"
/////////////////////////////////////////////////////////////////////////////
////
//// Copyright (C) 2013-2020 Efinix Inc. All rights reserved.
////
//// Description:
//// A dual port ram 
////
//// Language:  Verilog 2001
////
////
//------------------------------------------------------------------------------
//// REVISION:
////  $Snapshot: $
////  $Id:$
////
//// History:
//// 1.0 Initial Release. 
///////////////////////////////////////////////////////////////////////////////////

module user_dual_port_ram
#(
	parameter DATA_WIDTH	= `CFG_USER_DUAL_PORT_RAM_V_PARAMETER_DATA_WIDTH,
	parameter ADDR_WIDTH	= `CFG_USER_DUAL_PORT_RAM_V_PARAMETER_ADDR_WIDTH,
	parameter OUTPUT_REG	= `CFG_USER_DUAL_PORT_RAM_V_PARAMETER_OUTPUT_REG,
	parameter RAM_INIT_FILE	= `CFG_USER_DUAL_PORT_RAM_V_PARAMETER_RAM_INIT_FILE
)
(
	input [`CFG_USER_DUAL_PORT_RAM_V_RANGE_1] wdata,
	input [`CFG_USER_DUAL_PORT_RAM_V_RANGE_2] waddr, raddr,
	input we, wclk, re, rclk,
	output [`CFG_USER_DUAL_PORT_RAM_V_RANGE_3] rdata
);

	localparam MEMORY_DEPTH = `CFG_USER_DUAL_PORT_RAM_V_LOCALPARAM_MEMORY_DEPTH;
	localparam MAX_DATA = `CFG_USER_DUAL_PORT_RAM_V_LOCALPARAM_MAX_DATA;
	
	reg [`CFG_USER_DUAL_PORT_RAM_V_RANGE_4] ram[`CFG_USER_DUAL_PORT_RAM_V_RANGE_5];
	reg [`CFG_USER_DUAL_PORT_RAM_V_RANGE_6] r_rdata_1P;
	reg [`CFG_USER_DUAL_PORT_RAM_V_RANGE_7] r_rdata_2P;
	
	integer i;
	initial
	begin
	// By default the Efinix memory will initialize to 0
		if (RAM_INIT_FILE != "")
		begin
			$readmemh(RAM_INIT_FILE, ram);
		end
	end
	
	always @ (posedge wclk)
		if (we)
		ram[waddr] <= wdata;
	
	always @ (posedge rclk)
	begin
		if (re)
			r_rdata_1P <= ram[raddr];
		r_rdata_2P <= r_rdata_1P;
	end
	
	generate
		if (OUTPUT_REG == "TRUE")
			assign	rdata = r_rdata_2P;
		else
			assign	rdata = r_rdata_1P;
	endgenerate

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


