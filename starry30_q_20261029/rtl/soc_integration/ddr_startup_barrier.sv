// Synchronizes PLL/DDR readiness into each clock domain and blocks all AXI
// masters until both conditions have been observed in that domain.
module ddr_startup_barrier #(
  parameter integer SYNC_STAGES=2
)(
  input logic sys_clk,vid_clk,global_reset_n,pll_locked,ddr_cal_done,
  output logic sys_reset_n,vid_reset_n,master_allow_sys,master_allow_vid,cpu_waiting
);
  logic [SYNC_STAGES-1:0] sys_pll,sys_cal,vid_pll,vid_cal;
  integer i;
  always_ff @(posedge sys_clk or negedge global_reset_n) begin
    if(!global_reset_n) begin sys_pll<='0;sys_cal<='0; end
    else begin
      sys_pll[0] <= pll_locked; sys_cal[0] <= ddr_cal_done;
      for(i=1;i<SYNC_STAGES;i=i+1) begin sys_pll[i]<=sys_pll[i-1]; sys_cal[i]<=sys_cal[i-1]; end
    end
  end
  always_ff @(posedge vid_clk or negedge global_reset_n) begin
    if(!global_reset_n) begin vid_pll<='0;vid_cal<='0; end
    else begin
      vid_pll[0] <= pll_locked; vid_cal[0] <= ddr_cal_done;
      for(i=1;i<SYNC_STAGES;i=i+1) begin vid_pll[i]<=vid_pll[i-1]; vid_cal[i]<=vid_cal[i-1]; end
    end
  end
  always_comb begin
    sys_reset_n=global_reset_n && sys_pll[SYNC_STAGES-1] && sys_cal[SYNC_STAGES-1];
    vid_reset_n=global_reset_n && vid_pll[SYNC_STAGES-1] && vid_cal[SYNC_STAGES-1];
    master_allow_sys=sys_reset_n; master_allow_vid=vid_reset_n; cpu_waiting=!sys_reset_n;
  end
endmodule
