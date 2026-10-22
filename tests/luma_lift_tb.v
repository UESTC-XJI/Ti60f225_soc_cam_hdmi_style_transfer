`timescale 1ns/1ps
module luma_lift_tb #(parameter SAFE=0);
  reg clk=0,rst=0,en=0,vs=0,hs=0,de=0;reg[7:0] strength=0,r=0,g=0,b=0;
  wire ov,oh,od;wire[7:0] ro,go,bo;
  luma_tone_map #(.HIGHLIGHT_SAFE(SAFE)) dut(clk,rst,en,strength,vs,hs,de,r,g,b,ov,oh,od,ro,go,bo);
  always #5 clk=~clk;
  reg[8:0] gains[0:255];reg[9:0] caps[0:255];
  integer er[0:3],eg[0:3],eb[0:3],sy[0:3],ir[0:3],ig[0:3],ib[0:3],ff[0:3];
  integer n=0,k,y,m,f,sp=0,ep=0,checks=0,previous=-1,difference_rg,difference_rb;
  reg lastvs=0,gray_check=0;reg grayq[0:3];
  always @(posedge clk) if(rst) begin
    for(k=3;k>0;k=k-1) begin
      er[k]=er[k-1];eg[k]=eg[k-1];eb[k]=eb[k-1];sy[k]=sy[k-1];
      ir[k]=ir[k-1];ig[k]=ig[k-1];ib[k]=ib[k-1];ff[k]=ff[k-1];grayq[k]=grayq[k-1];
    end
    y=(r+2*g+b)/4;m=r>g?r:g;if(b>m)m=b;
    f=256+(ep?gains[y]*sp/128:0);if(f>caps[m])f=caps[m];
    er[0]=r*f/256;eg[0]=g*f/256;eb[0]=b*f/256;sy[0]={vs,hs,de};
    ir[0]=r;ig[0]=g;ib[0]=b;ff[0]=f;grayq[0]=gray_check;
    if(vs && !lastvs) begin ep=en;sp=strength>128?128:strength;end
    lastvs=vs;
    #1;
    if(n>=3) begin
      if({ov,oh,od}!==sy[3][2:0]) $fatal(1,"lift sync cycle %0d",n);
      if(od) begin
        if(ro!==er[3][7:0] || go!==eg[3][7:0] || bo!==eb[3][7:0]) $fatal(1,"lift RGB arithmetic cycle %0d",n);
        if(ro<ir[3] || go<ig[3] || bo<ib[3]) $fatal(1,"lift wrap/darken");
        if(ir[3]>=(SAFE?231:255) || ig[3]>=(SAFE?231:255) || ib[3]>=(SAFE?231:255)) begin
          if(ro!=ir[3] || go!=ig[3] || bo!=ib[3]) $fatal(1,"lift introduced clipping");
        end
        if(SAFE && ir[3]<232 && ig[3]<232 && ib[3]<232 && (ro>=232 || go>=232 || bo>=232)) $fatal(1,"safe lift created highlights");
        // Common scaling preserves channel ratios to within one output LSB.
        difference_rg=ro*ig[3]-go*ir[3];difference_rb=ro*ib[3]-bo*ir[3];
        if(difference_rg>255 || difference_rg< -255 || difference_rb>255 || difference_rb< -255)
          $fatal(1,"lift color ratio");
        if(grayq[3]) begin
          if(ro!=go || go!=bo || (previous>=0 && ro<previous)) $fatal(1,"lift gray monotonic/neutral");
          previous=ro;
          if(ir[3]<=16 && ro!=ir[3]) $fatal(1,"lift black pedestal");
        end
        checks=checks+1;
      end else if(!grayq[3]) previous=-1;
    end
    n=n+1;
  end
  task frame(input integer enable,s,random_count);
    integer j;
    begin
      @(negedge clk);en=enable;strength=s;vs=1;de=0;gray_check=0;
      repeat(6) @(negedge clk);vs=0;gray_check=1;
      for(j=0;j<256;j=j+1) begin de=1;r=j;g=j;b=j;hs=j%3==0;@(negedge clk);end
      gray_check=0;de=0;repeat(6) @(negedge clk);
      // Changed controls must take effect only at the next frame.
      en=!enable;strength=255-s;
      for(j=0;j<random_count;j=j+1) begin
        de=j%13!=0;r=$random;g=$random;b=$random;hs=j%7==0;@(negedge clk);
      end
      de=0;repeat(6) @(negedge clk);
    end
  endtask
  integer s;
  initial begin
    $readmemh("rtl/isp/lift_gain.mem",gains);if(SAFE) $readmemh("rtl/isp/lift_safe_cap.mem",caps);else $readmemh("rtl/isp/lift_cap.mem",caps);
    repeat(3) @(negedge clk);rst=1;
    frame(0,128,1000);frame(1,0,1000);
    for(s=0;s<=128;s=s+1) frame(1,s,s==96?10000:0);
    frame(1,255,1000);
    $display("PASS tone lift: %0d pixels, all strengths, gray monotonicity, color ratios, headroom, sync and frame latch",checks);$finish;
  end
endmodule
