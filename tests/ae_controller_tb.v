`timescale 1ns/1ps
module ae_controller_tb;
  reg clk=0,rst=0,cfg=0,en=0,fs=0,sv=0,hot=0;
  reg[7:0] mean=96,target=96,rddata=0;
  reg wd=0,rd=0,we=0,re=0;
  wire wr,read,ready,limit,fault;wire[15:0] addr,exp,vts;wire[7:0] data,om;
  sc431hai_auto_exposure #(.EXPOSURE_PRIORITY_ENABLE(0),.FIXED_STEP_ENABLE(0),.WAIT_FRAMES(2),.TIMEOUT_CYCLES(80),
    .FILTER_SHIFT(0),.CONFIRM_FRAMES(1),.DEADBAND(8),.SETTLE_BAND(8),
    .SMALL_STEP_SHIFT(3),.LARGE_STEP_SHIFT(3),.RELEASE_FRAMES(1),.PREDICTIVE_ENABLE(0)) dut(
    .clk(clk),.rst_n(rst),.i_config_done(cfg),.i_enable(en),.i_sensor_frame_start(fs),
    .i_stats_valid(sv),.i_highlights(hot),.i_mean(mean),.i_target(target),
    .o_wr_en(wr),.o_rd_en(read),.o_addr(addr),.o_data(data),.i_wr_done(wd),.i_rd_done(rd),
    .i_wr_error(we),.i_rd_error(re),.i_read_data(rddata),.o_exposure(exp),.o_vts(vts),
    .o_mean(om),.o_ready(ready),.o_at_limit(limit),.o_error(fault),
    .i_high_protect(1'b0),.i_high_permille(10'd0),.i_high_limit(8'd10),.o_highlight_limited());
  always #5 clk=~clk;
  integer initialexp=800,initialvts=1500,reads=0,writes=0,failwrite=-1;
  reg stall=0,failread=0;reg[15:0] wa[0:255];reg[7:0] wdata[0:255];
  always @(negedge clk) begin
    wd=0;rd=0;we=0;re=0;
    if(rst && read && !stall) begin
      case(addr)
        'h320e:rddata=initialvts>>8;
        'h320f:rddata=initialvts;
        'h3e00:rddata=8'ha0|(initialexp>>12);
        'h3e01:rddata=initialexp>>4;
        'h3e02:rddata=(initialexp<<4)|5;
        default:$fatal(1,"AE unexpected read address");
      endcase
      reads=reads+1;rd=1;re=failread;
    end
    if(rst && wr && !stall) begin
      wa[writes]=addr;wdata[writes]=data;we=writes==failwrite;writes=writes+1;wd=1;
    end
  end
  task boot(input integer exposure,frame_length);
    integer k;
    begin
      @(negedge clk);rst=0;cfg=0;en=0;sv=0;fs=0;stall=0;failread=0;failwrite=-1;
      initialexp=exposure;initialvts=frame_length;reads=0;writes=0;
      repeat(3) @(posedge clk);
      @(negedge clk);rst=1;cfg=1;
      for(k=0;k<40 && !ready && !fault;k=k+1) @(negedge clk);
      if(frame_length>=8 && frame_length<='h7ff0) begin
        if(!ready || fault || exp!=exposure || vts!=frame_length || reads!=5) $fatal(1,"AE boot readback");
      end else if(!fault) $fatal(1,"AE invalid VTS accepted");
      repeat(2) @(posedge clk);
    end
  endtask
  task sample(input integer m,h);
    begin @(negedge clk);mean=m;hot=h;sv=1;@(negedge clk);sv=0;repeat(2) @(negedge clk);end
  endtask
  task frame_start;
    begin @(negedge clk);fs=1;@(negedge clk);fs=0;end
  endtask
  task finish_update(input integer start_count,expected);
    integer k;
    begin
      frame_start;
      for(k=0;k<40 && writes<start_count+5;k=k+1) @(negedge clk);
      repeat(3) @(negedge clk);
      if(writes!=start_count+5 || exp!=expected || fault || !ready) $fatal(1,"AE update expected %0d got %0d writes %0d",expected,exp,writes);
      if(wa[start_count]!='h3812 || wdata[start_count]!=0 || wa[start_count+1]!='h3e00 ||
         wdata[start_count+1]!=(8'ha0|(expected>>12)) || wa[start_count+2]!='h3e01 ||
         wdata[start_count+2]!=(expected>>4 & 255) || wa[start_count+3]!='h3e02 ||
         wdata[start_count+3]!=((expected<<4 & 255)|5) || wa[start_count+4]!='h3812 || wdata[start_count+4]!='h30)
        $fatal(1,"AE group hold sequence / preserved bits");
    end
  endtask
  initial begin
    boot(800,1500);en=1;sample(40,0);finish_update(0,900);
    sample(40,0);sample(40,0);if(writes!=5 || dut.state!=4) $fatal(1,"AE cooldown");
    sample(200,0);finish_update(5,788);
    sample(96,0);sample(96,0);sample(96,0);if(dut.state!=4) $fatal(1,"AE deadband");
    sample(96,1);finish_update(10,690); // Protect highlights at the target mean.
    en=0;repeat(3) @(negedge clk);en=1;sample(40,0);en=0;repeat(3) @(negedge clk);
    frame_start;if(writes!=15 || exp!=690 || dut.state!=4) $fatal(1,"AE disabled pending request");
    en=1;sample(40,0);frame_start;
    wait(writes==16);en=0;repeat(20) @(negedge clk);
    if(writes!=20 || exp!=776 || !ready) $fatal(1,"AE disable mid group");
    boot(2988,1500);en=1;sample(0,0);finish_update(0,2989);
    sample(0,0);sample(0,0);sample(0,0);if(!limit || writes!=5 || dut.state!=4) $fatal(1,"AE max clamp");
    boot(4,1500);en=1;sample(200,0);if(!limit || writes!=0 || dut.state!=4) $fatal(1,"AE min clamp");
    boot(7103,1500);en=1;sample(96,0);finish_update(0,2989);
    // Regression: sparse highlights must not defeat a dark ROI or target changes.
    boot(800,1500);target=96;en=1;sample(40,1);finish_update(0,900);
    sample(88,1);sample(88,1);sample(88,1);
    if(writes!=5 || dut.state!=4) $fatal(1,"AE highlight protection below target");
    boot(800,1500);target=60;en=1;sample(80,1);finish_update(0,700);
    boot(800,1500);target=120;en=1;sample(80,1);finish_update(0,900);
    boot(4,1500);target=96;en=1;sample(40,1);finish_update(0,5);
    boot(800,1500);target=0;en=1;sample(0,0);finish_update(0,900);
    boot(800,1500);target=255;en=1;sample(230,0);
    if(writes!=0 || dut.state!=4) $fatal(1,"AE target clamp / widened arithmetic");
    target=96;
    boot(800,7);
    if(!fault) $fatal(1,"AE invalid VTS");
    boot(800,1500);en=1;failwrite=1;sample(0,0);frame_start;repeat(25) @(negedge clk);
    if(!fault || writes!=3 || wa[2]!='h3812 || wdata[2]!='h30 || exp!=800) $fatal(1,"AE NACK release/fault");
    en=0;repeat(3) @(negedge clk);en=1;repeat(3) @(negedge clk);
    if(!fault || ready) $fatal(1,"AE enable must not clear fault");
    boot(800,1500);en=1;sample(0,0);repeat(85) @(negedge clk);
    if(!fault) $fatal(1,"AE frame timeout");
    boot(800,1500);en=1;sample(0,0);stall=1;frame_start;repeat(90) @(negedge clk);
    if(!fault) $fatal(1,"AE write timeout");
    @(negedge clk);rst=0;repeat(3) @(negedge clk);stall=0;failread=1;rst=1;repeat(20) @(negedge clk);
    if(!fault) $fatal(1,"AE read error");
    @(negedge clk);rst=0;repeat(3) @(negedge clk);stall=1;rst=1;repeat(100) @(negedge clk);
    if(!fault) $fatal(1,"AE read timeout");
    boot(800,1500);
    if(fault) $fatal(1,"AE reset must clear fault");
    @(negedge clk);dut.state=15;repeat(2) @(negedge clk);
    if(!fault) $fatal(1,"AE invalid state");
    $display("PASS baseline AE: exposure limits, group hold, cooldown, disable, NACK release, sticky faults and reset");$finish;
  end
  initial begin #100000;$fatal(1,"AE test watchdog");end
endmodule
