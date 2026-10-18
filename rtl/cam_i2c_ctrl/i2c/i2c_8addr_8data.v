`include "../../defines.v"



module i2c_8addr_8data(
	input		wire				clk,
	input		wire				rst_n,
	input		wire	[`CFG_BITS_8-1:0] din,
	input		wire	[`CFG_BITS_8-1:0] addr,
	output	wire	[`CFG_BITS_8-1:0] dout,
	input		wire	[`CFG_BITS_8-1:0] dev_addr,
	output	reg					init_done,
	input		wire				wr_en,
	input		wire				rd_en,
	output	reg					wr_done,
	output	reg					rd_done,
	output	wire				dout_valid,
	
	output	wire	[`CFG_BITS_3-1:0]	i2c_address,
  output	wire				i2c_write   ,
  output	wire	[`CFG_BITS_8-1:0] i2c_writedata,
  output	wire				i2c_chipselect,
  input		wire				i2c_waitrequest,
  input		wire	[`CFG_BITS_8-1:0] i2c_readdata

);
//parameter I2C_ADDR = 8'h72;

parameter INIT_IDLE = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_INIT_IDLE;
parameter INIT_CNT_H = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_INIT_CNT_H;
parameter INIT_CNT_L = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_INIT_CNT_L;
parameter	INIT_CORE_EN = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_INIT_CORE_EN;
parameter INIT_OVER = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_INIT_OVER;
reg	[`CFG_BITS_3-1:0] init_state = INIT_IDLE;
reg	init_cs = 1'b0;
reg	init_wr = 1'b0;
reg	[`CFG_BITS_8-1:0] init_wrdata = 0;
reg	[`CFG_BITS_3-1:0] init_addr = 0;
always @( posedge clk or negedge rst_n)
begin
		if( ~rst_n ) begin
				init_state <= INIT_IDLE;
				init_cs <= 1'b0;
				init_wr <= 1'b0;
		end else begin
			case( init_state )
				INIT_IDLE : begin
						if( ~i2c_waitrequest ) begin
								init_cs <= 1'b0;
								init_wr <= 1'b0;
								init_state <= INIT_CNT_L;	
						end
				end
				INIT_CNT_L : begin
							init_addr <= 3'b000;
							init_cs <= 1'b1;
							init_wr <= 1'b1;
							init_wrdata[7:0] <= 8'h05;
							init_state <= INIT_CNT_H;
						
				end
				INIT_CNT_H :begin
							init_addr <= 3'b001;
							init_cs <= 1'b1;
							init_wr <= 1'b1;
							init_wrdata[7:0] <= 8'h00;
							init_state <= INIT_CORE_EN;
				end
				INIT_CORE_EN : begin
							init_addr <= 3'b010;
							init_cs <= 1'b1;
							init_cs <= 1'b1;
							init_wrdata[7:0] <= 8'h80;
							init_state <= INIT_OVER;
				end
				INIT_OVER : begin
						init_addr <= 3'b000;
						init_cs <= 1'b0;
						init_wr <= 1'b0;
						init_wrdata[7:0] <= 8'h00;
				end
				
				default:;
			endcase
				
		
		end
end

always @( posedge clk or negedge rst_n)
begin
		if( ~rst_n ) begin
				init_done <= 1'b0;
		end else if( init_state == INIT_OVER ) begin
				init_done <= 1'b1;
		end
end

parameter S_WR_IDLE 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_IDLE;
parameter S_WR_RD_TIP 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_RD_TIP;
parameter S_WR_TIP_WAIT = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_TIP_WAIT;
parameter S_WR_TIP_CHK 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_TIP_CHK;
parameter S_WR_WR_DATA 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_WR_DATA;
parameter S_WR_CTRL_SET = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_CTRL_SET;
parameter S_WR_SET_WAIT = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_SET_WAIT;
parameter S_WR_WR_OVER 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_WR_WR_OVER;

reg [`CFG_BITS_3-1:0] wr_state;
reg	[`CFG_BITS_3-1:0] wr_addr = 3'b000;
reg				wr_cs = 1'b0;
reg				wr_wr = 1'b0;
reg	[`CFG_BITS_8-1:0]wr_wrdata = 0;
reg	[`CFG_BITS_2-1:0] wr_cnt = 0;
reg	[`CFG_BITS_3-1:0] wait_cnt = 0;
always @( posedge clk or negedge rst_n )
begin
		if( ~rst_n ) begin
				wr_addr <= 0;
				wr_cs <= 1'b0;
				wr_wr <= 1'b0;
				wr_wrdata <= 0;
				wr_state <= S_WR_IDLE;
		end else begin
				case( wr_state ) 
				S_WR_IDLE : begin
						wr_addr <= 0;
						wr_cs <= 1'b0;
						wr_wr <= 1'b0;
						wr_wrdata <= 0;
						if( init_done & (wr_en || wr_cnt != 0)) begin
							wr_state <= S_WR_RD_TIP;
						end
				end
				S_WR_RD_TIP : begin
						wr_addr <= 3'd4;
						wr_cs <=1'b1;
						wr_state <= S_WR_TIP_WAIT;
				end
				S_WR_TIP_WAIT : begin
						wr_addr <= 3'd4;
						wr_cs <= 1'b0;
						if( wait_cnt[2] ) begin
								wait_cnt <= 0;
								wr_state <= S_WR_TIP_CHK;
						end else begin
								wait_cnt <= wait_cnt + 1'b1;
						end
				end
				S_WR_TIP_CHK: begin
						wr_cs <= 1'b0;
						if( i2c_readdata[1] == 1'b0 ) begin
								wr_state <= S_WR_WR_DATA;
						end 
				end
				S_WR_WR_DATA : begin
						wr_addr <= 3'd3;//write data address
						wr_cs <= 1'b1;
						wr_wr <= 1'b1;
						if( wr_cnt == 0 ) begin
							wr_wrdata <= dev_addr;
						end else if( wr_cnt == 1 ) begin
							wr_wrdata <= addr;
						end else begin
							wr_wrdata <= din;
						end
						wr_state <= S_WR_CTRL_SET;
				end
				S_WR_CTRL_SET : begin
						wr_addr <= 3'd4;//write data address
						wr_cs <= 1'b1;
						wr_wr <= 1'b1;
						if( wr_cnt == 0 ) begin
								wr_wrdata <= 8'h98;
						end else if( wr_cnt == 1 ) begin
								wr_wrdata <= 8'h18;
						end else begin
								wr_wrdata <= 8'h51;
						end
						
						wr_state <= S_WR_WR_OVER;
				end
				S_WR_WR_OVER : begin
						wr_addr <= 0;
						wr_cs <= 1'b0;
						wr_wr <= 1'b0;
						wr_wrdata <= 0;
						if( wr_cnt == 2'd2 ) begin
								wr_cnt <= 0;
								wr_state <= S_WR_SET_WAIT;
						end else begin
								wr_cnt <= wr_cnt + 1'b1;
								wr_state <= S_WR_RD_TIP;
						end
						
				end
				S_WR_SET_WAIT: begin
						wr_state <= S_WR_IDLE;
				end
				
				default:;
			endcase
				
		end
end            

always @( posedge clk or negedge rst_n )
begin
		if( ~rst_n ) begin
				wr_done <= 1'b0;
		end else if(wr_state == S_WR_SET_WAIT )begin
				wr_done <= 1'b1;
		end else begin
				wr_done <= 1'b0;
		end
end

//================================================================
//
//================================================================
parameter S_RD_IDLE 		= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_IDLE;
parameter S_RD_RD_TIP 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_RD_TIP;
parameter S_RD_TIP_WAIT = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_TIP_WAIT;
parameter S_RD_TIP_CHK 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_TIP_CHK;
parameter S_RD_WR_DATA 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_WR_DATA;
parameter S_RD_CTRL_SET = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_CTRL_SET;
parameter S_RD_SET_WAIT = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_SET_WAIT;
parameter S_RD_WR_OVER 	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_WR_OVER;
parameter	S_RD_CFG_SET  = `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_CFG_SET;
parameter	S_RD_RD_DATA	= `CFG_CAM_I2C_CTRL_I2C_I2C_8ADDR_8DATA_V_PARAMETER_S_RD_RD_DATA;
reg	[`CFG_BITS_3-1:0] rd_addr;
reg				rd_cs;
reg				rd_wr;
reg[`CFG_BITS_8-1:0]	rd_wrdata;
reg [`CFG_BITS_4-1:0] rd_state = S_RD_IDLE;
reg	[`CFG_BITS_3-1:0]	rd_cnt = 0;
reg	[`CFG_BITS_3-1:0] rd_wait_cnt = 0;
always @( posedge clk or negedge rst_n )
begin
		if( ~rst_n ) begin
				rd_addr <= 0;
				rd_cs <= 1'b0;
				rd_wr <= 1'b0;
				rd_wrdata <= 0;
				rd_state <= S_RD_IDLE;    
				rd_cnt <= 'd0;
		end else begin
				case( rd_state ) 
				S_RD_IDLE : begin
						rd_addr <= 0;
						rd_cs <= 1'b0;
						rd_wr <= 1'b0;
						rd_wrdata <= 0;
						if( init_done & (rd_en || rd_cnt != 0)) begin
							rd_state <= S_RD_RD_TIP;
						end
				end
				S_RD_RD_TIP : begin
						rd_addr <= 3'd4;
						rd_cs <=1'b1;
						rd_state <= S_RD_TIP_WAIT;
				end
				S_RD_TIP_WAIT : begin
						rd_addr <= 3'd4;
						rd_cs <= 1'b0;
						if( rd_wait_cnt[2] ) begin
								rd_wait_cnt <= 0;
								rd_state <= S_RD_TIP_CHK;    
						end else begin
								rd_wait_cnt <= rd_wait_cnt + 1'b1;
						end
				end
				S_RD_TIP_CHK: begin     //3 
						rd_cs <= 1'b0;
						if( i2c_readdata[1] == 1'b0 ) begin
								if( rd_cnt == 4 ) begin
										rd_state <= S_RD_WR_OVER;
								end else if( rd_cnt == 3 ) begin
										rd_state <= S_RD_CTRL_SET;
								end else begin
										rd_state <= S_RD_WR_DATA;
								end
						end 
				end
				S_RD_WR_DATA : begin     //state == 4
						rd_addr <= 3'd3;//write data address
						rd_cs <= 1'b1;
						rd_wr <= 1'b1;
						if( rd_cnt == 0 ) begin
							rd_wrdata <= dev_addr ;
						end else if( rd_cnt == 1 ) begin
							rd_wrdata <= addr;
						end else begin
							rd_wrdata <= dev_addr | 8'h01;
						end
						rd_state <= S_RD_CTRL_SET;  
				end
				S_RD_CTRL_SET : begin    //state == 5 
						rd_addr <= 3'd4;//write data address
						rd_cs <= 1'b1;
						rd_wr <= 1'b1;
						if( rd_cnt == 0 ) begin
								rd_wrdata <= 8'h90;
						end else if( rd_cnt == 1 ) begin
								rd_wrdata <= 8'h10;
						end else if( rd_cnt == 2 ) begin
								rd_wrdata <= 8'h90;
						end else begin
								rd_wrdata <= 8'h68;
						end
						
						rd_state <= S_RD_WR_OVER;
				end
				S_RD_WR_OVER : begin
						rd_addr <= 0;
						rd_cs <= 1'b0;
						rd_wr <= 1'b0;
						rd_wrdata <= 0;
						if( rd_cnt == 3'd4 ) begin
								rd_cnt <= 3'd0;
								rd_state <= S_RD_RD_DATA;
						end else begin
								rd_cnt <= rd_cnt + 1'b1;
								rd_state <= S_RD_RD_TIP;
						end
						
				end
				
				S_RD_RD_DATA : begin
						rd_state <= S_RD_CFG_SET ;
						rd_addr <= 3;
						rd_cs <= 1'b1;
				end
				S_RD_CFG_SET: begin
						rd_cs <= 1'b0;
						rd_wr <= 1'b0;
						rd_wrdata <= 8'h00;
						rd_state <= S_RD_IDLE;
				end
				default:;
			endcase
				
		end
end

always @( posedge clk or negedge rst_n )
begin
		if( ~rst_n ) begin
				rd_done <= 1'b0;
		end else if( rd_state == S_RD_CFG_SET ) begin
				rd_done <= 1'b1;
		end else begin
				rd_done <= 1'b0;
		end
end
assign dout_valid = rd_done;

assign 	i2c_address 		= init_addr | wr_addr |rd_addr;
assign	i2c_chipselect 	= init_cs | wr_cs |rd_cs;
assign	i2c_write 			= init_wr | wr_wr | rd_wr;
assign	i2c_writedata 	= init_wrdata | wr_wrdata | rd_wrdata;


endmodule

