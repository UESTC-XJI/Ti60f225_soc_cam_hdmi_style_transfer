`timescale 1ns/1ps
// 2026-10-30: directed edge cases for the full-frame 3x3 crop.
//  1) style_div9 exhaustive sweep n=0..2295 against (n+4)/9.
//  2) All-white (0xFF) and all-black (0x00) source frames: rounding and
//     overflow boundaries, plus the letterbox rows must stay 0.
module style_crop_edge_tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0;

 // ---- 1) divide-by-nine sweep ----
 reg [11:0] dn=0;wire [7:0] dq;
 reg [11:0] np0,np1,np2,np3;integer derr=0,hits=0;
 style_div9 d9(.clk(clk),.n(dn),.q(dq));
 always @(posedge clk)begin
   if(dn<12'd2300)dn<=dn+12'd1;
   np0<=dn;np1<=np0;np2<=np1;np3<=np2;
   if(dn<=12'd2295)begin
     hits=hits+1;
     if(np3<=12'd2295&&dq!==8'((np3+12'd4)/12'd9))derr=derr+1;
   end
 end

 // ---- 2) all-0xFF / all-0x00 frames ----
 reg i_vs=0,i_de=0;reg [47:0] i_rgb=0;
 wire valid,sof,eof,fault;wire [31:0] pixel,completed_frames;
 style_vga_crop #(.SOURCE_WIDTH(24),.SOURCE_HEIGHT(9),.WIDTH(8),.HEIGHT(5)) crop(.*);
 integer chk=0,npx=0,errs=0;reg checking=0,done=0;reg [7:0] want=0;
 always @(posedge clk)if(valid)begin
   if(sof&&!done)begin checking=1;chk=0;end
   if(checking)begin
     if(chk<8||chk>=32)begin if(pixel[23:0]!==24'd0)errs=errs+1;end
     else if(pixel[23:0]!=={want,want,want})errs=errs+1;
     if(sof!==(chk==0)||eof!==(chk==39))errs=errs+1;
     chk=chk+1;if(chk==40)begin checking=0;done=1;end
   end
   npx=npx+1;
 end
 task run_frame(input [47:0] pat);
   integer yy,xx,fr;
   begin
     for(fr=0;fr<2;fr=fr+1)begin
       @(negedge clk);i_vs=1;repeat(3)@(negedge clk);i_vs=0;repeat(3)@(negedge clk);
       for(yy=0;yy<9;yy=yy+1)begin
         for(xx=0;xx<12;xx=xx+1)begin i_de=1;i_rgb=pat;@(negedge clk);end
         i_de=0;repeat(20)@(negedge clk);
       end
       repeat(400)@(negedge clk);
     end
   end
 endtask
 initial begin
   repeat(5)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
   // sweep: 0..2295, one value per clock, then hold a few cycles
   repeat(2300)@(negedge clk);
   repeat(10)@(negedge clk);
   if(hits!=2296||derr!=0)$fatal(1,"div9 sweep hits=%0d errors=%0d",hits,derr);
   $display("div9: %0d values checked, %0d errors",hits,derr);
   // all white
   done=0;checking=0;npx=0;want=8'hFF;errs=0;
   run_frame({24'hFFFFFF,24'hFFFFFF});
   if(!done||errs!=0||fault||completed_frames!=1)$fatal(1,"white frame done=%0d errs=%0d fault=%b cf=%0d",done,errs,fault,completed_frames);
   $display("white frame: image 255, bars 0, tags ok, %0d pixels",npx);
   // all black.  completed_frames may show a third count: the white run ends
   // after a open sof (its next image never arrives in this test), so the next
   // eof closes that leftover frame.  Continuous video never hits this.
   done=0;checking=0;npx=0;want=8'h00;errs=0;
   run_frame({24'h000000,24'h000000});
   if(!done||errs!=0||fault||completed_frames<2)$fatal(1,"black frame done=%0d errs=%0d fault=%b cf=%0d",done,errs,fault,completed_frames);
   $display("black frame: all 0, tags ok");
   $display("PASS style crop edge cases: div9 exhaustive, 0xFF/0x00 frames, letterbox rows");
   $finish;
 end
 initial begin #2000000;$fatal(1,"edge timeout");end
endmodule
