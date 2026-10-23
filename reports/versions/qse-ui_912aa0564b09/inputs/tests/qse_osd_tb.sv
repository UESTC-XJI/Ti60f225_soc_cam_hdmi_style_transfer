`timescale 1ns/1ps
module qse_osd_tb;
 reg clk=0,rst_n=0,wr_enable=1;reg [1:0] ui_selection=0;
 reg vs=0,de=0;wire [7:0] r,g,b;wire char_pixel;
 always #5 clk=~clk;
 osd_text_double_buffer #(.QSE_UI(1)) dut(.wr_clk(clk),.pix_clk(clk),.rst_n(rst_n),.wr_en(1'b0),.wr_page(1'b1),.wr_addr(7'd0),.wr_data(8'd0),.wr_commit(1'b0),.wr_commit_page(1'b1),.wr_enable(wr_enable),.wr_x(12'd16),.wr_y(12'd40),.wr_color(24'h20ff40),.ui_selection(ui_selection),.i_vs(vs),.i_hs(1'b0),.i_de(de),.i_r(8'h12),.i_g(8'h34),.i_b(8'h56),.o_r(r),.o_g(g),.o_b(b),.o_char_pixel(char_pixel));
 integer s,j;reg [63:0] text_expected;
 initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(s=0;s<4;s=s+1)begin
 ui_selection=s;
 case(s)0:text_expected="0:origin";1:text_expected="1:style1";2:text_expected="2:style2";3:text_expected="3:style3";endcase
 for(j=0;j<8;j=j+1)begin
 force dut.x=16+j*8;force dut.y=16;
 @(posedge clk);#1;
 if(dut.active_ch!==text_expected[63:56])$fatal(1,"label selection=%d char=%d got=%h",s,j,dut.active_ch);
 text_expected=text_expected<<8;
 end
 end
 release dut.x;release dut.y;
 wr_enable=0;repeat(4)@(negedge clk);vs=1;@(negedge clk);vs=0;
 force dut.x=16;force dut.y=16;de=1;
 repeat(8)@(negedge clk);
 if(char_pixel||{r,g,b}!==24'h123456)$fatal(1,"OSD disable did not bypass RGB");
 $display("PASS OSD exact labels for all selections and disabled RGB bypass");$finish;
 end
endmodule
