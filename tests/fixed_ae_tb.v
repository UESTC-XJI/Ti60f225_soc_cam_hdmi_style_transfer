`timescale 1ns/1ps
// Arithmetic, latching, safety and cancellation against a host-style oracle.
module fixed_ae_tb;
  reg clk=0,rst=0,en=0,sv=0,fs=0,wd=0,rd=0,protect=0;
  reg[7:0] mean=100,target=100,read_data=0;reg[9:0] ratio=0;
  wire wr,read,ready,fault;wire[15:0] addr,exposure,vts;wire[7:0] data;
  sc431hai_auto_exposure #(.EXPOSURE_PRIORITY_ENABLE(0),.FIXED_STEP_ENABLE(1),.PREDICTIVE_ENABLE(0),.WAIT_FRAMES(0),.FILTER_SHIFT(0),.CONFIRM_FRAMES(1),.TIMEOUT_CYCLES(1000)) dut(
    .clk(clk),.rst_n(rst),.i_config_done(1'b1),.i_enable(en),.i_sensor_frame_start(fs),
    .i_stats_valid(sv),.i_highlights(1'b0),.i_mean(mean),.i_target(target),
    .o_wr_en(wr),.o_rd_en(read),.o_addr(addr),.o_data(data),.i_wr_done(wd),.i_rd_done(rd),
    .i_wr_error(1'b0),.i_rd_error(1'b0),.i_read_data(read_data),
    .o_exposure(exposure),.o_vts(vts),.o_mean(),.o_ready(ready),.o_at_limit(),.o_error(fault),
    .i_high_protect(protect),.i_high_permille(ratio),.i_high_limit(8'd10),.o_highlight_limited());
  always #5 clk=~clk;
  integer initialexp=800,initialvts=1500,writes=0,checks=0,j,m,t;
  reg[15:0] wa[0:4];reg[7:0] wb[0:4];
  always @(negedge clk) begin
    wd=0;rd=0;
    if(read) begin
      case(addr)
        'h320e:read_data=initialvts>>8;'h320f:read_data=initialvts;
        'h3e00:read_data='ha0|(initialexp>>12);
        'h3e01:read_data=initialexp>>4;'h3e02:read_data=(initialexp<<4)|5;
      endcase
      rd=1;
    end
    if(wr) begin
      if(writes>4) $fatal(1,"extra predictive writes");
      wa[writes]=addr;wb[writes]=data;writes=writes+1;wd=1;
    end
  end
  task boot(input integer e,v);
    begin
      @(negedge clk);rst=0;en=0;sv=0;fs=0;protect=0;ratio=0;target=100;mean=100;
      initialexp=e;initialvts=v;writes=0;
      repeat(3) @(negedge clk);rst=1;wait(ready);repeat(3) @(negedge clk);en=1;
    end
  endtask
  task sample(input integer y,goal);
    begin @(negedge clk);mean=y;target=goal;sv=1;@(negedge clk);sv=0;repeat(2) @(negedge clk);end
  endtask
  task check_case(input integer e,y,goal,v);
    integer clamped_target,upper,error,step,expected;
    begin
      boot(e,v);clamped_target=goal<16?16:(goal>224?224:goal);upper=2*v-11;
      error=y>clamped_target?y-clamped_target:clamped_target-y;
      step=error<=4?0:error<=6?2:error<=12?4:error<=23?16:error<=39?64:error<=63?128:error<=95?256:512;
      expected=y<clamped_target?e+step:e-step;
      if(e<4 || expected<4) expected=4;
      else if(e>upper || expected>upper) expected=upper;
      sample(y,goal);
      if(dut.state==9 || dut.state==10) $fatal(1,"fixed mode entered divider");
      if(exposure!=e || writes || fault) $fatal(1,"premature fixed update");
      if(expected==e) begin
        if(dut.state!=4) $fatal(1,"fixed deadband did not hold");
      end else begin
        if(dut.state!=5 || dut.pending!=expected) $fatal(1,"fixed arithmetic e=%0d y=%0d target=%0d pending=%0d expected=%0d",e,y,goal,dut.pending,expected);
        @(negedge clk);fs=1;@(negedge clk);fs=0;repeat(20) @(negedge clk);
        if(exposure!=expected || writes!=5 || fault) $fatal(1,"fixed I2C update");
        if(wa[0]!='h3812 || wb[0]!=0 || wa[1]!='h3e00 || wb[1]!=('ha0|(expected>>12)) ||
           wa[2]!='h3e01 || wb[2]!=(expected>>4 & 255) || wa[3]!='h3e02 ||
           wb[3]!=((expected<<4 & 255)|5) || wa[4]!='h3812 || wb[4]!='h30)
          $fatal(1,"fixed Group Hold/reserved bits");
      end
      checks=checks+1;
    end
  endtask
  initial begin
    for(j=0;j<6;j=j+1)
      for(m=0;m<=255;m=m+1)
        check_case(j==0?4:j==1?65:j==2?300:j==3?1000:j==4?1983:2989,m,128,1500);
    check_case(65523,0,224,32767);check_case(65535,96,96,32767);
    check_case(0,96,96,1500);check_case(800,0,0,1500);check_case(800,255,255,1500);
    boot(800,1500);protect=1;ratio=11;sample(30,100);
    if(dut.pending!=792 || !dut.o_highlight_limited) $fatal(1,"fixed mild high reduction");
    boot(800,1500);protect=1;ratio=20;sample(30,100);
    if(dut.pending!=768) $fatal(1,"fixed severe high reduction");
    en=0;fs=1;repeat(30) @(negedge clk);
    if(writes || exposure!=800) $fatal(1,"fixed disable cancellation");
    $display("PASS fixed AE: %0d cases, all eight bands/directions, sensor bounds, no divider, Group Hold, highlights and cancellation",checks);$finish;
  end
  initial begin #10000000;$fatal(1,"fixed watchdog");end
endmodule
