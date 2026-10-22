`include "../defines.v"


`timescale 1ps/1ps
module ddr_buffer #(
parameter AXI_DATA_WIDTH = `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_AXI_DATA_WIDTH, //!AXI接口位宽
parameter AXI_ADDR_WIDTH = `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_AXI_ADDR_WIDTH,  //!AXI地址位宽
parameter WR_FIFO_DEPTH	= `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_WR_FIFO_DEPTH, //!Write fifo depth
parameter RD_FIFO_DEPTH = `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_RD_FIFO_DEPTH, //!read fifo depth
parameter FB_NUM			= 	`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_FB_NUM,//2 buffer ,3 buffer
parameter MAX_VID_WIDTH		=	`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_MAX_VID_WIDTH ,//video width
parameter MAX_VID_HIGHT		=	`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_MAX_VID_HIGHT ,//wideo height
parameter START_ADDR				=	`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_START_ADDR,
parameter BURST_LEN       = `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_BURST_LEN,
parameter I_VID_WIDTH = `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_I_VID_WIDTH,
parameter AXI_STRB_WIDTH = `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_PARAMETER_AXI_STRB_WIDTH//!总共的字节数量，= AXI_DATA_WIDTH/8

) (

input 											axi_clk,
input                       wr_clk_rst_n,
input                       axi_clk_rst_n,
input                       rd_clk_rst_n,
input 											rd_start,
input											wr_start, // pulse signal 

// input		[AXI_ADDR_WIDTH-1:0]				start_wr_addr,
// input		[AXI_ADDR_WIDTH-1:0]				start_rd_addr,
input 		[`CFG_BITS_32-1:0] 								wr_busrt_len,
input 		[`CFG_BITS_32-1:0] 								rd_burst_len,
output		[`CFG_BITS_8-1:0] test_cnt ,

input                     wr_fifo_rst_p,
input											wr_fifo_wrclk,
input											wr_fifo_wren,
output											wr_fifo_wrfull,
input	 [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_1]					wr_fifo_wrdata,
input											rd_fifo_rdclk,
input                       rd_fifo_rst_p,
output											rd_fifo_rdvalid,
output	 [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_2] 					rd_fifo_rddata,
output wire										rd_fifo_rdempty,
input	 wire									rd_fifo_rden,

output 	[`CFG_BITS_6-1:0] 									awid,
output  [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_3] 					awaddr,
output  [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_4] 					awlen,
output  [`CFG_BITS_3-1:0] 									awsize,
output  [`CFG_BITS_2-1:0] 									awburst,
output  [`CFG_BITS_4-1:0] 									awcache,
output [`CFG_BITS_3-1:0]                    awprot,
output  										awlock,
output  										awvalid,
output  										awcobuf,
output  										awapcmd,
output  										awallstrb,
output  										awqos,
input 											awready,

output [`CFG_BITS_6-1:0] 									arid,
output  [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_5] 					araddr,
output  [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_6] 					arlen,
output  [`CFG_BITS_3-1:0] 									arsize,
output  [`CFG_BITS_2-1:0] 									arburst,
output  										arlock,
output  										arvalid,
output  										arapcmd,
output 											arqos,
input 											arready,
output  [`CFG_BITS_4-1:0] 									arcache,
output [`CFG_BITS_3-1:0]                    arprot,
output  [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_7] 					wdata,
output	[`CFG_BITS_32-1:0]									test_wdata,
output	[`CFG_BITS_32-1:0]									test_rdata,
output  [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_8] 					wstrb,
output  										wlast,
output  										wvalid,
input 											wready,

input [`CFG_BITS_6-1:0] 									rid,
input [`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_9] 						rdata,
input 											rlast,
input 											rvalid,
output  										rready,
input [`CFG_BITS_2-1:0] 									rresp,
output[`CFG_BITS_32-1:0]									wr_fifo_rd_data_test,
input [`CFG_BITS_6-1:0] 									bid,
input 											bvalid,
output  										bready,

output [`CFG_BITS_8-1:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;

//=============================================================
//reg define 
//=============================================================   


//=============================================================
//wire define 
//============================================================= 



wire		                        wr_sw_ack           ;
wire		                        wr_sw 		          ;
wire		                        rd_sw			          ;
wire		                        rd_sw_ack           ;
wire		[`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_10]		wr_start_addr       ;
wire		[`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_RANGE_11]    rd_start_addr       ;

//=============================================================  
//RTL                                                     
//=============================================================  



ddr_wr_buffer1 # (
    .AXI_DATA_WIDTH(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_DDR_WR_BUFFER_AXI_DATA_WIDTH),
    .AXI_ADDR_WIDTH(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_DDR_WR_BUFFER_AXI_ADDR_WIDTH),
    .WR_FIFO_DEPTH(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_DDR_WR_BUFFER_WR_FIFO_DEPTH),
    .BURST_LEN (`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_DDR_WR_BUFFER_BURST_LEN        )
  )

  u_ddr_wr_buffer (//_inst
    .axi_clk(axi_clk),
    .rst_n(axi_clk_rst_n),//(rst_n),
    .start(wr_start),
    .start_addr(wr_start_addr),//(0),//
    .total_burst_len(wr_busrt_len),
/*i*/.bank_sw_ack	(wr_sw_ack   	),
/*o*/.bank_sw 		  (wr_sw  		 	),
    .test_cnt(test_cnt),
    .wr_fifo_rst_p(wr_fifo_rst_p),
    .wr_fifo_wrclk(wr_fifo_wrclk),
    .wr_fifo_wren(wr_fifo_wren),
    .wr_fifo_wrfull(wr_fifo_wrfull),
    .wr_fifo_wrdata(wr_fifo_wrdata),
    .awid(awid),
    .awaddr(awaddr),
    .awlen(awlen),
    .awsize(awsize),
    .awburst(awburst),
    .awcache(awcache),
    .awlock(awlock),
    .awvalid(awvalid),
    .awcobuf(awcobuf),
    .awapcmd(awapcmd),
    .awallstrb(awallstrb),
    .awprot (awprot ),
    .awqos(awqos),
    .awready(awready),
    .wdata(wdata),
    .wstrb(wstrb),
    .wlast(wlast),
    .wvalid(wvalid),
    .wready(wready),
	  .bid	( bid			),
    .bvalid	( bvalid		),
    .bready	( bready		)
  );


assign test_wdata = wdata[32:0];
assign test_rdata = rdata[32:0];
//=============================================================================================
// FIFO RD_PROCESSING
//=============================================================================================
ddr_rd_buffer # (
    .AXI_DATA_WIDTH(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_DDR_RD_BUFFER_INST_AXI_DATA_WIDTH),
    .AXI_ADDR_WIDTH(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_DDR_RD_BUFFER_INST_AXI_ADDR_WIDTH),
    .RD_FIFO_DEPTH(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_DDR_RD_BUFFER_INST_RD_FIFO_DEPTH),
    .BURST_LEN (`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_DDR_RD_BUFFER_INST_BURST_LEN        )
  )
  ddr_rd_buffer_inst (
    .axi_clk(axi_clk),
    .axi_clk_rst_n(axi_clk_rst_n),
    .start(rd_start),
    .start_addr(rd_start_addr),//(0),//
    .burst_len(rd_burst_len),
    .rd_fifo_rdclk(rd_fifo_rdclk),
    .rd_fifo_rst_p (rd_fifo_rst_p),
    .rd_fifo_rdvalid(rd_fifo_rdvalid),
    .rd_fifo_rddata(rd_fifo_rddata),
    .rd_fifo_rdempty(rd_fifo_rdempty),
    .rd_fifo_rden(rd_fifo_rden),
/*i*/.bank_sw_ack	(rd_sw_ack   	),
/*o*/.bank_sw 		  (rd_sw  		 	),
    .arid(arid),
    .araddr(araddr),
    .arlen(arlen),
    .arsize(arsize),
    .arburst(arburst),
    .arlock(arlock),
    .arvalid(arvalid),
    .arapcmd(arapcmd),
    .arqos(arqos),
    .arready(arready),
    .arprot (arprot ),
    .arcache(arcache),
    .rid(rid),
    .rdata(rdata),
    .rlast(rlast),
    .rvalid(rvalid),
    .rready(rready),
    .rresp(rresp),
    .wr_fifo_rd_data_test(wr_fifo_rd_data_test)
  );
//===================================================================================== 
//
//===================================================================================== 
  


bank_switch #(
		.FB_NUM					( `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_BANK_SW_FB_NUM),
		.MAX_VID_WIDTH 	( `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_BANK_SW_MAX_VID_WIDTH),
		.MAX_VID_HIGHT 	( `CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_BANK_SW_MAX_VID_HIGHT),
		.START_ADDR			(	`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_BANK_SW_START_ADDR 	),
		.VID_DATA_WIDTH	(`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_BANK_SW_VID_DATA_WIDTH	),
		.AXI_DATA_WIDTH (`CFG_FRAME_BUFFER_V4_DDR_BUFFER_V_INST_U_BANK_SW_AXI_DATA_WIDTH )
)
  u_bank_sw
(
/*i*/.ddr_clk		(axi_clk	),
/*i*/.rst_n			(axi_clk_rst_n),
              	
/*i*/.wr_sw			(wr_sw),
/*i*/.rd_sw			(rd_sw),
                
/*o*/.wr_bank		(wr_bank	),
/*o*/.rd_bank		(rd_bank	),
/*o*/.rd_sw_ack	(rd_sw_ack),
/*o*/.wr_sw_ack (wr_sw_ack),
/*o*/.rd_start_addr(rd_start_addr),
/*o*/.wr_start_addr(wr_start_addr)
);



endmodule