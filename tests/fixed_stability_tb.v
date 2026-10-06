`timescale 1ns/1ps
// Shipping cadence: two settling frames plus two confirmation frames.
module fixed_stability_tb;
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
  task loop_scene(input integer initial_exposure,goal,scale,black,occupancy,learn_limit);
    integer n,y,old_exp,steps,first_stable,high,previous,near_step;
    begin
      boot(initial_exposure);target=goal;protect=learn_limit;
      if(learn_limit) begin
        sample(30,20);sample(30,20);settled(initial_exposure-32);
      end
      exposure_history[0]=exposure;exposure_history[1]=exposure;exposure_history[2]=exposure;
      steps=0;first_stable=-1;
      for(n=0;n<700;n=n+1) begin
        old_exp=exposure_history[2];
        exposure_history[2]=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
        y=black+old_exp*scale/1000;
        if(y>255)y=255;
        high=occupancy;
        sample(y,high);
        if(dut.state==9 || dut.state==10) $fatal(1,"shipping fixed mode used divider");
        if(dut.state==5) begin
          previous=exposure;newchange=dut.pending;
          if(learn_limit && newchange>previous && newchange-previous>(occupancy<=5?128:32))
            $fatal(1,"fixed highlight recovery exceeded guard");
          settled(newchange);steps=steps+1;
          if(first_stable>=0 && n>first_stable+60) $fatal(1,"fixed static scene hunts");
        end
        if(y>=goal-4 && y<=goal+4 && first_stable<0) first_stable=n;
      end
      if(first_stable<0 || fault || steps==0) $fatal(1,"fixed loop failed e=%0d mean=%0d steps=%0d",exposure,y,steps);
      $display("PASS fixed loop initial=%0d target=%0d occupancy=%0d steps=%0d settled_frame=%0d final_mean=%0d",initial_exposure,goal,occupancy,steps,first_stable,y);
      // Sustained +/-1 measurement noise must keep the converged exposure.
      beforewrites=writes;
      for(n=0;n<100;n=n+1) sample(y+n%3-1,occupancy);
      if(writes!=beforewrites) $fatal(1,"fixed noise hunts after settling");
    end
  endtask
  task window_scene;
    integer n,e,y,h,late_writes;
    begin
      boot(1983);target=100;protect=1;
      exposure_history[0]=1983;exposure_history[1]=1983;exposure_history[2]=1983;
      late_writes=0;
      for(n=0;n<700;n=n+1) begin
        e=exposure_history[2];y=e/30;h=e>1900?20:0;
        exposure_history[2]=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
        sample(y,h);
        if(dut.state==5) settled(dut.pending);
        if(n==300) late_writes=writes;
      end
      if(writes!=late_writes) $fatal(1,"static bright window causes recurring exposure updates: %0d ->%0d",late_writes,writes);
      if(exposure>1900 || exposure<1800 || !dut.o_exposure_constrained) $fatal(1,"window exposure not at safe boundary");
      $display("PASS static window exposure holds at %0d",exposure);
      // Removing the bright window lowers the mean at the same exposure.
      // Persistent scene change must invalidate the learned boundary.
      for(n=0;n<100;n=n+1) begin
        sample(30,0);
        if(dut.state==5) settled(dut.pending);
      end
      if(exposure<=2000 || dut.ceiling_valid)
        $fatal(1,"dark scene change failed to restore exposure priority");
      $display("PASS changed scene clears stale window boundary and recovers exposure=%0d",exposure);
    end
  endtask
  task lamp_to_dark;
    integer n;
    begin
      boot(100);target=100;protect=1;
      // An intense lamp remains clipped down to the physical exposure floor.
      for(n=0;n<100;n=n+1) begin
        sample(100,100);
        if(dut.state==5) settled(dut.pending);
      end
      if(exposure!=4 || !dut.ceiling_valid) $fatal(1,"lamp did not learn minimum boundary");
      // A remaining highlight must not trigger the zero-highlight escape.
      for(n=0;n<100;n=n+1) begin
        sample(20,1);
        if(dut.state==5) settled(dut.pending);
      end
      if(exposure!=4 || !dut.ceiling_valid) $fatal(1,"nonzero highlights released minimum boundary");
      // RAW black pedestal stays near 20 even after pointing away from lamp.
      // No eight-code mean drop is available to the old scene-change detector.
      for(n=0;n<40;n=n+1) begin
        sample(20,0);
        if(dut.state==5) settled(dut.pending);
      end
      if(exposure<=64 || dut.ceiling_valid)
        $fatal(1,"zero-highlight dark scene stuck at lamp boundary: exposure=%0d mean=%0d",exposure,om);
      exposure_history[0]=exposure;exposure_history[1]=exposure;exposure_history[2]=exposure;
      for(n=0;n<700;n=n+1) begin
        sample(20+exposure_history[2]/30,0);
        exposure_history[2]=exposure_history[1];exposure_history[1]=exposure_history[0];exposure_history[0]=exposure;
        if(dut.state==5) settled(dut.pending);
      end
      if(om<96 || om>104 || dut.ceiling_valid || dut.o_exposure_constrained)
        $fatal(1,"lamp-to-dark recovery did not converge: exposure=%0d mean=%0d",exposure,om);
      $display("PASS lamp-to-dark floor escape and convergence exposure=%0d mean=%0d",exposure,om);
    end
  endtask
  initial begin
    lamp_to_dark();
    window_scene();
    loop_scene(65,96,108,16,0,0);
    loop_scene(1983,100,99,0,0,0);
    loop_scene(500,128,64,0,0,0);


    // Short highlight spikes do not trigger a transaction under production smoothing.
    boot(800);sample(100,0);sample(100,20);
    for(j=0;j<50;j=j+1) sample(100,0);
    unchanged(800);if(writes) $fatal(1,"fixed single-frame highlight triggered update");
    $display("PASS shipping fixed stability: 3-frame latency, dark/bright convergence, low exposure recovery, near-limit recovery, noise and transient highlights");$finish;
  end
  initial begin #2000000;$fatal(1,"fixed stability watchdog");end
endmodule
