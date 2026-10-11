`timescale 1ns/1ps
module ae_camera_stats_tb;
  reg clk=0,rst=0,vs=0,de=0;reg[15:0] raw=0;
  wire rv,rd;wire[47:0] rgb;wire valid,hot;wire[7:0] mean;wire[9:0] ratio;
  always #5 clk=~clk;
  debayer_top_2to1 #(.RAW_GREEN_FIRST(0)) camera(
    .in_pclk(clk),.in_rstn(rst),.raw_vs_i(vs),.raw_hs_i(1'b0),.raw_de_i(de),.raw_valid_i(de),
    .raw_datax4_i(raw),.r_gain(16'd256),.g_gain(16'd256),.b_gain(16'd256),
    .rgb_vs_o(rv),.rgb_de_o(rd),.rgb_datax2_o(rgb));
  ae_frame_stats #(.FULL_FRAME_MEAN(1)) stats(.clk(clk),.rst_n(rst),.i_vs(rv),.i_de(rd),.i_rgb(rgb),
    .i_high_threshold(8'd232),.o_valid(valid),.o_mean(mean),.o_highlights(hot),.o_high_permille(ratio));
  integer count=0,expected=0,output_x=0,output_y=0,reference_sum=0,reference_count=0;
  reg previous_vs=0,previous_de=0;
  // Full-frame reference includes Debayer's border pixels, which do not have
  // the same neighborhood as interior pixels even for a constant RAW frame.
  always @(posedge clk) if(rst) begin
    if(rd && !rv && output_x%8==0 && output_y%8==0) begin
      reference_sum=reference_sum+(rgb[7:0]+2*rgb[15:8]+rgb[23:16])/4+
        (rgb[31:24]+2*rgb[39:32]+rgb[47:40])/4;
      reference_count=reference_count+2;
    end
    if(!rd) output_x=0;else output_x=output_x+1;
    if(previous_de && !rd) output_y=output_y+1;
    if(previous_vs && !rv) begin output_x=0;output_y=0;end
    if(rv && !previous_vs) begin
      if(reference_count!=0) begin
        if(reference_count!=32400) $fatal(1,"full-frame exposure sample count %0d",reference_count);
        expected=reference_sum/reference_count;
      end
      reference_sum=0;reference_count=0;
    end
    previous_vs=rv;previous_de=rd;
  end
  always @(posedge clk) begin #1;if(valid) begin
    if(mean!==expected[7:0] || hot!==1'b0 || ratio!=0) $fatal(1,"Camera stats got %0d hot %b expected %0d",mean,hot,expected);
    count=count+1;
  end end
  task frame(input integer mode);
    integer x,y,oldcount;
    begin
      oldcount=count;
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
