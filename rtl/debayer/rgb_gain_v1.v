`include "../defines.v"
module rgb_gain_v1
#(
	parameter	P_DEPTH			= `CFG_DEBAYER_RGB_GAIN_V1_V_PARAMETER_P_DEPTH,
	parameter	Q_WIDTH			= `CFG_DEBAYER_RGB_GAIN_V1_V_PARAMETER_Q_WIDTH,	// Q8.8定点
	parameter GREEN_FIRST = `CFG_DEBAYER_RGB_GAIN_V1_V_PARAMETER_GREEN_FIRST // 1: even G/B, odd R/G; 0: even B/G, odd G/R (low/high)
)
(
	input               i_pclk,
	input               i_arstn,

	input 		        i_hs,
	input               i_vs,
	input				i_de,
	input				i_valid,
	input [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_1]  		i_data,

	input [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_2]	gain_r,
	input [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_3]	gain_g,
	input [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_4]	gain_b,

	output  reg            	o_hs,
	output	reg				o_vs,
	output	reg				o_de,
	output	reg				o_valid,
	output  reg [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_5]  	o_data,
	output wire                 o_raw_row_odd
);

reg				r_hs_1P;
reg				r_de_1P;
reg				r_vs_1P;
reg				r_valid_1P;
reg						r_line_cnt;

// Tag the input RAW row with the exact phase used to select gains.
// This is not delayed with o_data; it belongs to i_data/i_de/i_vs.
assign o_raw_row_odd = r_line_cnt;

//同步信号打一拍
always@(posedge i_pclk)
begin
	if (!i_arstn) begin
		r_hs_1P		<= 1'b0;
		r_de_1P		<= 1'b0;
		r_vs_1P		<= 1'b0;
		r_valid_1P	<= 1'b0;
	end else begin
		r_hs_1P		<= i_hs;
		r_de_1P		<= i_de;
		r_vs_1P		<= i_vs;
		r_valid_1P	<= i_valid;
	end
end

//行标记切换
always @( posedge i_pclk )
begin
	if( !i_arstn )
		r_line_cnt <= 'd0;
	else if (r_vs_1P && !i_vs)
		r_line_cnt	<= 1'b0;
	else if(r_valid_1P && r_de_1P && (!i_de))
		r_line_cnt 	<= ~r_line_cnt;
end

wire [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_6] pix_high = i_data[P_DEPTH*2-1:P_DEPTH];
wire [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_7] pix_low  = i_data[P_DEPTH-1:0];

reg [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_8] mul_high;
reg [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_9] mul_low;

//多路选择对应通道增益
always @(*) begin
	if (!GREEN_FIRST) begin
		// BGGR RAW: even low=B/high=G, odd low=G/high=R.
		mul_high = pix_high * (r_line_cnt ? gain_r : gain_g);
		mul_low  = pix_low  * (r_line_cnt ? gain_g : gain_b);
	end else if(r_line_cnt) begin
		//奇数行 high=Gr(gain_g)  low=R(gain_r)
		mul_high = pix_high * gain_g;
		mul_low  = pix_low  * gain_r;
	end
	else begin
		//偶数行 high=B(gain_b)  low=Gb(gain_g)
		mul_high = pix_high * gain_b;
		mul_low  = pix_low  * gain_g;
	end
end

//Q8.8 右移8位 + 10bit饱和
wire [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_10] out_high = (|mul_high[Q_WIDTH+P_DEPTH-1:P_DEPTH+8] ) ? 2**P_DEPTH-1 : mul_high[P_DEPTH+8-1:8];
wire [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_11] out_low  = (|mul_low[Q_WIDTH+P_DEPTH-1:P_DEPTH+8]  ) ? 2**P_DEPTH-1 : mul_low[P_DEPTH+8-1:8];

wire [`CFG_DEBAYER_RGB_GAIN_V1_V_RANGE_12] w_data_filtered = {out_high,out_low};

always @( posedge i_pclk )
begin
	o_hs	<= i_hs;//r_hs_1P;
	o_de	<= i_de;//r_de_1P;
	o_vs	<= i_vs;//r_vs_1P;
	o_valid	<= i_valid;//r_valid_1P;
	o_data	<= w_data_filtered;
end

endmodule
