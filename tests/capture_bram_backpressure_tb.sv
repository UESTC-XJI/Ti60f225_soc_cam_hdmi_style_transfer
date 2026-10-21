`timescale 1ns/1ps
module capture_bram_backpressure_tb;
  reg clk=0,rst=0,vs=0,de=0,request=0,ready=0;
  always #5 clk=~clk;
  reg [15:0] raw=0;reg [47:0] pixels=0;
  reg [5:0] vd=0,dd=0;reg [47:0] pd[0:5];integer pipe;
  always @(posedge clk) begin
    if(!rst) begin vd<=0;dd<=0;for(pipe=0;pipe<6;pipe++)pd[pipe]<=0;end
    else begin
      vd<={vd[4:0],vs};dd<={dd[4:0],de};pd[0]<=pixels;
      for(pipe=1;pipe<6;pipe++)pd[pipe]<=pd[pipe-1];
    end
  end
  wire sv,hv,overrun;wire [383:0] stats;wire [38:0] hd;
  capture_frame_stats #(.FRAME_WIDTH(64),.FRAME_HEIGHT(16),.MIN_SAMPLES(2)) dut(
    .clk(clk),.rst_n(rst),.raw_vs(vs),.raw_de(de),.raw_data(raw),
    .rgb_vs(vd[5]),.rgb_de(dd[5]),.rgb_data(pd[5]),.raw_cfg_seq(32'd7),.rgb_cfg_seq(32'd7),
    .gain_r(16'd256),.gain_g(16'd256),.gain_b(16'd256),.high_threshold(8'd232),
    .awb_filter(32'h00f80800),.neutral_ratio(16'd512),.capture_fault(1'b0),.resize_fault(1'b0),
    .stats_valid(sv),.stats_data(stats),.stats_ready(1'b1),.hist_request(request),
    .hist_valid(hv),.hist_data(hd),.hist_ready(ready),.overrun(overrun));
  integer expected[0:63],sum,samples,frames=0,n,word_index=0;
  reg keep_expected=0;
  task frame(input integer mode);
    integer x,y,a,b;
    begin
      @(negedge clk);vs=1;de=0;repeat(8)@(negedge clk);vs=0;repeat(2)@(negedge clk);
      if(!keep_expected)begin sum=0;samples=0;for(n=0;n<64;n++)expected[n]=0;end
      for(y=0;y<16;y++)begin
        for(x=0;x<32;x++)begin
          a=mode==0 ? ((x/8+y/8)%4)*4+40 : mode==1 ? 200 : 60;
          b=mode==0 ? ((x/8+y/8)%4)*4+40 : mode==1 ? 20 : 64;
          de=1;raw=y%2 ? 16'h6080 : 16'h8040;
          pixels={8'(b),8'(b),8'(b),8'(a),8'(a),8'(a)};
          if(!keep_expected&&x%8==0&&y%8==0)begin expected[a/4]++;expected[b/4]++;sum+=a+b;samples+=2;end
          @(negedge clk);
        end
        de=0;repeat(8)@(negedge clk);
      end
      vs=1;repeat(30)@(negedge clk);frames++;
    end
  endtask
  reg collecting=0,stalled=0;reg [38:0] held;
  integer checked=0,updates=0;
  always @(posedge clk) if(!rst) stalled=0;else begin
    if(sv)updates++;
    if(stalled&&(!hv||hd!==held))$fatal(1,"snapshot changed under backpressure");
    stalled=hv&&!ready;held=hd;
    if(collecting&&hv&&ready)begin
      if(hd[38:32]!==word_index)$fatal(1,"snapshot index got %0d expected %0d",hd[38:32],word_index);
      if(word_index==0&&hd[31:0]!==sum)$fatal(1,"frozen META Y sum changed");
      if(word_index==1&&hd[31:0]!==samples)$fatal(1,"frozen sample count changed");
      if(word_index>=14&&hd[31:0]!==expected[word_index-14])
        $fatal(1,"frozen bin %0d got %0d expected %0d",word_index-14,hd[31:0],expected[word_index-14]);
      checked++;word_index++;
    end
  end
  task drain;
    integer cycle;
    begin
      collecting=1;word_index=0;checked=0;
      for(cycle=0;cycle<600&&checked<78;cycle++)begin
        @(negedge clk);ready=(cycle%7!=0&&cycle%7!=1);
      end
      @(negedge clk);ready=0;collecting=0;
      if(checked!=78)$fatal(1,"snapshot did not finish: %0d",checked);
    end
  endtask
  initial begin
    #21;rst=1;request=1;frame(0);
    if(!hv)$fatal(1,"snapshot unavailable");
    keep_expected=1;frame(1);frame(2);
    if(updates!=3)$fatal(1,"live statistics blocked by frozen RAM");
    drain();
    // Reuse the released bank with different bins, including two distinct bins.
    request=0;keep_expected=0;frame(1);drain();
    // Reset an in-flight snapshot; unknown old RAM words must be masked.
    request=1;frame(2);@(negedge clk);rst=0;repeat(3)@(negedge clk);
    rst=1;request=1;frame(0);drain();
    $display("PASS capture BRAM: same/distinct bins, unknown RAM contents, snapshot frozen across three frames, stable stalled stream, live stats, bank reuse and reset");$finish;
  end
  initial begin #1000000;$fatal(1,"capture BRAM timeout");end
endmodule
