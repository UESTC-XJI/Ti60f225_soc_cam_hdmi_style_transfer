`timescale 1ns/1ps
module video_status_counters_tb;
  logic clk=0,rst=0,fs=0,ov=0,uf=0,err=0,tick=0; always #5 clk=~clk;
  logic [31:0] cf,df,drop,under,ec; logic [15:0] cfps,dfps;
  video_status_counters dut(.clk,.rst_n(rst),.frame_start(fs),.capture_overflow(ov),.display_underflow(uf),.axi_error(err),.interval_tick(tick),.capture_frames(cf),.display_frames(df),.drop_count(drop),.underflow_count(under),.error_count(ec),.capture_fps(cfps),.display_fps(dfps));
  initial begin repeat(2) @(posedge clk);rst=1;fs=1;@(posedge clk);fs=0;ov=1;uf=1;err=1;@(posedge clk);ov=0;uf=0;err=0;fs=1;@(posedge clk);fs=0;tick=1;@(posedge clk);tick=0; err=1;@(posedge clk);err=0; if(cfps!=2||dfps!=2||drop!=1||under!=1||ec!=2) $fatal(1,"video status counters mismatch"); $display("PASS concurrent video status counters");$finish;end
endmodule
