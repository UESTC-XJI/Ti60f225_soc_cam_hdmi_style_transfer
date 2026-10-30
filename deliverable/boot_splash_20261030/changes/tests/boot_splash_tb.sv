`timescale 1ns/1ps
module boot_splash_tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,start=0,arm=0,valid=0,lvs=0;
 wire hs,vs,de,busy,done,selected;wire [7:0] r,g,b;
 boot_splash #(.FRAME_STEP(1),.HOLD_FRAMES(2)) dut(
  .clk(clk),.rst_n(rst_n),.start_toggle(start),.live_arm(arm),.live_valid(valid),
  .live_hs(1'b1),.live_vs(lvs),.live_de(1'b1),.live_r(8'h12),.live_g(8'h34),.live_b(8'h56),
  .out_hs(hs),.out_vs(vs),.out_de(de),.out_r(r),.out_g(g),.out_b(b),.busy(busy),.done(done),.selected(selected));
 task frame_end;
 begin
   @(negedge clk);force dut.h=1649;force dut.v=749;
   @(negedge clk);release dut.h;release dut.v;
   force dut.h=0;force dut.v=0;@(negedge clk);release dut.h;release dut.v;
 end endtask
 integer i;
 initial begin
  repeat(3)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
  if(busy||done||selected)$fatal(1,"reset flags");
  start=1;repeat(5)@(negedge clk);if(!busy||done)$fatal(1,"start handshake");
  for(i=1;i<=15;i=i+1)begin frame_end();if(dut.level!==i)$fatal(1,"fade in %d %d",i,dut.level);end
  repeat(2)begin frame_end();if(dut.level!==15)$fatal(1,"hold");end
  for(i=14;i>=0;i=i-1)begin frame_end();if(dut.level!==i)$fatal(1,"fade out %d %d",i,dut.level);end
  frame_end();frame_end();if(!done||busy)$fatal(1,"completion");
  arm=1;repeat(5)@(negedge clk);frame_end();lvs=1;repeat(2)@(negedge clk);
  if(selected)$fatal(1,"selected without captured frame");
  lvs=0;valid=1;repeat(5)@(negedge clk);if(selected)$fatal(1,"early selection");
  frame_end();lvs=1;repeat(3)@(negedge clk);
  if(!selected||{r,g,b}!==24'h123456||!hs||!vs||!de)$fatal(1,"handover");
  start=0;repeat(5)@(negedge clk);if(!busy||done||selected)$fatal(1,"replay");
  $display("PASS BRAM splash fade/hold/fade, deferred init flags, valid-frame gating, live handover and replay");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
