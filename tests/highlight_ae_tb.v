`timescale 1ns/1ps
module highlight_ae_tb;
  reg clk=0,rst=0,en=0,sv=0,fs=0,wd=0,rd=0;
  reg protect=1,hot=1;reg[9:0] ratio=20;reg[7:0] mean=30,target=100,limitpermille=10,read_data=0;
  wire wr,read,ready,atlimit,fault,blocked;wire[15:0] addr,exposure,vts;wire[7:0] data,om;
  // Fast settings isolate the original I2C/state-machine behavior. Default
  // smoothing, small steps and persistence are exercised by ae_stability_tb.
  sc431hai_auto_exposure #(.EXPOSURE_PRIORITY_ENABLE(0),.FIXED_STEP_ENABLE(0),.WAIT_FRAMES(2),.TIMEOUT_CYCLES(80),
    .FILTER_SHIFT(0),.CONFIRM_FRAMES(1),.DEADBAND(8),.SETTLE_BAND(8),
    .SMALL_STEP_SHIFT(3),.LARGE_STEP_SHIFT(3),.RELEASE_FRAMES(1),.PREDICTIVE_ENABLE(0)) dut(
    .clk(clk),.rst_n(rst),.i_config_done(1'b1),.i_enable(en),.i_sensor_frame_start(fs),
    .i_stats_valid(sv),.i_highlights(hot),.i_mean(mean),.i_target(target),
    .o_wr_en(wr),.o_rd_en(read),.o_addr(addr),.o_data(data),.i_wr_done(wd),.i_rd_done(rd),
    .i_wr_error(1'b0),.i_rd_error(1'b0),.i_read_data(read_data),
    .o_exposure(exposure),.o_vts(vts),.o_mean(om),.o_ready(ready),.o_at_limit(atlimit),.o_error(fault),
    .i_high_protect(protect),.i_high_permille(ratio),.i_high_limit(limitpermille),.o_highlight_limited(blocked));
  always #5 clk=~clk;
  integer writes=0,initialexp=800;
  always @(negedge clk) begin
    wd=0;rd=0;
    if(read) begin
      case(addr)
        'h320e:read_data=5;'h320f:read_data=220;
        'h3e00:read_data=initialexp>>12;'h3e01:read_data=initialexp>>4;'h3e02:read_data=initialexp<<4;
      endcase
      rd=1;
    end
    if(wr) begin writes=writes+1;wd=1;end
  end
  task boot(input integer exp);
    begin
      @(negedge clk);rst=0;en=0;sv=0;fs=0;initialexp=exp;writes=0;
      repeat(3) @(negedge clk);rst=1;wait(ready);repeat(3) @(negedge clk);en=1;
    end
  endtask
  task sample(input integer m,h);
    begin @(negedge clk);mean=m;ratio=h;sv=1;@(negedge clk);sv=0;repeat(2) @(negedge clk);end
  endtask
  task update(input integer exp);
    begin
      if(dut.state!=5) $fatal(1,"AE update not pending");
      @(negedge clk);fs=1;@(negedge clk);fs=0;repeat(20) @(negedge clk);
      if(exposure!=exp || fault || !ready) $fatal(1,"AE high protection expected %0d got %0d",exp,exposure);
    end
  endtask
  initial begin
    boot(800);sample(30,20);update(700);
    if(!blocked) $fatal(1,"AE did not report highlight constraint");
    sample(30,7);sample(30,7);sample(30,7);
    if(dut.state!=4 || exposure!=700 || writes!=5 || !blocked) $fatal(1,"AE highlight hysteresis hold");
    sample(30,5);update(787);if(blocked) $fatal(1,"AE hysteresis release");
    sample(30,20);sample(30,20);sample(30,20);update(689);
    protect=0;sample(30,20);sample(30,20);sample(30,20);update(775);
    if(blocked) $fatal(1,"AE protection disabled");
    protect=1;boot(4);sample(30,1000);
    if(exposure!=4 || !atlimit || !blocked || writes) $fatal(1,"AE min exposure high protection");
    boot(800);limitpermille=0;sample(30,2);update(700); // limit zero clamps to1.
    sample(30,0);sample(30,0);sample(30,0);update(787);
    limitpermille=10;boot(800);sample(30,10);update(900); // exactly limit: not over.
    en=0;repeat(3) @(negedge clk);if(blocked) $fatal(1,"AE disable clears highlight hold");
    $display("PASS highlight AE: dark ROI overrides, cooldown, hysteresis, disable, threshold equality, minimum exposure");$finish;
  end
  initial begin #100000;$fatal(1,"AE watchdog");end
endmodule
