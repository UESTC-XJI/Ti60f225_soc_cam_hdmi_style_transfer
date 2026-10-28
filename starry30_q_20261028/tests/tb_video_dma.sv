`timescale 1ns/1ps
module tb_video_dma;
localparam W=1280,H=6,N=W*H,WORDS=N/4,SLOT=(N*4+512)/16;
reg wc=0,ac=0,rc=0,rst=0,vs=0,de=0,period=0,ready=0;
always #3.367 wc=~wc;
always #5 ac=~ac;
always #6.734 rc=~rc;
reg [63:0] pixels=0;
wire [31:0] data;wire valid,last,user;
wire [31:0] awaddr,araddr;wire [7:0] awlen,arlen;
wire awvalid,arvalid,wvalid,wlast,rready,bready;
wire [127:0] wdata;wire [15:0] wstrb;
reg awready=0,wready=0,arready=0,bvalid=0,rvalid=0,rlast=0;reg [127:0] rdata=0;
frame_buffer #(.I_VID_WIDTH(64),.O_VID_WIDTH(32),.AXI_DATA_WIDTH(128),.AXI_ADDR_WIDTH(32),
 .START_ADDR(0),.WR_FIFO_DEPTH(1024),.RD_FIFO_DEPTH(1024),.BURST_LEN(127),.FB_NUM(3),
 .MAX_VID_WIDTH(W/2),.MAX_VID_HIGHT(H),.O_FRAME_WIDTH(W),.O_FRAME_HEIGHT(H)) dut(
 .axi_clk(ac),.rst_n(rst),.i_clk(wc),.i_vs(vs),.i_de(de),.vin(pixels),.o_clk(rc),.fifo_rd_period(period),
 .m_axis_tdata(data),.m_axis_tvalid(valid),.m_axis_tready(ready),.m_axis_tlast(last),.m_axis_tuser(user),
 .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
 .bid(6'd0),.bvalid(bvalid),.bready(bready),.araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
 .rid(6'd0),.rdata(rdata),.rlast(rlast),.rvalid(rvalid),.rready(rready),.rresp(2'd0));
reg [127:0] mem[0:3*SLOT-1];
integer addrs[0:1023],lens[0:1023],wp=0,rp=0,beat=0;
integer raddrs[0:1023],rlens[0:1023],rwp=0,rrp=0,rbeat=0;
integer cycle=0,writes=0,readcount=0;
always @(negedge ac) begin
 cycle=cycle+1;awready=rst && cycle%3!=0;wready=rst && cycle%4!=0;arready=rst && cycle%5!=0;
end
always @(posedge ac) if(rst) begin
 if(bvalid && bready) bvalid<=0;
 if(awvalid && awready) begin
   if(awaddr>=3*SLOT*16 || (awaddr%4096)+(awlen+1)*16>4096) $fatal(1,"bad AW %h len %0d",awaddr,awlen);
   addrs[wp]=awaddr/16;lens[wp]=awlen;wp=wp+1;
 end
 if(wvalid && wready) begin
   if(rp>=wp || wstrb!=16'hffff || wlast!=(beat==lens[rp])) $fatal(1,"write protocol");
   mem[addrs[rp]+beat]=wdata;writes=writes+1;
   if(wlast) begin rp=rp+1;beat=0;bvalid<=1;end else beat=beat+1;
 end
 if(arvalid && arready) begin
   if(araddr>=3*SLOT*16 || (araddr%4096)+(arlen+1)*16>4096) $fatal(1,"bad AR");
   raddrs[rwp]=araddr/16;rlens[rwp]=arlen;rwp=rwp+1;
 end
 if(!rvalid || rready) begin
   rvalid<=0;
   if(rrp<rwp && cycle%7!=0) begin
     rdata<=mem[raddrs[rrp]+rbeat];rlast<=rbeat==rlens[rrp];rvalid<=1;
     if(rbeat==rlens[rrp]) begin rrp=rrp+1;rbeat=0;end else rbeat=rbeat+1;
   end
 end
end
integer f,y,x,i,n=0,output_frames=0,frame_id=0;
reg check=0;
always @(posedge rc) if(check && valid && ready) begin
 if(n==0) frame_id=data[31:24];
 if(output_frames>0 && (frame_id==0 || data !== {frame_id[7:0],n[23:0]})) $fatal(1,"DMA pixel %0d got %h frame %0d writes=%0d",n,data,frame_id,writes);
 if(last != (n%W==W-1) || user!=(n==0)) $fatal(1,"AXIS markers pixel %0d",n);
 if(n==N-1) begin n=0;output_frames=output_frames+1;check=0;ready=0;end else n=n+1;
end
initial begin
 for(i=0;i<3*SLOT;i=i+1) mem[i]=0;
 repeat(20) @(negedge wc);rst=1;
 for(f=1;f<=5;f=f+1) begin
   @(negedge wc);vs=1;repeat(30) @(negedge wc);vs=0;
   repeat(40) @(negedge wc);
   for(y=0;y<H;y=y+1) begin
     for(x=0;x<W;x=x+2) begin
       de=1;pixels={f[7:0],24'(y*W+x),f[7:0],24'(y*W+x+1)};
       @(negedge wc);de=0;repeat(2) @(negedge wc);
     end
     repeat(25) @(negedge wc);
   end
   repeat(2000) @(negedge wc);
   // Frame lengths stabilize after two complete captures; read bank is switched
   // after the first read request. Ignore warm-up contents.
   if(f>=3) begin
     @(negedge rc);period=1;repeat(500) @(negedge rc);period=0;ready=1;check=1;
     wait(!check);repeat(500) @(negedge rc);
   end
 end
 if(output_frames!=3 || dut.ddr_frame_len!=WORDS) $fatal(1,"DMA counts");
 $display("PASS XRGB DMA: %0d frames, %0d AXI writes, stalls + 4KiB boundaries",output_frames,writes);$finish;
end
initial begin #10000000;$fatal(1,"DMA timeout writes=%0d output=%0d pixel=%0d AW=%0d AR=%0d frame_len=%0d",writes,output_frames,n,wp,rwp,dut.ddr_frame_len);end
endmodule
