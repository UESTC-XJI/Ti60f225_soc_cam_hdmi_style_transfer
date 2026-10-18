`include "../defines.v"
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2018 Efinix Inc. All rights reserved.
//
// Single RAM block
//
// *******************************
// Revisions:
// 0.0 Initial rev
// 0.1 Added output register
// 1.0 Finalized RTL macro
// *******************************

module simple_dual_port_ram
#(
	parameter DATA_WIDTH	= `CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_PARAMETER_DATA_WIDTH,
	parameter ADDR_WIDTH	= `CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_PARAMETER_ADDR_WIDTH,
	parameter OUTPUT_REG	= `CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_PARAMETER_OUTPUT_REG,
	parameter RAM_INIT_FILE	= `CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_PARAMETER_RAM_INIT_FILE
)
(
	input [`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_1] wdata,
	input [`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_2] waddr, raddr,
	input we, wclk, re, rclk,
	output [`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_3] rdata
);

	localparam MEMORY_DEPTH = `CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_LOCALPARAM_MEMORY_DEPTH;
	localparam MAX_DATA = `CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_LOCALPARAM_MAX_DATA;
	
	reg [`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_4] ram[`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_5];
	reg [`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_6] r_rdata_1P;
	reg [`CFG_DVI_TX_SIMPLE_DUAL_PORT_RAM_V_RANGE_7] r_rdata_2P;
	
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

