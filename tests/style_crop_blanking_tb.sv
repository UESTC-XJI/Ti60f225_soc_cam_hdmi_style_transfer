`timescale 1ns/1ps
// 2026-10-30: guard + recovery test for the letterbox bars.
//  Phase 1: blanking far too short for the 120 bar rows must raise
//           capture_fault (sticky) and must not lock the module up.
//  Phase 2: after a long idle that lets the bar FSM drain, two normal frames
//           must re-lock: the next complete frame is checked pixel by pixel
//           and completed_frames must keep growing.  The fault BIT stays set
//           by design (LED/APB sticky flag, cleared only by reset); what is
//           verified here is that the data path recovers.
module style_crop_blanking_tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0;
 reg i_vs=0,i_de=0;reg [47:0] i_rgb=0;
 wire valid,sof,eof,fault;wire [31:0] pixel,completed_frames;
 style_vga_crop #(.SOURCE_WIDTH(24),.SOURCE_HEIGHT(9),.WIDTH(8),.HEIGHT(5)) crop(.*);
 integer npx=0;
 always @(posedge clk)if(valid)npx=npx+1;
 // checker for phase 2: 8 top bars (0) + 24 image (PAT) + 8 bottom bars (0)
 localparam [7:0] PAT=8'h30;
 integer chk=0,errs=0;reg checking=0,done=0,armed=0;
 always @(posedge clk)if(valid&&armed&&!done)begin
   if(sof)begin checking=1;chk=0;end
   if(checking)begin
     if(chk<8||chk>=32)begin if(pixel[23:0]!==24'd0)begin errs=errs+1;$display("bar mismatch chk=%0d px=%h",chk,pixel[23:0]);end end
     else if(pixel[23:0]!=={PAT,PAT,PAT})begin errs=errs+1;$display("img mismatch chk=%0d px=%h",chk,pixel[23:0]);end
     if(sof!==(chk==0)||eof!==(chk==39))begin errs=errs+1;$display("tag mismatch chk=%0d sof=%b eof=%b",chk,sof,eof);end
     chk=chk+1;if(chk==40)begin checking=0;done=1;end
   end
 end
 task run_frames(input integer n,input integer gap);
   integer yy,xx,fr;
   begin
     for(fr=0;fr<n;fr=fr+1)begin
       @(negedge clk);i_vs=1;repeat(3)@(negedge clk);i_vs=0;repeat(3)@(negedge clk);
       for(yy=0;yy<9;yy=yy+1)begin
         for(xx=0;xx<12;xx=xx+1)begin i_de=1;i_rgb={24'h303030,24'h303030};@(negedge clk);end
         i_de=0;repeat(2)@(negedge clk);
       end
       repeat(gap)@(negedge clk);
     end
   end
 endtask
 integer cf0;
 initial begin
   repeat(5)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
   // Phase 1: two frames with 2 idle clocks per line (needs ~96 clocks of gap).
   run_frames(2,2);
   repeat(2000)@(negedge clk);
   if(!fault)$fatal(1,"short blanking did not raise capture_fault");
   if(npx<40)$fatal(1,"stream stopped after fault (%0d pixels)",npx);
   $display("phase1: capture_fault latched, %0d pixels streamed, no lock-up",npx);
   cf0=completed_frames;
   // Phase 2: drain the bar FSM, then two normal frames with real blanking.
   // The checker is only armed now: phase 1 is expected to be corrupt.
   repeat(4000)@(negedge clk);
   armed=1;done=0;errs=0;checking=0;chk=0;
   run_frames(2,400);
   repeat(4000)@(negedge clk);
   if(!done||errs!=0)$fatal(1,"did not re-lock after fault done=%0d errs=%0d",done,errs);
   if(completed_frames<=cf0)$fatal(1,"no frame closed after fault (%0d -> %0d)",cf0,completed_frames);
   $display("phase2: re-locked, full frame exact, completed_frames %0d -> %0d",cf0,completed_frames);
   $display("PASS letterbox guard and recovery: fault latches, no lock-up, data path re-locks");
   $finish;
 end
 initial begin #200000;$fatal(1,"blanking timeout");end
endmodule
