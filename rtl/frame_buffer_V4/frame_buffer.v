`include "../defines.v"


`timescale 1ps/1ps
module frame_buffer #(
parameter I_VID_WIDTH       = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_I_VID_WIDTH,
parameter O_VID_WIDTH       = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_O_VID_WIDTH,
parameter AXI_DATA_WIDTH	= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_AXI_DATA_WIDTH,
parameter AXI_ADDR_WIDTH 	= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_AXI_ADDR_WIDTH,
parameter	WR_FIFO_DEPTH	= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_WR_FIFO_DEPTH,
parameter	RD_FIFO_DEPTH 	= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_RD_FIFO_DEPTH,
parameter START_ADDR		= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_START_ADDR,
parameter BURST_LEN         = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_BURST_LEN,
parameter FB_NUM			= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_FB_NUM,//2 buffer ,3 buffer
parameter MAX_VID_WIDTH		= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_MAX_VID_WIDTH ,//video width
parameter MAX_VID_HIGHT		= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_MAX_VID_HIGHT ,//wideo height
parameter O_FRAME_WIDTH     = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_O_FRAME_WIDTH,
parameter O_FRAME_HEIGHT    = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_O_FRAME_HEIGHT,
parameter AXI_STRB_WIDTH 	= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_PARAMETER_AXI_STRB_WIDTH
) (

input 												axi_clk,
input 												rst_n,

input	wire								i_clk	,
input	wire								i_vs, //active hgih
input	wire								i_de, //active high
input	wire	[`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_1] 			vin ,

input	wire							o_clk	,
input   wire                   fifo_rd_period,//!!
output wire                    m_axis_tuser,
output wire                    m_axis_tvalid ,
input  wire                    m_axis_tready,
output wire                    m_axis_tlast,
output wire  [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_2] m_axis_tdata,



output 	[`CFG_BITS_6-1:0] 								awid,
output  [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_3] 	            awaddr,
output  [`CFG_BITS_8-1:0] 								awlen,
output  [`CFG_BITS_3-1:0] 								awsize,
output  [`CFG_BITS_2-1:0] 								awburst,
output  [`CFG_BITS_4-1:0] 								awcache,
output [`CFG_BITS_3-1:0]                                awprot,
output  									    awlock,
output  									    awvalid,
output  									    awcobuf,
output  									    awapcmd,
output  									    awallstrb,
output  									    awqos,
input 										    awready,

output [`CFG_BITS_6-1:0] 									arid,
output  [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_4] 	                araddr,
output  [`CFG_BITS_8-1:0] 								    arlen,
output  [`CFG_BITS_3-1:0] 								    arsize,
output  [`CFG_BITS_2-1:0] 								    arburst,
output  									    arlock,
output  									    arvalid,
output  									    arapcmd,
output 										    arqos,
input 										    arready,
output  [`CFG_BITS_4-1:0] 									arcache,
output [`CFG_BITS_3-1:0]                    arprot,

output  [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_5] 	wdata,
output  [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_6] 	wstrb,
output  											wlast,
output  											wvalid,
input 												wready,

input [`CFG_BITS_6-1:0] 									    rid,
input [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_7] 		rdata,
input 												rlast,
input 												rvalid,
output  											rready,
input [`CFG_BITS_2-1:0] 									    rresp,

input [`CFG_BITS_6-1:0] 									    bid,
input 												bvalid,
output  											bready,
output			[`CFG_BITS_32-1:0]								test_rd_fifo_rddata,
output	[`CFG_BITS_32-1:0]								        test_wdata,
output	[`CFG_BITS_32-1:0]								        test_rdata,
output [`CFG_BITS_8-1:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;
//=============================================================
//parameter define                                                  
//============================================================= 
wire [`CFG_BITS_32-1:0]               ddr_frame_len ;
wire [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_8] wr_fifo_wrdata;

wire                      rd_fifo_rdvalid	;
wire [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_9] rd_fifo_rddata	 ;
wire                      rd_fifo_rdempty	;
wire                      rd_fifo_rden     ;

wire		wr_sw_ack ;
wire		wr_sw 		;
wire		rd_sw			;
wire		rd_sw_ack ;

wire	[`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_10] o_fifo_rd_data;
wire					  o_fifo_rd_en;
wire  					  o_fifo_rd_empty;
//=============================================================  
//RTL                                                     
//=============================================================  
wire wr_clk_rst_n;
wire axi_clk_rst_n;
wire rd_clk_rst_n;
rst_n_piple #(                       
    .DLY ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_I_CLK_RST_PIP_DLY )
)	u_i_clk_rst_pip(                                          
/*i*/.clk			(i_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (wr_clk_rst_n)            
);

  rst_n_piple #(                       
    .DLY ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_AXI_RST_PIP_DLY )
)	u_axi_rst_pip(                                          
/*i*/.clk			(axi_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (axi_clk_rst_n)            
);

  rst_n_piple #(                       
    .DLY ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_O_CLK_RST_PIP_DLY )
)	u_o_clk_rst_pip(                                          
/*i*/.clk			(o_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (rd_clk_rst_n)            
);


wire                      wr_fifo_wren;
wire                      frame_start;
wire                      frame_stable;
// Capture can run faster than AXI; a one-cycle frame pulse may be missed.
reg write_frame_toggle;
(* async_reg = "true" *) reg write_frame_meta,write_frame_sync;
reg write_frame_seen;
always @(posedge i_clk or negedge wr_clk_rst_n)
  if(!wr_clk_rst_n) write_frame_toggle<=0;
  else if(frame_start) write_frame_toggle<=!write_frame_toggle;
always @(posedge axi_clk or negedge axi_clk_rst_n) begin
  if(!axi_clk_rst_n) begin write_frame_meta<=0;write_frame_sync<=0;write_frame_seen<=0;end
  else begin write_frame_meta<=write_frame_toggle;write_frame_sync<=write_frame_meta;write_frame_seen<=write_frame_sync;end
end
wire axi_write_frame_start=write_frame_sync ^ write_frame_seen;

vid_rx_align_v1 #(
	.I_VID_WIDTH   (`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_VID_RX_ALIGN_I_VID_WIDTH		),
	.AXI_DDR_WIDTH (`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_VID_RX_ALIGN_AXI_DDR_WIDTH )
)u_vid_rx_align(
/*i*/.clk			    (i_clk			),  
/*i*/.rst_n			  (wr_clk_rst_n	),
/*i*/.i_vs			  (i_vs			), //active hgih
/*i*/.i_de			  (i_de			), //active high
/*i*/.vin			    (vin			),
/*o*/.fifo_wr_en	  (wr_fifo_wren		),
/*o*/.fifo_wr_data	(wr_fifo_wrdata	),
/*o*/.frame_start	  (frame_start	),
/*O*/.fifo_rst_p		  (fifo_rst		  ),
/*O*/.frame_stable  (frame_stable ),
/*O*/.ddr_frame_len (ddr_frame_len)
);

reg fifo_rd_period_r0 = 'd0;
reg fifo_rd_period_r1 = 'd0;
reg fifo_rd_period_r2 = 'd0;
always @( posedge axi_clk)
begin
  fifo_rd_period_r0 <= fifo_rd_period;
  fifo_rd_period_r1 <= fifo_rd_period_r0;
  fifo_rd_period_r2 <= fifo_rd_period_r1; 
end
wire pos_rd_period = {fifo_rd_period_r2,fifo_rd_period_r1} == 2'b01;
ddr_buffer #(
.AXI_DATA_WIDTH ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_WR_FIFO_DEPTH		),
.RD_FIFO_DEPTH 	( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_RD_FIFO_DEPTH 	),
.START_ADDR		( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_START_ADDR        ),
.FB_NUM         ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_FB_NUM            ),
.MAX_VID_WIDTH  ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_MAX_VID_WIDTH     ),
.MAX_VID_HIGHT  ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_MAX_VID_HIGHT     ),
.I_VID_WIDTH    ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_I_VID_WIDTH       ),
.BURST_LEN      (`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_DDR_BUFFER_BURST_LEN          )
)u_ddr_buffer(
    .axi_clk		    (axi_clk	),
    .wr_clk_rst_n (wr_clk_rst_n),
    .axi_clk_rst_n(axi_clk_rst_n),
    .rd_clk_rst_n (rd_clk_rst_n),
    

/*i*/.wr_start	      (axi_write_frame_start),
/*i*/.rd_start	      (fifo_rd_period),// && frame_stable
    .wr_busrt_len     (ddr_frame_len ),//ddr address scope for one frame
    .rd_burst_len     (ddr_frame_len ),//ddr address scope for one frame

	   .test_cnt		(test_cnt         ),
/*i*/.wr_fifo_wrclk		(i_clk			  ),
/*i*/.wr_fifo_rst_p     ( fifo_rst        ),
/*i*/.wr_fifo_wren		(wr_fifo_wren	  ),
/*o*/.wr_fifo_wrfull	(wr_fifo_wrfull	  ),
/*i*/.wr_fifo_wrdata	(wr_fifo_wrdata	  ), 

/*i*/.rd_fifo_rdclk		(o_clk			  ),
/*i*/.rd_fifo_rst_p     (pos_rd_period    ),
/*o*/.rd_fifo_rdvalid	(rd_fifo_rdvalid  ),
/*o*/.rd_fifo_rddata	(rd_fifo_rddata	  ),
/*o*/.rd_fifo_rdempty	(rd_fifo_rdempty  ),
/*i*/.rd_fifo_rden		(rd_fifo_rden     ),

/*o*/.test_wdata    (test_wdata     ),
/*o*/.test_rdata    (test_rdata     ),    
    .awid			( awid			),
    .awaddr			( awaddr		),
    .awlen			( awlen			),
    .awsize			( awsize		),
    .awburst		( awburst		),
    .awvalid		( awvalid		),
    .awready		( awready		),
    .awqos			( awqos			),
    .awcache        ( awcache       ),
    .awprot         ( awprot        ),

    .arid			( arid			),
    .araddr			( araddr		),
    .arlen			( arlen			),
    .arsize			( arsize		),
    .arburst		( arburst		),
    .arlock			( arlock		),
    .arvalid		( arvalid		),
    .arapcmd		( arapcmd		),
    .arready		( arready		),
    .arqos			( arqos			),
    .arprot         (arprot         ),
    .arcache        (arcache        ),
    //
    .wdata			( wdata			),
    .wstrb			( wstrb			),
    .wlast			( wlast			),
    .wvalid			( wvalid		),
    .wready			( wready		),
    //
    .rid			( rid			),
    .rdata			( rdata			),
    .rlast			( rlast			),
    .rvalid			( rvalid		),
    .rready			( rready		),
    .rresp			( rresp			),
    .bid			( bid			),
    .bvalid			( bvalid		),
    .bready			( bready		));

//===================================================================================
//
//===================================================================================
			localparam FIFO_DIPTH 	= `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_LOCALPARAM_FIFO_DIPTH;
			localparam FIFO_ALMOST_FULL = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_LOCALPARAM_FIFO_ALMOST_FULL;

wire tx_valid;
wire [`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_11] tx_vin;
reg tx_almost_full = 'd0;




        vid_par2ser #(
        .O_VID_WIDTH (`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_PAR2SER_128_16_O_VID_WIDTH),
        .I_VID_WIDTH	(`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_PAR2SER_128_16_I_VID_WIDTH)

    )u_par2ser_128_16(
    /*i*/.clk               (o_clk            ),
    /*i*/.rst_n             (rd_clk_rst_n     ),
    /*i*/.frame_period      (fifo_rd_period   ),

    /*i*/.rd_fifo_rdvalid   (rd_fifo_rdvalid  ),
    /*i*/.rd_fifo_rddata    (rd_fifo_rddata   ),
    /*i*/.rd_fifo_rdempty   (rd_fifo_rdempty  ),
    /*o*/.rd_fifo_rden      ( rd_fifo_rden    ),
    /*o*/.tx_fifo_valid     ( tx_valid        ),
    /*i*/.wr_fifo_full      (tx_almost_full   ),
    /*i*/.tx_fifo_wrdata    (tx_vin           )
);




localparam FIFO_ADDR_WIDTH   = `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_LOCALPARAM_FIFO_ADDR_WIDTH ;
wire	[`CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_RANGE_12] 					wrusedw;

always @( posedge o_clk )
	begin
			if( wrusedw >= FIFO_ALMOST_FULL ) begin
					tx_almost_full <= 1'b1;
			end else begin
					tx_almost_full <= 1'b0;
			end
	end
reg [`CFG_BITS_2-1:0] fifo_rd_period_r = 'd0;

always @( posedge o_clk )
begin
  fifo_rd_period_r <= {fifo_rd_period_r[0],fifo_rd_period};
end
wire w_pos_rd_period = fifo_rd_period_r == 2'b01;
	
DC_FIFO
# (
    .FIFO_MODE  ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_RD_FIFO_FIFO_MODE        	), //"Normal"; //"ShowAhead"
    .DATA_WIDTH ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_RD_FIFO_DATA_WIDTH        ),
    .FIFO_DEPTH ( `CFG_FRAME_BUFFER_V4_FRAME_BUFFER_V_INST_U_RD_FIFO_FIFO_DEPTH        )//,

  ) u_rd_fifo(   
  //System Signal
  /*i*/.Reset   (w_pos_rd_period), //System Reset
  //Write Signal                             
  /*i*/.WrClk   (o_clk), //(I)Wirte Clock
  /*i*/.WrEn    (tx_valid), //(I)Write Enable
  /*o*/.WrDNum  (wrusedw), //(O)Write Data Number In Fifo
  /*o*/.WrFull  (), //(I)Write Full 
  /*i*/.WrData  (tx_vin), //(I)Write Data
  //Read Signal                            
  /*i*/.RdClk   (o_clk), //(I)Read Clock
  /*i*/.RdEn    (o_fifo_rd_en), //(I)Read Enable
  /*o*/.RdDNum  (), //(O)Radd Data Number In Fifo
  /*o*/.RdEmpty (o_fifo_rd_empty), //(O)Read FifoEmpty
  /*o*/.RdData  (o_fifo_rd_data)  //(O)Read Data
);            

reg [`CFG_BITS_13-1:0] rd_h_cnt = 'd0;
reg [`CFG_BITS_13-1:0] rd_v_cnt = 'd0;
reg tvalid_keep = 1'b0;
always @( posedge o_clk or negedge rd_clk_rst_n )
begin
    if( !rd_clk_rst_n )
        rd_h_cnt <= 'd0;
    else if( m_axis_tready & m_axis_tvalid ) begin
        if( rd_h_cnt >= O_FRAME_WIDTH-1)
            rd_h_cnt <= 'd0;
        else 
            rd_h_cnt <= rd_h_cnt + 1'b1;
    end
end
always @( posedge o_clk or negedge rd_clk_rst_n )
begin
    if( !rd_clk_rst_n )
        rd_v_cnt <= 'd0;
    else if( m_axis_tready && m_axis_tvalid  && rd_h_cnt >= O_FRAME_WIDTH-1) begin
        if( rd_v_cnt >= O_FRAME_HEIGHT-1)
            rd_v_cnt <= 'd0;
        else 
            rd_v_cnt <= rd_v_cnt + 1'b1;
    end
end
reg axis_tvalid = 'd0;
always @( posedge o_clk or negedge rd_clk_rst_n )
begin
    if( !rd_clk_rst_n )
        axis_tvalid <= 1'b0;
    else if(m_axis_tlast && rd_v_cnt >= O_FRAME_HEIGHT-1)
        axis_tvalid <= 1'b0;
    else
        axis_tvalid <= o_fifo_rd_en;

end
always @( posedge o_clk or negedge rd_clk_rst_n  )
begin
    if( !rd_clk_rst_n )
        tvalid_keep <= 1'b0;
    else if( m_axis_tlast && rd_v_cnt >= O_FRAME_HEIGHT-1)
        tvalid_keep <= 1'b0;
    else if( m_axis_tvalid & ~m_axis_tready )
        tvalid_keep <= 1'b1;
    else 
        tvalid_keep <= 1'b0;
end
assign m_axis_tvalid = axis_tvalid | tvalid_keep;
assign m_axis_tdata = o_fifo_rd_data;
assign m_axis_tuser = ((rd_v_cnt == 'd0) && (rd_h_cnt == 'd0) && m_axis_tvalid && m_axis_tready);
assign m_axis_tlast = (rd_h_cnt == O_FRAME_WIDTH-1) && m_axis_tvalid & m_axis_tready;
assign o_fifo_rd_en = m_axis_tready & (~o_fifo_rd_empty) ;


endmodule
