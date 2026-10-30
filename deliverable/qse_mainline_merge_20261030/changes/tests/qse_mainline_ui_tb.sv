`timescale 1ns/1ps
module qse_mainline_ui_tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,psel=0,penable=0,pwrite=0;
 reg [15:0] paddr=0;reg [31:0] pwdata=0;
 wire [31:0] prdata;wire pready,pslverr;
 reg [1:0] keys=0;wire [1:0] ui;
 video_apb_ctrl apb(.pclk(clk),.preset_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),
  .paddr(paddr),.pwdata(pwdata),.prdata(prdata),.pready(pready),.pslverr(pslverr),
  .capture_clk(clk),.display_clk(clk),.raw_vs(1'b0),.raw_de(1'b0),.rgb_vs(1'b0),.rgb_de(1'b0),.display_vs(1'b0),
  .raw_data(16'd0),.rgb_data(48'd0),.keys_in(keys),.knob_in(2'b10),.ui_control(ui));
 reg vs=0,en=1;wire [7:0] r,g,b;wire hsout,vsout,deout;
 fps_overlay fps(.clk(clk),.rst_n(rst_n),.i_enable(en),.i_vs(vs),.i_hs(1'b0),.i_de(1'b1),
  .i_r(8'h23),.i_g(8'h45),.i_b(8'h67),.i_fps(16'd30),
  .o_vs(vsout),.o_hs(hsout),.o_de(deout),.o_r(r),.o_g(g),.o_b(b));
 task wr(input [15:0] addr,input [31:0] value,input error);
 begin
  @(negedge clk);psel=1;penable=1;pwrite=1;paddr=addr;pwdata=value;
  #1;if(pslverr!==error)$fatal(1,"APB validation %h",addr);
  @(negedge clk);psel=0;penable=0;pwrite=0;
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  #1;if(ui!==3)$fatal(1,"default UI");
  paddr=16'h134;keys=2;#1;if(prdata!==2)$fatal(1,"key readback");
  paddr=16'h054;#1;if(prdata[3:2]!==2)$fatal(1,"B knob mapping");
  wr(16'h130,0,0);if(ui!==0)$fatal(1,"UI write");
  wr(16'h130,4,1);if(ui!==0)$fatal(1,"bad UI write mutated state");
  wr(16'h134,1,1);wr(16'h130,3,0);if(ui!==3)$fatal(1,"UI restore");
  force fps.x=8;force fps.y=128;
  @(negedge clk);#1;if({r,g,b}!==24'h000000)$fatal(1,"enabled box missing");
  en=0;repeat(5)@(negedge clk);#1;if({r,g,b}!==24'h000000)$fatal(1,"OSD changed mid-frame");
  vs=1;repeat(2)@(negedge clk);vs=0;repeat(2)@(negedge clk);
  #1;if({r,g,b}!==24'h234567)$fatal(1,"disabled OSD changed pixels");
  if(!deout||hsout||vsout)$fatal(1,"disabled OSD timing");
  en=1;repeat(4)@(negedge clk);vs=1;repeat(2)@(negedge clk);vs=0;repeat(2)@(negedge clk);
  #1;if({r,g,b}!==24'h000000)$fatal(1,"OSD did not resume");
  $display("PASS QSE APB keys/UI/invalid writes; B knob bits preserved; FPS frame-boundary enable and pixel/timing bypass");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
