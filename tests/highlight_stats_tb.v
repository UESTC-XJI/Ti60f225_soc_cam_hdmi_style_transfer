`timescale 1ns/1ps
module highlight_stats_tb;
  reg clk=0,rst=0,vs=0,de=0;reg[47:0] rgb=0;reg[7:0] threshold=232;
  wire valid,hot;wire[7:0] mean;wire[9:0] ratio;
  ae_frame_stats #(.FRAME_WIDTH(64),.FRAME_HEIGHT(32),.MIN_SAMPLES(4)) dut(
    .clk(clk),.rst_n(rst),.i_vs(vs),.i_de(de),.i_rgb(rgb),.i_high_threshold(threshold),
    .o_valid(valid),.o_mean(mean),.o_highlights(hot),.o_high_permille(ratio));
  always #5 clk=~clk;
  integer results=0,em=0,eh=0,er=0;
  always @(posedge clk) begin #1;if(valid) begin
    if(mean!==em[7:0] || hot!==eh[0] || ratio!==er[9:0])
      $fatal(1,"stats got %0d/%0d/%0d expected %0d/%0d/%0d",mean,hot,ratio,em,eh,er);
    results=results+1;
  end end
  task frame(input integer mode,th,lines,badwidth,change_midframe);
    integer x,y,r0,g0,b0,r1,g1,b1,sum,count,fullcount,hotcount,startcount,t;
    begin
      startcount=results;sum=0;count=0;fullcount=0;hotcount=0;t=th<192?192:(th>254?254:th);
      @(negedge clk);threshold=th;vs=1;de=0;repeat(70) @(negedge clk);vs=0;@(negedge clk);
      for(y=0;y<lines;y=y+1) begin
        for(x=0;x<32-(badwidth && y==0);x=x+1) begin
          r0=20+x;g0=30+y;b0=40;r1=60;g1=50+x;b1=10+y;
          case(mode)
            1:if(x==0 && y==0) begin r0=255;r1=255;end // Bright corner outside ROI.
            2:begin r0=255;g0=255;b0=255;r1=255;g1=255;b1=255;end
            3:begin r0=t;g0=0;b0=0;r1=t-1;g1=0;b1=0;end
            4:if(x==0 && y==0) r0=240; // Non-integer permille must round down.
          endcase
          if(change_midframe && y==4) threshold=254;
          rgb={b1[7:0],g1[7:0],r1[7:0],b0[7:0],g0[7:0],r0[7:0]};de=1;
          if(x%8==0 && y%8==0) begin
            fullcount=fullcount+2;
            hotcount=hotcount+(r0>=t || g0>=t || b0>=t)+(r1>=t || g1>=t || b1>=t);
            if(x>=8 && x<24 && y>=8 && y<24) begin
              sum=sum+(r0+2*g0+b0)/4+(r1+2*g1+b1)/4;count=count+2;
            end
          end
          @(negedge clk);
        end
        de=0;repeat(4) @(negedge clk);
      end
      em=count?sum/count:0;eh=hotcount*64>fullcount;er=fullcount?hotcount*1000/fullcount:0;
      vs=1;repeat(70) @(negedge clk);
      if(results!=startcount+((lines==32 && !badwidth)?1:0)) $fatal(1,"stats frame validity");
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst=1;
    frame(0,232,32,0,0);frame(1,232,32,0,0);frame(2,232,32,0,0);
    frame(3,232,32,0,1);frame(4,232,32,0,0);frame(3,0,32,0,0);frame(3,255,32,0,0);
    frame(0,232,0,0,0);frame(0,232,20,0,0);frame(0,232,32,1,0);frame(1,232,32,0,0);
    $display("PASS full-frame stats: edge highlights, permille, ROI mean, threshold clamp/latch, invalid frames");$finish;
  end
endmodule
