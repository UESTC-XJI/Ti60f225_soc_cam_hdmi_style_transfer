`timescale 1ns/1ps
module style_mac_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,in_valid=0,first=0,last=0,relu=0,out_ready=0;
  wire in_ready,out_valid; reg [767:0] activations=0,weights=0;
  reg [127:0] multipliers=0;reg [255:0] biases=0;reg [63:0] shifts=0;
  reg [15:0] in_tag=0;wire [15:0] out_tag; wire [63:0] result;
  reg [63:0] in_skip=0;wire [63:0] out_skip;
  style_mac8x12 dut(.*);
  reg [2002:0] packets[0:19999];reg [63:0] expected[0:9999];
  integer count,outputs,i=0,j=0,cycles=0;reg advance=0;reg [31:0] rng=32'h4e53bc99;
  string packet_file,expected_file;
  initial begin
    if(!$value$plusargs("packets=%s",packet_file)) $fatal(1,"missing packets");
    if(!$value$plusargs("expected=%s",expected_file)) $fatal(1,"missing expected");
    if(!$value$plusargs("count=%d",count)) $fatal(1,"missing count");
    if(!$value$plusargs("outputs=%d",outputs)) $fatal(1,"missing outputs");
    $readmemh(packet_file,packets,0,count-1);$readmemh(expected_file,expected,0,outputs-1);
    repeat(3) @(negedge clk);rst_n=1;
  end
  always @(negedge clk) if(rst_n) begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready=rng[0]||rng[2];
    if(!in_valid || advance) begin
      in_valid=i<count && (rng[1]||rng[3]);
      if(in_valid) {in_tag,relu,last,first,shifts,biases,multipliers,weights,activations}=packets[i];
    end
  end
  always @(posedge clk) if(rst_n) begin
    advance<=in_valid&&in_ready;
    cycles=cycles+1;
    if(in_valid&&in_ready) i=i+1;
    if(out_valid&&out_ready) begin
      if(out_tag!==j || result!==expected[j]) $fatal(1,"mismatch output %0d tag=%0d got=%h expected=%h",j,out_tag,result,expected[j]);
      j=j+1;
      if(j==outputs) begin $display("PASS style_mac packets=%0d outputs=%0d randomized stalls cycles=%0d",count,outputs,cycles);$finish;end
    end
    if(cycles>count*10+1000) $fatal(1,"timeout %0d/%0d",j,outputs);
  end
endmodule
