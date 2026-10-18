`include "../defines.v"
module raw_to_rgb
#(
	parameter	P_DEPTH			= `CFG_DEBAYER_RAW_TO_RGB_V_PARAMETER_P_DEPTH,
	parameter	PW				= `CFG_DEBAYER_RAW_TO_RGB_V_PARAMETER_PW,
	parameter	LEGACY			= `CFG_DEBAYER_RAW_TO_RGB_V_PARAMETER_LEGACY,
	parameter GREEN_FIRST = `CFG_DEBAYER_RAW_TO_RGB_V_PARAMETER_GREEN_FIRST // Input RAW row zero starts with G (1) or B (0).
)
(
	input			i_arstn,
	input			i_pclk,
	
	input			i_vsync,
	input			i_hsync,
	input			i_de,
	input			i_valid,
	input[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_1]	i_p_11,
	input[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_2]	i_p_00,
	input[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_3]	i_p_01,
	
	output			o_vsync,
	output			o_hsync,
	output			o_de,
	output			o_valid,
	output[`CFG_BITS_11-1:0]	o_x_cnt,
	output[`CFG_BITS_11-1:0]	o_y_cnt,
	output[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_4]	o_r,
	output[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_5]	o_g,
	output[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_6]	o_b
);

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// y -1  0  +1  x
// 
//   -1  0  +1 
//   -1  0  +1 
//   -1  0  +1 
//
//				r_bayer_11_11_2P						r_bayer_11_01_1P                       	r_bayer_11_01_0P
//				r_bayer_00_11_2P						r_bayer_00_00_1P                       	r_bayer_00_01_0P
//				r_bayer_01_11_2P						r_bayer_01_01_1P                       	r_bayer_01_01_0P
//
//	r_bayer_11_11_2P_0	r_bayer_11_11_2P_1	r_bayer_11_00_1P_0	r_bayer_11_00_1P_1	r_bayer_11_01_0P_0	r_bayer_11_01_0P_1
//	r_bayer_00_11_2P_0	r_bayer_00_11_2P_1	r_bayer_00_00_1P_0	r_bayer_00_00_1P_1	r_bayer_00_01_0P_0	r_bayer_00_01_0P_1
//	r_bayer_01_11_2P_0	r_bayer_01_11_2P_1	r_bayer_01_00_1P_0	r_bayer_01_00_1P_1	r_bayer_01_01_0P_0	r_bayer_01_01_0P_1
//
//  R | G | R | G | R | G              R G B | R G B | R G B | R G B | R G B | R G B
// --- --- --- --- --- ---            ------- ------- ------- ------- ------- -------
//  G | B | G | B | G | B        |\    R G B | R G B | R G B | R G B | R G B | R G B
// --- --- --- --- --- ---  -----  \  ------- ------- ------- ------- ------- -------
//  R | G | R | G | R | G   -----  /   R G B | R G B | R G B | R G B | R G B | R G B
// --- --- --- --- --- ---       |/   ------- ------- ------- ------- ------- -------
//  G | B | G | B | G | B              R G B | R G B | R G B | R G B | R G B | R G B
//
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
reg	[`CFG_BITS_11-1:0]			r_x_cnt;
reg	[`CFG_BITS_11-1:0]			r_x_cnt_1P;
reg	[`CFG_BITS_11-1:0]			r_x_cnt_2P;
reg	[`CFG_BITS_11-1:0]			r_y_cnt;
reg	[`CFG_BITS_11-1:0]			r_y_cnt_1P;
reg	[`CFG_BITS_11-1:0]			r_y_cnt_2P;

reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_7]		r_r_00_00_1P;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_8]		r_g_00_00_1P;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_9]		r_b_00_00_1P;

reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_10]	r_bayer_11_01_0P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_11]	r_bayer_11_01_0P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_12]	r_bayer_00_01_0P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_13]	r_bayer_00_01_0P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_14]	r_bayer_01_01_0P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_15]	r_bayer_01_01_0P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_16]	r_bayer_11_00_1P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_17]	r_bayer_11_00_1P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_18]	r_bayer_00_00_1P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_19]	r_bayer_00_00_1P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_20]	r_bayer_01_00_1P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_21]	r_bayer_01_00_1P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_22]	r_bayer_11_11_2P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_23]	r_bayer_11_11_2P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_24]	r_bayer_00_11_2P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_25]	r_bayer_00_11_2P_1;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_26]	r_bayer_01_11_2P_0;
reg	[`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_27]	r_bayer_01_11_2P_1;

reg					r_vsync_00_1P;
reg					r_hsync_00_1P;
reg					r_de_00_1P;
reg					r_valid_1P;
reg					r_vsync_00_2P;
reg					r_hsync_00_2P;
reg					r_de_00_2P;
reg					r_valid_2P;

// wire	[P_DEPTH+1:0]w_r_00_00_odd_lsb;
// wire	[P_DEPTH+1:0]w_g_00_00_odd_lsb;
// wire	[P_DEPTH+1:0]w_b_00_00_odd_lsb;

// wire	[P_DEPTH+1:0]w_r_00_00_odd_msb;
// wire	[P_DEPTH+1:0]w_g_00_00_odd_msb;
// wire	[P_DEPTH+1:0]w_b_00_00_odd_msb;

// wire	[P_DEPTH+1:0]w_r_00_00_even_lsb;
// wire	[P_DEPTH+1:0]w_g_00_00_even_lsb;
// wire	[P_DEPTH+1:0]w_b_00_00_even_lsb;

// wire	[P_DEPTH+1:0]w_r_00_00_even_msb;
// wire	[P_DEPTH+1:0]w_g_00_00_even_msb;
// wire	[P_DEPTH+1:0]w_b_00_00_even_msb;

// assign	w_r_00_00_odd_lsb	= {1'b0, r_bayer_00_00_1P_1 + r_bayer_00_11_2P_1};
// assign	w_g_00_00_odd_lsb	= {2'b0, r_bayer_00_00_1P_0};
// assign	w_b_00_00_odd_lsb	= {1'b0, r_bayer_11_00_1P_0 + r_bayer_01_00_1P_0};
				
// assign	w_r_00_00_odd_msb	= {1'b0, r_bayer_00_00_1P_1 + r_bayer_00_00_1P_1};
// assign	w_g_00_00_odd_msb	= r_bayer_00_01_0P_0 + r_bayer_00_00_1P_0 + r_bayer_11_00_1P_1 + r_bayer_01_00_1P_1;
// assign	w_b_00_00_odd_msb	= r_bayer_11_01_0P_0 + r_bayer_01_00_1P_0 + r_bayer_01_01_0P_0 + r_bayer_11_00_1P_0;

// assign	w_r_00_00_even_lsb	= r_bayer_11_00_1P_1 + r_bayer_01_11_2P_1 + r_bayer_01_00_1P_1 + r_bayer_11_11_2P_1;
// assign	w_g_00_00_even_lsb	= r_bayer_11_00_1P_0 + r_bayer_01_00_1P_0 + r_bayer_00_00_1P_1 + r_bayer_00_11_2P_1;
// assign	w_b_00_00_even_lsb	= {1'b0, r_bayer_00_00_1P_0 + r_bayer_00_00_1P_0};
							
// assign	w_r_00_00_even_msb	= {1'b0, r_bayer_11_00_1P_1 + r_bayer_01_00_1P_1};
// assign	w_g_00_00_even_msb	= {2'b0, r_bayer_00_00_1P_1};
// assign	w_b_00_00_even_msb	= {1'b0, r_bayer_00_01_0P_0 + r_bayer_00_00_1P_0};

/* RAW to RGB Debayer filter */
always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_vsync_00_1P		<= 1'b0;
		r_hsync_00_1P		<= 1'b0;
		r_de_00_1P			<= 1'b0;	
		r_valid_1P			<= 1'b0;	
		r_vsync_00_2P		<= 1'b0;
		r_hsync_00_2P		<= 1'b0;
		r_de_00_2P			<= 1'b0;	
		r_valid_2P			<= 1'b0;	
	end else begin
		r_vsync_00_1P		<= i_vsync;
		r_hsync_00_1P		<= i_hsync;
		r_de_00_1P			<= i_de;
		r_valid_1P			<= i_valid;
		r_vsync_00_2P		<= r_vsync_00_1P;
		r_hsync_00_2P		<= r_hsync_00_1P;
		r_de_00_2P			<= r_de_00_1P;
		r_valid_2P			<= r_valid_1P;
	end
end 
wire neg_vs = !i_vsync && r_vsync_00_1P;
wire pos_hs = i_hsync && !r_hsync_00_1P;
always@(posedge i_pclk)
begin
	if (~i_arstn)
		r_y_cnt	<= 11'b0;
	else if (!i_vsync && r_vsync_00_1P)		//Falling edge of VSYNC
		r_y_cnt	<= 11'b0;
	else if (r_de_00_1P && !i_de)			//Falling edge of DE		
		r_y_cnt <= r_y_cnt + 1'b1;

end 

always@(posedge i_pclk)
begin
	if (~i_arstn)
		r_x_cnt <= 11'b0;
	else if (i_de )
		r_x_cnt	<= r_x_cnt + 1'b1;
	else 
		r_x_cnt <= 11'b0;

end 

always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_x_cnt_1P			<= 11'b0;
		r_x_cnt_2P			<= 11'b0;
	end else begin
		r_x_cnt_1P			<= r_x_cnt;
		r_x_cnt_2P          <= r_x_cnt_1P;
	end
end 

always@(posedge i_pclk)
begin
	if (~i_arstn) begin 
		r_y_cnt_1P			<= 11'b0;
		r_y_cnt_2P			<= 11'b0;
	end else begin 
		r_y_cnt_1P			<= r_y_cnt;
		r_y_cnt_2P          <= r_y_cnt_1P;
	end 

end 

always @( posedge i_pclk )
begin
	if (~i_arstn)
	begin

		r_bayer_11_01_0P_0	<= {P_DEPTH{1'b0}};
        r_bayer_11_01_0P_1	<= {P_DEPTH{1'b0}};
        r_bayer_00_01_0P_0	<= {P_DEPTH{1'b0}};
        r_bayer_00_01_0P_1	<= {P_DEPTH{1'b0}};
        r_bayer_01_01_0P_0	<= {P_DEPTH{1'b0}};
        r_bayer_01_01_0P_1	<= {P_DEPTH{1'b0}};
	end else begin 
	if (LEGACY)
		begin
			if (r_y_cnt == 11'd0) //第0行是同一行的数据
			begin
				if (i_valid)
				begin
					r_bayer_11_01_0P_0	<= i_p_01[P_DEPTH-1:0]; //低8位
					r_bayer_11_01_0P_1	<= i_p_01[PW-1:P_DEPTH];//高8位
					r_bayer_00_01_0P_0	<= i_p_01[P_DEPTH-1:0]; //低8位
					r_bayer_00_01_0P_1	<= i_p_01[PW-1:P_DEPTH];//高8位
				end
			end else if (r_y_cnt == 11'd1) begin //第1行时使用的是第0和1行的数据
				if (i_valid)
				begin
					r_bayer_11_01_0P_0	<= i_p_00[P_DEPTH-1:0];
					r_bayer_11_01_0P_1	<= i_p_00[PW-1:P_DEPTH];
					r_bayer_00_01_0P_0	<= i_p_00[P_DEPTH-1:0];
					r_bayer_00_01_0P_1	<= i_p_00[PW-1:P_DEPTH];
				end
			end else begin
				if (i_valid) //以后的行数据都
				begin
					r_bayer_11_01_0P_0	<= i_p_11[P_DEPTH-1:0];
					r_bayer_11_01_0P_1	<= i_p_11[PW-1:P_DEPTH];
					r_bayer_00_01_0P_0	<= i_p_00[P_DEPTH-1:0];
					r_bayer_00_01_0P_1	<= i_p_00[PW-1:P_DEPTH];
				end
			end
			
			if (i_valid)
			begin
				r_bayer_01_01_0P_0	<= i_p_01[P_DEPTH-1:0];
				r_bayer_01_01_0P_1	<= i_p_01[PW-1:P_DEPTH];
			end
		end else begin
			if (i_valid)
			begin
				r_bayer_11_01_0P_0	<= i_p_11[P_DEPTH-1:0];
				r_bayer_11_01_0P_1	<= i_p_11[PW-1:P_DEPTH];
				r_bayer_00_01_0P_0	<= i_p_00[P_DEPTH-1:0];
				r_bayer_00_01_0P_1	<= i_p_00[PW-1:P_DEPTH];
				r_bayer_01_01_0P_0	<= i_p_01[P_DEPTH-1:0];
				r_bayer_01_01_0P_1	<= i_p_01[PW-1:P_DEPTH];
			end
		end
	end
end 



always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
        r_bayer_11_00_1P_0	<= {P_DEPTH{1'b0}};
        r_bayer_11_00_1P_1	<= {P_DEPTH{1'b0}};
        r_bayer_00_00_1P_0	<= {P_DEPTH{1'b0}};
        r_bayer_00_00_1P_1	<= {P_DEPTH{1'b0}};
        r_bayer_01_00_1P_0	<= {P_DEPTH{1'b0}};
        r_bayer_01_00_1P_1	<= {P_DEPTH{1'b0}};
	end else begin 
		if (r_x_cnt == 11'd0) begin
			r_bayer_11_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_11_00_1P_1	<= {P_DEPTH{1'b0}};
			r_bayer_00_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_00_00_1P_1	<= {P_DEPTH{1'b0}};
			r_bayer_01_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_01_00_1P_1	<= {P_DEPTH{1'b0}};
		end else begin
			r_bayer_11_00_1P_0	<= r_bayer_11_01_0P_0;
			r_bayer_11_00_1P_1	<= r_bayer_11_01_0P_1;
			r_bayer_00_00_1P_0	<= r_bayer_00_01_0P_0;
			r_bayer_00_00_1P_1	<= r_bayer_00_01_0P_1;
			r_bayer_01_00_1P_0	<= r_bayer_01_01_0P_0;
			r_bayer_01_00_1P_1	<= r_bayer_01_01_0P_1;
		end
	end 
end 


always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
        r_bayer_11_11_2P_0	<= {P_DEPTH{1'b0}};
        r_bayer_11_11_2P_1	<= {P_DEPTH{1'b0}};
        r_bayer_00_11_2P_0	<= {P_DEPTH{1'b0}};
        r_bayer_00_11_2P_1	<= {P_DEPTH{1'b0}};
        r_bayer_01_11_2P_0	<= {P_DEPTH{1'b0}};
        r_bayer_01_11_2P_1	<= {P_DEPTH{1'b0}};
			
	end
	else
	begin
		if (r_x_cnt == 11'd0)
		begin
			
			r_bayer_11_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_11_11_2P_1	<= {P_DEPTH{1'b0}};
			r_bayer_00_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_00_11_2P_1	<= {P_DEPTH{1'b0}};
			r_bayer_01_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_01_11_2P_1	<= {P_DEPTH{1'b0}};
		end else begin
			r_bayer_11_11_2P_0	<= r_bayer_11_00_1P_0;
			r_bayer_11_11_2P_1	<= r_bayer_11_00_1P_1;
			r_bayer_00_11_2P_0	<= r_bayer_00_00_1P_0;
			r_bayer_00_11_2P_1	<= r_bayer_00_00_1P_1;
			r_bayer_01_11_2P_0	<= r_bayer_01_00_1P_0;
			r_bayer_01_11_2P_1	<= r_bayer_01_00_1P_1;
		end
			
	end 
end 
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_28] w_r_00_00_l1 = r_bayer_00_00_1P_1 + r_bayer_00_11_2P_1;
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_29] w_b_00_00_l1 = r_bayer_11_00_1P_0  + r_bayer_01_00_1P_0 ;
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_30] w_g_00_00_h1	= r_bayer_11_00_1P_1 + r_bayer_01_00_1P_1 + r_bayer_00_01_0P_0 + r_bayer_00_00_1P_0;
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_31] w_b_00_00_h1	= r_bayer_01_01_0P_0 + r_bayer_11_00_1P_0 + r_bayer_11_01_0P_0 + r_bayer_01_00_1P_0;


wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_32] w_r_00_00_l0	= r_bayer_11_00_1P_1 + r_bayer_01_11_2P_1 + r_bayer_01_00_1P_1 + r_bayer_11_11_2P_1;
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_33] w_g_00_00_l0	= r_bayer_11_00_1P_0 + r_bayer_01_00_1P_0 + r_bayer_00_00_1P_1 + r_bayer_00_11_2P_1;
// At this green pixel, red is vertical and blue is horizontal.
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_34] w_r_00_00_h0 = r_bayer_11_00_1P_1 + r_bayer_01_00_1P_1;
wire [`CFG_DEBAYER_RAW_TO_RGB_V_RANGE_35] w_b_00_00_h0 = r_bayer_00_01_0P_0 + r_bayer_00_00_1P_0;

always@(posedge i_pclk)
begin
	if (~i_arstn) begin	
		r_r_00_00_1P		<= {PW{1'b0}};
		r_g_00_00_1P		<= {PW{1'b0}};
		r_b_00_00_1P		<= {PW{1'b0}};		
	end else begin

		if (!r_de_00_1P) begin
			r_r_00_00_1P	<= {PW{1'b0}};
			r_g_00_00_1P	<= {PW{1'b0}};
			r_b_00_00_1P	<= {PW{1'b0}};	

			

		end else if (r_y_cnt[0] == GREEN_FIRST) begin
			// The window center is the preceding row. Select the G/color
			// center-row formulas according to the input Bayer phase.
			/* R Gr RG R */
			// if (r_valid_1P)
			// begin
			// 	r_r_00_00_1P[P_DEPTH-1:0]	<= r_bayer_00_00_1P_0;
			// 	r_g_00_00_1P[P_DEPTH-1:0]	<= (((r_bayer_11_00_1P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1)) >> 1) + (((r_bayer_00_00_1P_1 >> 1) + (r_bayer_00_11_2P_1 >> 1)) >> 1);
			// 	r_b_00_00_1P[P_DEPTH-1:0]	<= (((r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_11_2P_1 >> 1)) >> 1) + (((r_bayer_01_00_1P_1 >> 1) + (r_bayer_11_11_2P_1 >> 1)) >> 1);
				
			// 	r_r_00_00_1P[PW-1:P_DEPTH]	<= (r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
			// 	r_g_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;				
			// 	r_b_00_00_1P[PW-1:P_DEPTH]	<= (r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
			// end
			//B Gb B Gb//
			if (r_valid_1P)
			begin
				
				r_r_00_00_1P[P_DEPTH-1:0]	<= w_r_00_00_l1>>1;//(r_bayer_00_00_1P_1 >> 1) + (r_bayer_00_11_2P_1 >> 1); 
				r_g_00_00_1P[P_DEPTH-1:0]	<= r_bayer_00_00_1P_0;				
				r_b_00_00_1P[P_DEPTH-1:0]	<= w_b_00_00_l1>>1;//(r_bayer_11_00_1P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1);
							
				r_r_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;
				r_g_00_00_1P[PW-1:P_DEPTH]	<= w_g_00_00_h1>>2;//(((r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1)) >> 1) + (((r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1)) >> 1);		
				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_b_00_00_h1>>2;//(((r_bayer_01_01_0P_0 >> 1) + (r_bayer_11_00_1P_0 >> 1)) >> 1) + (((r_bayer_11_01_0P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1)) >> 1);
			
			end
		end
		else
		begin
			/* Gb B Gb G */
			// if (r_valid_1P)
			// begin
			// 	r_r_00_00_1P[P_DEPTH-1:0]	<= (r_bayer_11_00_1P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1);
			// 	r_g_00_00_1P[P_DEPTH-1:0]	<= r_bayer_00_00_1P_0;				
			// 	r_b_00_00_1P[P_DEPTH-1:0]	<= (r_bayer_00_00_1P_1 >> 1) + (r_bayer_00_11_2P_1 >> 1);
							
			// 	r_r_00_00_1P[PW-1:P_DEPTH]	<= (((r_bayer_01_01_0P_0 >> 1) + (r_bayer_11_00_1P_0 >> 1)) >> 1) + (((r_bayer_11_01_0P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1)) >> 1);
			// 	r_g_00_00_1P[PW-1:P_DEPTH]	<= (((r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1)) >> 1) + (((r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1)) >> 1);		
			// 	r_b_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;
			
			// end
			//G R G R 
			if (r_valid_1P)
			begin
				r_r_00_00_1P[P_DEPTH-1:0]	<= w_r_00_00_l0>>2;//(((r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_11_2P_1 >> 1)) >> 1) + (((r_bayer_01_00_1P_1 >> 1) + (r_bayer_11_11_2P_1 >> 1)) >> 1);
				r_g_00_00_1P[P_DEPTH-1:0]	<= w_g_00_00_l0>>2;//(((r_bayer_11_00_1P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1)) >> 1) + (((r_bayer_00_00_1P_1 >> 1) + (r_bayer_00_11_2P_1 >> 1)) >> 1);
				r_b_00_00_1P[P_DEPTH-1:0]	<= r_bayer_00_00_1P_0; 
				
				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_r_00_00_h0>>1;
				r_g_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;				
				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_b_00_00_h0>>1;
				
			end
		end
	end	
end



assign	o_vsync	= r_vsync_00_2P;
assign	o_hsync	= r_hsync_00_2P;
assign	o_de	= r_de_00_2P;
assign	o_valid	= r_valid_2P;
assign	o_x_cnt	= r_x_cnt_2P;	
assign	o_y_cnt	= r_y_cnt_2P;
assign	o_r		= r_r_00_00_1P;
assign	o_g		= r_g_00_00_1P;
assign	o_b		= r_b_00_00_1P;

endmodule
