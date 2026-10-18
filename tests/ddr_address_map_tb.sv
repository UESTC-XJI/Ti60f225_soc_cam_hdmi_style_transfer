`timescale 1ns/1ps
`include "ddr_address_map.svh"
module ddr_address_map_tb;
  logic valid; logic [31:0] f0,f1,f2,e;
  ddr_address_map_check dut(.valid,.frame0(f0),.frame1(f1),.frame2(f2),.video_end(e));
  initial begin
    #1;
    if(!valid || f0!==32'h10000000 || f1!==32'h10384000 || f2!==32'h10708000 || e!==32'h10a8c000) $fatal(1,"DDR address map mismatch");
    $display("PASS DDR address map: CPU scratch isolated, three aligned video frames");
    $finish;
  end
endmodule
