`timescale 1ns/1ps
module tb_camera_resize;
parameter W=1920,H=1080,F=2;
reg sc=0,dc=0,rst=0,svs=0,svalid=0;reg [31:0] sd=0;
always #10 sc=~sc;
always #3.367 dc=~dc;
wire dvs,dde,gfault;wire [15:0] dd;
camera_raw_gearbox #(.SOURCE_WIDTH(W),.SOURCE_HEIGHT(H)) gb(
 .s_clk(sc),.s_rst_n(rst),.s_vs(svs),.s_valid(svalid),.s_data(sd),
 .d_clk(dc),.d_rst_n(rst),.d_vs(dvs),.d_de(dde),.d_data(dd),.fault(gfault));
wire rvs,rde;wire [47:0] rgb;
debayer_top_2to1 #(.RAW_GREEN_FIRST(0)) db(
 .in_pclk(dc),.in_rstn(rst),.raw_vs_i(dvs),.raw_hs_i(dde),.raw_de_i(dde),.raw_valid_i(dde),.raw_datax4_i(dd),
 .r_gain(16'd256),.g_gain(16'd256),.b_gain(16'd256),.rgb_vs_o(rvs),.rgb_de_o(rde),.rgb_datax2_o(rgb));
wire ovs,valid,afault;wire [63:0] data;wire [31:0] frames;
rgb_area_resize_3to2 #(.SOURCE_WIDTH(W),.SOURCE_HEIGHT(H)) area(
 .clk(dc),.rst_n(rst),.i_vs(rvs),.i_de(rde),.i_rgb(rgb),
 .o_vs(ovs),.o_valid(valid),.o_data(data),.fault(afault),.completed_frames(frames));
integer f,y,x,j,k,n=0,raw_n=0,rows=0,run=0,vsn=0;
reg deprev=0;
function [7:0] rawpixel;
 input integer a;
 begin rawpixel=(a*7+(a/W)*31+(a/(W*H))*11)%256;end
endfunction
always @(posedge dc) begin
 #1;
 if(gfault || afault) $fatal(1,"capture fault gearbox=%b area=%b rows=%0d",gfault,afault,rows);
 if(dvs) vsn=vsn+1;
 if(dde) begin
   if(dd !== {rawpixel(raw_n+1),rawpixel(raw_n)}) $fatal(1,"gearbox order at %0d: %h",raw_n,dd);
   raw_n=raw_n+2;run=run+1;
 end
 if(deprev && !dde) begin
   if(run!=W/2) $fatal(1,"non-contiguous RAW row length %0d",run);
   rows=rows+1;run=0;
 end
 deprev=dde;
 if(valid) begin
   if((^data)===1'bx) $fatal(1,"unknown RGB output at %0d",n);
   n=n+2;
 end
end
initial begin
 repeat(5) @(negedge sc);rst=1;
 // Must discard partial frame at startup.
 svalid=1;sd=32'hdeadbeef;repeat(6) @(negedge sc);svalid=0;
 for(f=0;f<F;f=f+1) begin
   svs=1;repeat(4) @(negedge sc);svs=0;repeat(4) @(negedge sc);
   for(y=0;y<H;y=y+1) begin
     for(x=0;x<W;x=x+4) begin
       for(j=0;j<4;j=j+1) sd[j*8+:8]=rawpixel(f*W*H+y*W+x+j);
       svalid=1;@(negedge sc);
       // Worst input burst: four samples on every source clock.
     end
     svalid=0;repeat(8+y%5) @(negedge sc);
   end
   repeat(1000) @(negedge sc);
 end
 if(n!=W*H*4/9*F || raw_n!=W*H*F || rows!=H*F || frames!=F || vsn!=F)
   $fatal(1,"counts RGB=%0d RAW=%0d rows=%0d completed=%0d VS=%0d",n,raw_n,rows,frames,vsn);
 $display("PASS CSI gearbox + legacy Debayer + resize, %0d frames %0d output pixels",F,n);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
