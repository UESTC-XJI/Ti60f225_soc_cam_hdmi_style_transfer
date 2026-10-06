`include "defines.v"
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2018 Efinix Inc. All rights reserved.
//
// True Dual Port RAM
//
//*******************************
//	Revisions:
//	0.0 Initial rev
//	0.1 Added output register
//	1.0 Finalized RTL macro
//*******************************

module true_dual_port_ram
#(
	parameter DATA_WIDTH	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_DATA_WIDTH,
	parameter ADDR_WIDTH	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_ADDR_WIDTH,
	parameter WRITE_MODE_1	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_WRITE_MODE_1,	// WRITE_FIRST, READ_FIRST, NO_CHANGE
	parameter WRITE_MODE_2	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_WRITE_MODE_2,
	parameter OUTPUT_REG_1	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_OUTPUT_REG_1,
	parameter OUTPUT_REG_2	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_OUTPUT_REG_2,
	parameter RAM_INIT_FILE	= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_RAM_INIT_FILE,
	parameter RAM_INIT_RADIX= `CFG_TRUE_DUAL_PORT_RAM_V_PARAMETER_RAM_INIT_RADIX
)
(
	input we1, we2, clka, clkb,
	input [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_1] din1, din2,
	input [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_2] addr1, addr2,
	output[`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_3] dout1, dout2
);

	localparam MEMORY_DEPTH = `CFG_TRUE_DUAL_PORT_RAM_V_LOCALPARAM_MEMORY_DEPTH;
	localparam MAX_DATA = `CFG_TRUE_DUAL_PORT_RAM_V_LOCALPARAM_MAX_DATA;
	
	reg [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_4] ram [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_5];
	
	reg [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_6] r_dout1_1P;
	reg [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_7] r_dout2_1P;

	reg [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_8] r_dout1_2P;
	reg [`CFG_TRUE_DUAL_PORT_RAM_V_RANGE_9] r_dout2_2P;
	
	integer i;
	initial
	begin
//	// By default the Efinix memory will initialize to 0
		if (RAM_INIT_FILE != "")
		begin
			if (RAM_INIT_RADIX == "BIN")
				$readmemb(RAM_INIT_FILE, ram);
			else
				$readmemh(RAM_INIT_FILE, ram);
		end
	end
	
	generate
		if (WRITE_MODE_1 == "WRITE_FIRST")
		begin
			always@(posedge clka)
			begin
				if (we1)
				begin
					ram[addr1]	<= din1;
					r_dout1_1P	<= din1;
				end
				else
					r_dout1_1P	<= ram[addr1];
			end
		end
		else if (WRITE_MODE_1 == "READ_FIRST")
		begin
			always@(posedge clka)
			begin
				if (we1)
					ram[addr1]	<= din1;
				r_dout1_1P	<= ram[addr1];
			end
		end
		else if (WRITE_MODE_1 == "NO_CHANGE")
		begin
			always@(posedge clka)
			begin
				if (we1)
					ram[addr1]	<= din1;
				else
					r_dout1_1P	<= ram[addr1];
			end
		end
		
		if (WRITE_MODE_2 == "WRITE_FIRST")
		begin
			always@(posedge clkb)
			begin
				if (we2)
				begin
					ram[addr2]	<= din2;
					r_dout2_1P	<= din2;
				end
				else
					r_dout2_1P	<= ram[addr2];
			end
		end
		else if (WRITE_MODE_2 == "READ_FIRST")
		begin
			always@(posedge clkb)
			begin
				if (we2)
					ram[addr2]	<= din2;
				r_dout2_1P	<= ram[addr2];
			end
		end
		else if (WRITE_MODE_2 == "NO_CHANGE")
		begin
			always@(posedge clkb)
			begin
				if (we2)
					ram[addr2]	<= din2;
				else
					r_dout2_1P	<= ram[addr2];
			end
		end

		if (OUTPUT_REG_1 == "TRUE")
		begin
			always@(posedge clka)
				r_dout1_2P	<= r_dout1_1P;
			
			assign dout1 = r_dout1_2P;
		end
		else
			assign dout1 = r_dout1_1P;
		
		if (OUTPUT_REG_2 == "TRUE")
		begin
			always@(posedge clkb)
				r_dout2_2P	<= r_dout2_1P;

			assign dout2 = r_dout2_2P;
		end
		else
			assign dout2 = r_dout2_1P;
	endgenerate
	
endmodule
