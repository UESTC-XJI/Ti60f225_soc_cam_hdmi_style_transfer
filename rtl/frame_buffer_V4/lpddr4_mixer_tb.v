`include "../defines.v"
`timescale 1 ns / 1 ns

module lpddr4_mixer_tb;

 /////////////   
parameter   AXI_DATA_WIDTH    = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_PARAMETER_AXI_DATA_WIDTH               ; //AXI Data Width(Bit)
  
parameter   DDR_WRITE_FIRST   = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_PARAMETER_DDR_WRITE_FIRST              ; //1:Write First ; 0: Read First
parameter   AXI_ID_WIDTH    =   `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_PARAMETER_AXI_ID_WIDTH         ;
localparam   AXI0_WR_ID        = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_AXI0_WR_ID           ; //AXI Write ID
localparam   AXI0_RD_ID        = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_AXI0_RD_ID           ; //AXI Read ID
localparam   AXI_ADDR_WIDTH 	= `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_AXI_ADDR_WIDTH;//Address Width

localparam H_FP   	      = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_H_FP 	;//
localparam H_SYNC 	 		  = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_H_SYNC 	;//
localparam H_VALID 	 	  	= `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_H_VALID  ;//
localparam H_BP  	        = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_H_BP   ;//
localparam V_FP   	      = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_V_FP 	;//
localparam V_SYNC 	 	    = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_V_SYNC 	;//
localparam V_VALID 	 	  	= `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_V_VALID  ;//
localparam V_BP  	        = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_V_BP 	;//

localparam WR_FIFO_DEPTH  = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_WR_FIFO_DEPTH;
localparam RD_FIFO_DEPTH  = `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_LOCALPARAM_RD_FIFO_DEPTH;

wire  axi0_ARQOS;         
wire  axi0_AWQOS;         
wire  [`CFG_BITS_6-1:0] axi0_AWID;
wire  [`CFG_BITS_33-1:0] axi0_AWADDR;
wire  [`CFG_BITS_8-1:0] axi0_AWLEN;
wire  [`CFG_BITS_3-1:0] axi0_AWSIZE;
wire  [`CFG_BITS_2-1:0] axi0_AWBURST;
wire  axi0_AWVALID;       
wire  [`CFG_BITS_4-1:0] axi0_AWCACHE;
wire  axi0_AWCOBUF;       
wire  axi0_AWLOCK;        
wire  axi0_AWAPCMD;       
wire  axi0_AWALLSTRB;     
wire  [`CFG_BITS_6-1:0] axi0_ARID;
wire  [`CFG_BITS_33-1:0] axi0_ARADDR;
wire  [`CFG_BITS_8-1:0] axi0_ARLEN;
wire  [`CFG_BITS_3-1:0] axi0_ARSIZE;
wire  [`CFG_BITS_2-1:0] axi0_ARBURST;
wire  axi0_ARVALID;       
wire  axi0_ARLOCK;        
wire  axi0_ARAPCMD;       
wire  axi0_WLAST;         
wire  axi0_WVALID;        
wire  [`CFG_BITS_512-1:0] axi0_WDATA;
wire  [`CFG_BITS_64-1:0] axi0_WSTRB;
wire  axi0_BREADY;        
wire  axi0_RREADY;        
wire axi0_AWREADY;        
wire axi0_ARREADY;        
wire axi0_WREADY;         
wire [`CFG_BITS_6-1:0] axi0_BID;
wire [`CFG_BITS_2-1:0] axi0_BRESP;
wire axi0_BVALID;         
wire [`CFG_BITS_6-1:0] axi0_RID;
wire axi0_RLAST;          
wire axi0_RVALID;         
wire [`CFG_BITS_512-1:0] axi0_RDATA;
wire [`CFG_BITS_2-1:0] axi0_RRESP;

  //Ports
  reg  clk= 0;
  reg  rst_n = 0;
  wire [`CFG_BITS_8-1:0] i_rdata;
  wire [`CFG_BITS_8-1:0] i_gdata;
  wire [`CFG_BITS_8-1:0] i_bdata;

  wire  hs;
  wire  vs;
  wire  de;

  wire [`CFG_BITS_8-1:0] rgb_r;
  wire [`CFG_BITS_8-1:0] rgb_g;
  wire [`CFG_BITS_8-1:0] rgb_b;

  
  wire [`CFG_BITS_8-1:0] 	ch0_r;
  wire [`CFG_BITS_8-1:0]    ch0_g;
  wire [`CFG_BITS_8-1:0]    ch0_b;
  wire ch0_vs;
  wire ch0_hs;
  wire ch0_de;

wire                    fb_m_axis_tuser ;
wire                    fb_m_axis_tvalid;
wire                    fb_m_axis_tready;
wire                    fb_m_axis_tlast ;
wire  [`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_RANGE_1] fb_m_axis_tdata ;
wire            fifo_rd_period;
reg rd_start = 'd0;
  always #10 clk = !clk;
  assign axi0_ACLK = clk;
  initial begin
    #0  rst_n = 0;
        rd_start = 0;
    # 100 rst_n = 1;

    #1000
      rd_start = 1;
    #100
      rd_start = 0;
  end

color_bar_rgb # (
  .HS_POLORY(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_HS_POLORY),
  .VS_POLORY(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_VS_POLORY),
  .NUM_OF_PIXERS_PER_CLOCK(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_NUM_OF_PIXERS_PER_CLOCK),
  .H_FRONT_PORCH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_H_FRONT_PORCH),
  .H_SYNC(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_H_SYNC),
  .H_VALID(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_H_VALID),
  .H_BACK_PORCH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_H_BACK_PORCH),
  .V_FRONT_PORCH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_V_FRONT_PORCH),
  .V_SYNC(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_V_SYNC),
  .V_VALID(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_V_VALID),
  .V_BACK_PORCH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_V_BACK_PORCH),
  .TEST_MODE(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_COLOR_BAR_RGB_INST_TEST_MODE)
)
color_bar_rgb_inst (
  .clk(clk),
  .rst_n(rst_n),
  .i_rdata(i_rdata),
  .i_gdata(i_gdata),
  .i_bdata(i_bdata),
  .h_cnt(h_cnt),
  .v_cnt(v_cnt),
  .hs(hs),
  .vs(vs),
  .de(de),
  .w_h_state(w_h_state),
  .w_v_state(w_v_state),
  .rgb_r(rgb_r),
  .rgb_g(rgb_g),
  .rgb_b(rgb_b)
);



frame_buffer #(
.I_VID_WIDTH (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_I_VID_WIDTH),
.O_VID_WIDTH (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_O_VID_WIDTH),
.START_ADDR     (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_START_ADDR        ),
.FB_NUM			    (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_FB_NUM),
.MAX_VID_WIDTH  (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_MAX_VID_WIDTH),
.MAX_VID_HIGHT	(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_MAX_VID_HIGHT)	,
.BURST_LEN  	(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_BURST_LEN),
.AXI_DATA_WIDTH ( `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH ( `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	( `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_WR_FIFO_DEPTH		),
.RD_FIFO_DEPTH 	( `CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_RD_FIFO_DEPTH 	),
.O_FRAME_WIDTH (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_O_FRAME_WIDTH),
.O_FRAME_HEIGHT(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_CHECKER0_O_FRAME_HEIGHT)
)checker0(
    .axi_clk(axi0_ACLK),
    .rst_n(rst_n),

/*i*/.i_clk			(clk   ),// (CLK_148P5M),//	(VI_CLK3_PLL		),    //(CLK_148P5M   ),//    
/*i*/.i_vs			(vs),//(rx_vsync 			),// (sync_vs2  ),//(e3_v							),  //(sw0_vs 			),//
/*i*/.i_de			(de),//(rx_de 				),// (sync_de2  ),//(e3_de						),    //(sw0_de 			),//
/*i*/.vin 			({rgb_r,rgb_g,rgb_b}),//({y_422,c_422}),//
                  
/*i*/.o_clk			  (clk	 ),//(clk_o),//
/*i*/.fifo_rd_period(fifo_rd_period),//(fifo_rd_period  ),
/*o*/.m_axis_tuser  (fb_m_axis_tuser ),
/*o*/.m_axis_tvalid (fb_m_axis_tvalid),
/*i*/.m_axis_tready (fb_m_axis_tready),
/*o*/.m_axis_tlast  (fb_m_axis_tlast ),
/*o*/.m_axis_tdata  (fb_m_axis_tdata ),
  
    .awid(axi0_AWID),
    .awaddr(axi0_AWADDR),
    .awlen(axi0_AWLEN),
    .awsize(axi0_AWSIZE),
    .awburst(axi0_AWBURST),
    .awcache(axi0_AWCACHE),
    .awlock(axi0_AWLOCK),
    .awvalid(axi0_AWVALID),
    .awcobuf(axi0_AWCOBUF),
    .awapcmd(axi0_AWAPCMD),
    .awallstrb(axi0_AWALLSTRB),
    .awready(axi0_AWREADY),
    .awqos(axi0_AWQOS),
    .arid(axi0_ARID),
    .araddr(axi0_ARADDR),
    .arlen(axi0_ARLEN),
    .arsize(axi0_ARSIZE),
    .arburst(axi0_ARBURST),
    .arlock(axi0_ARLOCK),
    .arvalid(axi0_ARVALID),
    .arapcmd(axi0_ARAPCMD),
    .arready(axi0_ARREADY),
    .arqos(axi0_ARQOS),
    .wdata(axi0_WDATA),
    .wstrb(axi0_WSTRB),
    .wlast(axi0_WLAST),
    .wvalid(axi0_WVALID),
    .wready(axi0_WREADY),
    .rid(axi0_RID),
    .rdata(axi0_RDATA),
    .rlast(axi0_RLAST),
    .rvalid(axi0_RVALID),
    .rready(axi0_RREADY),
    .rresp(axi0_RRESP),
    .bid(axi0_BID),
    .bvalid(axi0_BVALID),
    .bready(axi0_BREADY)
);



  
vout_display_pro  #(
    .BLUE_Y(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_BLUE_Y),
    .BLUE_CB(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_BLUE_CB),
    .BLUE_CR(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_BLUE_CR),
    .SYMBOL_WIDTH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_SYMBOL_WIDTH),
    .SYMBOL_NUM(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_SYMBOL_NUM),
    .PAR_PIXEL_NUM(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_PAR_PIXEL_NUM),
    .MAX_WIDTH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_MAX_WIDTH),
    .MAX_HEIGTH(`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_VOUT_DISPLAY_PRO_INST_MAX_HEIGTH)
)vout_display_pro_inst (
    .rst_n(rst_n),
    .dp_clk(clk),
    .priority_sel(priority_sel),

    .H_FRONT_PORCH(H_FP),
    .H_SYNC(H_SYNC),
    .H_VALID(500),
    .H_BACK_PORCH(H_BP),
    .V_FRONT_PORCH(V_FP),
    .V_SYNC(V_SYNC),
    .V_VALID(500),
    .V_BACK_PORCH(V_BP),

    .layer0_top(layer0_x),
    .layer0_left(layer0_y),
    .layer0_width(960),
    .layer0_height(1080),
    .layer0_alpha(255),
    .layer0_sync(),
    .layer0_rdreq(layer0_rdreq),
    .layer0_ycbcr(layer0_ycbcr),
    
    .layer1_top(0),
    .layer1_left(960),
    .layer1_width(960),
    .layer1_height(1080),
    .layer1_alpha(255),
    .layer1_sync(layer1_sync),
    .layer1_rdreq(layer1_rdreq),
    .layer1_ycbcr(layer1_ycbcr),

    .layer2_top(1080),
    .layer2_left(0),
    .layer2_width(960),
    .layer2_height(1080),
    .layer2_alpha(255),
    .layer2_sync(layer2_sync),
    .layer2_rdreq(layer2_rdreq),
    .layer2_ycbcr(layer2_ycbcr),

    .layer3_top(1080),
    .layer3_left(960),
    .layer3_width(960),
    .layer3_height(1080),
    .layer3_alpha(255),
    .layer3_sync(layer3_sync),
    .layer3_rdreq(layer3_rdreq),
    .layer3_ycbcr(layer3_ycbcr),


    .x_out_cnt(x_out_cnt),
    .y_out_cnt(y_out_cnt),
    .frame_complete(frame_complete),
    .frame_sync(frame_sync),
    .hs(ch0_hs),
    .vs(ch0_vs),
    .de(ch0_de),
    .rgb({ch0_r,ch0_g,ch0_b })
  );



vid_check  u_vid_check(
	/*i*/.clk		(clk ),
	/*i*/.rst_n		(rst_n),
	/*i*/.i_hs		(ch0_hs),
	/*i*/.i_vs		(ch0_vs),
	/*i*/.i_de		(ch0_de),
	/*i*/.vin 		({ch0_r,ch0_g,ch0_b }),
	/*o*/.check_fail()
	
	);

axi_ram #
(
    .DATA_WIDTH            (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_U_AXI_RAM_DATA_WIDTH       ),
    .ADDR_WIDTH            (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_U_AXI_RAM_ADDR_WIDTH       ),
    .ID_WIDTH              (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_U_AXI_RAM_ID_WIDTH            ),
    .PIPELINE_OUTPUT       (`CFG_FRAME_BUFFER_V4_LPDDR4_MIXER_TB_V_INST_U_AXI_RAM_PIPELINE_OUTPUT            )
)                                        
u_axi_ram
(
    .clk                   (axi0_ACLK     ),
    .rst                   (!io_asyncResetn),
    .s_axi_awid            (0     ),
    .s_axi_awaddr          (axi0_AWADDR   ), 
    .s_axi_awlen           (axi0_AWLEN   ), 
    .s_axi_awsize          (axi0_AWSIZE   ), 
    .s_axi_awburst         (axi0_AWBURST  ), 
    .s_axi_awlock          (axi0_AWLOCK   ), 
    .s_axi_awcache         (axi0_AWCACHE  ), 
    .s_axi_awprot          (axi0_AWPROT   ), 
    .s_axi_awvalid         (axi0_AWVALID  ), 
    .s_axi_awready         (axi0_AWREADY  ), 
    .s_axi_wdata           (axi0_WDATA    ), 
    .s_axi_wstrb           (axi0_WSTRB    ), 
    .s_axi_wlast           (axi0_WLAST    ), 
    .s_axi_wvalid          (axi0_WVALID   ), 
    .s_axi_wready          (axi0_WREADY   ), 
    .s_axi_bid             (axi0_BID      ),
    .s_axi_bresp           (axi0_BRESP    ), 
    .s_axi_bvalid          (axi0_BVALID   ), 
    .s_axi_bready          (axi0_BREADY   ),
    .s_axi_arid            (0     ),
    .s_axi_araddr          (axi0_ARADDR   ), 
    .s_axi_arlen           (axi0_ARLEN    ), 
    .s_axi_arsize          (axi0_ARSIZE   ), 
    .s_axi_arburst         (axi0_ARBURST  ), 
    .s_axi_arlock          (axi0_ARLOCK   ), 
    .s_axi_arcache         (axi0_ARCACHE  ), 
    .s_axi_arprot          (axi0_ARPROT   ), 
    .s_axi_arvalid         (axi0_ARVALID  ), 
    .s_axi_arready         (axi0_ARREADY  ),
    .s_axi_rid             (axi0_RID      ),
    .s_axi_rdata           (axi0_RDATA    ), 
    .s_axi_rresp           (axi0_RRESP    ), 
    .s_axi_rlast           (axi0_RLAST    ), 
    .s_axi_rvalid          (axi0_RVALID   ), 
    .s_axi_rready          (axi0_RREADY   )
);






endmodule

