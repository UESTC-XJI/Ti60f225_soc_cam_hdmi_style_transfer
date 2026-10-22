`timescale 1ns/1ps
module video_status_counters_tb;
  logic clk=0,rst=0,fs=0,raw=0,disp=0,ov=0,uf=0,err=0,tick=0;
  always #5 clk=~clk;
  logic [31:0] cf,df,drop,under,ec;
  logic [15:0] cfps,dfps,rfps;
  video_status_counters dut(.clk,.rst_n(rst),.frame_start(fs),.raw_frame_start(raw),
    .display_frame_start(disp),.capture_overflow(ov),.display_underflow(uf),.axi_error(err),
    .interval_tick(tick),.capture_frames(cf),.display_frames(df),.drop_count(drop),
    .underflow_count(under),.error_count(ec),.capture_fps(cfps),.display_fps(dfps),.raw_fps(rfps));
  initial begin
    repeat(2) @(negedge clk);rst=1;
    // Independent rates: RAW=3, RESIZE=2, DISP=4; held faults count once.
    raw=1;fs=1;disp=1;ov=1;uf=1;err=1;
    @(negedge clk);fs=0;
    @(negedge clk);fs=1;
    @(negedge clk);raw=0;fs=0;
    @(negedge clk);disp=0;ov=0;uf=0;err=0;tick=1;
    @(negedge clk);tick=0;
    if(rfps!=3||cfps!=2||dfps!=4||cf!=2||df!=4||drop!=1||under!=1||ec!=1)
      $fatal(1,"independent frame rates mismatch");
    // Events on the closing tick belong to the window being latched.
    raw=1;fs=1;disp=1;err=1;tick=1;
    @(negedge clk);raw=0;fs=0;disp=0;err=0;tick=0;
    if(rfps!=1||cfps!=1||dfps!=1||ec!=2) $fatal(1,"tick boundary mismatch");
    tick=1;@(negedge clk);tick=0;
    if(rfps!=0||cfps!=0||dfps!=0) $fatal(1,"idle window did not clear rates");
    raw=1;fs=1;disp=1;repeat(65536) @(negedge clk);
    raw=0;fs=0;disp=0;tick=1;@(negedge clk);tick=0;
    if(rfps!=65535||cfps!=65535||dfps!=65535) $fatal(1,"rate saturation mismatch");
    rst=0;#1;
    if(rfps!=0||cfps!=0||dfps!=0||cf!=0||df!=0) $fatal(1,"reset mismatch");
    $display("PASS independent RAW/RESIZE/DISP windows, boundary events, idle, saturation and cumulative faults");
    $finish;
  end
endmodule
