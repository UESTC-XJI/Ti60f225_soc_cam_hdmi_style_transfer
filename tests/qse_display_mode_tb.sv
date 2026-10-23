`timescale 1ns/1ps
module qse_display_mode_tb;
 reg clk=0,pix_clk=0,rst_n=0,compare_enable=1;
 always #5 clk=~clk;always #7 pix_clk=~pix_clk;
 wire [31:0] araddr; wire [7:0] arlen; wire arvalid;
 style_display #(.UI_ENABLE(1)) dut(.clk(clk),.pix_clk(pix_clk),.rst_n(rst_n),.display_slot(3'd0),.display_valid(1'b1),.compare_enable(compare_enable),.araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(1'b0),.rdata(128'd0),.rresp(2'd0),.rlast(1'b0),.rvalid(1'b0));
 initial begin
 repeat(4)@(negedge clk);rst_n=1;
 wait(dut.rd_start);#1;if(dut.rd_address!==32'h05000000)$fatal(1,"compare first half not origin");
 // Reset, select single before blanking completes; first transfer must use result.
 @(negedge clk);rst_n=0;compare_enable=0;repeat(4)@(negedge clk);rst_n=1;
 wait(dut.rd_start);#1;if(dut.rd_address!==32'h05800000)$fatal(1,"single not styled");
 if(dut.frame_compare!==0)$fatal(1,"single mode not latched");
 force dut.v=145;force dut.h=580;#1;if(!dut.image||dut.expect_x!=0)$fatal(1,"single left edge");
 force dut.h=1219;#1;if(!dut.image||dut.expect_x!=639)$fatal(1,"single right edge");
 force dut.h=1220;#1;if(dut.image)$fatal(1,"single right black margin");
 release dut.v;release dut.h;
 $display("PASS display mode: comparison raw base; single style base and centered 640px viewport");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
