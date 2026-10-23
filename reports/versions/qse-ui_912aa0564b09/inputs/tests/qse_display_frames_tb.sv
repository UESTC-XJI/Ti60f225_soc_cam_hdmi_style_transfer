`timescale 1ns/1ps
module qse_display_frames_tb;
 reg clk=0,pix_clk=0,rst_n=0,compare_enable=1;
 always #5 clk=~clk;always #7 pix_clk=~pix_clk;
 wire [31:0] araddr,pixel,dma_errors;wire [7:0] arlen;wire arvalid,rready,underflow;
 reg reading=0;reg [7:0] beat=0,len=0;reg [31:0] word=0;
 wire arready=!reading;wire rvalid=reading;wire rlast=beat==len;
 style_display #(.UI_ENABLE(1)) dut(.clk(clk),.pix_clk(pix_clk),.rst_n(rst_n),.display_slot(3'd0),.display_valid(1'b1),.compare_enable(compare_enable),.araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),.rdata({4{word}}),.rresp(2'd0),.rlast(rlast),.rvalid(rvalid),.rready(rready),.pixel(pixel),.underflow(underflow),.dma_errors(dma_errors));
 always @(posedge clk)begin
  if(!rst_n)begin reading<=0;beat<=0;end
  else begin
   if(arvalid&&arready)begin reading<=1;beat<=0;len<=arlen;word<=araddr>=32'h05800000 ? 32'h00445566:32'h00112233;end
   if(rvalid&&rready)begin beat<=beat+1'b1;if(rlast)reading<=0;end
  end
 end
 integer frames=0,pixels=0,single_pixels=0,raw_pixels=0,style_pixels=0;
 reg [31:0] expected;reg image;
 always @(posedge pix_clk)if(rst_n)begin
  image=dut.image;
  expected=0;
  if(image)expected=(!dut.frame_compare||dut.h>=900) ? 32'h00445566:32'h00112233;
  if(dut.h==0&&dut.v==746)begin
   frames=frames+1;
   if(frames==1)compare_enable=0;
   if(frames==2)compare_enable=1;
   if(frames==3)begin
    if(dma_errors||raw_pixels!=614400||style_pixels!=921600||single_pixels!=307200)$fatal(1,"coverage raw=%d style=%d single=%d",raw_pixels,style_pixels,single_pixels);
    $display("PASS full frames comparison -> single -> comparison: exact RGB, 1536000 image pixels, no underflow/DMA errors");$finish;
   end
  end
  #1;
  if(underflow)$fatal(1,"underflow frame=%d h=%d v=%d",frames,dut.h,dut.v);
  if(pixel!==expected)$fatal(1,"pixel frame=%d got=%h expected=%h h=%d v=%d",frames,pixel,expected,dut.h,dut.v);
  if(image)begin
   pixels=pixels+1;
   if(expected==32'h00112233)raw_pixels=raw_pixels+1;else style_pixels=style_pixels+1;
   if(frames==1)single_pixels=single_pixels+1;
  end
 end
 initial begin repeat(5)@(negedge clk);rst_n=1;end
 initial begin #60000000;$fatal(1,"timeout");end
endmodule
