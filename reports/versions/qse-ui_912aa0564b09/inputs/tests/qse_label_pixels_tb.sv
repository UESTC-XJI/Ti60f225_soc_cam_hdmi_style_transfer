`timescale 1ns/1ps
module qse_label_pixels_tb;
 reg clk=0,rst_n=0,vs=0,de=0,enable=1;reg [1:0] selection=0;
 always #5 clk=~clk;
 wire ov,oh,od,cp;wire [7:0] r,g,b;
 osd_text_double_buffer #(.FRAME_WIDTH(96),.FRAME_HEIGHT(40),.BASE_Y(40),.QSE_UI(1)) dut(
 .wr_clk(clk),.pix_clk(clk),.rst_n(rst_n),.wr_en(1'b0),.wr_page(1'b1),.wr_addr(7'd0),.wr_data(8'd0),.wr_commit(1'b0),.wr_commit_page(1'b1),.wr_enable(enable),.wr_x(12'd16),.wr_y(12'd40),.wr_color(24'h20ff40),.ui_selection(selection),.i_vs(vs),.i_hs(1'b0),.i_de(de),.i_r(8'h12),.i_g(8'h34),.i_b(8'h56),.o_vs(ov),.o_hs(oh),.o_de(od),.o_char_pixel(cp),.o_r(r),.o_g(g),.o_b(b));
 reg [7:0] oracle[0:4095];reg [63:0] text;
 reg [27:0] q0=0,q1=0,expected;reg glyph;
 integer x=0,y=0,ch,col,row,lit=0,n,s;
 always @(posedge clk)if(rst_n)begin
  if(vs)begin x=0;y=0;end
  glyph=0;
  if(enable&&de&&x>=16&&x<80&&y>=16&&y<32)begin
   ch=(text>>((7-(x-16)/8)*8))&255;row=y-16;col=(x-16)%8;
   glyph=oracle[ch*16+row][7-col];
  end
  expected={vs,1'b0,de,glyph,(glyph ? 24'h20ff40:24'h123456)};
  if(de)begin if(x==95)begin x=0;y=y+1;end else x=x+1;end
  #1;
  if({ov,oh,od,cp,r,g,b}!==q1)$fatal(1,"label pixel/latency mismatch selection=%d x=%d y=%d",selection,x,y);
  if(cp)lit=lit+1;
  q1=q0;q0=expected;
 end
 initial begin
  $readmemh("work/validation/font_oracle.hex",oracle);
  repeat(4)@(negedge clk);rst_n=1;
  // Flush reset pipeline before reference checks become meaningful.
  for(s=0;s<5;s=s+1)begin
   selection=s%4;enable=s<4;
   case(selection)0:text="0:origin";1:text="1:style1";2:text="2:style2";3:text="3:style3";endcase
   repeat(6)@(negedge clk);vs=1;repeat(4)@(negedge clk);vs=0;
   for(n=0;n<3840;n=n+1)begin de=1;@(negedge clk);end
   de=0;repeat(6)@(negedge clk);
  end
  if(lit<100)$fatal(1,"empty labels");
  $display("PASS QSE labels: 19200 exact pixels, all four labels, disabled overlay, 3-cycle RGB and sync alignment");$finish;
 end
endmodule
