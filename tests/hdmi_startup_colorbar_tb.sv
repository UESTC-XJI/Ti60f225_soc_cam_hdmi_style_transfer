`timescale 1ns/1ps
module hdmi_startup_colorbar_tb;
  reg clk=0,rst_n=0;
  always #5 clk=~clk;
  wire hs,vs,de;
  wire [7:0] r,g,b;
  hdmi_startup_colorbar dut(.clk(clk),.rst_n(rst_n),.hs(hs),.vs(vs),.de(de),.r(r),.g(g),.b(b));
  integer frame,x,y,active_count;
  reg active;
  reg [23:0] expected;
  initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    for(frame=0;frame<2;frame=frame+1) begin
      active_count=0;
      for(y=0;y<750;y=y+1) for(x=0;x<1650;x=x+1) begin
        @(posedge clk); #1;
        active=(x>=260 && x<1540 && y>=25 && y<745);
        if(hs !== (x<40) || vs !== (y<5) || de !== active)
          $fatal(1,"720p timing frame=%0d x=%0d y=%0d HS/VS/DE=%b%b%b",frame,x,y,hs,vs,de);
        expected=24'd0;
        if(active) begin
          active_count=active_count+1;
          case((x-260)/160)
            0:expected=24'hffffff; 1:expected=24'hffff00;
            2:expected=24'h00ffff; 3:expected=24'h00ff00;
            4:expected=24'hff00ff; 5:expected=24'hff0000;
            6:expected=24'h0000ff; 7:expected=24'h000000;
          endcase
        end
        if({r,g,b} !== expected) $fatal(1,"bar pixel x=%0d y=%0d got=%h expected=%h",x,y,{r,g,b},expected);
      end
      if(active_count!=1280*720) $fatal(1,"active pixel count %0d",active_count);
    end
    $display("PASS two complete 720p frames: 1650x750 timing, 1280x720 DE, eight 160-pixel bars and blanking");
    $finish;
  end
endmodule

module hdmi_startup_select_tb;
  reg clk=0,rst_n=0,cam_rst_n=0,ready=0;
  always #5 clk=~clk;
  wire bh,bv,bd,ch,cv,cd,oh,ov,od;
  wire [7:0] br,bg,bb,cr,cg,cb,orr,og,ob;
  hdmi_startup_colorbar #(.HACT(16),.HFP(2),.HSP(2),.HBP(4),.VACT(4),.VFP(1),.VSP(1),.VBP(2))
    bars(.clk(clk),.rst_n(rst_n),.hs(bh),.vs(bv),.de(bd),.r(br),.g(bg),.b(bb));
  hdmi_startup_colorbar #(.HACT(16),.HFP(2),.HSP(2),.HBP(4),.VACT(4),.VFP(1),.VSP(1),.VBP(2))
    camera(.clk(clk),.rst_n(cam_rst_n),.hs(ch),.vs(cv),.de(cd),.r(cr),.g(cg),.b(cb));
  hdmi_startup_select dut(.clk(clk),.rst_n(rst_n),.ready_async(ready),
    .bar_vs(bv),.bar_hs(bh),.bar_de(bd),.bar_r(br),.bar_g(bg),.bar_b(bb),
    .cam_vs(cv),.cam_hs(ch),.cam_de(cd),.cam_r(cr),.cam_g(cg),.cam_b(cb),
    .out_vs(ov),.out_hs(oh),.out_de(od),.out_r(orr),.out_g(og),.out_b(ob));
  reg [1:0] prior_state;
  reg prior_bv=0,prior_cv=0,bar_edge,cam_edge;
  always @(posedge clk) if(rst_n) begin
    prior_state=dut.state;
    bar_edge=bv && !prior_bv && !bd;
    cam_edge=cv && !prior_cv && !cd;
    prior_bv=bv; prior_cv=cv;
    #1;
    if(prior_state==0 && dut.state==1 && !bar_edge) $fatal(1,"bar frame truncated");
    if(prior_state!=2 && dut.state==2 && !cam_edge) $fatal(1,"entered camera mid-frame");
    if(prior_state==3 && dut.state==0 && !bar_edge) $fatal(1,"returned to bars mid-frame");
    if(dut.state==1 || dut.state==3)
      if(od || {orr,og,ob}!==24'd0) $fatal(1,"handover must blank active video");
  end
  task check_bars;
    begin
      if({oh,ov,od,orr,og,ob} !== {bh,bv,bd,br,bg,bb}) $fatal(1,"startup bars mismatch");
    end
  endtask
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    // No DDR/camera activity: ready alone must not suppress the test pattern.
    repeat(500) begin @(negedge clk); check_bars(); end
    #2; ready=1;
    repeat(500) begin @(negedge clk); check_bars(); end
    ready=0; repeat(5) @(negedge clk);
    cam_rst_n=1;
    // Active camera output must still be hidden while CPU readiness is zero.
    repeat(500) begin @(negedge clk); check_bars(); end
    wait(bd); @(negedge clk); #2; ready=1;
    wait(dut.state==2);
    repeat(500) begin
      @(negedge clk);
      if({oh,ov,od,orr,og,ob} !== {ch,cv,cd,cr,cg,cb}) $fatal(1,"camera output mismatch");
    end
    // Firmware reload/readiness clear, including loss of camera sync.
    #2; ready=0; cam_rst_n=0;
    wait(dut.state==0);
    repeat(500) begin @(negedge clk); check_bars(); end
    @(negedge clk); rst_n=0;
    repeat(3) @(negedge clk); rst_n=1;
    repeat(100) begin @(negedge clk); check_bars(); end
    $display("PASS startup selector: no-camera bars, CPU gate, asynchronous readiness, frame-boundary handover, reload/reset");
    $finish;
  end
  initial begin #100000; $fatal(1,"selector timeout"); end
endmodule
