`include "defines.v"
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2020 Efinix Inc. All rights reserved.
//
// Description:
// System Reset Control  
//
// Language:  Verilog 2001
//
// ------------------------------------------------------------------------------
/////////////////////////////////////////////////////////////////////////////////

module reset_ctrl
#(
	parameter	NUM_RST			= `CFG_RESET_V_PARAMETER_NUM_RST,
	parameter	CYCLE			= `CFG_RESET_V_PARAMETER_CYCLE,
	parameter	IN_RST_ACTIVE	= `CFG_RESET_V_PARAMETER_IN_RST_ACTIVE,
	parameter	OUT_RST_ACTIVE	= `CFG_RESET_V_PARAMETER_OUT_RST_ACTIVE
)
(
	input	[`CFG_RESET_V_RANGE_1]	i_arst,
	input	[`CFG_RESET_V_RANGE_2]	i_clk,
	output	[`CFG_RESET_V_RANGE_3]	o_srst
);

genvar i;
generate
	for (i=0; i<NUM_RST; i=i+1)
	begin
		if (IN_RST_ACTIVE & (1'b1 << i))
		begin
			if (OUT_RST_ACTIVE & (1'b1 << i))
			begin
				reset
				#(
					.IN_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_IN_RST_ACTIVE),
					.OUT_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_OUT_RST_ACTIVE),
					.CYCLE			(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_CYCLE)
				)
				inst_sysclk_rstn
				(
					.i_arst	(i_arst[i]),
					.i_clk	(i_clk[i]),
					.o_srst	(o_srst[i])
				);
			end
			else
			begin
				reset
				#(
					.IN_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_IN_RST_ACTIVE_2),
					.OUT_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_OUT_RST_ACTIVE_2),
					.CYCLE			(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_CYCLE_2)
				)
				inst_sysclk_rstn
				(
					.i_arst	(i_arst[i]),
					.i_clk	(i_clk[i]),
					.o_srst	(o_srst[i])
				);
			end
		end
		else
		begin
			if (OUT_RST_ACTIVE & (1'b1 << i))
			begin
				reset
				#(
					.IN_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_IN_RST_ACTIVE_3),
					.OUT_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_OUT_RST_ACTIVE_3),
					.CYCLE			(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_CYCLE_3)
				)
				inst_sysclk_rstn
				(
					.i_arst	(i_arst[i]),
					.i_clk	(i_clk[i]),
					.o_srst	(o_srst[i])
				);
			end
			else
			begin
				reset
				#(
					.IN_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_IN_RST_ACTIVE_4),
					.OUT_RST_ACTIVE	(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_OUT_RST_ACTIVE_4),
					.CYCLE			(`CFG_RESET_V_INST_INST_SYSCLK_RSTN_CYCLE_4)
				)
				inst_sysclk_rstn
				(
					.i_arst	(i_arst[i]),
					.i_clk	(i_clk[i]),
					.o_srst	(o_srst[i])
				);
			end
		end
	end
endgenerate

endmodule


module reset
#(
	parameter	IN_RST_ACTIVE	= `CFG_RESET_V_PARAMETER_IN_RST_ACTIVE_2,
	parameter	OUT_RST_ACTIVE	= `CFG_RESET_V_PARAMETER_OUT_RST_ACTIVE_2,
	parameter	CYCLE			= `CFG_RESET_V_PARAMETER_CYCLE_2
)
(
	input	i_arst,
	input	i_clk,

	output	o_srst
);

reg		[`CFG_RESET_V_RANGE_4]r_srst_1P;

genvar i;
generate
	if (IN_RST_ACTIVE == "LOW")
	begin
		if (OUT_RST_ACTIVE == "LOW")
		begin
			always@(negedge i_arst or posedge i_clk)
			begin
				if (~i_arst)
					r_srst_1P[0]	<= 1'b0;
				else
					r_srst_1P[0]	<= 1'b1;
			end
			
			for (i=0; i<CYCLE-1; i=i+1)
			begin
				always@(negedge i_arst or posedge i_clk)
				begin
					if (~i_arst)
						r_srst_1P[i+1]	<= 1'b0;
					else
						r_srst_1P[i+1]	<= r_srst_1P[i];
				end
			end
		end
		else
		begin
			always@(negedge i_arst or posedge i_clk)
			begin
				if (~i_arst)
					r_srst_1P[0]	<= 1'b1;
				else
					r_srst_1P[0]	<= 1'b0;
			end
			
			for (i=0; i<CYCLE-1; i=i+1)
			begin
				always@(negedge i_arst or posedge i_clk)
				begin
					if (~i_arst)
						r_srst_1P[i+1]	<= 1'b1;
					else
						r_srst_1P[i+1]	<= r_srst_1P[i];
				end
			end
		end
	end
	else
	begin
		if (OUT_RST_ACTIVE == "LOW")
		begin
			always@(posedge i_arst or posedge i_clk)
			begin
				if (i_arst)
					r_srst_1P[0]	<= 1'b0;
				else
					r_srst_1P[0]	<= 1'b1;
			end
			
			for (i=0; i<CYCLE-1; i=i+1)
			begin
				always@(posedge i_arst or posedge i_clk)
				begin
					if (i_arst)
						r_srst_1P[i+1]	<= 1'b0;
					else
						r_srst_1P[i+1]	<= r_srst_1P[i];
				end
			end
		end
		else
		begin
			always@(posedge i_arst or posedge i_clk)
			begin
				if (i_arst)
					r_srst_1P[0]	<= 1'b1;
				else
					r_srst_1P[0]	<= 1'b0;
			end
			
			for (i=0; i<CYCLE-1; i=i+1)
			begin
				always@(posedge i_arst or posedge i_clk)
				begin
					if (i_arst)
						r_srst_1P[i+1]	<= 1'b1;
					else
						r_srst_1P[i+1]	<= r_srst_1P[i];
				end
			end
		end
	end
endgenerate

assign	o_srst	= r_srst_1P[CYCLE-1];

endmodule
