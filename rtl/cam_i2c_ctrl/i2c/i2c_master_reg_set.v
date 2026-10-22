`include "../../defines.v"


module i2c_master_reg_set #(
	parameter DATA_LENGTH = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_DATA_LENGTH,
	parameter I2C_REG_ADDR_WIDTH = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_I2C_REG_ADDR_WIDTH,
	parameter I2C_DATA_WIDTH = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_I2C_DATA_WIDTH,
	parameter I2C_DEVICE_ADDR = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_I2C_DEVICE_ADDR
)(
	input		wire		clk,
	input		wire		rst_n,
	
	input		wire		init_done,  //keep high all the time
	input		wire		rd_done,		//one clock pulse
	input		wire		wr_done,		//one clock pulse
	output	reg			wr_en,			//one clock pulse
	output	reg			rd_en,			//one clock pulse
	output	wire	[`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_RANGE_1] addr,		//i2c register address
	output	wire	[`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_RANGE_2] dout,		//i2c configure data to the register
	output	reg		[`CFG_BITS_8-1:0] dev_addr,
	output reg config_done
	
);
localparam ROM_ADDR_WIDTH = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_LOCALPARAM_ROM_ADDR_WIDTH;

wire	[`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_RANGE_3] rom_addr;
wire	[`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_RANGE_4] rom_dout;

reg	[`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_RANGE_5] cnt =0;
parameter	S0 = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_S0;
parameter	S1 = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_S1;
parameter	S2 = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_S2;
parameter	S3 = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_S3;
parameter	S4 = `CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_PARAMETER_S4;
reg	[`CFG_BITS_3-1:0] state = S0;

	i2c_master_reg_rom #(
		.ROM_SIZE              (`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_INST_U_USER_ROM_ROM_SIZE ),
		.TOTAL_ROM_DEPTH       (`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_INST_U_USER_ROM_TOTAL_ROM_DEPTH), // 6*7
		.ADDR_WIDTH            (`CFG_CAM_I2C_CTRL_I2C_I2C_MASTER_REG_SET_V_INST_U_USER_ROM_ADDR_WIDTH  ) // alt_clogb2(42)
	)u_user_rom(
    .clock(clk),
    .addr_ptr(rom_addr),
    .rdata_out(rom_dout)
);

assign rom_addr = cnt;
assign addr = rom_dout[24:9];
assign dout = rom_dout[8:1];
wire rw_flag = rom_dout[0];

always @( posedge clk or negedge rst_n )
begin
	if( ~rst_n ) begin
			cnt <= 0;
			state <= S0;
			rd_en <= 1'b0;
			wr_en <= 1'b0; 
			config_done <= 1'b0;

	end else begin
			if( init_done ) begin
					case( state ) 
					S0: begin
						if( cnt < DATA_LENGTH ) //address from 0~60
								state <= S1;
						else config_done <= 1'b1;
					end
					S1:	begin
								state <= S2;
					end
					S2: begin
							state <= S3;
							if( rw_flag )
									rd_en <= 1'b1; 
							else 	
									wr_en <= 1'b1;
					end		
					S3: begin 
							rd_en <= 1'b0;
							wr_en <= 1'b0;
							state <= S4;
					end
					S4: begin
							if( rd_done | wr_done ) begin
									state <= S0;
									cnt <= cnt + 1'b1;
							end
								
					end
					default:;
					endcase
			end
	end
end

always @( posedge clk  )
		dev_addr <= I2C_DEVICE_ADDR;//8bit address(include w/r bit)



endmodule
