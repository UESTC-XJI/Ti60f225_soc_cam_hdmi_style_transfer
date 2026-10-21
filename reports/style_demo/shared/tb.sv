`timescale 1ns/1ps
module style_shared_tb;
reg clk=0,rst_n=0;always #5 clk=~clk;
wire [31:0] errors_inner,errors_outer;
wire [7:0] awid[0:4];
reg [7:0] m_awid[0:2];
assign awid[0]=m_awid[0];
assign awid[1]=m_awid[1];
assign awid[2]=m_awid[2];
wire [31:0] awaddr[0:4];
reg [31:0] m_awaddr[0:2];
assign awaddr[0]=m_awaddr[0];
assign awaddr[1]=m_awaddr[1];
assign awaddr[2]=m_awaddr[2];
wire [7:0] awlen[0:4];
reg [7:0] m_awlen[0:2];
assign awlen[0]=m_awlen[0];
assign awlen[1]=m_awlen[1];
assign awlen[2]=m_awlen[2];
wire [2:0] awsize[0:4];
reg [2:0] m_awsize[0:2];
assign awsize[0]=m_awsize[0];
assign awsize[1]=m_awsize[1];
assign awsize[2]=m_awsize[2];
wire [1:0] awburst[0:4];
reg [1:0] m_awburst[0:2];
assign awburst[0]=m_awburst[0];
assign awburst[1]=m_awburst[1];
assign awburst[2]=m_awburst[2];
wire [0:0] awvalid[0:4];
reg [0:0] m_awvalid[0:2];
assign awvalid[0]=m_awvalid[0];
assign awvalid[1]=m_awvalid[1];
assign awvalid[2]=m_awvalid[2];
wire [0:0] awready[0:4];
wire [127:0] wdata[0:4];
reg [127:0] m_wdata[0:2];
assign wdata[0]=m_wdata[0];
assign wdata[1]=m_wdata[1];
assign wdata[2]=m_wdata[2];
wire [15:0] wstrb[0:4];
reg [15:0] m_wstrb[0:2];
assign wstrb[0]=m_wstrb[0];
assign wstrb[1]=m_wstrb[1];
assign wstrb[2]=m_wstrb[2];
wire [0:0] wlast[0:4];
reg [0:0] m_wlast[0:2];
assign wlast[0]=m_wlast[0];
assign wlast[1]=m_wlast[1];
assign wlast[2]=m_wlast[2];
wire [0:0] wvalid[0:4];
reg [0:0] m_wvalid[0:2];
assign wvalid[0]=m_wvalid[0];
assign wvalid[1]=m_wvalid[1];
assign wvalid[2]=m_wvalid[2];
wire [0:0] wready[0:4];
wire [7:0] bid[0:4];
wire [1:0] bresp[0:4];
wire [0:0] bvalid[0:4];
wire [0:0] bready[0:4];
reg [0:0] m_bready[0:2];
assign bready[0]=m_bready[0];
assign bready[1]=m_bready[1];
assign bready[2]=m_bready[2];
wire [7:0] arid[0:4];
reg [7:0] m_arid[0:2];
assign arid[0]=m_arid[0];
assign arid[1]=m_arid[1];
assign arid[2]=m_arid[2];
wire [31:0] araddr[0:4];
reg [31:0] m_araddr[0:2];
assign araddr[0]=m_araddr[0];
assign araddr[1]=m_araddr[1];
assign araddr[2]=m_araddr[2];
wire [7:0] arlen[0:4];
reg [7:0] m_arlen[0:2];
assign arlen[0]=m_arlen[0];
assign arlen[1]=m_arlen[1];
assign arlen[2]=m_arlen[2];
wire [2:0] arsize[0:4];
reg [2:0] m_arsize[0:2];
assign arsize[0]=m_arsize[0];
assign arsize[1]=m_arsize[1];
assign arsize[2]=m_arsize[2];
wire [1:0] arburst[0:4];
reg [1:0] m_arburst[0:2];
assign arburst[0]=m_arburst[0];
assign arburst[1]=m_arburst[1];
assign arburst[2]=m_arburst[2];
wire [0:0] arvalid[0:4];
reg [0:0] m_arvalid[0:2];
assign arvalid[0]=m_arvalid[0];
assign arvalid[1]=m_arvalid[1];
assign arvalid[2]=m_arvalid[2];
wire [0:0] arready[0:4];
wire [7:0] rid[0:4];
wire [127:0] rdata[0:4];
wire [1:0] rresp[0:4];
wire [0:0] rlast[0:4];
wire [0:0] rvalid[0:4];
wire [0:0] rready[0:4];
reg [0:0] m_rready[0:2];
assign rready[0]=m_rready[0];
assign rready[1]=m_rready[1];
assign rready[2]=m_rready[2];
axi_shared_ddr_2m #(.DDR_ID_W(6)) inner(.clk(clk),.rst_n(rst_n),.allow_access(rst_n),.axi_error_count(errors_inner),.cpu_awid(awid[1]),.cpu_awaddr(awaddr[1]),.cpu_awlen(awlen[1]),.cpu_awsize(awsize[1]),.cpu_awburst(awburst[1]),.cpu_awvalid(awvalid[1]),.cpu_awready(awready[1]),.cpu_wdata(wdata[1]),.cpu_wstrb(wstrb[1]),.cpu_wlast(wlast[1]),.cpu_wvalid(wvalid[1]),.cpu_wready(wready[1]),.cpu_bid(bid[1]),.cpu_bresp(bresp[1]),.cpu_bvalid(bvalid[1]),.cpu_bready(bready[1]),.cpu_arid(arid[1]),.cpu_araddr(araddr[1]),.cpu_arlen(arlen[1]),.cpu_arsize(arsize[1]),.cpu_arburst(arburst[1]),.cpu_arvalid(arvalid[1]),.cpu_arready(arready[1]),.cpu_rid(rid[1]),.cpu_rdata(rdata[1]),.cpu_rresp(rresp[1]),.cpu_rlast(rlast[1]),.cpu_rvalid(rvalid[1]),.cpu_rready(rready[1]),.vid_awid(awid[2]),.vid_awaddr(awaddr[2]),.vid_awlen(awlen[2]),.vid_awsize(awsize[2]),.vid_awburst(awburst[2]),.vid_awvalid(awvalid[2]),.vid_awready(awready[2]),.vid_wdata(wdata[2]),.vid_wstrb(wstrb[2]),.vid_wlast(wlast[2]),.vid_wvalid(wvalid[2]),.vid_wready(wready[2]),.vid_bid(bid[2]),.vid_bresp(bresp[2]),.vid_bvalid(bvalid[2]),.vid_bready(bready[2]),.vid_arid(arid[2]),.vid_araddr(araddr[2]),.vid_arlen(arlen[2]),.vid_arsize(arsize[2]),.vid_arburst(arburst[2]),.vid_arvalid(arvalid[2]),.vid_arready(arready[2]),.vid_rid(rid[2]),.vid_rdata(rdata[2]),.vid_rresp(rresp[2]),.vid_rlast(rlast[2]),.vid_rvalid(rvalid[2]),.vid_rready(rready[2]),.ddr_awid(awid[3][5:0]),.ddr_awaddr(awaddr[3]),.ddr_awlen(awlen[3]),.ddr_awsize(awsize[3]),.ddr_awburst(awburst[3]),.ddr_awvalid(awvalid[3]),.ddr_awready(awready[3]),.ddr_wdata(wdata[3]),.ddr_wstrb(wstrb[3]),.ddr_wlast(wlast[3]),.ddr_wvalid(wvalid[3]),.ddr_wready(wready[3]),.ddr_bid(bid[3][5:0]),.ddr_bresp(bresp[3]),.ddr_bvalid(bvalid[3]),.ddr_bready(bready[3]),.ddr_arid(arid[3][5:0]),.ddr_araddr(araddr[3]),.ddr_arlen(arlen[3]),.ddr_arsize(arsize[3]),.ddr_arburst(arburst[3]),.ddr_arvalid(arvalid[3]),.ddr_arready(arready[3]),.ddr_rid(rid[3][5:0]),.ddr_rdata(rdata[3]),.ddr_rresp(rresp[3]),.ddr_rlast(rlast[3]),.ddr_rvalid(rvalid[3]),.ddr_rready(rready[3]));
axi_shared_ddr_2m #(.DDR_ID_W(4)) outer(.clk(clk),.rst_n(rst_n),.allow_access(rst_n),.axi_error_count(errors_outer),.cpu_awid(awid[0]),.cpu_awaddr(awaddr[0]),.cpu_awlen(awlen[0]),.cpu_awsize(awsize[0]),.cpu_awburst(awburst[0]),.cpu_awvalid(awvalid[0]),.cpu_awready(awready[0]),.cpu_wdata(wdata[0]),.cpu_wstrb(wstrb[0]),.cpu_wlast(wlast[0]),.cpu_wvalid(wvalid[0]),.cpu_wready(wready[0]),.cpu_bid(bid[0]),.cpu_bresp(bresp[0]),.cpu_bvalid(bvalid[0]),.cpu_bready(bready[0]),.cpu_arid(arid[0]),.cpu_araddr(araddr[0]),.cpu_arlen(arlen[0]),.cpu_arsize(arsize[0]),.cpu_arburst(arburst[0]),.cpu_arvalid(arvalid[0]),.cpu_arready(arready[0]),.cpu_rid(rid[0]),.cpu_rdata(rdata[0]),.cpu_rresp(rresp[0]),.cpu_rlast(rlast[0]),.cpu_rvalid(rvalid[0]),.cpu_rready(rready[0]),.vid_awid(awid[3]),.vid_awaddr(awaddr[3]),.vid_awlen(awlen[3]),.vid_awsize(awsize[3]),.vid_awburst(awburst[3]),.vid_awvalid(awvalid[3]),.vid_awready(awready[3]),.vid_wdata(wdata[3]),.vid_wstrb(wstrb[3]),.vid_wlast(wlast[3]),.vid_wvalid(wvalid[3]),.vid_wready(wready[3]),.vid_bid(bid[3]),.vid_bresp(bresp[3]),.vid_bvalid(bvalid[3]),.vid_bready(bready[3]),.vid_arid(arid[3]),.vid_araddr(araddr[3]),.vid_arlen(arlen[3]),.vid_arsize(arsize[3]),.vid_arburst(arburst[3]),.vid_arvalid(arvalid[3]),.vid_arready(arready[3]),.vid_rid(rid[3]),.vid_rdata(rdata[3]),.vid_rresp(rresp[3]),.vid_rlast(rlast[3]),.vid_rvalid(rvalid[3]),.vid_rready(rready[3]),.ddr_awid(awid[4][3:0]),.ddr_awaddr(awaddr[4]),.ddr_awlen(awlen[4]),.ddr_awsize(awsize[4]),.ddr_awburst(awburst[4]),.ddr_awvalid(awvalid[4]),.ddr_awready(awready[4]),.ddr_wdata(wdata[4]),.ddr_wstrb(wstrb[4]),.ddr_wlast(wlast[4]),.ddr_wvalid(wvalid[4]),.ddr_wready(wready[4]),.ddr_bid(bid[4][3:0]),.ddr_bresp(bresp[4]),.ddr_bvalid(bvalid[4]),.ddr_bready(bready[4]),.ddr_arid(arid[4][3:0]),.ddr_araddr(araddr[4]),.ddr_arlen(arlen[4]),.ddr_arsize(arsize[4]),.ddr_arburst(arburst[4]),.ddr_arvalid(arvalid[4]),.ddr_arready(arready[4]),.ddr_rid(rid[4][3:0]),.ddr_rdata(rdata[4]),.ddr_rresp(rresp[4]),.ddr_rlast(rlast[4]),.ddr_rvalid(rvalid[4]),.ddr_rready(rready[4]));
assign awid[3][7:6]=0;assign arid[3][7:6]=0;assign bid[4][7:4]=0;assign rid[4][7:4]=0;
reg [31:0] rng=32'h276839af;reg wa=0,ra=0,bv=0,rh=0;
reg [3:0] wi=0,ri=0;integer wp=0,rp=0,wb=0,rb=0;
reg [127:0] mem[0:3071];integer writes=0,reads=0;
assign awready[4]=!wa&&!bv&&rng[0];assign wready[4]=wa&&rng[1];
assign bvalid[4]=bv;assign bid[4][3:0]=wi;assign bresp[4]=0;
assign arready[4]=!ra&&rng[2];assign rvalid[4]=ra&&rh;assign rid[4][3:0]=ri;
assign rdata[4]=mem[rp+rb];assign rresp[4]=0;assign rlast[4]=rb==3;
always @(posedge clk)begin
 rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 if(awvalid[4]&&awready[4])begin wa<=1;wi<=awid[4];wp<=(awaddr[4]-32'h10000)>>4;wb<=0;end
 if(wvalid[4]&&wready[4])begin
   if(wlast[4]!==(wb==3))$fatal(1,"shared WLAST");mem[wp+wb]<=wdata[4];wb<=wb+1;
   if(wlast[4])begin wa<=0;bv<=1;writes=writes+1;end
 end
 if(bvalid[4]&&bready[4])bv<=0;
 if(arvalid[4]&&arready[4])begin ra<=1;ri<=arid[4];rp<=(araddr[4]-32'h10000)>>4;rb<=0;rh<=0;end
 if(ra&&!rh)rh<=rng[3]||rng[4];
 if(rvalid[4]&&rready[4])begin rh<=0;rb<=rb+1;if(rlast[4])begin ra<=0;reads=reads+1;end end
end
integer finished=0;
task automatic traffic(input integer m);
 integer n,k;reg [7:0] id;reg [127:0] data;
 begin
   id=m==0?8'ha5:m==1?8'hc3:8'he3;
   m_awvalid[m]=0;m_wvalid[m]=0;m_arvalid[m]=0;m_wlast[m]=0;
   m_bready[m]=1;m_rready[m]=1;m_wstrb[m]=16'hffff;
   m_awid[m]=id;m_arid[m]=id;m_awlen[m]=3;m_arlen[m]=3;
   m_awsize[m]=4;m_arsize[m]=4;m_awburst[m]=1;m_arburst[m]=1;
   wait(rst_n);
   for(n=0;n<50;n=n+1)begin
     @(negedge clk);m_awaddr[m]=32'h10000+m*16384+n*64;m_awvalid[m]=1;
     do @(posedge clk);while(!awready[m]);@(negedge clk);m_awvalid[m]=0;
     for(k=0;k<4;k=k+1)begin
       m_wvalid[m]=1;m_wlast[m]=k==3;m_wdata[m]=128'haced0000+m*4096+n*4+k;
       do @(posedge clk);while(!wready[m]);@(negedge clk);m_wvalid[m]=0;
     end
     do @(posedge clk);while(!bvalid[m]);
     if(bid[m]!=id||bresp[m]!=0)$fatal(1,"full write ID m=%0d id=%h",m,bid[m]);
     @(negedge clk);m_araddr[m]=m_awaddr[m];m_arvalid[m]=1;
     do @(posedge clk);while(!arready[m]);@(negedge clk);m_arvalid[m]=0;
     for(k=0;k<4;k=k+1)begin
       do @(posedge clk);while(!rvalid[m]);
       if(rid[m]!=id||rresp[m]!=0||rlast[m]!==(k==3)||rdata[m]!==128'haced0000+m*4096+n*4+k)$fatal(1,"full read/data m=%0d id=%h",m,rid[m]);
       @(negedge clk);
     end
   end
   finished=finished+1;
 end
endtask
initial begin
 fork traffic(0);traffic(1);traffic(2);join
 if(errors_inner||errors_outer||writes!=150||reads!=150)$fatal(1,"shared counts/errors");
 $display("PASS nested AXI: CPU/CNN/video simultaneous traffic, 150 writes+150 reads, full IDs, no starvation");$finish;
end
initial begin repeat(5)@(negedge clk);rst_n=1;end
initial begin #5000000;$fatal(1,"shared timeout");end
endmodule
