`timescale 1ns/1ps
module osd_text_double_buffer_tb;
  logic wclk=0,pclk=0,rst=0; always #5 wclk=~wclk; always #7 pclk=~pclk;
  logic we=0,page=1; logic [6:0] wa=0; logic [7:0] wd=0; logic commit=0,commit_page=1,en=1; logic [11:0] wx=2,wy=1; logic [23:0] wc=24'hffffff; logic vs=0,hs=0,de=0; logic [7:0] r=8'h10,g=8'h20,b=8'h30; logic ovs,ohs,ode,cp,ack,active,busy; logic [7:0] or_,og,ob;
  osd_text_double_buffer #(.FRAME_WIDTH(40),.FRAME_HEIGHT(20),.BASE_X(2),.BASE_Y(1)) dut(.wr_clk(wclk),.pix_clk(pclk),.rst_n(rst),.wr_en(we),.wr_page(page),.wr_addr(wa),.wr_data(wd),.wr_commit(commit),.wr_commit_page(commit_page),.wr_enable(en),.wr_x(wx),.wr_y(wy),.wr_color(wc),.i_vs(vs),.i_hs(hs),.i_de(de),.i_r(r),.i_g(g),.i_b(b),.o_vs(ovs),.o_hs(ohs),.o_de(ode),.o_r(or_),.o_g(og),.o_b(ob),.o_char_pixel(cp),.ack_toggle(ack),.active_page(active),.busy(busy));
  integer i,j,lit;
  task write_char(input [7:0] c); begin @(negedge wclk);we=1;wa=0;wd=c;@(negedge wclk);we=0;end endtask
  task sample_pixel; begin
    #1;
    if(cp) begin
      lit=lit+1;
      if(!ode || {or_,og,ob}!==wc) $fatal(1,"invalid glyph pixel/color");
    end else if(ode && {or_,og,ob}!=={r,g,b}) $fatal(1,"OSD changed background pixel");
  end endtask
  // Change wr_enable well inside a glyph-bearing frame. The whole frame
  // must retain its original enable; the change applies at the next VS.
  task frame(input bit change_enable,input bit next_enable); begin
    @(negedge pclk);de=0;vs=1;
    repeat(3) @(negedge pclk);
    vs=0;lit=0;
    for(j=0;j<20;j=j+1) begin
      de=0;@(negedge pclk);sample_pixel;
      for(i=0;i<40;i=i+1) begin
        de=1;@(negedge pclk);sample_pixel;
        if(change_enable&&j==5&&i==10) en=next_enable;
      end
      de=0;@(negedge pclk);sample_pixel;
    end
    repeat(5) begin @(negedge pclk);sample_pixel;end
  end endtask
  integer reference_lit;
  initial begin
    repeat(2) @(negedge pclk);rst=1;
    write_char("A");@(negedge wclk);commit=~commit;
    repeat(6) @(negedge pclk);
    if(ack||active||!busy) $fatal(1,"COMMIT applied without a frame boundary");
    frame(0,1);
    if(!ack||!active||busy||lit<5) $fatal(1,"OSD commit/render failed ack=%b active=%b lit=%0d",ack,active,lit);
    reference_lit=lit;
    frame(1,0);
    if(lit!=reference_lit) $fatal(1,"disable cut text mid-frame");
    frame(0,0);
    if(lit!=0||!ack||!active) $fatal(1,"disable without COMMIT failed lit=%0d",lit);
    frame(1,1);
    if(lit!=0) $fatal(1,"enable drew text mid-frame");
    frame(0,1);
    if(lit!=reference_lit) $fatal(1,"reenable lost active text/page");
    // Active-page writes are ignored even with the text disabled. A new
    // inactive page may still be committed and ACKed while disabled.
    en=0;repeat(6) @(negedge pclk);frame(0,0);
    page=1;write_char(" ");
    en=1;repeat(6) @(negedge pclk);frame(0,1);
    if(lit!=reference_lit) $fatal(1,"active-page write corrupted displayed text");
    en=0;repeat(6) @(negedge pclk);frame(0,0);
    page=0;write_char("B");@(negedge wclk);commit_page=0;commit=~commit;
    repeat(6) @(negedge pclk);
    if(!ack||!active||!busy) $fatal(1,"disabled COMMIT switched before VS");
    frame(0,0);
    if(ack||active||busy||lit) $fatal(1,"disabled COMMIT/ACK failed");
    en=1;repeat(6) @(negedge pclk);frame(0,1);
    if(lit<5) $fatal(1,"disabled page commit was not retained");
    $display("PASS OSD: async two-page COMMIT/ACK, active-page protection, frame-boundary enable/disable without COMMIT, disabled commit and RGB passthrough");
    $finish;
  end
  initial begin #1000000;$fatal(1,"OSD test timeout");end
endmodule
