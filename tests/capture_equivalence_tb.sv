`timescale 1ns/1ps
module capture_equivalence_tb;
parameter W=1920,H=1080;
reg clk=0;always #3.367 clk=~clk;
reg rst_n=0,raw_vs=0,raw_de=0;reg [15:0] raw_data=0;
reg rgb_vs=0,rgb_de=0;reg [47:0] rgb_data=0;
reg [31:0] raw_cfg_seq=0,rgb_cfg_seq=0;
reg [15:0] gain_r=65535,gain_g=65535,gain_b=65535;
reg [7:0] high_threshold=232;reg [31:0] awb_filter=32'h00ff0001;
reg [15:0] neutral_ratio=65535;
reg capture_fault=0,resize_fault=0,stats_ready=1,hist_request=0,hist_ready=0;
wire av,bv,bh,ao,bo;wire [383:0] ad,bd;wire [38:0] bx;
// The reference keeps its histogram and neutral filter; awb_filter[0]=0 disables
// the neutral test so it matches the range-only AWB of the simplified DUT.
wire [31:0] ref_awb_filter=awb_filter&~32'd1;
capture_frame_stats #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H),.MIN_SAMPLES(1)) dut(
 .stats_valid(av),.stats_data(ad),.overrun(ao),.*);
capture_frame_stats_baseline #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H),.MIN_SAMPLES(1)) refdut(
 .stats_valid(bv),.stats_data(bd),.hist_valid(bh),.hist_data(bx),.overrun(bo),.awb_filter(ref_awb_filter),.*);
integer checks=0,packets=0,words=0;
always @(posedge clk)begin
 if(rst_n&&av&&stats_ready)packets++;
 if(rst_n&&bh&&hist_ready)words++;
 #1;
 if(rst_n)begin
 if({av,ad,ao}!=={bv,bd,bo})$fatal(1,"capture publication mismatch");
 if(dut.ys!==refdut.ys||dut.samples!==refdut.samples||dut.hot!==refdut.hot||dut.total!==refdut.total||
    dut.done_rs!==refdut.done_rs||dut.done_gs!==refdut.done_gs||dut.done_bs!==refdut.done_bs||dut.done_cells!==refdut.done_cells)$fatal(1,"accumulator mismatch (AE live, AWB latched)");
 checks++;
 end
end
integer x,y,f,t;reg [31:0] seed=32'h12345678;
function [31:0] rnd;begin seed=seed^(seed<<13);seed=seed^(seed>>17);seed=seed^(seed<<5);rnd=seed;end endfunction
task tick;begin @(negedge clk);end endtask
task frame(input integer mode,input integer height);
 begin
 raw_vs=1;rgb_vs=1;raw_de=0;rgb_de=0;repeat(12)tick();
 raw_cfg_seq=raw_cfg_seq+1;rgb_cfg_seq=raw_cfg_seq;
 raw_vs=0;rgb_vs=0;repeat(4)tick();
 for(y=0;y<height;y++)begin
 for(x=0;x<W/2;x++)begin
 raw_de=1;rgb_de=1;
 raw_data=mode==0?16'hfefe:mode==1?0:rnd();
 rgb_data=mode==0?48'hffffffffffff:mode==1?0:{rnd(),16'(rnd())};
 tick();
 end
 raw_de=0;rgb_de=0;repeat(12)tick();
 end
 raw_vs=1;repeat(12)tick();rgb_vs=1;repeat(12)tick();
 end
endtask
initial begin
 repeat(4)tick();rst_n=1;hist_request=1;
 frame(0,H); // maximum luminance and accepted AWB values
 stats_ready=0; // retained scalar and frozen histogram while new frames run
 frame(1,H);
 hist_ready=1;stats_ready=1;repeat(200)tick();
 if(packets<1||words<78)$fatal(1,"no valid evidence packets=%0d words=%0d good=%b samples=%0d rawid=%0d cid=%0d bad=%b/%b",packets,words,dut.good,dut.samples,dut.raw_done_id,dut.cid,dut.done_bad,dut.cbad);
 gain_r=0;gain_g=65535;gain_b=1;neutral_ratio=0;
 capture_fault=1;frame(2,3);capture_fault=0;
 for(f=0;f<8;f++)begin
 gain_r=rnd();gain_g=rnd();gain_b=rnd();neutral_ratio=rnd();
 awb_filter=f%2?32'h00ff0001:32'h00f80800;
 hist_request=~hist_request;hist_ready=f%2;stats_ready=f%3!=0;
 frame(2,f%2?H:2);
 end
 rst_n=0;repeat(4)tick();rst_n=1;stats_ready=1;hist_ready=1;frame(2,H);
 $display("PASS capture baseline differential W=%0d H=%0d cycles=%0d packets=%0d histwords=%0d",W,H,checks,packets,words);$finish;
end
initial begin #1000000000;$fatal(1,"timeout");end
endmodule
