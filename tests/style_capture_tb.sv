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
 // 2026-10-30: full-frame 3x3 average -> 640x360, letterboxed to 640x480.
 // Output row 0..59 and 420..479 are black; row 60+r is source rows 3r..3r+2.
 function [31:0] expected_pixel(input integer p);
   integer row,col,x,y,c,dx,dy,total;reg [23:0] sample;
   begin
     row=p/640;col=p%640;expected_pixel=0;
     if(row>=60&&row<420)begin
       x=col*3;y=(row-60)*3;
       for(c=0;c<3;c=c+1)begin
         total=0;
         for(dx=0;dx<3;dx=dx+1)for(dy=0;dy<3;dy=dy+1)begin sample=color(x+dx,y+dy);total=total+sample[c*8+:8];end
         expected_pixel[c*8+:8]=(total+4)/9;
       end
     end
   end
 endfunction
 integer words=0,beats=0,bursts=0;
 always @(posedge cnn_clk)if(valid&&!input_ready)$fatal(1,"capture FIFO overflow");
 always @(posedge clk)begin
   rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   // Check only the committed frame.  After its eof the crop opens the next
   // frame's top bars (sof) immediately, and this TB never feeds that frame's
   // image, so those trailing writes belong to a partial frame in slot 1 and
   // must not be counted.
   if(awvalid&&awready)begin
     if(!captured)begin
       if(awaddr!==32'h05000000+words*4||awlen!=31)$fatal(1,"capture address aw=%h want=%h len=%0d words=%0d",awaddr,32'h05000000+words*4,awlen,words);
       bursts=bursts+1;
     end
     wa<=1;beats=0;
   end
   if(wvalid&&wready)begin
     if(!captured)begin
       if(wstrb!=16'hffff||wlast!==(beats==31))$fatal(1,"capture write protocol");
       for(integer k=0;k<4;k=k+1)if(wdata[k*32+:32]!==expected_pixel(words+k))$fatal(1,"VGA capture pixel %0d",words+k);
       words=words+4;
     end
     beats=beats+1;if(wlast)begin wa<=0;bvalid<=1;end
   end
   if(bvalid&&bready)bvalid<=0;
 end
 integer xx,yy,fr;
 initial begin
   repeat(5)@(negedge cnn_clk);rst_n=1;repeat(3)@(negedge cnn_clk);
   // Two sensor frames: the first one only fills the line buffers before the
   // letterbox stream opens (its sof sits after the first bottom-bar block),
   // so the store commits the second one.
   for(fr=0;fr<2;fr=fr+1)begin
     i_vs=1;repeat(4)@(negedge cnn_clk);i_vs=0;repeat(3)@(negedge cnn_clk);
     for(yy=0;yy<1080;yy=yy+1)begin
       for(xx=0;xx<960;xx=xx+1)begin i_de=1;i_rgb={color(xx*2+1,yy),color(xx*2,yy)};@(negedge cnn_clk);end
       i_de=0;repeat(40)@(negedge cnn_clk);
     end
     repeat(400000)@(negedge cnn_clk);   // 1080p30 vertical blanking
   end
   wait(captured==1);@(negedge clk);
   if(words!=307200||bursts!=2400||dropped||fault||completed_frames!=1||store.ready_count!=1)$fatal(1,"full capture counts");
   $display("PASS full 1080p -> VGA capture: 307200 exact XBGR pixels, 2400 DDR bursts, 148.5/100MHz FIFO, no overflow");$finish;
 end
 initial begin #40000000;$fatal(1,"capture timeout");end
endmodule
