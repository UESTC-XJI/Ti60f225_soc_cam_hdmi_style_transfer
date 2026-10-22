`timescale 1ns/1ps
module tb_resize_faults;
reg clk=0,slow=0,rst=0,vs=0,de=0;
always #5 clk=~clk;
always #50 slow=~slow;
wire fault,valid;wire [31:0] frames;
rgb_area_resize_3to2 #(.SOURCE_WIDTH(12),.SOURCE_HEIGHT(6)) dut(
 .clk(clk),.rst_n(rst),.i_vs(vs),.i_de(de),.i_rgb(48'h123456789abc),.o_valid(valid),.fault(fault),.completed_frames(frames));
reg grst=0,gvs=0,gvalid=0;wire gfault,gde;
camera_raw_gearbox #(.SOURCE_WIDTH(48),.SOURCE_HEIGHT(6),.FIFO_AW(4)) gb(
 .s_clk(clk),.s_rst_n(grst),.s_vs(gvs),.s_valid(gvalid),.s_data(32'h12345678),
 .d_clk(slow),.d_rst_n(grst),.d_de(gde),.fault(gfault));
reg [11:0] dn=0;wire [7:0] dq;
resize_div9 divider(.clk(clk),.n(dn),.q(dq));
integer i,y;
task newframe;
 begin @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(8) @(negedge clk);end
endtask
initial begin
 repeat(5) @(negedge clk);rst=1;
 newframe();de=1;repeat(5) @(negedge clk);de=0;repeat(15) @(negedge clk);
 if(!fault || frames!=0) $fatal(1,"short row undetected");
 rst=0;repeat(5) @(negedge clk);rst=1;
 newframe();de=1;repeat(7) @(negedge clk);de=0;repeat(15) @(negedge clk);
 if(!fault) $fatal(1,"long row undetected");
 rst=0;repeat(5) @(negedge clk);rst=1;
 newframe();de=1;repeat(6) @(negedge clk);de=0;repeat(15) @(negedge clk);newframe();
 if(!fault) $fatal(1,"short frame undetected");
 rst=0;repeat(5) @(negedge clk);rst=1;
 // Fresh valid frame after reset; no stale pending output is accepted.
 newframe();for(y=0;y<6;y=y+1) begin de=1;repeat(6) @(negedge clk);de=0;repeat(8) @(negedge clk);end
 repeat(20) @(negedge clk);
 if(fault || frames!=1) $fatal(1,"reset recovery failed");
 for(i=0;i<=2295;i=i+1) begin
   @(negedge clk);dn=i;repeat(4) @(negedge clk);
   if(dq!=(i+4)/9) $fatal(1,"divide/round %0d got %0d",i,dq);
 end
 grst=1;gvs=1;repeat(15) @(negedge clk);gvs=0;repeat(2) @(negedge clk);gvalid=1;
 repeat(50) @(negedge clk);gvalid=0;repeat(30) @(negedge slow);
 if(!gfault) $fatal(1,"overflow undetected");
 repeat(10) @(negedge slow);if(gde) $fatal(1,"overflow must stop capture");
 grst=0;repeat(8) @(negedge slow);grst=1;repeat(8) @(negedge slow);
 if(gfault || gde) $fatal(1,"FIFO reset recovery");
 $display("PASS exhaustive divide/round 0..2295, malformed rows/frames, reset + FIFO overflow");$finish;
end
endmodule
