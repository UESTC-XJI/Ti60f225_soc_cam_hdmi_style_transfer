`timescale 1ns/1ps
module tb_area_resize;
parameter W=18,H=12,F=8;
localparam OW=W*2/3,OH=H*2/3;
reg clk=0,rst=0,vs=0,de=0;
reg [47:0] rgb=0;
always #3.367 clk=~clk;
wire ovs,valid,fault;wire [63:0] data;wire [31:0] frames;
rgb_area_resize_3to2 #(.SOURCE_WIDTH(W),.SOURCE_HEIGHT(H)) dut(
 .clk(clk),.rst_n(rst),.i_vs(vs),.i_de(de),.i_rgb(rgb),
 .o_vs(ovs),.o_valid(valid),.o_data(data),.fault(fault),.completed_frames(frames));
reg [23:0] src[0:W*H*F-1];
reg [31:0] exp[0:OW*OH*F-1];
integer n=0,f,y,x;
string srcfile,expfile;
always @(posedge clk) begin
 #1;
 if(rst && fault) $fatal(1,"unexpected resize fault f=%0d row=%0d",f,y);
 if(valid) begin
   if(n>=OW*OH*F) $fatal(1,"excess output");
   if(data !== {exp[n],exp[n+1]}) $fatal(1,"pixel %0d got %h expected %h %h",n,data,exp[n],exp[n+1]);
   n=n+2;
 end
end
initial begin
 if(!$value$plusargs("src=%s",srcfile) || !$value$plusargs("exp=%s",expfile)) $fatal;
 $readmemh(srcfile,src);$readmemh(expfile,exp);
 repeat(5) @(negedge clk);rst=1;
 for(f=0;f<F;f=f+1) begin
   @(negedge clk);vs=1;
   @(negedge clk);vs=0;
   repeat(8) @(negedge clk);
   for(y=0;y<H;y=y+1) begin
     for(x=0;x<W;x=x+2) begin
       de=1;rgb={src[f*W*H+y*W+x+1],src[f*W*H+y*W+x]};
       @(negedge clk);
     end
     de=0;repeat(1+y%7) @(negedge clk);
   end
   repeat(40) @(negedge clk);
 end
 if(n!=OW*OH*F || frames!=F) $fatal(1,"count %0d frames %0d",n,frames);
 $display("PASS area %0dx%0d -> %0dx%0d frames=%0d pixels=%0d",W,H,OW,OH,F,n);
 $finish;
end
initial begin #100000000; $fatal(1,"timeout");end
endmodule
