`timescale 1ns/1ps
module ddr_startup_barrier_tb;
  logic sys=0,vid=0,rst=0,pll=0,cal=0; always #5 sys=~sys; always #7 vid=~vid;
  logic sr,vr,as,av,wait_cpu;
  ddr_startup_barrier dut(.sys_clk(sys),.vid_clk(vid),.global_reset_n(rst),.pll_locked(pll),.ddr_cal_done(cal),.sys_reset_n(sr),.vid_reset_n(vr),.master_allow_sys(as),.master_allow_vid(av),.cpu_waiting(wait_cpu));
  initial begin
    repeat(2) @(posedge sys); rst=1; pll=1; cal=0; repeat(5) @(posedge sys); if(as||!wait_cpu) $fatal(1,"DDR access opened before calibration");
    cal=1; repeat(3) @(posedge sys); if(!as) $fatal(1,"System barrier did not release"); repeat(3) @(posedge vid); if(!av) $fatal(1,"Video barrier did not release");
    cal=0; repeat(3) @(posedge sys); if(as) $fatal(1,"Barrier did not close on lost calibration");
    $display("PASS DDR startup barrier and synchronized reset release"); $finish;
  end
endmodule

