`timescale 1ns/1ps
module axi_shared_ddr_2m_tb;
  logic clk=0,rst_n=0,allow_access=0; always #5 clk=~clk;
  wire video_read_urgent=1'b0;
  logic [7:0] cpu_awid=8'hA5,vid_awid=8'h5A,cpu_arid=8'hC3,vid_arid=8'h3C; logic [31:0] cpu_awaddr=32'h01000000,vid_awaddr=32'h10000000,cpu_araddr=32'h01000000,vid_araddr=32'h10000000; logic [7:0] cpu_awlen=3,vid_awlen=3,cpu_arlen=3,vid_arlen=3; logic [2:0] cpu_awsize=4,vid_awsize=4,cpu_arsize=4,vid_arsize=4; logic [1:0] cpu_awburst=1,vid_awburst=1,cpu_arburst=1,vid_arburst=1;
  logic cpu_awvalid=0,vid_awvalid=0,cpu_wlast=0,vid_wlast=0,cpu_wvalid=0,vid_wvalid=0,cpu_bready=1,vid_bready=1,cpu_arvalid=0,vid_arvalid=0,cpu_rready=1,vid_rready=1;
  logic [127:0] cpu_wdata=1,vid_wdata=2; logic [15:0] cpu_wstrb='1,vid_wstrb='1;
  logic [7:0] cpu_bid,vid_bid,cpu_rid,vid_rid; logic [1:0] cpu_bresp,vid_bresp,cpu_rresp,vid_rresp; logic [127:0] cpu_rdata,vid_rdata; logic cpu_awready,vid_awready,cpu_wready,vid_wready,cpu_bvalid,vid_bvalid,cpu_arready,vid_arready,cpu_rvalid,vid_rvalid,cpu_rlast,vid_rlast;
  logic [3:0] ddr_awid,ddr_bid,ddr_arid,ddr_rid; logic [31:0] ddr_awaddr,ddr_araddr; logic [7:0] ddr_awlen,ddr_arlen; logic [2:0] ddr_awsize,ddr_arsize; logic [1:0] ddr_awburst,ddr_arburst; logic [127:0] ddr_wdata,ddr_rdata; logic [15:0] ddr_wstrb; logic ddr_awvalid,ddr_awready,ddr_wlast,ddr_wvalid,ddr_wready,ddr_bvalid,ddr_bready,ddr_arvalid,ddr_arready,ddr_rvalid,ddr_rready,ddr_rlast; logic [1:0] ddr_bresp=0,ddr_rresp=0; logic [31:0] axi_error_count; logic inject_b_error=0,inject_r_error=0;
  axi_shared_ddr_2m dut(.*);
  integer aw_count=0,w_count=0,ar_count=0; logic wr_seen,rd_seen; integer wr_beats,rd_beats; logic [3:0] wr_owner,rd_owner;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin ddr_awready<=0;ddr_wready<=0;ddr_arready<=0;ddr_bvalid<=0;ddr_rvalid<=0;ddr_rlast<=0;wr_seen<=0;rd_seen<=0;wr_beats<=0;rd_beats<=0; end
    else begin
      ddr_awready<=~ddr_awready; ddr_wready<=~ddr_wready; ddr_arready<=1'b1;
      if(ddr_awvalid&&ddr_awready) begin aw_count<=aw_count+1; wr_seen<=1;wr_owner<=ddr_awid;wr_beats<=0; end
      if(ddr_wvalid&&ddr_wready) begin w_count<=w_count+1;wr_beats<=wr_beats+1; if(ddr_wlast) begin ddr_bvalid<=1;ddr_bid<=inject_b_error ? ~wr_owner : wr_owner;ddr_bresp<=inject_b_error ? 2'b10 : 2'b00; end end
      if(ddr_bvalid&&ddr_bready) begin ddr_bvalid<=0;wr_seen<=0;end
      if(ddr_arvalid&&ddr_arready) begin ar_count<=ar_count+1;rd_seen<=1;rd_owner<=ddr_arid;rd_beats<=0;end
      if(rd_seen&&!ddr_rvalid) begin ddr_rvalid<=1;ddr_rid<=inject_r_error ? ~rd_owner : rd_owner;ddr_rresp<=inject_r_error ? 2'b10 : 2'b00;ddr_rdata<=128'hCAFE_BABE;ddr_rlast=(rd_beats==3);end
      if(ddr_rvalid&&ddr_rready) begin ddr_rvalid<=0;rd_beats<=rd_beats+1;if(ddr_rlast) rd_seen<=0;end
    end
  end
  task automatic clear_valid; begin cpu_awvalid=0;vid_awvalid=0;cpu_wvalid=0;vid_wvalid=0;cpu_wlast=0;vid_wlast=0;cpu_arvalid=0;vid_arvalid=0; end endtask
  task automatic send_write(input bit video); integer n; begin
    if(video) vid_awvalid=1; else cpu_awvalid=1;
    do @(posedge clk); while(!(video?vid_awready:cpu_awready));
    if(video) vid_awvalid=0; else cpu_awvalid=0;
    for(n=0;n<4;n=n+1) begin
      if(video) begin vid_wvalid=1;vid_wlast=(n==3);end else begin cpu_wvalid=1;cpu_wlast=(n==3);end
      do @(posedge clk); while(!(video?vid_wready:cpu_wready));
      if(video) begin vid_wvalid=0;vid_wlast=0;end else begin cpu_wvalid=0;cpu_wlast=0;end
    end
    while(video?vid_bvalid:cpu_bvalid) @(posedge clk);
  end endtask
  task automatic send_read(input bit video); begin
    if(video) vid_arvalid=1; else cpu_arvalid=1;
    do @(posedge clk); while(!(video?vid_arready:cpu_arready));
    if(video) vid_arvalid=0; else cpu_arvalid=0;
    repeat(6) @(posedge clk);
  end endtask
  initial begin
    clear_valid; repeat(3) @(posedge clk);rst_n=1;allow_access=1;
    // Simultaneous addresses are held until the bridge actually accepts one.
    cpu_awvalid=1;vid_awvalid=1; @(posedge clk); while(!ddr_awvalid||!ddr_awready) @(posedge clk);
    if(ddr_awid[3]!==1'b1) $fatal(1,"video address was not selected first");
    vid_awvalid=0;cpu_awvalid=0;
    begin integer n; for(n=0;n<4;n=n+1) begin vid_wvalid=1;vid_wlast=(n==3); do @(posedge clk); while(!vid_wready); vid_wvalid=0;vid_wlast=0; end end
    while(vid_bvalid) @(posedge clk);
    send_write(0);
    send_read(1); send_read(0);
    if(aw_count!=2||ar_count!=2||w_count!=8||axi_error_count!=0) $fatal(1,"counts aw=%0d ar=%0d w=%0d err=%0d",aw_count,ar_count,w_count,axi_error_count);
    inject_b_error=1; inject_r_error=1;
    fork send_write(0); send_read(0); join
    repeat(2) @(posedge clk);
    if(axi_error_count<2) $fatal(1,"B/R errors were not both counted: err=%0d",axi_error_count);
    $display("PASS AXI shared DDR: stable backpressure, 4-beat bursts, fairness, ID/B/R ownership and simultaneous error accounting");$finish;
  end
endmodule
