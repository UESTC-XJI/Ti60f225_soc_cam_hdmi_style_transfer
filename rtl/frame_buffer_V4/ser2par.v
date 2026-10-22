`include "../defines.v"


module ser2par #(
	parameter I_VID_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V_PARAMETER_I_VID_WIDTH,
    parameter I_MUX  = `CFG_FRAME_BUFFER_V4_SER2PAR_V_PARAMETER_I_MUX,
	parameter O_VID_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V_PARAMETER_O_VID_WIDTH
	 
)(
input		wire										clk		,    
input		wire										rst_n	,
input       wire                                        i_valid,
input		wire	[`CFG_FRAME_BUFFER_V4_SER2PAR_V_RANGE_1] 					i_data,
input		wire										i_start	, //active hgih
input		wire										i_end	, //active high


output		wire										    o_valid,
output		wire	[`CFG_FRAME_BUFFER_V4_SER2PAR_V_RANGE_2]					o_data


);
localparam IN_CNT_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V_LOCALPARAM_IN_CNT_WIDTH;
//==================================================================================

reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V_RANGE_3] par_pix_data = 'd0;
reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V_RANGE_4] r_in_cnt = 'd0;
reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V_RANGE_5] w_in_cnt;
reg last_shift = 'd0;
// reg last_shift_r = 'd0;
reg start_cycle = 'd0;
always @( posedge clk or negedge rst_n )
begin 
    if( !rst_n ) begin
        par_pix_data <= 'd0;
    end else if( i_valid |last_shift)
        par_pix_data <= {par_pix_data[O_VID_WIDTH-I_VID_WIDTH-1:0],i_data};
end 

always @( posedge clk or negedge rst_n )
begin
    if( !rst_n )
        r_in_cnt <= 'd0;
    else 
        r_in_cnt <= w_in_cnt ;
end

always @(*)
begin
    if( i_start )
        w_in_cnt = 'd1;
    else if( r_in_cnt == I_MUX-1 & i_valid)
        w_in_cnt = 'd0;
    else if( i_valid | last_shift)
        w_in_cnt = r_in_cnt + 1'b1;
    else 
        w_in_cnt = r_in_cnt;
end


reg w_o_valid= 1'b0;
always @( posedge clk )
begin
    // last_shift_r <= last_shift;
    if( i_end && r_in_cnt != I_MUX-1 )
        last_shift <= 1'b1;
    else if(w_o_valid)//( r_in_cnt == I_MUX-1)
        last_shift <= 1'b0;
end

always@( posedge clk )
begin

  if( r_in_cnt == I_MUX-1 && ( i_valid |last_shift))
        w_o_valid <=  1'b1;
  else 
        w_o_valid <= 1'b0;
end
 
//  assign    w_o_valid =  r_in_cnt == I_MUX-1;//(~i_start) && (~|r_in_cnt) && (i_valid | last_shift);//last_shift_r);

 assign    o_data = par_pix_data;
 assign    o_valid = w_o_valid;

endmodule

