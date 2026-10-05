`timescale 1ns/1ps
// Exercise shipping defaults, including WAIT_FRAMES=8, against scene changes.
module ae_stability_tb;
  reg clk=0,rst=0,en=0,sv=0,fs=0,wd=0,rd=0;
  reg protect=1;reg[9:0] ratio=0;reg[7:0] mean=100,target=100,read_data=0;
  wire wr,read,ready,fault,blocked;wire[15:0] addr,exposure,vts;wire[7:0] data,om;
  sc431hai_auto_exposure #(.TIMEOUT_CYCLES(1000)) dut(
    .clk(clk),.rst_n(rst),.i_config_done(1'b1),.i_enable(en),.i_sensor_frame_start(fs),
    .i_stats_valid(sv),.i_highlights(ratio>15),.i_mean(mean),.i_target(target),
    .o_wr_en(wr),.o_rd_en(read),.o_addr(addr),.o_data(data),.i_wr_done(wd),.i_rd_done(rd),
    .i_wr_error(1'b0),.i_rd_error(1'b0),.i_read_data(read_data),
    .o_exposure(exposure),.o_vts(vts),.o_mean(om),.o_ready(ready),.o_at_limit(),.o_error(fault),
    .i_high_protect(protect),.i_high_permille(ratio),.i_high_limit(8'd10),.o_highlight_limited(blocked));
  always #5 clk=~clk;
  integer writes=0,initialexp=800,j,k,beforewrites,changes,lastchange,newchange;
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
      @(negedge clk);rst=0;en=0;sv=0;fs=0;initialexp=exp;writes=0;protect=1;target=100;
      repeat(3) @(negedge clk);rst=1;wait(ready);repeat(3) @(negedge clk);en=1;
    end
  endtask
  task sample(input integer m,h);
    begin @(negedge clk);mean=m;ratio=h;sv=1;@(negedge clk);sv=0;repeat(2) @(negedge clk);end
  endtask
  task settled(input integer exp);
    begin
      if(dut.state!=5) $fatal(1,"stability update not pending");
      @(negedge clk);fs=1;@(negedge clk);fs=0;repeat(20) @(negedge clk);
      if(exposure!=exp || fault || !ready) $fatal(1,"stability expected %0d got %0d",exp,exposure);
    end
  endtask
  task unchanged(input integer expected);
    begin if(dut.state!=4 || exposure!=expected || fault)
      $fatal(1,"unexpected state=%0d exposure=%0d expected=%0d fault=%0d mean=%0d filtered=%0d ratio=%0d blocked=%0d j=%0d",dut.state,exposure,expected,fault,mean,dut.mean_control,dut.high_control,blocked,j);end
  endtask
  initial begin
    boot(800);sample(100,0);
    for(j=0;j<80;j=j+1) sample(90+j%21, j%11);
    unchanged(800);if(writes) $fatal(1,"small scene jitter caused writes");
    sample(140,20);sample(140,0);
    for(j=0;j<20;j=j+1) sample(100,0);
    unchanged(800);if(writes) $fatal(1,"brief bright scene/highlight caused writes");
    boot(800);sample(80,0);sample(80,0);sample(80,0);unchanged(800);
    sample(80,0);settled(812); // Near target: floor(800/64)=12.
    for(j=0;j<8;j=j+1) sample(240,1000); // Old bright frames in the settling interval.
    unchanged(812);if(blocked || dut.filter_valid) $fatal(1,"cooldown retained stale stats");
    sample(80,0);sample(80,0);sample(80,0);unchanged(812);
    sample(80,0);settled(824);
    boot(800);sample(20,0);sample(20,0);sample(20,0);unchanged(800);
    sample(20,0);settled(825); // Large error: floor(800/32)=25.
    boot(800);sample(120,0);sample(120,0);sample(120,0);unchanged(800);
    sample(120,0);settled(788);
    for(j=0;j<8;j=j+1) sample(0,0);
    for(j=0;j<12;j=j+1) sample(100,0);
    unchanged(788);if(writes!=5) $fatal(1,"old dark frames caused reverse adjustment");
    boot(800);sample(30,20);sample(30,20);sample(30,20);unchanged(800);
    sample(30,20);settled(775);
    if(!blocked) $fatal(1,"persistent highlights not protected");
    for(j=0;j<8;j=j+1) sample(30,7);
    for(j=0;j<20;j=j+1) sample(30,7);
    unchanged(775);if(!blocked || writes!=5) $fatal(1,"highlight hold unstable");
    sample(30,0);sample(30,0);sample(30,0);sample(30,7);
    unchanged(775);if(!blocked) $fatal(1,"brief highlight relief released hold");
    for(j=0;j<8;j=j+1) sample(30,10);
    unchanged(775);if(!blocked) $fatal(1,"release persistence reset failed");
    k=0;
    while(blocked && k<40) begin sample(30,0);k=k+1;end
    if(blocked || k<8) $fatal(1,"release did not require persistent low highlights");
    unchanged(775);
    sample(30,0);sample(30,0);sample(30,0);sample(30,0);settled(799);
    // Closed-loop linear scene: actual mean tracks exposure, with +/-3 code noise.
    // Long run must converge inside the deadband and stop, without reversing.
    boot(800);protect=0;target=96;changes=0;lastchange=-100;
    for(j=0;j<400;j=j+1) begin
      sample(exposure*96/1000+(j%7)-3,0);
      if(dut.state==5) begin
        newchange=dut.pending;
        if(newchange<=exposure || newchange-exposure>exposure/32 || j-lastchange<12)
          $fatal(1,"closed-loop step/direction/interval instability");
        settled(newchange);changes=changes+1;lastchange=j;
      end
    end
    if(changes==0 || lastchange>300 || exposure*96/1000<84 || exposure*96/1000>108)
      $fatal(1,"static scene failed to converge and settle");
    beforewrites=writes;
    for(j=0;j<100;j=j+1) sample(exposure*96/1000+(j%7)-3,0);
    unchanged(exposure);if(writes!=beforewrites) $fatal(1,"static scene hunts after convergence");
    boot(1200);protect=0;target=96;changes=0;lastchange=-100;
    for(j=0;j<500;j=j+1) begin
      sample(exposure*96/1000+(j%7)-3,0);
      if(dut.state==5) begin
        newchange=dut.pending;
        if(newchange>=exposure || exposure-newchange>exposure/32 || j-lastchange<12)
          $fatal(1,"bright closed-loop direction/step/interval instability");
        settled(newchange);changes=changes+1;lastchange=j;
      end
    end
    unchanged(exposure);
    if(changes==0 || lastchange>400 || exposure*96/1000<84 || exposure*96/1000>108)
      $fatal(1,"bright scene failed to converge and settle");
    en=0;repeat(3) @(negedge clk);
    if(dut.filter_valid || blocked || dut.confirm_count) $fatal(1,"disable retains history");
    $display("PASS AE stability: default filtering, four-frame confirmation, 1/64 and 1/32 steps, settling reset, sustained highlight release and noisy closed-loop convergence");$finish;
  end
  initial begin #1000000;$fatal(1,"stability watchdog");end
endmodule
