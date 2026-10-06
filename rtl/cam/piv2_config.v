`include "../defines.v"
module piv2_config
#(
	parameter I2C_ID		= `CFG_CAM_PIV2_CONFIG_V_PARAMETER_I2C_ID,
	parameter INITIAL_CODE	= `CFG_CAM_PIV2_CONFIG_V_PARAMETER_INITIAL_CODE,
	parameter MEM_DEPTH		= `CFG_CAM_PIV2_CONFIG_V_PARAMETER_MEM_DEPTH,
	parameter REGISTER_BYTE	= `CFG_CAM_PIV2_CONFIG_V_PARAMETER_REGISTER_BYTE
)
(
	input	i_arst,
	input	i_sysclk,
	input	i_pll_locked,
	output	[`CFG_BITS_3-1:0]o_state,
	output	o_confdone,
	
	input	i_dbg_we,
	input	[`CFG_BITS_8-1:0]i_dbg_din,
	input	[`CFG_BITS_10-1:0]i_dbg_addr,
	output	[`CFG_BITS_8-1:0]o_dbg_dout,
	input	i_dbg_reconfig,
	input	i_dbg_i2c_rd,
//	output	[8*(REGISTER_BYTE-1)-1:0]o_dbg_i2c_dout,
	output	[`CFG_BITS_8-1:0]o_dbg_i2c_dout,
	
	output	[`CFG_BITS_4-1:0]o_dbg_i2c_state,
	output	[`CFG_BITS_9-1:0]o_dbg_reg_cnt,
	output	[`CFG_BITS_2-1:0]o_dbg_byte_cnt,
	output	[`CFG_BITS_8-1:0]o_dbg_rsr,
	
	input	i_sda,
	output	o_sda_oe,
	input	i_scl,
	output	o_scl_oe,
	output	o_rstn
);

localparam RAM_DEPTH = `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_RAM_DEPTH;

localparam	DEVICE_ADDRESS	= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_DEVICE_ADDRESS;
localparam	ADDRESSING		= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_ADDRESSING;
localparam	SYSCLK_FREQ		= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_SYSCLK_FREQ;
//localparam	MODE			= "STANDARD";
localparam	MODE			= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_MODE;
localparam	SLAVE_ENABLE	= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_SLAVE_ENABLE;
localparam	tSYSCLK			= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_TSYSCLK;

//localparam	s_IDLE		= 3'b001;
localparam	s_IDLE		= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_IDLE;
localparam	s_CONFIG	= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_CONFIG;
localparam	s_DONE		= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_DONE;
//localparam	s_DONE		= 3'b000;
localparam	s_WAIT		= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_WAIT;
localparam	s_LAST		= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_LAST; // debug
localparam	s_READ_ADDR	= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_READ_ADDR;
localparam	s_READ_DATA	= `CFG_CAM_PIV2_CONFIG_V_LOCALPARAM_S_READ_DATA;

reg		r_m_en_1P;
reg		r_m_wr_1P;
wire	[`CFG_BITS_8-1:0]w_opn008_reg;
reg		r_last_1P;
wire	w_ack;
wire	w_last;
wire	[`CFG_BITS_8-1:0]w_data;

reg		[`CFG_BITS_3-1:0]s_state;
reg		[`CFG_BITS_10-1:0]r_addr_1P;
//reg		[8*(REGISTER_BYTE-1)-1:0]r_i2c_data_1P;
reg		[`CFG_BITS_8-1:0]r_i2c_data_1P;
reg		[`CFG_BITS_2-1:0]r_byte_cnt_1P;
reg		[`CFG_BITS_9-1:0]r_reg_cnt_1P;

reg		r_confdone_1P;
reg		[`CFG_BITS_16-1:0]r_timer_1P;
reg		r_rstn_1P;

reg		[`CFG_BITS_16-1:0]r_clk_div_1P;
reg		r_clk_div_2P;
reg		r_clk_div_3P;
reg		[`CFG_BITS_8-1:0]r_ms_dly_1P;

reg		r_dbg_reconfig_1P;
reg		r_dbg_reconfig_2P;
reg		r_dbg_i2c_rd_1P;
reg		r_dbg_i2c_rd_2P;

i2c_wrapper
#(
	.DEVICE_ADDRESS	(`CFG_CAM_PIV2_CONFIG_V_INST_INST_I2C_DEVICE_ADDRESS),
	.ADDRESSING		(`CFG_CAM_PIV2_CONFIG_V_INST_INST_I2C_ADDRESSING),
	.SYSCLK_FREQ	(`CFG_CAM_PIV2_CONFIG_V_INST_INST_I2C_SYSCLK_FREQ),
	.MODE			(`CFG_CAM_PIV2_CONFIG_V_INST_INST_I2C_MODE),
	.SLAVE_ENABLE	(`CFG_CAM_PIV2_CONFIG_V_INST_INST_I2C_SLAVE_ENABLE)
)
inst_i2c
(
	.i_arst		(i_arst),
	.i_sysclk	(i_sysclk),
	.i_m_en		(r_m_en_1P),
	.i_m_wr		(r_m_wr_1P),
	.i_last		(r_last_1P),
	.i_addr		(7'h10),		// I2C ID
	.i_data		(w_opn008_reg),
//	.o_s_en		(w_s_en),
//	.o_s_wr		(w_s_wr),
	.o_ack		(w_ack),
	.o_last		(w_last),
	.o_data		(w_data),
	.o_dbg_i2c_state	(o_dbg_i2c_state),
	.o_dbg_rsr			(o_dbg_rsr),
	.i_sda		(i_sda),
	.o_sda_oe	(o_sda_oe),
	.i_scl		(i_scl),
	.o_scl_oe	(o_scl_oe)
);
/*
opn008_reg
inst_opn008_reg
(
	.i_addr(r_addr_1P),
	.o_data(w_opn008_reg)
);
*/
true_dual_port_ram
#(
	.DATA_WIDTH(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_DATA_WIDTH),
	.ADDR_WIDTH(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_ADDR_WIDTH),
	.WRITE_MODE_1(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_WRITE_MODE_1),
	.WRITE_MODE_2(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_WRITE_MODE_2),
	.OUTPUT_REG_1(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_OUTPUT_REG_1),
	.OUTPUT_REG_2(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_OUTPUT_REG_2),
	.RAM_INIT_FILE(`CFG_CAM_PIV2_CONFIG_V_INST_INST_PIV2_REG_RAM_INIT_FILE)		// Initial code file   ("piv2_720p_reg.mem")
)
inst_piv2_reg
(
	.we1(1'b0),
	.we2(i_dbg_we),
	.clka(i_sysclk),
	.clkb(i_sysclk),
	.din1({8{1'b0}}),
	.din2(i_dbg_din),
	.addr1(r_addr_1P[9:0]),
	.addr2(i_dbg_addr),
	.dout1(w_opn008_reg),
	.dout2(o_dbg_dout)
);

always@(posedge i_arst or posedge i_sysclk)
begin
	if (i_arst)
	begin
		s_state	<= s_IDLE;
		r_addr_1P				<= {10{1'b0}};
		r_m_en_1P				<= 1'b0;
		r_m_wr_1P				<= 1'b0;
		r_last_1P				<= 1'b0;
//		r_i2c_data_1P			<= {8*(REGISTER_BYTE-1){1'b0}};
		r_i2c_data_1P			<= {8{1'b1}};
		
		r_byte_cnt_1P			<= {2{1'b0}};
		r_reg_cnt_1P			<= {9{1'b0}};
		
		r_confdone_1P			<= 1'b0;
		r_timer_1P				<= {16{1'b0}};
		r_rstn_1P				<= 1'b0;
		
		r_clk_div_1P			<= {16{1'b0}};
		r_ms_dly_1P				<= {8{1'b0}};
		
		r_dbg_reconfig_1P		<= 1'b0;
		r_dbg_reconfig_2P		<= 1'b0;
		r_dbg_i2c_rd_1P			<= 1'b0;
		r_dbg_i2c_rd_2P			<= 1'b0;
	end
	else
	begin
		case (s_state)
			s_IDLE:
			begin
				if (r_rstn_1P)
				begin
					r_timer_1P	<= r_timer_1P+1'b1;
					if (r_timer_1P == 16'd50000)
					begin
						s_state					<= s_CONFIG;
						r_addr_1P				<= {10{1'b0}};
						r_m_en_1P				<= 1'b1;
						r_m_wr_1P				<= 1'b0;
						r_last_1P				<= 1'b0;
						
						r_byte_cnt_1P			<= {2{1'b0}};
						r_reg_cnt_1P			<= {9{1'b0}};
					end
				end
				else /*if (i_pll_locked)*/
				begin
					r_timer_1P	<= r_timer_1P+1'b1;
					if (r_timer_1P == 16'd500/tSYSCLK)
					begin
						r_rstn_1P	<= 1'b1;
						r_timer_1P	<= {16{1'b0}};
					end
				end
			end
			
			s_CONFIG:
			begin
				r_m_en_1P		<= 1'b1;
				r_last_1P		<= 1'b0;
				if (w_ack)
				begin
					if (r_reg_cnt_1P != RAM_DEPTH)		// MEM depth
					begin
						r_addr_1P		<= r_addr_1P+1'b1;
						r_byte_cnt_1P	<= r_byte_cnt_1P+1'b1;
						if (r_byte_cnt_1P == REGISTER_BYTE-1'b1)		// Number of byte of register
						begin
							r_m_en_1P		<= 1'b0;
							r_last_1P		<= 1'b1;
							r_byte_cnt_1P	<= {2{1'b0}};
							r_reg_cnt_1P	<= r_reg_cnt_1P+1'b1;
						end						
					end
					else
					begin
						s_state	<= s_DONE;
						r_m_en_1P				<= 1'b0;
						r_confdone_1P			<= 1'b1;
					end
				end
			end
	
			s_WAIT:
			begin
				r_clk_div_1P	<= r_clk_div_1P+1'b1;
				r_clk_div_2P	<= r_clk_div_1P[15];
				r_clk_div_3P	<= r_clk_div_2P;
				if (~r_clk_div_2P & r_clk_div_3P)
				begin
					r_ms_dly_1P		<= r_ms_dly_1P+1'b1;
				
					if (r_ms_dly_1P == 8'd255)
					begin
						s_state	<= s_CONFIG;
						r_m_en_1P				<= 1'b1;
						r_m_wr_1P				<= 1'b0;
						r_last_1P				<= 1'b0;
					end
				end
			end
			
			s_DONE:
			begin
				r_m_en_1P			<= 1'b0;
				r_m_wr_1P			<= 1'b0;
				r_last_1P			<= 1'b0;
				r_dbg_reconfig_1P	<= i_dbg_reconfig;
				r_dbg_reconfig_2P	<= r_dbg_reconfig_1P;
				r_dbg_i2c_rd_1P		<= i_dbg_i2c_rd;
				r_dbg_i2c_rd_2P		<= r_dbg_i2c_rd_1P;
				if (r_dbg_reconfig_1P && ~r_dbg_reconfig_2P)
					s_state	<= s_IDLE;
				else if (r_dbg_i2c_rd_1P && ~r_dbg_i2c_rd_2P)
				begin
					s_state	<= s_READ_ADDR;
					r_addr_1P				<= i_dbg_addr;
					r_m_en_1P				<= 1'b1;
					r_m_wr_1P				<= 1'b0;
					r_last_1P				<= 1'b1;
					
					r_byte_cnt_1P			<= {2{1'b0}};
				end
			end
			
			s_READ_ADDR:
			begin
				r_last_1P				<= 1'b0;
				if (w_ack)
				begin
					r_addr_1P				<= r_addr_1P+1'b1;
					r_byte_cnt_1P			<= r_byte_cnt_1P+1'b1;
					if (r_byte_cnt_1P == 2'd1)
					begin
						s_state	<= s_READ_DATA;
						r_m_en_1P				<= 1'b0;
						r_last_1P				<= 1'b1;
						r_byte_cnt_1P			<= {2{1'b0}};
					end
				end
			end
			
			s_READ_DATA:
			begin
				r_m_en_1P	<= 1'b1;
				r_m_wr_1P	<= 1'b1;
				if (w_ack)
				begin
//					r_i2c_data_1P	<= {w_data, r_i2c_data_1P[8*(REGISTER_BYTE-1)-1:8]};
					r_i2c_data_1P	<= w_data;
					r_byte_cnt_1P	<= r_byte_cnt_1P+1'b1;
					if (r_byte_cnt_1P == 2'd0)
					begin
						s_state	<= s_DONE;
						r_m_en_1P				<= 1'b0;
						r_last_1P				<= 1'b1;
						r_byte_cnt_1P			<= {2{1'b0}};
					end
				end
			end

			s_LAST:
			begin
				/*r_addr_1P <= 10'h000;
				r_m_en_1P <= 1'b0;
				r_m_wr_1P <= 1'b0;
				r_last_1P <= 1'b1;
				s_state <= s_DONE;*/
			end
			
			default:
			begin
				s_state	<= s_IDLE;
				r_addr_1P				<= {10{1'b0}};
				r_m_en_1P				<= 1'b0;
				r_m_wr_1P				<= 1'b0;
				
				r_byte_cnt_1P			<= {2{1'b0}};
				r_reg_cnt_1P			<= {9{1'b0}};
			end
		endcase
	end
end

assign	o_dbg_i2c_dout	= r_i2c_data_1P;
assign	o_dbg_reg_cnt	= r_reg_cnt_1P;
assign	o_dbg_byte_cnt	= r_byte_cnt_1P;

assign	o_state			= s_state;
assign	o_confdone		= r_confdone_1P;
assign	o_rstn			= r_rstn_1P;

endmodule
