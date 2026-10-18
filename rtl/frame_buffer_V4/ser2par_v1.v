`include "../defines.v"


module ser2par_v1 #(
	parameter I_VID_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_PARAMETER_I_VID_WIDTH,
	parameter O_VID_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_PARAMETER_O_VID_WIDTH
	 
)(
input		wire										clk		,    
input		wire										rst_n	,
input       wire                                        i_valid,
input		wire										i_frame_start	, //active hgih
input		wire										i_frame_end	, //active high
input       wire                                        frame_stable,
input		wire				[`CFG_BITS_24-1:0]					frame_pix_num,
input		wire	[`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_1] 					i_data,

output		wire										o_valid,
output		wire	[`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_2]					o_data,
output      wire                                        o_frame_start,
output      wire                                         o_frame_end


);
localparam SHIFT_INT = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_SHIFT_INT;
localparam SHIFT_FLOAT = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_SHIFT_FLOAT;
localparam I_VID_DIV = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_I_VID_DIV;
localparam MAXI_DATA_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_MAXI_DATA_WIDTH;
localparam IN_CNT = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_IN_CNT;
localparam OU_CNT = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_OU_CNT;
localparam IN_CNT_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_IN_CNT_WIDTH;
localparam OU_CNT_WIDTH = `CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_LOCALPARAM_OU_CNT_WIDTH;
//==================================================================================

reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_3] par_pix_data = 'd0;
reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_4] par_pix_data_r0 = 'd0;
reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_5] r_in_cnt = 'd0;
reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_6] w_in_cnt;
reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_7] r_out_cnt = 'd0;
reg last_shift = 'd0;
// reg [1:0] last_shift_r = 'd0;
reg par_pix_valid = 1'b0;
reg start_cycle = 'd0;
reg i_valid_r = 'd0;
reg par_valid = 1'b1;
always @( posedge clk or negedge rst_n )
begin 
    if( !rst_n ) begin
        par_pix_data <= 'd0;
    end else if( i_valid |last_shift)
        par_pix_data <= {par_pix_data[MAXI_DATA_WIDTH-I_VID_WIDTH-1:0],i_data};
end 

always @( posedge clk or negedge rst_n )
begin
    if( !rst_n ) begin 
        r_in_cnt <= 'd0;
    end else begin 
        r_in_cnt <= w_in_cnt ;
    end 
end

always @(*)
begin
    if( i_frame_start )
        w_in_cnt = 'd1;
    else if( r_in_cnt == IN_CNT-1 && (i_valid | last_shift) )
        w_in_cnt = 'd0;
    else if( i_valid | last_shift)
        w_in_cnt = r_in_cnt + 1'b1;
    else 
        w_in_cnt = r_in_cnt;
end

always @( posedge clk )
begin
    // last_shift_r <= {last_shift_r[0],last_shift};
    if( i_frame_end && r_in_cnt != IN_CNT-1 )
        last_shift <= 1'b1;
    else if( r_in_cnt == IN_CNT-1)
        last_shift <= 1'b0;
end
always @( posedge clk or negedge rst_n )
begin
    if( !rst_n )
        par_valid <= 1'b0;
    else if( r_in_cnt == IN_CNT -1 && (i_valid | last_shift))//last_shift_r[0]))
        par_valid <= 1'b1;
    else 
        par_valid <= 1'b0;
end

always @( posedge clk or negedge rst_n )
begin
      if( ~rst_n )
            start_cycle <= 1'b0;
      else if( i_frame_start ) 
            start_cycle <= 1'b1;
      else if( o_valid )
            start_cycle <= 1'b0;
end


always @( posedge clk or negedge rst_n )
begin
    if( !rst_n ) begin 
        par_pix_valid <= 1'b0;
    end else begin 
        par_pix_valid <= par_valid;
    end 
end

generate 
    
if( SHIFT_FLOAT != 0 ) begin : SHIFT_FLOAT_NONE_ZERO
always @( posedge clk or negedge rst_n )
begin
    if( !rst_n )
        par_pix_data_r0 <= 'd0;
    else if( par_valid )
        par_pix_data_r0 <= par_pix_data;
    else 
        par_pix_data_r0 <= par_pix_data_r0 << O_VID_WIDTH;
end

always @( posedge clk or negedge rst_n )
begin
    if( !rst_n )
        r_out_cnt <= 'd0;
    else if( par_pix_valid )
        r_out_cnt <= 1;
    else if( |r_out_cnt == 1'b0)
        r_out_cnt <= 0;
    else 
        r_out_cnt <= r_out_cnt == OU_CNT-1 ? 0 :r_out_cnt + 1'b1;
end

reg [`CFG_BITS_2-1:0] state = 'd0;
always @( posedge clk )
begin
    if( i_frame_start ) begin 
        state <= 2'd0;
    end else begin 
        case( state )
        2'd0 : begin
            state <= i_frame_end ? 2'd1 : 2'd0;
        end
        2'd1 : begin
            state <= last_shift  ? 2'd1 : 2'd2;
        end
        2'd2: begin
        end
        default:;
        endcase
    end 
end

 assign    o_data = par_pix_data_r0[MAXI_DATA_WIDTH-1:MAXI_DATA_WIDTH-O_VID_WIDTH];
 assign    o_valid = (|r_out_cnt) | par_pix_valid;
 assign    o_frame_end = state == 2 &  (r_out_cnt == OU_CNT -1);
 assign o_frame_start = start_cycle & o_valid;

//  always @( posedge clk )
//  begin
//     o_data              <= par_pix_data_r0[MAXI_DATA_WIDTH-1:MAXI_DATA_WIDTH-O_VID_WIDTH];
//     o_valid             <= (|r_out_cnt) | par_pix_valid;
//     o_frame_end         <= end_cycle & par_pix_valid_r[1];
//     o_frame_start       <= start_cycle & o_valid;
//  end

end else begin
    always @( posedge clk or negedge rst_n )
    begin
        if( !rst_n )
            par_pix_data_r0 <= 'd0;
        else if( par_valid )
            par_pix_data_r0 <= par_pix_data;
    end
    reg [`CFG_BITS_2-1:0] state = 'd0;
    always @( posedge clk )
    begin
        if( i_frame_start ) begin 
            state <= 2'd0;
        end else begin 
            case( state )
            2'd0 : begin
                state <= i_frame_end ? 2'd1 : 2'd0;
            end
            2'd1 : begin
                state <= last_shift  ? 2'd1 : 2'd2;
            end
            2'd2: begin
            end
            default:;
            endcase
        end 
    end
    assign    o_data = par_pix_data_r0;
    assign    o_valid = par_pix_valid;
    assign    o_frame_end = state == 2 & o_valid;
    assign o_frame_start = start_cycle & o_valid;
end
endgenerate
//=======================================================================================
 function integer max_width;
 input [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_8] indata;
 input [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_9]	axi_data;
 integer i;
 reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_10] sub_idata1,sub_idata2;
 reg [`CFG_FRAME_BUFFER_V4_SER2PAR_V1_V_RANGE_11] max_sub_idata;
 begin

 for(i = 0;i <= indata;i = i+1 ) begin 
         sub_idata1 = indata%i;
         sub_idata2 = axi_data%i;
         if( sub_idata1 == 0 && sub_idata2 == 0 ) begin 
             max_sub_idata = i ;
         end 
         
 end 

 max_width=indata/max_sub_idata* axi_data;
 end
endfunction

endmodule

