`include "../defines.v"
module vid_par2ser#(
    parameter I_VID_WIDTH = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_PARAMETER_I_VID_WIDTH,
    parameter O_VID_WIDTH = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_PARAMETER_O_VID_WIDTH
    

)(
    input clk,
    input rst_n,

    input frame_period,
    input rd_fifo_rdvalid,
    input [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_1]rd_fifo_rddata ,
    input rd_fifo_rdempty,
    output   rd_fifo_rden ,

    output reg tx_fifo_valid = 'd0,
    input       wr_fifo_full,
    output wire [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_2] tx_fifo_wrdata
);

localparam MAXI_DATA_WIDTH = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_LOCALPARAM_MAXI_DATA_WIDTH;
localparam IN_CNT = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_LOCALPARAM_IN_CNT;
localparam OU_CNT = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_LOCALPARAM_OU_CNT;
localparam IN_CNT_WIDTH = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_LOCALPARAM_IN_CNT_WIDTH;
localparam OU_CNT_WIDTH = `CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_LOCALPARAM_OU_CNT_WIDTH;


reg frame_period_r0 = 1'b0;
reg frame_period_r1 = 1'b0;
reg [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_3] data_buffer = 'd0;
reg [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_4] data_buffer1 = 'd0;
reg [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_5] shift_in = 'd0;
reg [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_6] shift_out = 'd0;
reg dirty_data = 'd0;
reg pipe_en = 'd0;
reg tx_valid_en = 'd0;
wire rd_last;
always @( posedge clk or negedge rst_n )
begin
    if( !rst_n ) begin
        frame_period_r0 <= 1'b0;
        frame_period_r1 <= 1'b0;
    end else begin
        frame_period_r0 <= frame_period;
        frame_period_r1 <= frame_period_r0;
    end
end
wire frame_start_w = {frame_period_r0,frame_period} == 2'b01;
reg rd_fifo_rdvalid_r = 1'b0;
always @( posedge clk )
begin
    rd_fifo_rdvalid_r <= rd_fifo_rden;
end
generate 

if( MAXI_DATA_WIDTH ==  I_VID_WIDTH) begin 
    always @( posedge clk )
    begin
        data_buffer <= rd_fifo_rdvalid_r ? rd_fifo_rddata : data_buffer;
    end
end else begin 
    always @( posedge clk )
    begin
        data_buffer <= rd_fifo_rdvalid_r ? {data_buffer[MAXI_DATA_WIDTH-I_VID_WIDTH-1:0],rd_fifo_rddata} : data_buffer;
    end
end 
endgenerate 


always @( posedge clk )
begin
    if( frame_start_w)
        shift_in <= 'd0 ;
    else if( rd_fifo_rden )
        shift_in <= (shift_in == IN_CNT-1)? 'd0 : shift_in + 1'b1;
end

always @( posedge clk )
begin
    if( frame_start_w )
        pipe_en <= 1'b0;
    else if( shift_in == 0 && rd_fifo_rdvalid_r )
        pipe_en <= 1'b1;
    else if(dirty_data || rd_last)
        pipe_en <= 1'b0;
end
reg rd_fifo_rden_r = 1'b0;
always @( posedge clk  or negedge rst_n )
begin
    if( !rst_n )
        rd_fifo_rden_r <= 1'b0;
    else if( frame_start_w || (shift_in == IN_CNT-1 && rd_fifo_rden ))
        rd_fifo_rden_r <= 1'b0;
    else
        rd_fifo_rden_r <=(~rd_fifo_rdempty);//~pipe_en&
end
assign rd_fifo_rden =  ~pipe_en & rd_fifo_rden_r &(~rd_fifo_rdempty) ;

always @( posedge clk )
begin
    if( pipe_en &&(dirty_data | rd_last)) begin 
        data_buffer1 <= data_buffer;
    end else if( ~wr_fifo_full & tx_valid_en ) begin //
        data_buffer1 <= data_buffer1 << O_VID_WIDTH;
    end 
end

always @( posedge clk )
begin
    if( pipe_en &&(dirty_data | rd_last)) begin 
        tx_fifo_valid <= 1'b1;
    end else if( ~wr_fifo_full & tx_valid_en & ~rd_last ) begin //
        tx_fifo_valid <= 1'b1;
    end else begin
        tx_fifo_valid <= 1'b0;
    end
end

always @( posedge clk )
begin
    if( pipe_en && (dirty_data | rd_last)) begin
        tx_valid_en <= 'd1;
    end else if( rd_last)
        tx_valid_en <= 'd0;
end
always @( posedge clk or negedge rst_n )
begin
    if( !rst_n )
        shift_out <= 'd0;
    else if(tx_valid_en ) begin //~dirty_data &&
        if( ~wr_fifo_full )
            shift_out <= shift_out == OU_CNT-1 ? 'd0 : shift_out + 1'b1;
    end else 
        shift_out <= 'd0;
end

always @( posedge clk or negedge rst_n )
begin
    if( !rst_n )
        dirty_data <= 1'b1;
    else if( pipe_en )//第一个数据控制 dirty_data && 
        dirty_data <= 1'b0;
    else if( rd_last & ~pipe_en)
        dirty_data <= 1'b1;
end
assign rd_last = shift_out == OU_CNT-1 && ~wr_fifo_full && tx_valid_en;
assign tx_fifo_wrdata = data_buffer1[MAXI_DATA_WIDTH-1:MAXI_DATA_WIDTH-O_VID_WIDTH];



//=======================================================================================
function integer max_width;
input [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_7] indata;
input [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_8]	axi_data;
integer i;
reg [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_9] sub_idata1,sub_idata2;
reg [`CFG_FRAME_BUFFER_V4_VID_PAR2SER_V_RANGE_10] max_sub_idata;
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
