`timescale 1ns/1ps
// crop, rounding, SOF/EOF under blanking; finite frame queue and DMA errors.
module style_video_tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0;
 reg i_vs=0,i_de=0;reg [47:0] i_rgb=0;
 wire valid,sof,eof,fault;wire [31:0] pixel,completed_frames;
 style_vga_crop #(.SOURCE_WIDTH(32),.SOURCE_HEIGHT(16),.WIDTH(8),.HEIGHT(4)) crop(.*);
 function [23:0] color(input integer x,y);
   color={8'(x*5+y*2),8'(x+y*3),8'(x*2+y)};
 endfunction
 integer crop_count=0,x,y,c,total;reg [23:0] expected_rgb;
 always @(posedge clk)if(valid)begin
   for(c=0;c<3;c=c+1)begin
     total=0;
     for(y=0;y<2;y=y+1)for(x=0;x<2;x=x+1)begin
       expected_rgb=color(8+(crop_count%8)*2+x,4+(crop_count/8)*2+y);total=total+expected_rgb[c*8+:8];
     end
     if(pixel[c*8+:8] !== 8'((total+2)/4))$fatal(1,"crop channel=%0d pixel=%0d",c,crop_count);
   end
   if(sof !== (crop_count==0)||eof !== (crop_count==31))$fatal(1,"crop frame tags");
   crop_count=crop_count+1;
 end
 reg cap_valid=0;wire cap_ready;reg [33:0] cap_packet=0;
 reg stream_enable=0,nn_ready=0,nn_done=0,nn_error=0,display_frame_event=0,display_safe=0;
 wire nn_start;wire [31:0] nn_source,nn_result;wire [2:0] display_slot;wire display_valid;
 wire [31:0] captured,dropped,inferred,infer_errors,display_frame_id,awaddr;
 wire [7:0] awlen;wire awvalid,wvalid,wlast,bready;wire [127:0] wdata;wire [15:0] wstrb;
 reg awready=0,wready=0,bvalid=0;reg [1:0] bresp=0;
 style_frame_store #(.FRAME_PIXELS(384)) store(.*);
 reg [31:0] rng=32'h97425634;reg wa=0;integer wb=0,bursts=0,words=0;
 reg inject_error=0;reg [31:0] held_addr;
 always @(posedge clk)begin
   rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   awready<=!wa&&!bvalid&&rng[0];wready<=wa&&rng[1];
   if(awvalid&&awready)begin
     if(awlen!=31||awaddr[8:0]!=0)$fatal(1,"capture burst");
     held_addr<=awaddr;wa<=1;wb<=0;bursts=bursts+1;
   end
   if(wvalid&&wready)begin
     if(wlast!==(wb==31)||wstrb!=16'hffff)$fatal(1,"capture beat");
     for(integer k=0;k<4;k=k+1)if(wdata[k*32+:32]!==32'(words+k))$fatal(1,"capture data got %h expected_rgbed %0d",wdata,words+k);
     words=words+4;wb<=wb+1;
     if(wlast)begin wa<=0;bvalid<=1;bresp<=inject_error?2:0;end
   end
   if(bvalid&&bready)bvalid<=0;
 end
 task frame(input integer short_count);
   integer k;begin
     words=0;
     for(k=0;k<short_count;k=k+1)begin
       @(negedge clk);cap_valid=1;cap_packet={k==0,k==short_count-1,32'(k)};
       do @(posedge clk);while(!cap_ready);
       @(negedge clk);cap_valid=0;
     end
     wait(store.state==0);repeat(2)@(negedge clk);
   end
 endtask
 task finish_nn(input bit bad);
   begin @(negedge clk);nn_done=1;nn_error=bad;@(negedge clk);nn_done=0;nn_error=0;end
 endtask
 task tick_display;
   begin @(negedge clk);display_frame_event=1;@(negedge clk);display_frame_event=0;end
 endtask
 integer xx,yy;
 initial begin
   repeat(4)@(negedge clk);rst_n=1;
   @(negedge clk);i_vs=1;repeat(3)@(negedge clk);i_vs=0;
   repeat(3)@(negedge clk);
   for(yy=0;yy<16;yy=yy+1)begin
     for(xx=0;xx<16;xx=xx+1)begin i_de=1;i_rgb={color(xx*2+1,yy),color(xx*2,yy)};@(negedge clk);end
     i_de=0;repeat(5)@(negedge clk);
   end
   repeat(5)@(negedge clk);
   if(crop_count!=32||completed_frames!=1||fault)$fatal(1,"crop count");
   for(integer f=0;f<6;f=f+1)frame(384);
   if(captured!=6||dropped!=0)$fatal(1,"six queue slots");
   frame(384);if(dropped!=1||captured!=6)$fatal(1,"queue overflow count");
   stream_enable=1;nn_ready=1;wait(nn_start);@(negedge clk);
   if(nn_source!=32'h05000000||nn_result!=32'h05800000)$fatal(1,"oldest ready");
   finish_nn(0);nn_ready=0;
   tick_display;repeat(4)@(negedge clk);
   if(display_valid)$fatal(1,"unsafe slot released");
   display_safe=1;repeat(3)@(negedge clk);
   if(!display_valid||display_slot!=0||inferred!=1)$fatal(1,"paired display");
   nn_ready=1;wait(nn_start);@(negedge clk);nn_ready=0;finish_nn(0);
   tick_display;repeat(4)@(negedge clk);
   if(display_slot!=1||store.ownership[0]!=0||display_frame_id!=1)$fatal(1,"completed swap");
   nn_ready=1;wait(nn_start);@(negedge clk);nn_ready=0;finish_nn(1);
   if(infer_errors!=1||store.ownership[2]!=0)$fatal(1,"NN error frees slot");
   inject_error=1;frame(384);inject_error=0;
   if(dropped!=2||captured!=6)$fatal(1,"BRESP discards frame");
   frame(37);if(dropped!=3)$fatal(1,"short frame dropped");
   if(bursts!=21)$fatal(1,"DMA bursts=%0d",bursts);
   $display("PASS style crop and frame store: exact averages, 6-slot exhaustion, paired ownership, unsafe swap, errors");$finish;
 end
 initial begin #5000000;$fatal(1,"video timeout");end
endmodule
