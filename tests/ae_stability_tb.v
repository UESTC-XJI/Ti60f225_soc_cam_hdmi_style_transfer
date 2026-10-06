`timescale 1ns/1ps
// Shipping cadence: two settling frames plus two confirmation frames.
module ae_stability_tb;
  reg clk=0,rst=0,en=0,sv=0,fs=0,wd=0,rd=0;
  reg protect=1;reg[9:0] ratio=0;reg[7:0] mean=100,target=100,read_data=0;
  wire wr,read,ready,fault,blocked;wire[15:0] addr,exposure,vts;wire[7:0] data,om;
  sc431hai_auto_exposure #(.EXPOSURE_PRIORITY_ENABLE(0),.FIXED_STEP_ENABLE(0),.PREDICTIVE_ENABLE(1),.FAST_RECOVERY_FRAMES(8),.TIMEOUT_CYCLES(1000)) dut(
    .clk(clk),.rst_n(rst),.i_config_done(1'b1),.i_enable(en),.i_sensor_frame_start(fs),
    .i_stats_valid(sv),.i_highlights(ratio>15),.i_mean(mean),.i_target(target),
    .o_wr_en(wr),.o_rd_en(read),.o_addr(addr),.o_data(data),.i_wr_done(wd),.i_rd_done(rd),
    .i_wr_error(1'b0),.i_rd_error(1'b0),.i_read_data(read_data),
    .o_exposure(exposure),.o_vts(vts),.o_mean(om),.o_ready(ready),.o_at_limit(),.o_error(fault),
    .i_high_protect(protect),.i_high_permille(ratio),.i_high_limit(8'd10),.o_highlight_limited(blocked));
  always #5 clk=~clk;
  integer writes=0,initialexp=800,j,k,beforewrites,changes,lastchange,newchange;
  integer exposure_history[0:2],four_frame_updates;
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
    integer wait_cycles;
    begin
      wait_cycles=0;
      while(dut.state!=5 && wait_cycles<40) begin @(negedge clk);wait_cycles=wait_cycles+1;end
      if(dut.state!=5) $fatal(1,"stability update not pending");
      @(negedge clk);fs=1;@(negedge clk);fs=0;repeat(20) @(negedge clk);
      if(exposure!=exp || fault || !ready) $fatal(1,"stability expected %0d got %0d",exp,exposure);
    end
  endtask
  task unchanged(input integer expected);
    begin if(dut.state!=4 || exposure!=expected || fault)
      $fatal(1,"unexpected state=%0d exposure=%0d expected=%0d fault=%0d mean=%0d filtered=%0d ratio=%0d blocked=%0d j=%0d",dut.state,exposure,expected,fault,mean,dut.mean_control,dut.high_control,blocked,j);end
  endtask
  task scene(input integer goal,start_exposure,start_luma,black,max_changes,latency);
    integer n,y,steps,previous,wait_cycles;
    begin
      boot(start_exposure);protect=0;target=goal;steps=0;
      exposure_history[0]=start_exposure;exposure_history[1]=start_exposure;exposure_history[2]=start_exposure;
      for(n=0;n<120;n=n+1) begin
        y=black+exposure_history[latency-1]*(start_luma-black)/start_exposure;
        if(y>255)y=255;
        exposure_history[2]=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
        sample(y,0);
        if(dut.state==9 || dut.state==10 || dut.state==5) begin
          wait_cycles=0;
          while(dut.state!=5 && wait_cycles<40) begin @(negedge clk);wait_cycles=wait_cycles+1;end
          if(dut.state!=5) $fatal(1,"scene prediction did not finish");
          previous=exposure;newchange=dut.pending;
          if((start_luma>goal && newchange>=previous) || (start_luma<goal && newchange<=previous))
            $fatal(1,"scene oscillated across target");
          settled(newchange);steps=steps+1;
        end
      end
      y=black+exposure*(start_luma-black)/start_exposure;
      unchanged(exposure);
      if(steps==0 || steps>max_changes || y<goal-6 || y>goal+6)
        $fatal(1,"scene convergence target=%0d start=%0d black=%0d steps=%0d final=%0d",goal,start_luma,black,steps,y);
      $display("PREDICTIVE SCENE target=%0d initial_mean=%0d initial_exposure=%0d black=%0d updates=%0d final_mean=%0d",goal,start_luma,start_exposure,black,steps,y);
    end
  endtask
  // Static dark ROI with a bright window: mean target is physically incompatible
  // with highlight protection. A steep clipping threshold must not cause jumps.
  task highlight_scene;
    integer n,y,h,old_exp,updates,wait_cycles,seen_limit;
    begin
      boot(1983);target=100;updates=0;seen_limit=0;
      exposure_history[0]=1983;exposure_history[1]=1983;exposure_history[2]=1983;
      for(n=0;n<800;n=n+1) begin
        old_exp=exposure_history[2];y=old_exp/30;h=old_exp>1900 ? 20 : 0;
        exposure_history[2]=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
        sample(y,h);
        if(blocked) seen_limit=1;
        if(dut.state==9 || dut.state==10 || dut.state==5) begin
          wait_cycles=0;
          while(dut.state!=5 && wait_cycles<40) begin @(negedge clk);wait_cycles=wait_cycles+1;end
          if(dut.state!=5) $fatal(1,"highlight scene prediction did not finish");
          old_exp=exposure;newchange=dut.pending;
          if(seen_limit && newchange>old_exp && newchange-old_exp>old_exp/16+1)
            $fatal(1,"highlight recovery jumped: %0d -> %0d",old_exp,newchange);
          settled(newchange);updates=updates+1;
        end
      end
      if(!seen_limit || fault || exposure>1940 || exposure<1800 || updates>230)
        $fatal(1,"highlight scene hunts: exposure=%0d updates=%0d",exposure,updates);
      $display("PASS highlight closed loop: 3-frame latency, steep clipping, bounded recovery; exposure=%0d updates=%0d",exposure,updates);
    end
  endtask
  // Reproduce the reported stuck state by first learning a tiny safe ceiling.
  // Then remove excess highlights and verify enabled protection permits recovery.
  task dark_recovery(input integer occupancy,max_frames);
    integer n,wait_cycles,y,seen_recovery;
    begin
      boot(67);target=96;seen_recovery=0;
      sample(23,20);sample(23,20);settled(65);
      if(!dut.ceiling_valid || !blocked) $fatal(1,"tiny ceiling not learned");
      for(n=0;n<max_frames;n=n+1) begin
        y=16+exposure*7/65;
        sample(y,occupancy);
        if(dut.state==9 || dut.state==10 || dut.state==5) begin
          wait_cycles=0;
          while(dut.state!=5 && wait_cycles<40) begin @(negedge clk);wait_cycles=wait_cycles+1;end
          if(dut.state!=5) $fatal(1,"dark recovery prediction did not finish");
          newchange=dut.pending;
          if(newchange>exposure) seen_recovery=1;
          if(newchange>exposure && newchange-exposure>(exposure/16<4?4:exposure/16)+1)
            $fatal(1,"dark recovery jumped");
          settled(newchange);
        end
      end
      if(fault || (occupancy<10 && !seen_recovery) || (occupancy==2 && y<90) || ((occupancy==6 || occupancy==7) && y<90) || (occupancy==10 && (exposure!=65 || seen_recovery)))
        $fatal(1,"dark recovery stuck occupancy=%0d exposure=%0d mean=%0d",occupancy,exposure,y);
      $display("PASS dark recovery highlights=%0d exposure=%0d mean=%0d frames=%0d",occupancy,exposure,y,max_frames);
    end
  endtask
  initial begin
    dark_recovery(2,800);
    dark_recovery(6,1200);
    dark_recovery(7,1200);
    dark_recovery(10,200);
    highlight_scene();
    boot(800);sample(100,0);
    for(j=0;j<80;j=j+1) sample(90+j%21, j%11);
    unchanged(800);if(writes) $fatal(1,"small scene jitter caused writes");
    sample(140,20);
    for(j=0;j<20;j=j+1) sample(100,0);
    unchanged(800);if(writes) $fatal(1,"brief bright scene/highlight caused writes");
    boot(800);sample(80,0);unchanged(800);
    sample(80,0);settled(900); // goal=1000; halfway=900.
    for(j=0;j<2;j=j+1) sample(240,1000); // Old bright frames in the settling interval.
    unchanged(900);if(blocked || dut.filter_valid) $fatal(1,"cooldown retained stale stats");
    sample(80,0);unchanged(900);
    sample(80,0);settled(1012);
    boot(800);sample(20,0);unchanged(800);
    sample(20,0);settled(1600); // Clamped goal=2989; increase capped at current exposure.
    boot(800);sample(120,0);unchanged(800);
    sample(120,0);settled(733);
    for(j=0;j<2;j=j+1) sample(0,0);
    for(j=0;j<12;j=j+1) sample(100,0);
    unchanged(733);if(writes!=5) $fatal(1,"old dark frames caused reverse adjustment");
    boot(800);sample(30,20);unchanged(800);
    sample(30,20);settled(775);
    if(!blocked) $fatal(1,"persistent highlights not protected");
    for(j=0;j<2;j=j+1) sample(30,7);
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
    k=0;
    while(dut.state==4 && k<40) begin sample(30,0);k=k+1;end
    if(k<8 || k>12) $fatal(1,"recovery ceiling relaxed without eight stable frames");
    settled(823); // floor(775/16)=48; bounded recovery with low highlights.
    protect=0;repeat(3) @(negedge clk);
    sample(30,0);sample(30,0);sample(30,0);sample(30,0);settled(1646); // Explicitly disabling protection restores prediction.
    // Closed-loop scene includes TWO stale output frames and +/-3 code noise.
    // Long run must converge inside the deadband and stop, without reversing.
    boot(800);protect=0;target=96;changes=0;lastchange=-100;
    exposure_history[0]=800;exposure_history[1]=800;four_frame_updates=0;
    for(j=0;j<400;j=j+1) begin
      newchange=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
      sample(newchange*96/1000+(j%7)-3,0);
      if(dut.state==9 || dut.state==10 || dut.state==5) begin
        k=0;while(dut.state!=5 && k<40) begin @(negedge clk);k=k+1;end
        if(dut.state!=5) $fatal(1,"prediction did not finish");newchange=dut.pending;
        if(j-lastchange==4) four_frame_updates=four_frame_updates+1;
        if(newchange<=exposure || newchange-exposure>exposure || j-lastchange<4)
          $fatal(1,"closed-loop step/direction/interval instability");
        settled(newchange);changes=changes+1;lastchange=j;
      end
    end
    if(changes==0 || four_frame_updates==0 || lastchange>300 || exposure*96/1000<84 || exposure*96/1000>108)
      $fatal(1,"static scene failed to converge and settle");
    beforewrites=writes;
    for(j=0;j<100;j=j+1) sample(exposure*96/1000+(j%7)-3,0);
    unchanged(exposure);if(writes!=beforewrites) $fatal(1,"static scene hunts after convergence");
    boot(1200);protect=0;target=96;changes=0;lastchange=-100;
    exposure_history[0]=1200;exposure_history[1]=1200;four_frame_updates=0;
    for(j=0;j<500;j=j+1) begin
      newchange=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
      sample(newchange*96/1000+(j%7)-3,0);
      if(dut.state==9 || dut.state==10 || dut.state==5) begin
        k=0;while(dut.state!=5 && k<40) begin @(negedge clk);k=k+1;end
        if(dut.state!=5) $fatal(1,"prediction did not finish");newchange=dut.pending;
        if(j-lastchange==4) four_frame_updates=four_frame_updates+1;
        if(newchange>=exposure || exposure-newchange>exposure/4 || j-lastchange<4)
          $fatal(1,"bright closed-loop direction/step/interval instability");
        settled(newchange);changes=changes+1;lastchange=j;
      end
    end
    unchanged(exposure);
    if(changes==0 || four_frame_updates==0 || lastchange>400 || exposure*96/1000<84 || exposure*96/1000>108)
      $fatal(1,"bright scene failed to converge and settle");
    scene(100,1983,196,0,4,2);
    scene(128,500,32,0,5,2);
    scene(100,500,32,16,10,2);
    scene(100,1983,396,0,10,2); // Sensor/output clipping above255.
    scene(100,1983,196,0,6,3);
    scene(128,500,32,0,8,3);
    en=0;repeat(3) @(negedge clk);
    if(dut.filter_valid || blocked || dut.confirm_count) $fatal(1,"disable retains history");
    $display("PASS AE stability: prediction, four-frame cadence, two-frame confirmation, settling reset, highlight hold/release and noisy closed-loop convergence with two-/three-frame display latency");$finish;
  end
  initial begin #1000000;$fatal(1,"stability watchdog");end
endmodule
