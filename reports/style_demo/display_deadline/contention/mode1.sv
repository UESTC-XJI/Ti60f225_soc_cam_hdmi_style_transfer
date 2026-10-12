`timescale 1ns/1ps
module style_contention_tb;
 reg clk=0,pix_clk=0;always #5 clk=~clk;always #6.734 pix_clk=~pix_clk;
 reg rst_n=0;reg [2:0] display_slot=2;reg display_valid=1;
 wire display_frame_event,display_safe;wire [31:0] pixel,dma_errors;wire hs,vs,de,underflow;
 wire read_urgent;
 wire [31:0] araddr;wire [7:0] arlen;wire arvalid,rready;
 reg read_active=0,rhold=0;reg [31:0] address=32'h05000000;reg [7:0] beat=0,len=0;
 reg [31:0] rng=32'h871429f3;integer block_cycles=0;
 wire arready,rvalid; wire mrready; wire marvalid; wire [31:0] maraddr; wire [7:0] marlen; wire [3:0] marid; reg [3:0] saved_id; integer return_delay=0; wire mrvalid=read_active&&rhold&&return_delay==0;
 wire rlast;wire [1:0] rresp;
 function [31:0] value(input integer slot,right_side,row,x);
   value={8'b0,8'(slot*17+right_side*91),8'(row),8'(x)};
 endfunction
 function [127:0] data_at(input [31:0] a);
   integer slot,offset,right_side,row,x,k;reg [31:0] base;
   begin
     right_side=a>=32'h05800000;base=right_side?32'h05800000:32'h05000000;
     slot=(a-base)/32'h140000;offset=(a-base)%32'h140000;row=offset/2560;x=(offset%2560)/4;
     for(k=0;k<4;k=k+1)data_at[k*32+:32]=value(slot,right_side,row,x+k);
   end
 endfunction
 wire [127:0] rdata;
axi_shared_ddr_2m #(.DYNAMIC_VIDEO_READ(1'b1),.URGENT_OVERRIDES_FAIRNESS(1'b1),.RESERVE_URGENT_READ(1'b0)) bridge(.clk(clk),.rst_n(rst_n),.allow_access(rst_n),.video_read_urgent(read_urgent),.cpu_awid(8'b0),.cpu_awaddr(32'b0),.cpu_awlen(8'b0),.cpu_awsize(3'd4),.cpu_awburst(2'b01),.cpu_awvalid(1'b0),.cpu_wdata(128'b0),.cpu_wstrb(16'b0),.cpu_wlast(1'b0),.cpu_wvalid(1'b0),.cpu_bready(1'b1),.vid_awid(8'b0),.vid_awaddr(32'b0),.vid_awlen(8'b0),.vid_awsize(3'd4),.vid_awburst(2'b01),.vid_awvalid(1'b0),.vid_wdata(128'b0),.vid_wstrb(16'b0),.vid_wlast(1'b0),.vid_wvalid(1'b0),.vid_bready(1'b1),.cpu_arid(8'h03),.cpu_araddr(32'h06000000),.cpu_arlen(8'd31),.cpu_arsize(3'd4),.cpu_arburst(2'b01),.cpu_arvalid(rst_n),.cpu_rready(1'b1),.vid_arid(8'h01),.vid_araddr(araddr),.vid_arlen(arlen),.vid_arsize(3'd4),.vid_arburst(2'b01),.vid_arvalid(arvalid),.vid_arready(arready),.vid_rdata(rdata),.vid_rresp(rresp),.vid_rlast(rlast),.vid_rvalid(rvalid),.vid_rready(rready),.ddr_awready(1'b0),.ddr_wready(1'b0),.ddr_bid(4'b0),.ddr_bresp(2'b0),.ddr_bvalid(1'b0),.ddr_araddr(maraddr),.ddr_arlen(marlen),.ddr_arid(marid),.ddr_arvalid(marvalid),.ddr_arready(!read_active),.ddr_rid(saved_id),.ddr_rdata(data_at(address)),.ddr_rresp(2'b0),.ddr_rlast(beat==len),.ddr_rvalid(mrvalid),.ddr_rready(mrready));
 style_display dut(.*);
 integer ticks=0,frames=0,bad_pixels=0,good_pixels=0,ar_count=0;
 integer oldh,oldv;reg stalled=0;
 always @(posedge clk)begin
   rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   if(marvalid&&!read_active)begin
     if(araddr[3:0]!=0||arlen>31||(araddr[11:0]+(arlen+1)*16)>4096)$fatal(1,"display AR boundary");
     read_active<=1;address<=maraddr;len<=marlen;saved_id<=marid;beat<=0;rhold<=0;ar_count=ar_count+1;return_delay<=marid[3] ? 24:320;
   end
   if(read_active&&!rhold)rhold<=rng[1]||rng[2];
   if(mrvalid&&mrready)begin
     rhold<=0;address<=address+16;beat<=beat+1'b1;if(rlast)read_active<=0;
   end
   if(return_delay>0)return_delay<=return_delay-1;

   if(display_frame_event&&frames==2)display_slot<=4;
 end
 always @(posedge pix_clk)if(rst_n)begin
   oldh=dut.h;oldv=dut.v;
   #1;
   if(hs!==(oldh<40)||vs!==(oldv<5)||de!==(oldv>=25&&oldv<745&&oldh>=260&&oldh<1540))$fatal(1,"720p sync stopped");
   if(de)begin
     if(oldv<145||oldv>=625)begin if(pixel!==0)$fatal(1,"letterbox not black");end
     else if(underflow)begin
       if(pixel!==0)$fatal(1,"underflow not black");bad_pixels=bad_pixels+1;

     end else begin
       if(pixel!==value(frames==2?4:2,oldh>=900,oldv-145,(oldh-260)%640))$fatal(1,"paired DDR pixel frame=%0d row=%0d x=%0d got=%h",frames,oldv-145,oldh-260,pixel);
       good_pixels=good_pixels+1;
     end
   end
   ticks=ticks+1;
   if(oldh==1649&&oldv==749)begin
     if(ticks!=1650*750)$fatal(1,"frame period");ticks=0;frames=frames+1;
     if(frames==1)begin
       if(dma_errors!=0)$fatal(1,"DMA errors");
       $display("PASS sustained contention: good=%0d underflow=%0d bursts=%0d",good_pixels,bad_pixels,ar_count);$finish;
     end
   end
 end
 initial begin repeat(4)@(negedge clk);rst_n=1;end
 initial begin #70000000;$fatal(1,"display timeout");end
endmodule
