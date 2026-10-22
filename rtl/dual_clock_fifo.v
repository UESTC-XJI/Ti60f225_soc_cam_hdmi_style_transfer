`include "defines.v"
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2018 Efinix Inc. All rights reserved.
//
// Dual Clock FIFO
//
//********************************
// Revisions:
// 0.0 Initial rev
// 0.1 Added read/write count, almost full, almost empty signal
//********************************

module dual_clock_fifo_wrapper
#(
	parameter	DATA_WIDTH		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_DATA_WIDTH,
	parameter	ADDR_WIDTH		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_ADDR_WIDTH,
	parameter	LATENCY			= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_LATENCY,
	parameter	FIFO_MODE		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_FIFO_MODE,
	parameter	RAM_INIT_FILE	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_RAM_INIT_FILE,
	/////////////////////////////////////////////////////////////////////////////////////
	// compatibility	output_reg			check_full_overflow		check_empty_underflow
	/////////////////////////////////////////////////////////////////////////////////////
	// E				user configurable	user configurable		user configurable
	// X				user configurable	always on				always on
	// A				always off			user configurable		user configurable
	parameter	COMPATIBILITY	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_COMPATIBILITY,
	parameter	OUTPUT_REG		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_OUTPUT_REG,
	parameter	CHECK_FULL		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_CHECK_FULL,
	parameter	CHECK_EMPTY		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_CHECK_EMPTY,
	parameter	AFULL_THRESHOLD	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AFULL_THRESHOLD,
	parameter	AEMPTY_THRESHOLD= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AEMPTY_THRESHOLD,
	parameter	AFULL_OFFSET	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AFULL_OFFSET,
	parameter	AEMPTY_OFFSET	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AEMPTY_OFFSET
)
(
	input						i_arst,
	
	input						i_wclk,
	input						i_we,
	input	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_1]	i_wdata,
	
	input						i_rclk,
	input						i_re,
//	input						i_restore,
	
	output						o_full,
	output						o_empty,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_2]	o_rdata,
	
	output						o_afull,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_3]	o_wcnt,
	output						o_aempty,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_4]	o_rcnt,
	
	output						o_dbg_w_re,
	
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_5]		o_dbg_w_waddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_6]	o_dbg_w_waddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_7]		o_dbg_r_waddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_8]	o_dbg_r_waddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_9]	o_dbg_r_waddrg_2P,
	output						o_dbg_r_wflag_1P,
	
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_10]		o_dbg_w_raddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_11]	o_dbg_w_raddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_12]		o_dbg_r_raddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_13]	o_dbg_r_raddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_14]	o_dbg_r_raddrg_2P,
	output						o_dbg_r_rflag_1P,
	output						o_dbg_r_rflag_2P
);

generate
	if (COMPATIBILITY == "X")
	begin
		if (FIFO_MODE == "BYPASS")
		begin
			dual_clock_fifo
			#(
				.DATA_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_DATA_WIDTH),
				.ADDR_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_ADDR_WIDTH),
				.LATENCY			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_LATENCY),
				.FIFO_MODE			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_FIFO_MODE),
				.RAM_INIT_FILE		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_RAM_INIT_FILE),
				.COMPATIBILITY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_COMPATIBILITY),
				.OUTPUT_REG			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_OUTPUT_REG),
				.CHECK_FULL			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_FULL),
				.CHECK_EMPTY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_EMPTY),
				.AFULL_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_THRESHOLD),
				.AEMPTY_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_THRESHOLD),
				.AFULL_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_OFFSET),
				.AEMPTY_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_OFFSET)
			)
			inst_dual_clock_fifo
			(
				.i_arst		(i_arst),
				.i_wclk		(i_wclk),
				.i_we		(i_we),
				.i_wdata	(i_wdata),
				.i_rclk		(i_rclk),
				.i_re		(i_re),
//				.i_restore	(i_restore),
				.o_full		(o_full),
				.o_empty	(o_empty),
				.o_rdata	(o_rdata),
				
				.o_afull	(o_afull),
				.o_wcnt		(o_wcnt),
				.o_aempty	(o_aempty),
				.o_rcnt		(o_rcnt)
			);
		end
		else
		begin
			dual_clock_fifo
			#(
				.DATA_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_DATA_WIDTH_2),
				.ADDR_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_ADDR_WIDTH_2),
				.LATENCY			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_LATENCY_2),
				.FIFO_MODE			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_FIFO_MODE_2),
				.RAM_INIT_FILE		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_RAM_INIT_FILE_2),
				.COMPATIBILITY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_COMPATIBILITY_2),
				.OUTPUT_REG			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_OUTPUT_REG_2),
				.CHECK_FULL			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_FULL_2),
				.CHECK_EMPTY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_EMPTY_2),
				.AFULL_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_THRESHOLD_2),
				.AEMPTY_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_THRESHOLD_2),
				.AFULL_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_OFFSET_2),
				.AEMPTY_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_OFFSET_2)
			)
			inst_dual_clock_fifo
			(
				.i_arst		(i_arst),
				.i_wclk		(i_wclk),
				.i_we		(i_we),
				.i_wdata	(i_wdata),
				.i_rclk		(i_rclk),
				.i_re		(i_re),
//				.i_restore	(i_restore),
				.o_full		(o_full),
				.o_empty	(o_empty),
				.o_rdata	(o_rdata),
				
				.o_afull	(o_afull),
				.o_wcnt		(o_wcnt),
				.o_aempty	(o_aempty),
				.o_rcnt		(o_rcnt)
			);
		end
	end
	else if (COMPATIBILITY == "A")
	begin
		dual_clock_fifo
		#(
			.DATA_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_DATA_WIDTH_3),
			.ADDR_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_ADDR_WIDTH_3),
			.LATENCY			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_LATENCY_3),
			.FIFO_MODE			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_FIFO_MODE_3),
			.RAM_INIT_FILE		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_RAM_INIT_FILE_3),
			.COMPATIBILITY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_COMPATIBILITY_3),
			.OUTPUT_REG			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_OUTPUT_REG_3),
			.CHECK_FULL			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_FULL_3),
			.CHECK_EMPTY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_EMPTY_3),
			.AFULL_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_THRESHOLD_3),
			.AEMPTY_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_THRESHOLD_3),
			.AFULL_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_OFFSET_3),
			.AEMPTY_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_OFFSET_3)
		)
		inst_dual_clock_fifo
		(
			.i_arst		(i_arst),
			.i_wclk		(i_wclk),
			.i_we		(i_we),
			.i_wdata	(i_wdata),
			.i_rclk		(i_rclk),
			.i_re		(i_re),
//			.i_restore	(i_restore),
			.o_full		(o_full),
			.o_empty	(o_empty),
			.o_rdata	(o_rdata),
			
			.o_afull	(o_afull),
			.o_wcnt		(o_wcnt),
			.o_aempty	(o_aempty),
			.o_rcnt		(o_rcnt)
		);
	end
	else
	begin
		dual_clock_fifo
		#(
			.DATA_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_DATA_WIDTH_4),
			.ADDR_WIDTH			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_ADDR_WIDTH_4),
			.LATENCY			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_LATENCY_4),
			.FIFO_MODE			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_FIFO_MODE_4),
			.RAM_INIT_FILE		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_RAM_INIT_FILE_4),
			.COMPATIBILITY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_COMPATIBILITY_4),
			.OUTPUT_REG			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_OUTPUT_REG_4),
			.CHECK_FULL			(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_FULL_4),
			.CHECK_EMPTY		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_CHECK_EMPTY_4),
			.AFULL_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_THRESHOLD_4),
			.AEMPTY_THRESHOLD	(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_THRESHOLD_4),
			.AFULL_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AFULL_OFFSET_4),
			.AEMPTY_OFFSET		(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_DUAL_CLOCK_FIFO_AEMPTY_OFFSET_4)
		)
		inst_dual_clock_fifo
		(
			.i_arst		(i_arst),
			.i_wclk		(i_wclk),
			.i_we		(i_we),
			.i_wdata	(i_wdata),
			.i_rclk		(i_rclk),
			.i_re		(i_re),
//			.i_restore	(i_restore),
			.o_full		(o_full),
			.o_empty	(o_empty),
			.o_rdata	(o_rdata),
			
			.o_afull	(o_afull),
			.o_wcnt		(o_wcnt),
			.o_aempty	(o_aempty),
			.o_rcnt		(o_rcnt),
			
			.o_dbg_w_re			(o_dbg_w_re),
			
			.o_dbg_w_waddrb_1P	(o_dbg_w_waddrb_1P),
			.o_dbg_w_waddrg_1P	(o_dbg_w_waddrg_1P),
			.o_dbg_r_waddrb_1P	(o_dbg_r_waddrb_1P),
			.o_dbg_r_waddrg_1P	(o_dbg_r_waddrg_1P),
			.o_dbg_r_waddrg_2P	(o_dbg_r_waddrg_2P),
			.o_dbg_r_wflag_1P	(o_dbg_r_wflag_1P),
			
			.o_dbg_w_raddrb_1P	(o_dbg_w_raddrb_1P),
			.o_dbg_w_raddrg_1P	(o_dbg_w_raddrg_1P),
			.o_dbg_r_raddrb_1P	(o_dbg_r_raddrb_1P),
			.o_dbg_r_raddrg_1P	(o_dbg_r_raddrg_1P),
			.o_dbg_r_raddrg_2P	(o_dbg_r_raddrg_2P),
			.o_dbg_r_rflag_1P	(o_dbg_r_rflag_1P),
			.o_dbg_r_rflag_2P	(o_dbg_r_rflag_2P)
		);
	end
endgenerate

endmodule

module dual_clock_fifo
#(
	parameter	DATA_WIDTH		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_DATA_WIDTH_2,
	parameter	ADDR_WIDTH		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_ADDR_WIDTH_2,
	parameter	LATENCY			= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_LATENCY_2,
	parameter	FIFO_MODE		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_FIFO_MODE_2,
	parameter	RAM_INIT_FILE	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_RAM_INIT_FILE_2,
	parameter	COMPATIBILITY	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_COMPATIBILITY_2,
	parameter	OUTPUT_REG		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_OUTPUT_REG_2,
	parameter	CHECK_FULL		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_CHECK_FULL_2,
	parameter	CHECK_EMPTY		= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_CHECK_EMPTY_2,
	parameter	AFULL_THRESHOLD	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AFULL_THRESHOLD_2,
	parameter	AEMPTY_THRESHOLD= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AEMPTY_THRESHOLD_2,
	parameter	AFULL_OFFSET	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AFULL_OFFSET_2,
	parameter	AEMPTY_OFFSET	= `CFG_DUAL_CLOCK_FIFO_V_PARAMETER_AEMPTY_OFFSET_2
)
(
	input						i_arst,
	
	input						i_wclk,
	input						i_we,
	input	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_15]	i_wdata,
	
	input						i_rclk,
	input						i_re,
//	input						i_restore,
	
	output						o_full,
	output						o_empty,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_16]	o_rdata,
	
	output						o_afull,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_17]	o_wcnt,
	output						o_aempty,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_18]	o_rcnt,
	
	output						o_dbg_w_re,
	
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_19]		o_dbg_w_waddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_20]	o_dbg_w_waddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_21]		o_dbg_r_waddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_22]	o_dbg_r_waddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_23]	o_dbg_r_waddrg_2P,
	output						o_dbg_r_wflag_1P,
	
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_24]		o_dbg_w_raddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_25]	o_dbg_w_raddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_26]		o_dbg_r_raddrb_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_27]	o_dbg_r_raddrg_1P,
	output	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_28]	o_dbg_r_raddrg_2P,
	output						o_dbg_r_rflag_1P,
	output						o_dbg_r_rflag_2P
);

(* async_reg = "true" *)reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_29]	r_waddrb_1P;
(* async_reg = "true" *)reg						r_wflag_1P;
(* async_reg = "true" *)reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_30]r_waddrg_1P;
(* async_reg = "true" *)reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_31]r_waddrg_2P;

reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_32]r_raddrb_wclk_1P;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_33]r_raddrb_wclk_neg;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_34]wr_cnt;

reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_35]r_waddrb_rclk_1P;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_36]r_waddrb_rclk_neg;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_37]rd_cnt;

reg						r_we_1P;
reg						r_re_1P;
(* async_reg = "true" *)reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_38]	r_raddrb_1P;
(* async_reg = "true" *)reg						r_rflag_1P;
(* async_reg = "true" *)reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_39]r_raddrg_1P;
(* async_reg = "true" *)reg						r_rflag_2P;
(* async_reg = "true" *)reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_40]r_raddrg_2P;

reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_41]	r_empty;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_42]		r_full;

//reg		r_restore_1P;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_43]	r_raddrb_2P;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_44]r_raddrg_PP;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_45]	r_raddrb_3P;
reg		[`CFG_DUAL_CLOCK_FIFO_V_RANGE_46]r_raddrg_3P;

wire	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_47]	w_waddrb_1P;
wire					w_wflag_1P;
wire	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_48]w_waddrg_1P;

wire	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_49]	w_raddrb_1P;
wire					w_rflag_1P;
wire	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_50]w_raddrg_1P;

wire	w_empty;
wire	w_full;

wire	w_empty_P;
wire	w_full_P;

wire					w_we;
wire					w_re;
wire	[`CFG_DUAL_CLOCK_FIFO_V_RANGE_51]w_raddr;

assign	w_waddrb_1P					=	r_waddrb_1P + 1'b1;
assign	w_wflag_1P					=	w_waddrb_1P[ADDR_WIDTH];
assign	w_waddrg_1P[ADDR_WIDTH-1]	=	w_waddrb_1P[ADDR_WIDTH-1] ^ 1'b0;
assign	w_waddrg_1P[ADDR_WIDTH-2:0]	=	w_waddrb_1P[ADDR_WIDTH-2:0] ^ w_waddrb_1P[ADDR_WIDTH-1:1];

assign	w_full	=	((r_waddrg_1P == r_raddrg_1P) &
					(r_wflag_1P != r_rflag_1P))?
						1'b1:
					(i_we &
					((w_waddrg_1P == r_raddrg_2P) &
					(w_wflag_1P != r_rflag_2P)))?
						1'b1:
						1'b0;

always@(posedge i_arst or posedge i_wclk)
begin
	if (i_arst) begin
		r_raddrb_wclk_1P	<= {ADDR_WIDTH+1{1'b0}};
	end
	else begin
		r_raddrb_wclk_1P	<= r_raddrb_1P;
	end
end

always@(posedge i_arst or posedge i_wclk)
begin
	if (i_arst) begin
		r_raddrb_wclk_neg	<= {ADDR_WIDTH+1{1'b0}};
	end
	else begin
		r_raddrb_wclk_neg	<= ~r_raddrb_wclk_1P + 1'b1;
	end
end

always@(posedge i_arst or posedge i_wclk)
begin
	if (i_arst) begin
		wr_cnt			<= {ADDR_WIDTH+1{1'b0}};
	end
	else begin
		wr_cnt			<= r_waddrb_1P + r_raddrb_wclk_neg;
	end
end

always@(posedge i_arst or posedge i_rclk)
begin
	if (i_arst) begin
		r_waddrb_rclk_1P	<= {ADDR_WIDTH+1{1'b0}};
	end
	else begin
		r_waddrb_rclk_1P	<= r_waddrb_1P;
	end
end

always@(posedge i_arst or posedge i_rclk)
begin
	if (i_arst) begin
		r_waddrb_rclk_neg	<= {ADDR_WIDTH+1{1'b0}};
	end
	else begin
		r_waddrb_rclk_neg	<= ~r_waddrb_rclk_1P;
	end
end

always@(posedge i_arst or posedge i_rclk)
begin
	if (i_arst) begin
		rd_cnt			<= {ADDR_WIDTH+1{1'b0}};
	end
	else begin
		rd_cnt			<= r_raddrb_1P + r_waddrb_rclk_neg;
	end
end

always@(posedge i_arst or posedge i_wclk)
begin
	if (i_arst)
	begin
		r_we_1P			<= 1'b0;
		r_waddrb_1P		<= {ADDR_WIDTH+1{1'b0}};
		r_wflag_1P		<= 1'b0;
		r_waddrg_1P		<= {ADDR_WIDTH{1'b0}};
		r_waddrg_2P		<= {ADDR_WIDTH{1'b0}};
		
		r_full[0]		<= 1'b0;
	end
	else
	begin
		r_we_1P	<= 1'b0;

		if (CHECK_FULL == "TRUE")
		begin
			if (i_we & ~w_full_P)
			begin
				r_we_1P			<= 1'b1;
				r_waddrb_1P		<= w_waddrb_1P;
				r_wflag_1P		<= w_wflag_1P;
				r_waddrg_1P		<= w_waddrg_1P;
			end
		end
		else
		begin
			if (i_we)
			begin
				r_we_1P			<= 1'b1;
				r_waddrb_1P		<= w_waddrb_1P;
				r_wflag_1P		<= w_wflag_1P;
				r_waddrg_1P		<= w_waddrg_1P;
			end
		end
		
		if (r_we_1P)
			r_waddrg_2P		<= r_waddrg_1P;
		
		r_full[0]		<= w_full;
	end
end

assign	w_raddrb_1P					=	r_raddrb_1P + 1'b1;
assign	w_rflag_1P					=	w_raddrb_1P[ADDR_WIDTH];
assign	w_raddrg_1P[ADDR_WIDTH-1]	=	w_raddrb_1P[ADDR_WIDTH-1] ^ 1'b0;
assign	w_raddrg_1P[ADDR_WIDTH-2:0]	=	w_raddrb_1P[ADDR_WIDTH-2:0] ^ w_raddrb_1P[ADDR_WIDTH-1:1];

assign	w_empty	=	((r_waddrg_2P == r_raddrg_1P) &
//					(r_wflag_1P == r_rflag_2P))?
					(r_wflag_1P == r_rflag_1P))?	// changed for BYPASS
						1'b1:
					(i_re &
					((r_waddrg_1P == r_raddrg_1P) &
					(r_wflag_1P == r_rflag_1P)))?
						1'b1:
						1'b0;
//assign	w_empty	=	(r_waddrg_2P == r_raddrg_1P)?
//						1'b1:
//					(i_re & (r_waddrg_1P == r_raddrg_1P))?
//						1'b1:
//						1'b0;

always@(posedge i_arst or posedge i_rclk)
begin
	if (i_arst)
	begin
		r_re_1P			<= 1'b0;
		r_raddrb_1P		<= {ADDR_WIDTH+1{1'b0}};
		r_rflag_1P		<= 1'b0;
		r_raddrg_1P		<= {ADDR_WIDTH{1'b0}};
		r_rflag_2P		<= 1'b0;
		r_raddrg_2P		<= {ADDR_WIDTH{1'b0}};
		
		r_empty[0]		<= 1'b1;
		
//		r_restore_1P	<= 1'b0;
		r_raddrb_2P		<= {ADDR_WIDTH+1{1'b0}};
		r_raddrg_PP		<= {ADDR_WIDTH{1'b0}};
		r_raddrb_3P		<= {ADDR_WIDTH+1{1'b0}};
		r_raddrg_3P		<= {ADDR_WIDTH{1'b0}};
	end
	else
	begin
		r_re_1P	<= 1'b0;
		
//		r_restore_1P	<= 1'b0;
		r_raddrb_2P		<= r_raddrb_1P;
		r_raddrg_PP		<= r_raddrg_1P;
		r_raddrb_3P		<= r_raddrb_2P;
		r_raddrg_3P		<= r_raddrg_PP;
		
//		if (CHECK_FULL == "TRUE")
		if (CHECK_EMPTY == "TRUE")
		begin
			if (i_re & ~w_empty_P)
			begin
				r_re_1P			<= 1'b1;
				r_raddrb_1P		<= w_raddrb_1P;
				r_rflag_1P		<= w_rflag_1P;
				r_raddrg_1P		<= w_raddrg_1P;
			end
/*			else if (i_restore)
			begin
				r_restore_1P	<= 1'b1;
				r_raddrb_1P		<= r_raddrb_3P;
				r_raddrg_1P		<= r_raddrg_3P;
			end*/
		end
		else
		begin
			if (i_re)
			begin
				r_re_1P			<= 1'b1;
				r_raddrb_1P		<= w_raddrb_1P;
				r_rflag_1P		<= w_rflag_1P;
				r_raddrg_1P		<= w_raddrg_1P;
			end
/*			else if (i_restore)
			begin
				r_restore_1P	<= 1'b1;
				r_raddrb_1P		<= r_raddrb_3P;
				r_raddrg_1P		<= r_raddrg_3P;
			end*/
		end
		
		if (r_re_1P)
		begin
			r_raddrg_2P		<= r_raddrg_1P;
			r_rflag_2P		<= r_rflag_1P;
		end
		
		r_empty[0]		<= w_empty;
	end
end

genvar i, j;
generate
	for (i=1; i<LATENCY; i=i+1)
	begin: pipe_empty
		always@(posedge i_arst or posedge i_rclk)
		begin
			if (i_arst)
				r_empty[i]	<= 1'b1;
			else
				r_empty[i]	<= r_empty[i-1];
		end
	end
	
	assign	w_empty_P	= w_empty | r_empty[LATENCY-1];
//	assign	w_empty_P	= r_empty[0];
	
	for (j=1; j<LATENCY+1; j=j+1)
	begin: pipe_full
		always@(posedge i_arst or posedge i_wclk)
		begin
			if (i_arst)
				r_full[j]	<= 1'b0;
			else
				r_full[j]	<= r_full[j-1];
		end
	end
	
	if (COMPATIBILITY == "X")
		if (FIFO_MODE == "BYPASS")
			assign	w_full_P	= r_full[0] | r_full[LATENCY-2];
		else
			assign	w_full_P	= r_full[0]	| r_full[LATENCY];
	else
		assign	w_full_P	= r_full[0] | r_full[LATENCY-1];
//	assign	w_full_P	= r_full[0];
	
	if (CHECK_FULL == "TRUE")
		assign	w_we	= i_we & ~w_full_P;
	else
		assign	w_we	= i_we;
	
	if (FIFO_MODE == "BYPASS")
	begin
		assign	w_re	= 1'b1;
		if (CHECK_EMPTY == "TRUE")
			assign	w_raddr	= (i_re & ~w_empty_P)?
								w_raddrg_1P[ADDR_WIDTH-1:0]:
								r_raddrg_1P[ADDR_WIDTH-1:0];
		else
			assign	w_raddr	= (i_re)?
								w_raddrg_1P[ADDR_WIDTH-1:0]:
								r_raddrg_1P[ADDR_WIDTH-1:0];
	end
	else
	begin
		if (CHECK_EMPTY == "TRUE")
			assign	w_re	= i_re & ~w_empty_P;
//			assign	w_re	= (i_re | r_restore_1P) & ~w_empty_P;
		else
			assign	w_re	= i_re;
//			assign	w_re	= i_re | r_restore_1P;
		assign	w_raddr	= r_raddrg_1P[ADDR_WIDTH-1:0];
	end

	simple_dual_port_ram
	#(
		.DATA_WIDTH(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_SIMPLE_DUAL_PORT_RAM_DATA_WIDTH),
		.ADDR_WIDTH(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_SIMPLE_DUAL_PORT_RAM_ADDR_WIDTH),
		.OUTPUT_REG(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_SIMPLE_DUAL_PORT_RAM_OUTPUT_REG),
		.RAM_INIT_FILE(`CFG_DUAL_CLOCK_FIFO_V_INST_INST_SIMPLE_DUAL_PORT_RAM_RAM_INIT_FILE)
	)
	inst_simple_dual_port_ram
	(
		.wdata(i_wdata),
		.waddr(r_waddrg_1P[ADDR_WIDTH-1:0]),
		.raddr(w_raddr),
		.we(w_we),
		.wclk(i_wclk),
		.re(w_re),
		.rclk(i_rclk),
		.rdata(o_rdata)
	);
endgenerate

//assign	o_empty	= w_empty_P;
//assign	o_full	= w_full_P;
//assign	o_empty	= (r_empty == {LATENCY{1'b1}});
/*assign	o_full	= (COMPATIBILITY == "X")?
						(FIFO_MODE == "BYPASS")?
							(r_full[LATENCY-2:0] != {LATENCY-1{1'b0}}):
							(r_full != {LATENCY+1{1'b1}}):
						(r_full[LATENCY-1:0] != {LATENCY{1'b0}});*/
assign	o_empty	= w_empty_P;
assign	o_full	= w_full_P;

//assign	o_aempty= w_empty_P;
//assign	o_wcnt	= r_waddrb_1P;
//assign	o_afull	= w_full_P;
//assign	o_rcnt	= r_raddrb_1P;

//assign	o_aempty= w_empty_P | (rd_cnt[ADDR_WIDTH-1] & rd_cnt[ADDR_WIDTH-2] & rd_cnt[ADDR_WIDTH-3]);
assign	o_wcnt	= wr_cnt[ADDR_WIDTH] ? {ADDR_WIDTH{1'b1}} : wr_cnt[ADDR_WIDTH-1:0];
//assign	o_afull	= w_full_P | wr_cnt[ADDR_WIDTH] | (wr_cnt[ADDR_WIDTH-1] & wr_cnt[ADDR_WIDTH-2] & wr_cnt[ADDR_WIDTH-3]);
assign	o_rcnt	= w_full_P ? {ADDR_WIDTH{1'b0}} : rd_cnt[ADDR_WIDTH-1:0];

assign	o_aempty= w_empty_P | (rd_cnt[ADDR_WIDTH-1:AEMPTY_OFFSET] == {ADDR_WIDTH-AEMPTY_OFFSET{1'b1}});
assign	o_afull	= w_full_P | wr_cnt[ADDR_WIDTH] | (wr_cnt[ADDR_WIDTH-1:AFULL_OFFSET] == {ADDR_WIDTH-AFULL_OFFSET{1'b1}});

assign	o_dbg_w_re			= w_re;

assign	o_dbg_w_waddrb_1P	= w_waddrb_1P;
assign	o_dbg_w_waddrg_1P	= w_waddrg_1P;
assign	o_dbg_r_waddrb_1P	= r_waddrb_1P;
assign	o_dbg_r_waddrg_1P	= r_waddrg_1P;
assign	o_dbg_r_waddrg_2P	= r_waddrg_2P;
assign	o_dbg_r_wflag_1P	= r_wflag_1P;

assign	o_dbg_w_raddrb_1P	= w_raddrb_1P;
assign	o_dbg_w_raddrg_1P	= w_raddrg_1P;
assign	o_dbg_r_raddrb_1P	= r_raddrb_1P;
assign	o_dbg_r_raddrg_1P	= r_raddrg_1P;
assign	o_dbg_r_raddrg_2P	= r_raddrg_2P;
assign	o_dbg_r_rflag_1P	= r_rflag_1P;
assign	o_dbg_r_rflag_2P	= r_rflag_2P;

endmodule
