`timescale 1ns/1ps
module tb_cvo_720p;
reg clk=0,rst=0;always #6.734 clk=~clk;
wire period,underflow,ready,hs,vs,de;wire [31:0] pixel;
integer sent=0;
cvo_axi #(.SYMBOL_WIDTH(8),.SYMBOL_NUM(4),.PIXEL_NUM(1),.FIFO_DEPTH(1024),.FIFO_ALMOST_FULL(1000),.MAX_H_VALID(1280),.MAX_V_VALID(720)) dut(
 .o_clk(clk),.rst_n(rst),.fifo_rd_period(period),.fifo_rd_underflow(underflow),.s_axi_clk(clk),
 .s_axis_tdata(32'(sent)),.s_axis_tvalid(1'b1),.s_axis_tready(ready),
 .s_axis_tlast(sent%1280==1279),.s_axis_tuser(sent==0),
 .H_FRONT_PORCH(13'd110),.H_SYNC(13'd40),.H_VALID(13'd1280),.H_BACK_PORCH(13'd220),
 .V_FRONT_PORCH(13'd5),.V_SYNC(13'd5),.V_VALID(13'd720),.V_BACK_PORCH(13'd20),
 .vout(pixel),.o_hs(hs),.o_vs(vs),.o_de(de));
always @(posedge clk) if(rst && ready) sent<=sent==1280*720-1 ? 0 : sent+1;
integer cycles=0,last_vs=-1,last_hs=-1,run=0,rows=0,pixels=0,frames=0,hs_run=0,vs_cycles=0;
reg prev_vs=0,prev_hs=0,prev_de=0;
always @(posedge clk) begin
 #2;cycles=cycles+1;
 if(rst) begin
   if(underflow) $fatal(1,"CVO underflow");
   if(vs && !prev_vs) begin
     if(last_vs>=0) begin
       if(cycles-last_vs!=1650*750) $fatal(1,"frame period %0d",cycles-last_vs);
       if(rows!=720 || pixels!=921600) $fatal(1,"720p frame size %0d rows %0d pixels",rows,pixels);
       frames=frames+1;
       if(frames==2) begin $display("PASS HDMI 720p timing 1650x750, active 1280x720, pixels ordered");$finish;end
     end
     last_vs=cycles;rows=0;pixels=0;
   end
   if(hs && !prev_hs) begin
     if(last_hs>=0 && cycles-last_hs!=1650) $fatal(1,"line period %0d",cycles-last_hs);
     last_hs=cycles;hs_run=0;
   end
   if(hs) hs_run=hs_run+1;
   if(prev_hs && !hs && hs_run!=40) $fatal(1,"H sync %0d",hs_run);
   if(de) begin
     if(pixel!==32'(pixels)) $fatal(1,"CVO pixel %0d got %h",pixels,pixel);
     pixels=pixels+1;run=run+1;
   end
   if(prev_de && !de) begin
     if(run!=1280) $fatal(1,"DE row length %0d",run);
     rows=rows+1;run=0;
   end
   prev_vs=vs;prev_hs=hs;prev_de=de;
 end
end
initial begin repeat(10) @(negedge clk);rst=1;end
initial begin #60000000;$fatal(1,"CVO timeout");end
endmodule
