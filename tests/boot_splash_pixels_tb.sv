`timescale 1ns/1ps
module boot_splash_pixels_tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0;wire hs,vs,de;wire [7:0] r,g,b;
 boot_splash dut(.clk(clk),.rst_n(rst_n),.start_toggle(1'b0),.live_arm(1'b0),.live_valid(1'b0),
  .live_hs(1'b0),.live_vs(1'b0),.live_de(1'b0),.live_r(8'd0),.live_g(8'd0),.live_b(8'd0),
  .out_hs(hs),.out_vs(vs),.out_de(de),.out_r(r),.out_g(g),.out_b(b),.busy(),.done(),.selected());
 reg [7:0] pixels[0:36863];reg [23:0] colors[0:4095];
 integer x,y,n=0;reg oldhs,oldvs,oldde,prevhs=0,prevvs=0,prevde=0;
 reg [23:0] expected,previous=0;
 initial begin
  $readmemh("assets/boot/pixels.hex",pixels);$readmemh("assets/boot/fade_palette.hex",colors);
  repeat(3)@(negedge clk);rst_n=1;force dut.playing=1;force dut.level=15;
 end
 always @(posedge clk)if(rst_n)begin
   oldhs=dut.h<40;oldvs=dut.v<5;
   oldde=dut.h>=260&&dut.h<1540&&dut.v>=25&&dut.v<745;
   x=(dut.h-260)/5;y=(dut.v-25)/5;
   expected=oldde?colors[3840+pixels[y*256+x]]:0;
   #1;
   if(n>2)begin
    if(hs!==prevhs||vs!==prevvs||de!==prevde)$fatal(1,"timing alignment");
    if({r,g,b}!==previous)$fatal(1,"ROM image mismatch %d %d got %h exp %h",dut.h,dut.v,{r,g,b},previous);
   end
   previous=expected;prevhs=oldhs;prevvs=oldvs;prevde=oldde;n=n+1;
   if(n==1237500)begin $display("PASS complete 720p splash frame: every visible pixel equals approved indexed asset, timing aligned");$finish;end
 end
 initial begin #13000000;$fatal(1,"timeout");end
endmodule
