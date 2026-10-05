`timescale 1ns/1ps
module ae_camera_stats_tb;
  reg clk=0,rst=0,vs=0,de=0;reg[15:0] raw=0;
  wire rv,rd;wire[47:0] rgb;wire valid,hot;wire[7:0] mean;wire[9:0] ratio;
  always #5 clk=~clk;
  debayer_top_2to1 #(.RAW_GREEN_FIRST(0)) camera(
    .in_pclk(clk),.in_rstn(rst),.raw_vs_i(vs),.raw_hs_i(1'b0),.raw_de_i(de),.raw_valid_i(de),
    .raw_datax4_i(raw),.r_gain(16'd256),.g_gain(16'd256),.b_gain(16'd256),
    .rgb_vs_o(rv),.rgb_de_o(rd),.rgb_datax2_o(rgb));
  ae_frame_stats stats(.clk(clk),.rst_n(rst),.i_vs(rv),.i_de(rd),.i_rgb(rgb),
    .i_high_threshold(8'd232),.o_valid(valid),.o_mean(mean),.o_highlights(hot),.o_high_permille(ratio));
  integer count=0,expected=40;
  always @(posedge clk) begin #1;if(valid) begin
    if(mean!==expected[7:0] || hot!==1'b0 || ratio!=0) $fatal(1,"Camera stats got %0d hot %b expected %0d",mean,hot,expected);
    count=count+1;
  end end
  task frame(input integer mode);
    integer x,y,oldcount;
    begin
      oldcount=count;expected=mode==0?40:100;
      @(negedge clk);vs=1;de=0;repeat(80) @(negedge clk);vs=0;repeat(50) @(negedge clk);
      for(y=0;y<1080;y=y+1) begin
        for(x=0;x<960;x=x+1) begin
          de=1;raw=mode==0?16'h2828:(y%2?16'h3c64:16'h648c);@(negedge clk);
        end
        de=0;repeat(40) @(negedge clk);
      end
      vs=1;repeat(80) @(negedge clk);
      if(count!=oldcount+1) $fatal(1,"Full 1920x1080 Debayer frame rejected by AE stats");
    end
  endtask
  initial begin
    repeat(5) @(negedge clk);rst=1;
    frame(0);frame(1);
    $display("PASS camera integration: two full 1920x1080 BGGR frames through gain/Debayer/stats");$finish;
  end
endmodule
