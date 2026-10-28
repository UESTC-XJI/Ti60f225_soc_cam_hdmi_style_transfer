`timescale 1ns/1ps
module hdmi_overlay_tb #(parameter FULL=0);
  localparam W=FULL==2?1280:(FULL?1920:320),H=FULL==2?720:(FULL?1080:192),M=16,PH=128,TOP=H-M-PH-2;
  localparam SAMPLES=((W+15)/16)*((H+7)/8);
  reg clk=0,rst=0,vs=0,hs=0,de=0,enable=0,text_enable=0,text_valid=0;
  reg [1:0] mode=0;
  reg [7:0] r=0,g=0,b=0;
  wire ov,oh,od,hv;wire [7:0] ro,go,bo;wire [15:0] samples;
  hdmi_info_overlay #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) dut(
    .clk(clk),.rst_n(rst),.i_vs(vs),.i_hs(hs),.i_de(de),.i_r(r),.i_g(g),.i_b(b),
    .i_hist_enable(enable),.i_hist_mode(mode),.i_text_enable(text_enable),
    .i_text_valid(text_valid),.i_text_rgb(24'h123456),.o_x(),.o_y(),
    .o_hist_valid(hv),.o_hist_samples(samples),.o_vs(ov),.o_hs(oh),.o_de(od),.o_r(ro),.o_g(go),.o_b(bo));
  always #5 clk=~clk;
  integer counts[0:63],heights[0:63];
  integer xx=0,yy=0,frame_count=0,pixels=0,n,j,k,peak,value,idx,rr,gg,bb;
  reg prev_vs=0,prev_de=0,frame_enable=0,frame_text=0,reference_valid=0;
  reg [1:0] frame_mode=0;
  reg qv=0,qh=0,qd=0;reg [23:0] qr=0,expected;
  // Independent software-style pixel compositor and two-cycle sync oracle.
  always @(posedge clk) if(rst) begin
    if(prev_vs && !vs) begin
      xx=0;yy=0;frame_enable=enable;frame_text=text_enable;
      if(frame_mode!=mode) reference_valid=0;
      frame_mode=mode;
    end
    rr=r;gg=g;bb=b;
    if(de && !vs) begin
      pixels=pixels+1;
      if(frame_enable && xx>=M && xx<M+258 && yy>=TOP && yy<TOP+130) begin
        if(xx==M || xx==M+257 || yy==TOP || yy==TOP+129) begin rr=192;gg=192;bb=192;end
        else if(reference_valid && TOP+PH-yy<heights[(xx-M-1)/4]) begin
          case(frame_mode)
            0: begin rr=64;gg=224;bb=224;end
            1: begin rr=255;gg=64;bb=64;end
            2: begin rr=64;gg=255;bb=64;end
            3: begin rr=96;gg=128;bb=255;end
          endcase
        end else begin rr=r/2;gg=g/2;bb=b/2;end
      end
      if(frame_text && text_valid && xx>=M && xx<M+320 && yy>=M && yy<M+64) begin rr=18;gg=52;bb=86;end
    end
    expected={rr[7:0],gg[7:0],bb[7:0]};
    if(!de) xx=0;else xx=xx+1;
    if(prev_de && !de) yy=yy+1;
    prev_vs=vs;prev_de=de;
    #1;
    if({ov,oh,od,ro,go,bo}!={qv,qh,qd,qr})
      $fatal(1,"overlay pixel/sync mismatch frame=%0d xy=%0d,%0d got=%h expected=%h",frame_count,xx,yy,{ro,go,bo},qr);
    qv=vs;qh=hs;qd=de;qr=expected;
  end
  task blank;
    begin
      @(negedge clk);vs=1;de=0;hs=0;text_valid=0;
      repeat(1800) @(negedge clk);
    end
  endtask
  task image(input integer channel,show,textshow,partial);
    integer x,y,l,bin,total;
    begin
      enable=show;mode=channel;text_enable=textshow;
      for(j=0;j<64;j=j+1) counts[j]=0;
      @(negedge clk);vs=0;de=0;@(negedge clk);
      for(y=0;y<(partial?H/2:H);y=y+1) begin
        for(x=0;x<W;x=x+1) begin
          r=((x/16+y/8*20)%64)*4;g=255-r;b=37;
          de=1;hs=0;text_valid=textshow && x%3==0;
          if(x%16==0 && y%8==0) begin
            l=channel==1?r:channel==2?g:channel==3?b:(r+2*g+b)/4;
            bin=l/4;counts[bin]=counts[bin]+1;
          end
          // Must not affect this frame's enable or channel selection.
          if(y==100 && x==100) begin enable=!show;mode=(channel+1)%4;text_enable=!textshow;end
          @(negedge clk);
        end
        de=0;hs=1;repeat(4) @(negedge clk);
      end
      blank();frame_count=frame_count+1;
      if(partial) begin
        if(hv || samples!=0) $fatal(1,"partial frame histogram published");
        reference_valid=0;
      end else begin
        if(!hv || samples!=SAMPLES) $fatal(1,"hist sample count=%0d valid=%0d",samples,hv);
        peak=0;total=0;
        for(j=0;j<64;j=j+1) begin if(counts[j]>peak) peak=counts[j];total=total+counts[j];end
        if(total!=SAMPLES) $fatal(1,"oracle samples");
        for(j=0;j<64;j=j+1) begin
          heights[j]=counts[j]*128/peak;
          if(dut.histogram.heights[j]!=heights[j]) $fatal(1,"hist channel=%0d bin=%0d got=%0d expected=%0d",channel,j,dut.histogram.heights[j],heights[j]);
        end
        reference_valid=1;
      end
    end
  endtask
  initial begin
    for(n=0;n<64;n=n+1) begin counts[n]=0;heights[n]=0;end
    repeat(4) @(negedge clk);rst=1;blank();
    if(FULL) begin image(0,0,0,0);image(0,1,0,0);end
    else begin
    image(0,0,0,0);image(0,1,0,0);image(0,1,0,0);
    image(1,1,0,0);image(1,1,0,0);
    image(2,1,0,0);image(2,1,0,0);
    image(3,1,0,0);image(3,1,1,0);
    image(3,0,0,1);image(0,0,0,0);image(0,1,0,0);
    end
    repeat(4) @(negedge clk);
    $display("PASS HDMI overlay: %0d pixels, Y/R/G/B exact counts and peak scaling, previous-frame snapshot, bottom-left composition, bypass/sync, frame controls, text reservation, partial-frame recovery",pixels);$finish;
  end
  initial begin #100000000;$fatal(1,"overlay timeout");end
endmodule
