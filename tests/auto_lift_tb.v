`timescale 1ns/1ps
module auto_lift_tb;
  reg clk=0,rst=0,en=1,vs=0,de=0;reg [7:0] pixel=68,target=100,maximum=128;
  wire lv,lh,ld,valid,atmax;wire [7:0] r,g,b,mean,strength;
  auto_tone_lift control(.clk(clk),.rst_n(rst),.i_enable(en),.i_valid(valid),.i_mean(mean),
    .i_target(target),.i_max_strength(maximum),.i_manual_strength(8'd32),.o_strength(strength),.o_at_max(atmax));
  luma_tone_map #(.HIGHLIGHT_SAFE(1)) lift(.clk(clk),.rst_n(rst),.i_enable(1'b1),.i_strength(strength),
    .i_vs(vs),.i_hs(1'b0),.i_de(de),.i_r(pixel),.i_g(pixel),.i_b(pixel),
    .o_vs(lv),.o_hs(lh),.o_de(ld),.o_r(r),.o_g(g),.o_b(b));
  ae_frame_stats #(.FRAME_WIDTH(64),.FRAME_HEIGHT(32),.MIN_SAMPLES(4),.PIXELS_PER_CLOCK(1),.MEAN_ONLY(1)) meter(
    .clk(clk),.rst_n(rst),.i_vs(lv),.i_de(ld),.i_rgb({24'd0,b,g,r}),.i_high_threshold(8'd232),
    .o_valid(valid),.o_mean(mean),.o_highlights(),.o_high_permille());
  always #5 clk=~clk;
  integer samples=0,sum=0,expected=0,frames=0,j,stable_strength;
  always @(posedge clk) if(rst) begin
    if(ld) begin
      if(r!=g || g!=b || r<pixel && pixel==0) $fatal(1,"lift color/black");
    end
    if(meter.take_full && meter.in_roi) begin sum=sum+(r+2*g+b)/4;samples=samples+1;end
    if(lv && !meter.vs_d) begin
      if(samples!=0) begin expected=sum/samples;end
      sum=0;samples=0;
    end
    #1;if(valid) begin
      if(mean!=expected) $fatal(1,"display mean=%0d expected=%0d",mean,expected);
      frames=frames+1;
    end
  end
  task frame(input integer gray,noise);
    integer x,y;
    begin
      @(negedge clk);de=0;vs=1;repeat(60) @(negedge clk);vs=0;@(negedge clk);
      for(y=0;y<32;y=y+1) begin
        for(x=0;x<64;x=x+1) begin
          // Existing bright highlight outside ROI must remain unchanged.
          pixel=(x==0 && y==0)?250:gray+noise;de=1;@(negedge clk);
        end
        de=0;repeat(4) @(negedge clk);
      end
      vs=1;repeat(60) @(negedge clk);
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst=1;
    for(j=0;j<120;j=j+1) frame(68,0);
    if(mean<97 || mean>103 || strength==0 || atmax) $fatal(1,"automatic midtone convergence mean=%0d strength=%0d",mean,strength);
    stable_strength=strength;
    for(j=0;j<80;j=j+1) frame(68,j%3-1);
    if(strength!=stable_strength) $fatal(1,"automatic lift hunts under +/-1 input noise");
    // Exposure reductions make RAW mean lower; display loop must compensate.
    for(j=0;j<120;j=j+1) frame(56,0);
    if(mean<97 || mean>103 || strength<=stable_strength) $fatal(1,"lower-exposure compensation failed");
    // Impossible target: clamp at the configured strength, with explicit status.
    maximum=32;
    for(j=0;j<80;j=j+1) frame(56,0);
    if(strength!=32 || !atmax || mean>=97) $fatal(1,"lift maximum indication");
    en=0;repeat(5) @(negedge clk);
    if(strength!=32 || atmax) $fatal(1,"manual fallback");
    en=1;maximum=128;
    for(j=0;j<100;j=j+1) frame(110,0);
    if(strength!=0 || mean!=110) $fatal(1,"bright scene must not add lift");
    if(frames<490) $fatal(1,"missing display frames");
    $display("PASS automatic lift: real curve/post-lift single-pixel meter, dark/midtone compensation, noise stability, strength limit, manual fallback and bright bypass");$finish;
  end
  initial begin #15000000;$fatal(1,"auto lift watchdog");end
endmodule
