`timescale 1ns/1ps
module style_display_beats_tb;
  reg clk=0,rst_n=0;always #5 clk=~clk;
  reg in_valid=0,out_ready=0;wire in_ready,out_valid;
  reg [127:0] in_data;reg [1:0] in_resp;reg in_last;
  wire [127:0] out_data;wire [1:0] out_resp;wire out_last;
  style_display_beats dut(.*);
  integer sent=0,received=0;reg [31:0] rng=32'hb91aeb54;reg [130:0] held;reg was_stalled=0;
  function [127:0] sample(input integer n);
    sample={8'hca,24'(n+300),8'hfe,24'(n+200),8'hba,24'(n+100),8'hbe,24'(n)};
  endfunction
  function [127:0] expected(input integer n);
    expected={8'b0,24'(n+300),8'b0,24'(n+200),8'b0,24'(n+100),8'b0,24'(n)};
  endfunction
  always @(posedge clk)if(rst_n)begin
    if(was_stalled&&{out_last,out_resp,out_data}!==held)$fatal(1,"buffer changed under backpressure");
    was_stalled=out_valid&&!out_ready;held={out_last,out_resp,out_data};
    if(in_valid&&in_ready)sent=sent+1;
    if(out_valid&&out_ready)begin
      if(out_data!==expected(received)||out_resp!==(received%4)||out_last!==(received%32==31))$fatal(1,"buffer packet %0d",received);
      received=received+1;
    end
  end
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    // Entire 32-beat burst must be accepted while the pixel consumer is stopped.
    while(sent<32)begin
      in_valid=1;in_data=sample(sent);in_resp=sent%4;in_last=sent%32==31;
      @(negedge clk);
      if(!in_ready&&sent<32)$fatal(1,"cannot accept a full burst");
    end
    in_valid=0;repeat(8)@(negedge clk);
    while(received<512)begin
      rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready=rng[2]||rng[3];
      in_valid=sent<512&&(in_valid&&!in_ready||rng[0]);
      in_data=sample(sent);in_resp=sent%4;in_last=sent%32==31;
      @(negedge clk);
    end
    if(sent!=512)$fatal(1,"count");
    // Reset discards buffered data, including an unread elastic output.
    in_valid=1;out_ready=0;in_data=sample(0);@(negedge clk);rst_n=0;in_valid=0;
    repeat(3)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
    if(out_valid)$fatal(1,"reset retained old pixels");
    $display("PASS display beats: full burst with stalled consumer, 512 packets, RGB padding, RRESP/RLAST, random backpressure, reset");$finish;
  end
  initial begin #1000000;$fatal(1,"timeout");end
endmodule
