`timescale 1ns/1ps
module osd_bram_pixels_tb;
  reg wc=0,pc=0,rst=0;always #5 wc=~wc;always #7 pc=~pc;
  reg we=0,page=1,commit=0,commit_page=1,en=1;reg [6:0] addr=0;reg [7:0] data=0;
  reg [11:0] wx=3,wy=2;reg [23:0] color=24'h12a34f;
  reg vs=0,hs=0,de=0;reg [7:0] r=0,g=0,b=0;
  wire ov,oh,od,cp,ack,active,busy;wire [7:0] ro,go,bo;
  osd_text_double_buffer #(.FRAME_WIDTH(660),.FRAME_HEIGHT(20)) dut(
    .wr_clk(wc),.pix_clk(pc),.rst_n(rst),.wr_en(we),.wr_page(page),.wr_addr(addr),.wr_data(data),
    .wr_commit(commit),.wr_commit_page(commit_page),.wr_enable(en),.wr_x(wx),.wr_y(wy),.wr_color(color),
    .i_vs(vs),.i_hs(hs),.i_de(de),.i_r(r),.i_g(g),.i_b(b),
    .o_vs(ov),.o_hs(oh),.o_de(od),.o_r(ro),.o_g(go),.o_b(bo),.o_char_pixel(cp),
    .ack_toggle(ack),.active_page(active),.busy(busy));
  reg [7:0] font[0:4095],chars[0:255];string font_file;
  reg avs=0,aen=1,apage=0,seen=0;integer ax=16,ay=16,x=0,y=0;
  reg [23:0] acolor=24'h20ff40,expect_rgb,qr[0:1];reg [3:0] expect_flags,qflags[0:1];
  integer i,j,ch,row,col,pixels=0,lit=0;
  always @(posedge pc) begin
    if(!rst)begin x=0;y=0;avs=0;qflags[0]=0;qflags[1]=0;qr[0]=0;qr[1]=0;end
    else begin
      // Reference applies stable controls only at the frame boundary.
      if(vs&&!avs)begin
        x=0;y=0;aen=en;
        if(commit!=seen)begin apage=commit_page;ax=wx;ay=wy;acolor=color;seen=commit;end
      end
      expect_rgb={r,g,b};expect_flags={vs,hs,de,1'b0};
      if(aen&&de&&x>=ax&&x<ax+640&&y>=ay&&y<ay+16)begin
        ch=chars[apage*128+(x-ax)/8];row=y-ay;col=(x-ax)%8;
        if(font[ch*16+row][7-col])begin expect_rgb=acolor;expect_flags[0]=1;lit++;end
      end
      if(de)begin pixels++;if(x==659)begin x=0;if(y<19)y++;end else x++;end
      avs=vs;
      #1;
      if({ov,oh,od,cp,ro,go,bo}!=={qflags[1],qr[1]})
        $fatal(1,"OSD pixel/latency mismatch pixel=%0d got=%h expected=%h",pixels,{ov,oh,od,cp,ro,go,bo},{qflags[1],qr[1]});
      qflags[1]=qflags[0];qr[1]=qr[0];qflags[0]=expect_flags;qr[0]=expect_rgb;
    end
  end
  task fill(input bit p);
    integer n;
    begin
      page=p;
      for(n=0;n<80;n++)begin
        @(negedge wc);we=1;addr=n;data=n%3==0 ? "A" : n%3==1 ? "B" : " ";
        chars[p*128+n]=data;
      end
      @(negedge wc);we=0;
    end
  endtask
  task frame(input bit mid_disable);
    integer fx,fy;
    begin
      @(negedge pc);vs=1;de=0;hs=0;repeat(8)@(negedge pc);vs=0;
      for(fy=0;fy<20;fy++)begin
        for(fx=0;fx<660;fx++)begin
          de=1;hs=0;r=fx;g=fy;b=fx+fy;
          if(mid_disable&&fx==100&&fy==5)en=0;
          @(negedge pc);
        end
        de=0;hs=1;repeat(4)@(negedge pc);
      end
      de=0;hs=0;repeat(8)@(negedge pc);
    end
  endtask
  initial begin
    if(!$value$plusargs("font=%s",font_file))$fatal(1,"missing font oracle");
    $readmemh(font_file,font);
    for(i=0;i<256;i++)chars[i]=" ";
    chars[0]="H";chars[1]="E";chars[2]="L";chars[3]="L";chars[4]="O";chars[6]="S";chars[7]="O";chars[8]="C";
    repeat(3)@(negedge pc);rst=1;
    fill(1);@(negedge wc);commit=1;repeat(8)@(negedge pc);
    frame(1);frame(0);en=1;repeat(8)@(negedge pc);frame(0);
    fill(0);@(negedge wc);commit_page=0;commit=0;wx=7;wy=0;color=24'hf04689;
    repeat(8)@(negedge pc);frame(0);
    if(lit<100)$fatal(1,"oracle drew no glyphs");
    $display("PASS OSD BRAM: %0d exact pixels, both pages/all 80 characters, glyph edges/rows, color/position, frame enable and three-cycle RGB/DE/HS/VS",pixels);$finish;
  end
  initial begin #3000000;$fatal(1,"OSD pixel timeout");end
endmodule
