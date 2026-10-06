`include "../defines.v"

`timescale 1ps/1ps
module ddr_rd_buffer #(
parameter AXI_DATA_WIDTH = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_PARAMETER_AXI_DATA_WIDTH, //!AXI接口位宽
parameter AXI_ADDR_WIDTH = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_PARAMETER_AXI_ADDR_WIDTH,  //!AXI地址位宽
parameter RD_FIFO_DEPTH = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_PARAMETER_RD_FIFO_DEPTH, //!read fifo depth
parameter BURST_LEN       = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_PARAMETER_BURST_LEN

) (

input 								            axi_clk,
input 								            axi_clk_rst_n,
input 								            start,//!电平有效。

input		[`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_1]	            start_addr,
input		[`CFG_BITS_25-1:0]								burst_len,
input wire                                     bank_sw_ack	,
output  wire                                     bank_sw 		  ,

input											rd_fifo_rdclk,
input                                           rd_fifo_rst_p,
output	reg										rd_fifo_rdvalid ='d0,
output	 [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_2] 				    rd_fifo_rddata,
output wire										rd_fifo_rdempty,
input	 wire									rd_fifo_rden,

output [`CFG_BITS_6-1:0] 									    arid,
output  [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_3] 	                    araddr,
output  [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_4] 						            arlen,
output  [`CFG_BITS_3-1:0] 										arsize,
output  [`CFG_BITS_2-1:0] 										arburst,
output  											arlock,
output reg 											arvalid,
output  											arapcmd,
output 												arqos,
input 												arready,
output  [`CFG_BITS_4-1:0] 								        arcache,
output [`CFG_BITS_3-1:0]                                        arprot,

input [`CFG_BITS_6-1:0] 									rid,
input [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_5] 						rdata,
input 											rlast,
input 											rvalid,
output  reg										rready,
input [`CFG_BITS_2-1:0] 									rresp,
output[`CFG_BITS_32-1:0]									wr_fifo_rd_data_test,

output [`CFG_BITS_8-1:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;
localparam AXSIZE_WTH = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_LOCALPARAM_AXSIZE_WTH;//!内部数据
localparam RD_USEDW_WITH = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_LOCALPARAM_RD_USEDW_WITH ;
localparam ADDR_SHIFT_BITS = `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_LOCALPARAM_ADDR_SHIFT_BITS;
reg 										ddr_rd_valid;                      
reg [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_6] 					ddr_rd_data;
wire [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_7]					rd_fifo_wrusedw;
 
reg	 [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_8] 					ddr_addr	= 'd0;
reg	[`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_9]					                ddr_arlen = 'd0;
reg			[`CFG_BITS_3-1:0]							start_sync = 'd0;
wire [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_10] 					nx_ddr_addr;
wire										rd_addr_en	;
reg	[`CFG_BITS_25-1:0]									burst_len_r = 'd0;
reg											burst_last ='d0;
reg [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_11] 					start_addr_r = 'd0;
reg                                         sync_r0 = 'd0;
reg                                         sync_r1 = 'd0;
reg                                         sync_r2 = 'd0;
reg [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_12]                                 first_burst_cnt = 'd0;
reg	[`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_13] 			                    last_burst_cnt = 'd0;
reg [`CFG_BITS_25-1:0]                                  align_burst_num = 'd0;
reg [`CFG_BITS_25-1:0]                                  burst_num = 'd0;
reg [`CFG_BITS_25-1:0]                                  total_burst_num = 'd0;

//wire pos_start;
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
	if( !axi_clk_rst_n )			start_sync <= 'd0;
	else 				    start_sync <= {start_sync[1:0],start};
end

assign pos_start = start_sync[1:0] == 2'b01;
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
	if( !axi_clk_rst_n ) begin
		sync_r0 <= 1'b0;
		sync_r1 <= 1'b0;
		sync_r2 <= 1'b0;
	end else begin 
		sync_r0 <= pos_start;
		sync_r1 <= sync_r0;
		sync_r2 <= sync_r1;
	end 
end

always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
	if( !axi_clk_rst_n ) begin
			// cfg_alen_r   <= cfg_alen;
			burst_len_r<= burst_len;
			start_addr_r <= start_addr;
	end else begin
			burst_len_r  <= pos_start ? burst_len   : burst_len_r ;
			// cfg_alen_r   <= pos_start ? cfg_alen    :cfg_alen_r;
			start_addr_r <= pos_start ? start_addr  :start_addr_r;
	end
end

wire [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_14]     first_4k_burst_len = {1'b0,~start_addr_r[11:ADDR_SHIFT_BITS]} + 1'b1;
wire [`CFG_BITS_32-1:0]                     last_4k_burst_len  = burst_len_r - first_4k_burst_len;


generate
    if( BURST_LEN == 1)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[0]  ? {7'd0,first_4k_burst_len[0]}-'d1  :BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[0]  ? {7'd0,last_4k_burst_len[0]}-1  :BURST_LEN;
            burst_num <= align_burst_num[24:1] + 2 ;
        end 
    else if( BURST_LEN == 3 )
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[1:0]? {6'd0,first_4k_burst_len[1:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[1:0]? {6'd0,last_4k_burst_len[1:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:2] + 2 ;
        end 
    else if( BURST_LEN == 7)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[2:0]? {5'd0,first_4k_burst_len[2:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[2:0]? {5'd0,last_4k_burst_len[2:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:3] + 2 ;
        end 
    else if( BURST_LEN == 15)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[3:0]? {4'd0,first_4k_burst_len[3:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[3:0]? {4'd0,last_4k_burst_len[3:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:4] + 2 ;
        end 
    else if( BURST_LEN == 31)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[4:0]? {3'd0,first_4k_burst_len[4:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[4:0]? {3'd0,last_4k_burst_len[4:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:5] + 2 ;
        end 
    else if( BURST_LEN == 63)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[5:0]? {2'd0,first_4k_burst_len[5:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[5:0]? {2'd0,last_4k_burst_len[5:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:6] + 2 ;
        end 
    else if( BURST_LEN == 127)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[6:0]?{1'd0,first_4k_burst_len[6:0]}-1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[6:0]? {1'd0,last_4k_burst_len[6:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:7] + 2 ;
        end 
    else if( BURST_LEN == 255)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[7:0]?first_4k_burst_len[7:0]-1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[7:0]? last_4k_burst_len[7:0]-1:BURST_LEN;
            burst_num <= align_burst_num[24:8] + 2 ;
        end 

endgenerate

always @( posedge axi_clk or negedge axi_clk_rst_n   )
begin 
    if( !axi_clk_rst_n ) begin
        align_burst_num <= 'd0;
    end else begin //w_wr_sync_r1;
	    align_burst_num <= burst_len_r - first_burst_cnt - last_burst_cnt -'d2 ;
    end 
end

//====================================================================================
//address process
always @(posedge axi_clk or negedge axi_clk_rst_n) 
begin
	if (!axi_clk_rst_n) 									ddr_addr <= start_addr_r;
	else if( sync_r2 )						                ddr_addr <= start_addr_r;
	else if (rd_addr_en) 						            ddr_addr <= nx_ddr_addr;
    
end 
assign nx_ddr_addr =  ddr_addr + {(ddr_arlen+1),{ADDR_SHIFT_BITS{1'b0}} };  


//=====================================================================================

//ddr alen process
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
 	if( !axi_clk_rst_n )  							        total_burst_num <= 0;
 	else if(sync_r2)					                    total_burst_num <= 0;//( w_wr_sync0 )
 	else if( rd_addr_en )					                total_burst_num <= total_burst_num + 1'b1;
end 

always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n )								    burst_last <= 1'b0;
    else if( sync_r2 )					                    burst_last <= 1'b0;	
    else if(rd_addr_en && burst_num == total_burst_num+2 )  burst_last <= 1'b1;
    else if(rd_addr_en && burst_num == total_burst_num+1)   burst_last <= 1'b0;
end 

always @( posedge axi_clk or negedge axi_clk_rst_n  )
begin
    if( !axi_clk_rst_n ) 							            ddr_arlen 	<= BURST_LEN;//cfg_alen;
    else if( sync_r2 )						                    ddr_arlen 	<= first_burst_cnt;	 
    else if(rd_addr_en && burst_num == total_burst_num+2)		ddr_arlen	<= last_burst_cnt;//(rd_addr_en && burst_last) 
    else if( rd_addr_en )					                    ddr_arlen 	<= BURST_LEN;//cfg_alen_r;	
end


assign arapcmd  = 1'b0;  
assign arlock   = 1'b0;  
assign arqos    = 1'b0; 
assign arid     = 6'h00;
assign arsize   = AXSIZE_WTH;
assign arlen	= ddr_arlen;
assign arburst  = 2'b01;
assign araddr   = ddr_addr;    
assign arprot       = 3'd2;
assign arcache 		= 4'd3; 


assign rd_addr_en = arvalid & arready;

always @(posedge axi_clk or negedge axi_clk_rst_n )											
begin
	if( !axi_clk_rst_n )							ddr_rd_valid <= 1'b0;
	else											ddr_rd_valid <= rvalid;				
end 			

always @( posedge axi_clk )
begin
    ddr_rd_data <= rdata;
end

//==========================================================================================
reg [`CFG_BITS_2-1:0] state = 2'd0;
reg rd_req = 0;
reg ddr_read_stop = 'd0;
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n )
        ddr_read_stop <= 1'b0;
    else if( sync_r2 )
        ddr_read_stop <= 1'b0;
    else if( rd_addr_en &&burst_last )
        ddr_read_stop <= 1'b1;
end
assign bank_sw = ddr_read_stop;

always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n )
        rd_req <= 1'b0;
    else if(RD_FIFO_DEPTH < rd_fifo_wrusedw + BURST_LEN + 5)//( rd_fifo_wrusedw > 512  )//
        rd_req <= 1'b0;
    else 
        rd_req <= 1'b1;
end


always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n ) begin
        arvalid <= 1'b0;
        rready <= 1'b0;
        state <= 'd0;
    end else if(rd_fifo_rst_p) begin
        state <= 2'd0;
        arvalid <= 1'b0;
        rready <= 1'b0;
    end else begin
        rready <= 1'b1;
        case(state )
        2'd0 : begin
            state <= sync_r2 ? 2'd1 : 2'd0;
        end
        2'd1 : begin
            if( rd_req ) begin
                state <= 2'd2;
                arvalid <= 1'b1;
            end
        end
        2'd2 : begin
            if( arready) begin
                state <= 2'd3;
                arvalid <= 1'b0;
                rready <= 1'b1;
            end
        end
        2'd3 : begin
            if( rvalid & rlast) begin//rready & 
                if( ddr_read_stop )
                    state <= 2'd0;
                else 
                    state <= 2'd1;
            end
        end
        default :;
    
        endcase
end
end


wire										rd_fifo_wr_full;
wire [`CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_RANGE_15] 					rd_fifo_rdusedw;
	DC_FIFO
# (
    .FIFO_MODE  ( `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_INST_U_RD_FIFO_FIFO_MODE    	 ), //"Normal"; //"ShowAhead"
    .DATA_WIDTH ( `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_INST_U_RD_FIFO_DATA_WIDTH ),
    .FIFO_DEPTH ( `CFG_FRAME_BUFFER_V4_DDR_RD_BUFFER_V_INST_U_RD_FIFO_FIFO_DEPTH  )
  ) u_rd_fifo(   
  //System Signal
  /*i*/.Reset   (	(~axi_clk_rst_n)	|| rd_fifo_rst_p		), 
  /*i*/.WrClk   (axi_clk			), 
  /*i*/.WrEn    (ddr_rd_valid		), 
  /*o*/.WrDNum  (rd_fifo_wrusedw	), 
  /*o*/.WrFull  (rd_fifo_wr_full 	), 
  /*i*/.WrData  (ddr_rd_data 		), 
  /*i*/.RdClk   (rd_fifo_rdclk		), 
  /*i*/.RdEn    (rd_fifo_rden		), 
  /*o*/.RdDNum  (rd_fifo_rdusedw	), 
  /*o*/.RdEmpty (rd_fifo_rdempty	), 
  /*o*/.RdData  (rd_fifo_rddata		)  
);

always @( posedge axi_clk )
begin
    rd_fifo_rdvalid <=   rd_fifo_rden;
end



endmodule