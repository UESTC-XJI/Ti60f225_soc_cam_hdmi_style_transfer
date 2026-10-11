`timescale 1ns/1ps
module style_display_tb;
 reg clk=0,pix_clk=0;always #5 clk=~clk;always #6.734 pix_clk=~pix_clk;
 reg rst_n=0;reg [2:0] display_slot=2;reg display_valid=1;
 wire display_frame_event,display_safe;wire [31:0] pixel,dma_errors;wire hs,vs,de,underflow;
 wire [31:0] araddr;wire [7:0] arlen;wire arvalid,rready;
 reg read_active=0,rhold=0;reg [31:0] address=32'h05000000;reg [7:0] beat=0,len=0;
 reg [31:0] rng=32'h871429f3;integer block_cycles=0;
 wire arready=!read_active&&rng[0];wire rvalid=read_active&&rhold&&block_cycles==0;
 wire rlast=beat==len;wire [1:0] rresp=0;
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
 wire [127:0] rdata=data_at(address);
 style_display dut(.*);
 integer ticks=0,frames=0,bad_pixels=0,good_pixels=0,ar_count=0;
 integer oldh,oldv;reg stalled=0;
 always @(posedge clk)begin
   rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   if(arvalid&&arready)begin
     if(araddr[3:0]!=0||arlen>31||(araddr[11:0]+(arlen+1)*16)>4096)$fatal(1,"display AR boundary");
     read_active<=1;address<=araddr;len<=arlen;beat<=0;rhold<=0;ar_count=ar_count+1;
   end
   if(read_active&&!rhold)rhold<=rng[1]||rng[2];
   if(rvalid&&rready)begin
     rhold<=0;address<=address+16;beat<=beat+1'b1;if(rlast)read_active<=0;
   end
   if(block_cycles>0)block_cycles<=block_cycles-1;
   if(frames==1&&dut.v==310&&!stalled)begin block_cycles<=5000;stalled<=1;end
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
       if(frames!=1)$fatal(1,"unexpected starvation frame=%0d row=%0d x=%0d",frames,oldv-145,oldh-260);
     end else begin
       if(pixel!==value(frames==2?4:2,oldh>=900,oldv-145,(oldh-260)%640))$fatal(1,"paired DDR pixel frame=%0d row=%0d x=%0d got=%h",frames,oldv-145,oldh-260,pixel);
       good_pixels=good_pixels+1;
     end
   end
   ticks=ticks+1;
   if(oldh==1649&&oldv==749)begin
     if(ticks!=1650*750)$fatal(1,"frame period");ticks=0;frames=frames+1;
     if(frames==3)begin
       if(bad_pixels==0||dma_errors!=0)$fatal(1,"error recovery");
       $display("PASS 720p60 display: 3 full frames, paired slots 2/4, exact RGB, starvation black/recovery, good=%0d underflow=%0d bursts=%0d",good_pixels,bad_pixels,ar_count);$finish;
     end
   end
 end
 initial begin repeat(4)@(negedge clk);rst_n=1;end
 initial begin #70000000;$fatal(1,"display timeout");end
endmodule
