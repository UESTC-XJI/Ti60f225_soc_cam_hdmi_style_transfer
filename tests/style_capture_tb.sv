`timescale 1ns/1ps
// Full 1080p RGB pairs -> VGA crop -> unrelated-clock FIFO -> real DDR store.
module style_capture_tb;
 reg clk=0,cnn_clk=0,rst_n=0;always #5 clk=~clk;always #3.367 cnn_clk=~cnn_clk;
 reg i_vs=0,i_de=0;reg [47:0] i_rgb=0;
 wire valid,sof,eof,fault;wire [31:0] pixel,completed_frames;
 style_vga_crop crop(.clk(cnn_clk),.rst_n(rst_n),.*);
 wire cap_valid,cap_ready,input_ready;wire [33:0] cap_packet;
 style_async_fifo #(.WIDTH(34),.LOG_DEPTH(11)) fifo(.reset_n(rst_n),.wclk(cnn_clk),.rclk(clk),
   .in_valid(valid),.in_ready(input_ready),.in_data({sof,eof,pixel}),.out_valid(cap_valid),.out_ready(cap_ready),.out_data(cap_packet));
 wire nn_start,display_valid;wire [31:0] nn_source,nn_result,captured,dropped,inferred,infer_errors,display_frame_id,awaddr;
 wire [2:0] display_slot;wire [7:0] awlen;wire awvalid,wvalid,wlast,bready;wire [127:0] wdata;wire [15:0] wstrb;
 reg bvalid=0;wire [1:0] bresp=0;reg wa=0;reg [31:0] rng=32'h892639fa;
 wire awready=!wa&&!bvalid&&rng[0],wready=wa&&(rng[1]||rng[2]);
 style_frame_store store(.*,.stream_enable(1'b1),.nn_ready(1'b0),.nn_done(1'b0),.nn_error(1'b0),.display_frame_event(1'b0),.display_safe(1'b1));
 function [23:0] color(input integer x,y);
   color={8'(x*3+y*5),8'(x*7+y*11),8'(x*13+y*17)};
 endfunction
 function [31:0] expected_pixel(input integer p);
   integer x,y,c,dx,dy,total;reg [23:0] sample;
   begin
     x=320+(p%640)*2;y=60+(p/640)*2;expected_pixel=0;
     for(c=0;c<3;c=c+1)begin
       total=0;
       for(dx=0;dx<2;dx=dx+1)for(dy=0;dy<2;dy=dy+1)begin sample=color(x+dx,y+dy);total=total+sample[c*8+:8];end
       expected_pixel[c*8+:8]=(total+2)/4;
     end
   end
 endfunction
 integer words=0,beats=0,bursts=0;
 always @(posedge cnn_clk)if(valid&&!input_ready)$fatal(1,"capture FIFO overflow");
 always @(posedge clk)begin
   rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   if(awvalid&&awready)begin
     if(awaddr!==32'h05000000+words*4||awlen!=31)$fatal(1,"capture address");wa<=1;beats=0;bursts=bursts+1;
   end
   if(wvalid&&wready)begin
     if(wstrb!=16'hffff||wlast!==(beats==31))$fatal(1,"capture write protocol");
     for(integer k=0;k<4;k=k+1)if(wdata[k*32+:32]!==expected_pixel(words+k))$fatal(1,"VGA capture pixel %0d",words+k);
     words=words+4;beats=beats+1;if(wlast)begin wa<=0;bvalid<=1;end
   end
   if(bvalid&&bready)bvalid<=0;
 end
 integer xx,yy;
 initial begin
   repeat(5)@(negedge cnn_clk);rst_n=1;i_vs=1;repeat(4)@(negedge cnn_clk);i_vs=0;repeat(3)@(negedge cnn_clk);
   for(yy=0;yy<1080;yy=yy+1)begin
     for(xx=0;xx<960;xx=xx+1)begin i_de=1;i_rgb={color(xx*2+1,yy),color(xx*2,yy)};@(negedge cnn_clk);end
     i_de=0;repeat(40)@(negedge cnn_clk);
   end
   wait(captured==1);@(negedge clk);
   if(words!=307200||bursts!=2400||dropped||fault||completed_frames!=1||store.ready_count!=1)$fatal(1,"full capture counts");
   $display("PASS full 1080p -> VGA capture: 307200 exact XBGR pixels, 2400 DDR bursts, 148.5/100MHz FIFO, no overflow");$finish;
 end
 initial begin #15000000;$fatal(1,"capture timeout");end
endmodule
