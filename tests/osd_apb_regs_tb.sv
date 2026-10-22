`timescale 1ns/1ps
module osd_apb_regs_tb;
  logic clk=0,rst_n=0,psel=0,penable=0,pwrite=0; always #5 clk=~clk;
  logic [15:0] addr; logic [31:0] wdata,rdata; logic pready,err,en,cwe,cpage,ct,video_ready; logic [11:0] ox,oy; logic [23:0] color; logic [6:0] caddr; logic [7:0] cdata; logic ack=0,active=0,busy=0; logic [15:0] frames=3,drops=4,errors=5;
  logic [15:0] capfps=7,dispfps=8;
  osd_apb_regs dut(.pclk(clk),.preset_n(rst_n),.psel,.penable,.pwrite,.paddr(addr),.pwdata(wdata),.prdata(rdata),.pready,.pslverr(err),.o_enable(en),.o_x(ox),.o_y(oy),.o_color(color),.o_char_we(cwe),.o_char_addr(caddr),.o_char_page(cpage),.o_char_data(cdata),.o_commit_toggle(ct),.o_commit_page(),.i_ack_toggle(ack),.i_active_page(active),.i_busy(busy),.i_frame_count(frames),.i_capture_fps(capfps),.i_display_fps(dispfps),.i_drop_count(drops),.i_error_count(errors));
  assign video_ready=dut.o_video_ready;
  assign dut.i_raw_fps=16'd30;
  task write(input [15:0] a,input [31:0] d); begin @(negedge clk);addr=a;wdata=d;pwrite=1;psel=1;penable=0;@(negedge clk);penable=1;@(posedge clk);#1;psel=0;penable=0;pwrite=0;end endtask
  initial begin repeat(2) @(posedge clk);rst_n=1; write(12'h004,1);write(12'h008,32);write(12'h014,32'h080);write(12'h018,"H"); if(!cwe||caddr!=0||cpage!=1||cdata!="H") $fatal(1,"APB char write failed");
    // A second COMMIT while the pixel side is busy is rejected and has no
    // side effect; the synchronized busy input takes two core clocks.
    busy=1; repeat(3) @(posedge clk); write(12'h01c,0); if(ct) $fatal(1,"busy commit was accepted");
    busy=0; repeat(3) @(posedge clk); write(12'h01c,0); if(!ct) $fatal(1,"APB commit failed");
    addr=12'h020;psel=1;penable=1;pwrite=0;#1;if(rdata[10:3]!==8'd3||rdata[26:19]!==8'd5) $fatal(1,"APB status read failed");
    addr=12'h024;#1;if(rdata[15:0]!==16'd7||rdata[31:16]!==16'd8) $fatal(1,"APB extended FPS status failed");
    addr=16'h002c;#1;if(rdata!==30) $fatal(1,"RAW_FPS readback failed");
    addr=16'h0030;#1;if(rdata!==7) $fatal(1,"RESIZE_FPS readback failed");
    pwrite=1;wdata=99;#1;if(!err) $fatal(1,"RESIZE_FPS write not rejected");
    @(negedge clk);addr=16'h002c;#1;if(!err) $fatal(1,"RAW_FPS write not rejected");
    @(negedge clk);pwrite=0;#1;if(rdata!==30) $fatal(1,"read-only RAW_FPS modified");
    @(negedge clk);addr=16'h0028;pwrite=1;wdata=1;psel=1;penable=0;
    repeat(3) begin @(posedge clk);#1;if(video_ready) $fatal(1,"SETUP set video readiness");end
    @(negedge clk);psel=0;
    write(16'h0028,1);if(!video_ready) $fatal(1,"readiness ACCESS write failed");
    addr=16'h0028;#1;if(rdata!==1) $fatal(1,"readiness readback failed");
    write(16'h0028,0);if(video_ready) $fatal(1,"readiness clear failed");
    write(16'h0028,1);@(negedge clk);rst_n=0;#1;if(video_ready) $fatal(1,"reset did not clear readiness");
    @(negedge clk);rst_n=1;
    psel=0;penable=0;addr=12'h3fc;pwrite=1;psel=1;penable=1;#1;if(!err) $fatal(1,"APB illegal access not rejected");$display("PASS APB OSD registers, CDC busy gate, FPS status, video readiness set/clear/reset and access-only writes");$finish;end
endmodule


