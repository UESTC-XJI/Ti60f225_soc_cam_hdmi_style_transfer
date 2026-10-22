`include "../defines.v"

	module color_bar_rgb #(
			parameter HS_POLORY =`CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_HS_POLORY,
			parameter VS_POLORY = `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_VS_POLORY,
			parameter NUM_OF_PIXERS_PER_CLOCK = `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_NUM_OF_PIXERS_PER_CLOCK,
			parameter H_FRONT_PORCH 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_H_FRONT_PORCH,
			parameter H_SYNC 			= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_H_SYNC,
			parameter H_VALID 			= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_H_VALID,
			parameter H_BACK_PORCH 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_H_BACK_PORCH,
			parameter V_FRONT_PORCH 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_V_FRONT_PORCH,
			parameter V_SYNC 			= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_V_SYNC,
			parameter V_VALID 			= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_V_VALID,
			parameter V_BACK_PORCH 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_V_BACK_PORCH,
			parameter TEST_MODE 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_PARAMETER_TEST_MODE
	)(
	input		wire			clk,
	input 		wire 			rst_n,
	//`ifdef TEST_MODE == 2'b11
	input  wire [`CFG_BITS_8-1:0]           i_rdata,
	input  wire [`CFG_BITS_8-1:0] 			i_gdata,
	input  wire [`CFG_BITS_8-1:0] 			i_bdata,
	//`endif
	output 	reg	[`CFG_BITS_16-1:0] h_cnt = 0,
	output  reg	[`CFG_BITS_16-1:0] v_cnt = 0,
	output	reg					hs = 0,
	output	reg					vs  = 0,
	output	reg					de = 1'b0,
	output wire [`CFG_BITS_2-1:0]     		w_h_state,
	output wire [`CFG_BITS_2-1:0] 			w_v_state,
	output	reg [`CFG_BITS_8-1:0] 			rgb_r = 8'd0,    //像素数据、红色分量
	output	reg [`CFG_BITS_8-1:0] 			rgb_g = 8'd0,    //像素数据、绿色分量
	output 	reg [`CFG_BITS_8-1:0] 			rgb_b = 8'd0     //像素数据、蓝色分量
	
	);


//=========================================================
//
//=========================================================
	localparam WHITE_R 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_WHITE_R;
	localparam WHITE_G 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_WHITE_G;
	localparam WHITE_B 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_WHITE_B;
	localparam YELLOW_R 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_YELLOW_R;
	localparam YELLOW_G 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_YELLOW_G;
	localparam YELLOW_B 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_YELLOW_B;
	localparam CYAN_R 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_CYAN_R;
	localparam CYAN_G 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_CYAN_G;
	localparam CYAN_B 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_CYAN_B;
	localparam GREEN_R 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_GREEN_R;
	localparam GREEN_G 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_GREEN_G;
	localparam GREEN_B 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_GREEN_B;
	localparam MAGENTA_R 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_MAGENTA_R;
	localparam MAGENTA_G 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_MAGENTA_G;
	localparam MAGENTA_B 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_MAGENTA_B;
	localparam RED_R 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_RED_R;
	localparam RED_G 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_RED_G;
	localparam RED_B 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_RED_B;
	localparam BLUE_R 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_BLUE_R;
	localparam BLUE_G 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_BLUE_G;
	localparam BLUE_B 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_BLUE_B;
	localparam BLACK_R 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_BLACK_R;
	localparam BLACK_G 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_BLACK_G;
	localparam BLACK_B 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_BLACK_B;
	
	
	localparam S_H_BACK_PORCH 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_H_BACK_PORCH;
	localparam S_H_SYNC 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_H_SYNC;
	localparam S_H_VALID 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_H_VALID;
	localparam S_H_FRONT_PORCH 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_H_FRONT_PORCH;
	localparam S_V_BACK_PORCH 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_V_BACK_PORCH;
	localparam S_V_SYNC 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_V_SYNC;
	localparam S_V_VALID 		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_V_VALID;
	localparam S_V_FRONT_PORCH 	= `CFG_FRAME_BUFFER_V4_COLOR_BAR_RGB_V_LOCALPARAM_S_V_FRONT_PORCH;
	
	reg	[`CFG_BITS_2-1:0] 	h_state = S_H_SYNC;
	reg	[`CFG_BITS_2-1:0] 	v_state = S_H_SYNC;
	reg	hs_r1 = 1'b0;
	reg vs_r1 = 1'b0;
	reg	de_r1 = 1'b0;

	assign w_h_state = h_state	;
	assign w_v_state = v_state	;

	always @( posedge clk or negedge rst_n )
	begin
		if( ~rst_n ) begin 
			h_state <= S_H_SYNC;
			h_cnt <= 0;
		end else begin 
			case(h_state )
			S_H_SYNC : begin
					if( h_cnt == H_SYNC - 1) begin
							h_cnt <= 0;
							h_state <= S_H_BACK_PORCH;
					end else 
							h_cnt <= h_cnt + 1'b1;
			end
			S_H_BACK_PORCH : begin

					if( h_cnt == H_BACK_PORCH - 1) begin
							h_cnt <= 0;
							h_state <= S_H_VALID;
					end else 
							h_cnt <= h_cnt + 1'b1;
			end

			S_H_VALID : begin
					if( h_cnt == H_VALID - 1) begin
							h_cnt <= 0;
							h_state <= S_H_FRONT_PORCH;
					end else 
							h_cnt <= h_cnt + 1'b1;
			end
			S_H_FRONT_PORCH : begin
					if( h_cnt == H_FRONT_PORCH - 1) begin
							h_cnt <= 0;
							h_state <= S_H_SYNC;
					end else 
							h_cnt <= h_cnt + 1'b1;
			end
			default: begin
					h_state <= S_H_SYNC;
					h_cnt <= 0;
			end
			endcase
		end 
	end
	
	always @( posedge clk or negedge rst_n  )
	begin
		if( ~rst_n ) begin 
			v_state <= S_V_SYNC;
			v_cnt <= 0;
		end else begin 
			case(v_state )

			S_V_SYNC : begin
					if( h_cnt == H_FRONT_PORCH - 1 && h_state == S_H_FRONT_PORCH ) begin
						if( v_cnt == V_SYNC - 1 ) begin 
							v_cnt <= 0;
							v_state <= S_V_BACK_PORCH;
						end else 
							v_cnt <= v_cnt + 1'b1;
					end
			end
			S_V_BACK_PORCH : begin
					if( h_cnt == H_FRONT_PORCH - 1 && h_state == S_H_FRONT_PORCH ) begin
						if( v_cnt == V_BACK_PORCH - 1 ) begin 
							v_cnt <= 0;
							v_state <= S_V_VALID;
						end else 
							v_cnt <= v_cnt + 1'b1;
					end
			end
			S_V_VALID : begin
					if( h_cnt == H_FRONT_PORCH - 1 && h_state == S_H_FRONT_PORCH ) begin
						if( v_cnt == V_VALID - 1 ) begin 
							v_cnt <= 0;
							v_state <= S_V_FRONT_PORCH;
						end else 
							v_cnt <= v_cnt + 1'b1;
					end
			end
			S_V_FRONT_PORCH : begin
					if( h_cnt == H_FRONT_PORCH - 1 && h_state == S_H_FRONT_PORCH ) begin
						if( v_cnt == V_FRONT_PORCH - 1 ) begin 
							v_cnt <= 0;
							v_state <= S_V_SYNC;
						end else 
							v_cnt <= v_cnt + 1'b1;
					end
			end
			default: begin
					v_state <= S_V_SYNC;
					v_cnt <= 0;
			end
			endcase
		end 
	end
	reg [`CFG_BITS_24-1:0] data = 24'd0;

	generate
	    if(TEST_MODE  == 2'b00 ) begin : V_MIRROR_P//===========================================================
			wire pos_vs;
			assign pos_vs = {vs,vs_r1} == 2'b01 ;
	    	always@(posedge clk or negedge  rst_n)
			begin
				if(~rst_n)
					data <= 'd0;
				else if( h_state == S_H_VALID && v_state == S_V_VALID )
					data <= data + 1'b1; 
				else if(pos_vs)
					data <= 'd0;
			end
		end else if( TEST_MODE == 2'b01 )begin : Clor //===============================================================
			wire pos_vs;
			assign pos_vs = {vs,vs_r1} == 2'b01 ;
			reg [`CFG_BITS_6-1:0] frame_cnt = 6'd0;
			reg [`CFG_BITS_24-1:0] data_buf = 24'd0;
			reg [`CFG_BITS_3-1:0] color_state = 2'b00;
			always @( posedge clk or negedge rst_n )
			begin 
				if( ~rst_n )
					frame_cnt <= 0;
				else if( pos_vs )
					frame_cnt <= frame_cnt + 1'b1;
			end
			//EBU检测图从左至右依次为 白色、黄色、靛色、绿色 紫色、红色、蓝色、黑色
			always @( posedge clk )
			begin 
				case( color_state )
				3'b000 :  begin 

					data_buf <= {WHITE_R,WHITE_G,WHITE_B};
					if( &frame_cnt & pos_vs )
						color_state <= 3'b001;
				end 

				3'b001 :  begin 
						data_buf <= {YELLOW_R,YELLOW_G,YELLOW_B};
						if( &frame_cnt & pos_vs )
							color_state <= 3'b010;
				end

				3'b010 :  begin 
						data_buf <= {CYAN_R,CYAN_G,CYAN_B};
					if( &frame_cnt & pos_vs )
							color_state <= 3'b011;
				end

				3'b011 :  begin 
						data_buf <= {GREEN_R,GREEN_G,GREEN_B};


						if( &frame_cnt & pos_vs )
							color_state <= 3'b100;
				 end
				 3'b100 : begin 
						data_buf <= {MAGENTA_R,MAGENTA_G,MAGENTA_B};
						if( &frame_cnt & pos_vs )
							color_state <= 3'b101;
				 end 
				 3'b101: begin 
						data_buf <= {RED_R,RED_G,RED_B};  


						if( &frame_cnt & pos_vs )
							color_state <= 3'b110;
				 end
				 3'b110: begin 
						data_buf <= {BLUE_R,BLUE_G,BLUE_B};
						if( &frame_cnt & pos_vs )
							color_state <= 3'b111;
				 end
				 3'b111:begin 
						data_buf <= {BLACK_R,BLACK_G,BLACK_B};
						if( &frame_cnt & pos_vs )
							color_state <= 3'b000;
				 end 

				default:;
				endcase // color_state
			end

			always@(posedge clk or negedge  rst_n)
			begin
				if(~rst_n) begin
						data <= 0;
					end
				else if(h_state == S_H_VALID && v_state == S_V_VALID) 
						data <= data_buf ;
				else 	
						data <= 'd0;
			end

		end else if( TEST_MODE == 2'b10 )begin : ColorBar//===============================================================
			always@(posedge clk or negedge  rst_n)
			begin
				if(~rst_n) begin
						data <= 0;
				end else if(h_state == S_H_VALID ) begin
					if( h_cnt <H_VALID/8) 
						data <=  {WHITE_R,WHITE_G,WHITE_B};
					else if( h_cnt <H_VALID/8*2)
						data <= {YELLOW_R,YELLOW_G,YELLOW_B};
					else if( h_cnt <H_VALID/8*3)
						data <= {CYAN_R,CYAN_G,CYAN_B};
					else if(h_cnt <H_VALID/8*4)
						data <= {GREEN_R,GREEN_G,GREEN_B};
					else if(h_cnt <H_VALID/8*5)
						data <= {MAGENTA_R,MAGENTA_G,MAGENTA_B};
					else if(h_cnt <H_VALID/8*6)
						data <= {RED_R,RED_G,RED_B}; 
					else if(h_cnt <H_VALID/8*7)
						data <= {BLUE_R,BLUE_G,BLUE_B};
					else 
						data <= {BLACK_R,BLACK_G,BLACK_B};
				end else 
						data <= 'd0;	
			end 

		end else begin //=======================================================================================
			always@( posedge clk or negedge rst_n )
			begin 
				if( !rst_n ) begin
					data <= 'd0 ;
				end else begin
					data <= {i_rdata,i_gdata,i_bdata} ;
				end 
			end
		end //==================================================================================================
	endgenerate 
	
	
	always @( posedge clk or negedge rst_n )
	begin
		if( !rst_n ) begin
			rgb_r <= 'd0;//rgb_r_reg;
	       	rgb_g <= 'd0;//rgb_g_reg; 
	       	rgb_b <= 'd0;//rgb_b_reg;  
		end else begin
	       	rgb_r <= data[23:16];//rgb_r_reg;
	       	rgb_g <= data[15:8];//rgb_g_reg; 
	       	rgb_b <= data[7:0];//rgb_b_reg;  
		end 
	end

	
	always @( posedge clk or negedge rst_n )
	begin
		if( !rst_n ) begin
			de_r1 <= 'd0;
			de 	  <= 'd0;
		end else begin
			de_r1 <= (h_state == S_H_VALID & v_state == S_V_VALID );
			de    <= de_r1;
		end 
	end
	always @( posedge clk or negedge rst_n )
	begin
		if( !rst_n ) begin
			vs_r1 <= 'd0;
			vs 	  <= 'd0;
		end else begin
			vs_r1 <= (VS_POLORY == 1'b1) ? (v_state == S_V_SYNC) : ~(v_state == S_V_SYNC );
			vs    <= vs_r1;
		end 
	end
	
	always @( posedge clk or negedge rst_n)
	begin
		if( !rst_n ) begin
			hs_r1 <= 'd0;
			hs 	  <= 'd0;
		end else begin
			hs_r1 <= (HS_POLORY == 1'b1) ? (h_state == S_H_SYNC) : ~(h_state == S_H_SYNC);
			hs    <= hs_r1;
		end 
	end
	
	
	endmodule
	
	

