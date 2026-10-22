`timescale 1ns/1ps
module osd_fixed_text_tb;
  localparam W=96, H=32;
  logic clk=0, rst_n=0;
  logic vs=0, hs=0, de=0;
  logic [7:0] r=8'h11,g=8'h22,b=8'h33;
  logic o_vs,o_hs,o_de,cp;
  logic [7:0] or_,og,ob;
  integer x=0,y=0, lit=0, bad=0, frames=0;
  osd_fixed_text #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H),.BASE_X(4),.BASE_Y(2)) dut(
    .clk,.rst_n,.i_vs(vs),.i_hs(hs),.i_de(de),.i_r(r),.i_g(g),.i_b(b),.i_enable(1'b1),
    .o_vs,.o_hs,.o_de,.o_r(or_),.o_g(og),.o_b(ob),.o_char_pixel(cp));
  always #5 clk=~clk;

  task tick; begin @(negedge clk); end endtask
  task line(input integer yy); integer xx; integer px; begin
    y=yy; vs=0; hs=0; de=0; tick;
    for(xx=0;xx<W;xx=xx+1) begin
      x=xx; de=1; r=8'h11;g=8'h22;b=8'h33; tick; px=xx-1;
      if(cp) begin
        lit=lit+1;
        if(px < 4 || px >= 4+9*8 || y < 2 || y >= 18) begin bad=bad+1; $display("bad pos x=%0d y=%0d px=%0d",x,y,px); end
        if({or_,og,ob} !== 24'h20ff40) begin bad=bad+1; $display("bad color x=%0d y=%0d rgb=%h",x,y,{or_,og,ob}); end
      end
    end
    de=0; tick;
  end endtask

  integer i;
  initial begin
    repeat(3) tick;
    rst_n=1;
    // Active-high VS interval establishes the coordinate origin.
    vs=1; de=0; tick; tick; vs=0; tick;
    for(i=0;i<H;i=i+1) line(i);
    // Drain the registered output.
    de=0; repeat(3) tick;
    if(lit < 20) $fatal(1,"OSD produced too few lit pixels: %0d",lit);
    if(bad != 0) $fatal(1,"OSD alignment/color errors: %0d",bad);
    $display("PASS OSD fixed HELLO SOC: %0d lit pixels",lit);
    $finish;
  end
endmodule
