`timescale 1ns/1ps
module osd_text_double_buffer_tb;
  logic wclk=0,pclk=0,rst=0; always #5 wclk=~wclk; always #7 pclk=~pclk;
  logic we=0,page=1; logic [6:0] wa=0; logic [7:0] wd=0; logic commit=0,commit_page=1,en=1; logic [11:0] wx=2,wy=1; logic [23:0] wc=24'hffffff; logic vs=0,hs=0,de=0; logic [7:0] r=8'h10,g=8'h20,b=8'h30; logic ovs,ohs,ode,cp,ack,active; logic [7:0] or_,og,ob;
  osd_text_double_buffer #(.FRAME_WIDTH(40),.FRAME_HEIGHT(20),.BASE_X(2),.BASE_Y(1)) dut(.wr_clk(wclk),.pix_clk(pclk),.rst_n(rst),.wr_en(we),.wr_page(page),.wr_addr(wa),.wr_data(wd),.wr_commit(commit),.wr_commit_page(commit_page),.wr_enable(en),.wr_x(wx),.wr_y(wy),.wr_color(wc),.i_vs(vs),.i_hs(hs),.i_de(de),.i_r(r),.i_g(g),.i_b(b),.o_vs(ovs),.o_hs(ohs),.o_de(ode),.o_r(or_),.o_g(og),.o_b(ob),.o_char_pixel(cp),.ack_toggle(ack),.active_page(active));
  integer i,j,lit;
  task write_char(input [7:0] c); begin @(negedge wclk);we=1;wa=0;wd=c;@(negedge wclk);we=0;end endtask
  task frame; begin vs=1;repeat(2) @(negedge pclk);vs=0;for(j=0;j<20;j=j+1) begin de=0;@(negedge pclk);for(i=0;i<40;i=i+1) begin de=1;@(negedge pclk);if(cp) lit=lit+1;end de=0;@(negedge pclk);end end endtask
  initial begin repeat(2) @(posedge pclk);rst=1;write_char("A");@(negedge wclk);commit=~commit;repeat(5) @(posedge pclk);lit=0;frame;if(!ack||!active||lit<5) $fatal(1,"OSD page commit/render failed ack=%b active=%b lit=%0d",ack,active,lit);$display("PASS OSD double buffer commit/ACK at frame boundary");$finish;end
endmodule
