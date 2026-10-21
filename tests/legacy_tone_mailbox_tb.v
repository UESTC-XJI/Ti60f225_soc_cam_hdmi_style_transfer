`timescale 1ns/1ps
module tone_tb;
  reg clk=0,rst=0,en=0,vs=0,hs=0,de=0;
  reg [7:0] high=0,dark=0,r=0,g=0,b=0;
  wire ov,oh,od; wire [7:0] ro,go,bo;
  luma_color_suppress dut(clk,rst,en,high,dark,vs,hs,de,r,g,b,ov,oh,od,ro,go,bo);
  always #5 clk=~clk;
  integer er[0:2],eg[0:2],eb[0:2],sy[0:2];
  integer n=0,k,y,hw,dw,hp=0,dp=0,ep=0,checked=0;
  reg lastvs=0;
  always @(posedge clk) if(rst) begin
    for(k=2;k>0;k=k-1) begin er[k]=er[k-1];eg[k]=eg[k-1];eb[k]=eb[k-1];sy[k]=sy[k-1];end
    y=(r+2*g+b)/4;
    hw=y>192?(y-192)*4:0;dw=y<64?(64-y)*4:0;if(dw>255) dw=255;
    er[0]=ep ? r*(256-(dw*dp)/256)/256 : r;
    eg[0]=ep ? g*(256-(hw*hp)/256)/256 : g;
    eb[0]=b;sy[0]={vs,hs,de};
    if(vs && !lastvs) begin ep=en;hp=high>128?128:high;dp=dark>128?128:dark;end
    lastvs=vs;
    #1;
    if(n>=2) begin
      if({ov,oh,od}!==sy[2][2:0]) $fatal(1,"tone sync cycle %0d",n);
      if(od) begin
        if(ro!==er[2][7:0] || go!==eg[2][7:0] || bo!==eb[2][7:0])
          $fatal(1,"tone RGB cycle %0d got %0d,%0d,%0d expected %0d,%0d,%0d",n,ro,go,bo,er[2],eg[2],eb[2]);
        checked=checked+1;
      end
    end
    n=n+1;
  end
  task frame(input integer enable,hi,lo);
    integer j;
    begin
      @(negedge clk);en=enable;high=hi;dark=lo;vs=1;de=0;
      repeat(5) @(negedge clk);
      vs=0;
      for(j=0;j<256;j=j+1) begin
        de=1;r=j;g=j;b=j;hs=j%3==0;@(negedge clk);
      end
      // Controls change during active frame: must retain the latched values.
      en=!enable;high=255-hi;dark=255-lo;
      for(j=0;j<1000;j=j+1) begin
        de=j%13!=0;r=$random;g=$random;b=$random;hs=j%7==0;@(negedge clk);
      end
      de=0;repeat(5) @(negedge clk);
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst=1;
    frame(0,128,128);frame(1,0,0);frame(1,32,16);frame(1,128,128);frame(1,255,255);
    $display("PASS tone: %0d active pixels, sync, frame latch and strength clamp",checked);$finish;
  end
endmodule


module mailbox_tb;
  reg sc=0,dc=0,rst=0,valid=0;reg[16:0] data=0;
  wire ready,dv;wire[16:0] dd;
  isp_cdc_mailbox #(.WIDTH(17)) dut(sc,rst,valid,data,ready,dc,rst,dv,dd);
  always #3 sc=~sc;always #11 dc=~dc;
  integer sent=0,received=0;reg[16:0] expected[0:199];
  always @(posedge sc) if(rst && valid && ready) begin expected[sent]=data;sent=sent+1;end
  always @(posedge dc) begin #1;if(rst && dv) begin
    if(dd!==expected[received]) $fatal(1,"mailbox message %0d",received);
    received=received+1;
  end end
  integer i;
  initial begin
    repeat(4) @(negedge sc);rst=1;
    for(i=0;i<100;i=i+1) begin
      @(negedge sc);valid=1;data=$random;
      // Deliberately offer changing data while busy; only accepted items count.
      repeat(i%8+1) @(negedge sc);
      valid=0;
    end
    repeat(50) @(negedge dc);
    if(sent!=received || received<20) $fatal(1,"mailbox missing deliveries");
    $display("PASS mailbox: %0d ordered messages with asynchronous clocks",received);$finish;
  end
endmodule
