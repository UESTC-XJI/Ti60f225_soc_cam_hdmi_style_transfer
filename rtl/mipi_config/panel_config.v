`include "../defines.v"
module panel_config
#(
	parameter INITIAL_CODE	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_PARAMETER_INITIAL_CODE,
	parameter REG_DEPTH		= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_PARAMETER_REG_DEPTH
)
(
	input		i_axi_clk,
	input		i_restn,
	
	input		i_axi_awready,
	input		i_axi_wready,
	input		i_axi_bvalid,
	output reg	[`CFG_BITS_7-1:0]o_axi_awaddr,
	output reg	o_axi_awvalid,
	output reg	[`CFG_BITS_32-1:0]o_axi_wdata,
	output reg	o_axi_wvalid,
	output reg	o_axi_bready,
	
	input		i_axi_arready,
	input		[`CFG_BITS_32-1:0]i_axi_rdata,
	input		i_axi_rvalid,
	output reg	[`CFG_BITS_7-1:0]o_axi_araddr,
	output reg	o_axi_arvalid,
	output reg	o_axi_rready,
	
	output		o_addr_cnt,
	output		[`CFG_BITS_4-1:0]o_state,
	output		o_confdone,
	
	input		i_dbg_we,
	input		[`CFG_BITS_40-1:0]i_dbg_din,
	input		[`CFG_BITS_9-1:0]i_dbg_addr,
	output		[`CFG_BITS_40-1:0]o_dbg_dout,
	input		i_dbg_reconfig
);

localparam	IDLE 		= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_IDLE;
localparam	WRITE_ADDR 	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_WRITE_ADDR;
localparam	PRE_WRITE 	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_PRE_WRITE;
localparam	WRITE 		= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_WRITE;
localparam	POST_WRITE 	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_POST_WRITE;
localparam	READ_ADDR 	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_READ_ADDR;
localparam	PRE_READ 	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_PRE_READ;
localparam	READ 		= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_READ;
localparam	POST_READ 	= `CFG_MIPI_CONFIG_PANEL_CONFIG_V_LOCALPARAM_POST_READ;

reg 	[`CFG_BITS_4-1:0]r_state;
reg 	r_done;
reg 	r_confdone;
reg 	[`CFG_BITS_22-1:0]r_timer;
reg 	[`CFG_BITS_16-1:0]r_addr;
reg 	[`CFG_BITS_32-1:0]r_read_reg;
reg		[`CFG_BITS_3-1:0]r_cnt;

wire	[`CFG_BITS_40-1:0]w_reg;
wire	[`CFG_BITS_40-1:0]w_reg_default;

assign	o_addr_cnt	= r_addr[0];

true_dual_port_ram
#(
	.DATA_WIDTH(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_DATA_WIDTH),
	.ADDR_WIDTH(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_ADDR_WIDTH),
	.WRITE_MODE_1(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_WRITE_MODE_1),
	.WRITE_MODE_2(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_WRITE_MODE_2),
	.OUTPUT_REG_1(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_OUTPUT_REG_1),
	.OUTPUT_REG_2(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_OUTPUT_REG_2),
	.RAM_INIT_FILE(`CFG_MIPI_CONFIG_PANEL_CONFIG_V_INST_INST_PIV2_REG_RAM_INIT_FILE)		// Initial code file   ("piv2_720p_reg.mem")
)
inst_piv2_reg
(
	.we1(1'b0),
	.we2(i_dbg_we),
	.clka(i_axi_clk),
	.clkb(i_axi_clk),
	.din1({40{1'b0}}),
	.din2(i_dbg_din),
	.addr1(r_addr[8:0]),
	.addr2(i_dbg_addr),
	.dout1(w_reg_default),
	.dout2(o_dbg_dout)
);

assign	w_reg	= w_reg_default;

always@(negedge i_restn or posedge i_axi_clk)
begin
	if (~i_restn)
	begin
		r_state			<= IDLE;
		o_axi_awaddr	<= {7{1'b0}};
		o_axi_awvalid	<= 1'b0;
		o_axi_wdata		<= {32{1'b0}};
		o_axi_wvalid    <= 1'b0;
		o_axi_bready    <= 1'b0;
		o_axi_araddr	<= {7{1'b0}};
		o_axi_arvalid   <= 1'b0;
		o_axi_rready	<= 1'b0;
		r_done			<= 1'b1;
		r_confdone		<= 1'b0;
		r_timer			<= {22{1'b0}};
		r_addr			<= {16{1'b0}};
		r_read_reg		<= {32{1'b0}};
		r_cnt			<= 3'b0;
	end
	else
	begin
		case (r_state)
			IDLE:
			begin				
				if ((r_addr == REG_DEPTH) || (w_reg == 40'b0))//read to the last address
					r_confdone	<= 1'b1;
				else if (w_reg[39:32] == 8'b0) //read the wait address
				begin
					if (~r_done)
					begin
						if (r_timer == w_reg[21:0])
						begin
							r_done	<= 1'b1;
							r_addr	<= r_addr + 1'b1;
							r_timer	<= {22{1'b0}};
						end
						else
							r_timer 	<= r_timer + 1'b1;
					end
				end
				else if (~r_confdone) //每个地址之间必须要有一个等待
				begin
					r_cnt	<= r_cnt + 1'b1;
					if (r_cnt[2])
					begin
						r_state				<= WRITE_ADDR;
						o_axi_awaddr		<= w_reg[38:32];
						o_axi_wdata[31:0]	<= w_reg[31:0];
						o_axi_awvalid		<= 1'b1;
						r_cnt				<= 3'b0;
					end
				end
			end
			
			WRITE_ADDR:
			begin				
				if (i_axi_awready)
				begin
					r_state			<= WRITE;
					o_axi_bready	<= 1'b1;
					o_axi_awvalid	<= 1'b0;
					o_axi_wvalid	<= 1'b1;
					r_addr			<= r_addr + 1'b1;					
				end
			end
	
			WRITE:
			begin				
				if (i_axi_wready)
				begin
					r_state			<= POST_WRITE;
					o_axi_wvalid	<= 1'b0;
				end
			end
			
			POST_WRITE:
			begin				
				if (i_axi_bvalid)
				begin
					r_state			<= READ_ADDR;
					o_axi_bready	<= 1'b0;
					o_axi_arvalid	<= 1'b1;
				end
			end
			
			READ_ADDR:
			begin				
				if (i_axi_arready)
				begin
					r_state			<= READ;
					o_axi_araddr	<= 6'h24;
					o_axi_rready	<= 1'b1;
					o_axi_arvalid	<= 1'b0;
				end				
			end
			
			READ:
			begin
				if (i_axi_rvalid)
				begin
					r_state			<= POST_READ;
					r_read_reg		<= i_axi_rdata;
					o_axi_rready	<= 1'b0;
				end
			end
			
			POST_READ:
			begin
				if (r_read_reg[11:10] == 2'b00)
				begin
					r_state	<= IDLE;
					r_done	<= 1'b0;
				end
				else
				begin
					r_state			<= READ_ADDR;
					o_axi_arvalid	<= 1'b1;
				end
			end
			
			default:
			begin
				r_state			<= IDLE;
				o_axi_awaddr	<= {7{1'b0}};
				o_axi_awvalid	<= 1'b0;
				o_axi_wdata		<= {32{1'b0}};
				o_axi_wvalid    <= 1'b0;
				o_axi_bready    <= 1'b0;
				o_axi_araddr	<= {7{1'b0}};
				o_axi_arvalid   <= 1'b0;
				o_axi_rready	<= 1'b0;
				r_done			<= 1'b1;
				r_confdone		<= 1'b0;
			end
		endcase
	end
end

assign	o_state		= r_state;
assign	o_confdone	= r_confdone;

endmodule
