`timescale 1ns/1ps
module style_control_fifo_case #(parameter WIDTH=40,parameter real WT=3.367,RT=5)(output reg done=0);
  reg wclk=0,rclk=0,reset_n=0;
  always #(WT) wclk=~wclk;
  always #(RT) rclk=~rclk;
  reg in_valid=0,out_ready=0,run=0,drain=0;
  wire in_ready,out_valid;wire [WIDTH-1:0] out_data;
  wire [2:0] write_level;
  integer sent=0,received=0;
  reg [31:0] wrng=32'h194bee47,rrng=32'h34aef672;
  reg was_stalled=0;reg [WIDTH-1:0] held_word;
  function [WIDTH-1:0] packet(input integer n);
    packet={13'h17b3,32'(n^32'h8560f13d)};
  endfunction
  wire [WIDTH-1:0] in_data=packet(sent);
  style_async_fifo #(.WIDTH(WIDTH),.LOG_DEPTH(2)) dut(.*);
  always @(negedge wclk)begin
    wrng={wrng[30:0],wrng[31]^wrng[21]^wrng[1]^wrng[0]};
    if(!reset_n)in_valid=0;
    else in_valid=run&&sent<1000&&(in_valid&&!in_ready||wrng[0]||!drain);
  end
  always @(negedge rclk)begin
    rrng={rrng[30:0],rrng[31]^rrng[21]^rrng[1]^rrng[0]};
    out_ready=reset_n&&drain&&(rrng[0]||rrng[1]);
  end
  always @(posedge wclk or negedge reset_n)
    if(!reset_n)sent<=0;else if(in_valid&&in_ready)sent<=sent+1;
  always @(posedge rclk or negedge reset_n)
    if(!reset_n)received<=0;
    else if(out_valid&&out_ready)begin
      if(out_data!==packet(received))$fatal(1,"control FIFO width=%0d sequence %0d",WIDTH,received);
      received<=received+1;
    end
  always @(posedge rclk or negedge reset_n)
    if(!reset_n)was_stalled<=0;
    else begin
      if(was_stalled&&(!out_valid||out_data!==held_word))$fatal(1,"control word changed under backpressure");
      was_stalled<=out_valid&&!out_ready;held_word<=out_data;
    end
  initial begin
    repeat(4)@(negedge wclk);reset_n=1;run=1;
    // Four RAM/register entries plus the read-side elastic word fill while
    // the destination is stopped. Full must backpressure the producer.
    wait(sent==5);repeat(10)@(negedge wclk);
    if(in_ready||!out_valid||sent!=5||write_level!==3'd4)$fatal(1,"control FIFO full/elastic capacity");
    reset_n=0;run=0;repeat(4)@(negedge wclk);reset_n=1;
    repeat(6)@(negedge rclk);if(out_valid)$fatal(1,"reset retained control word");
    run=1;drain=1;wait(received==1000);repeat(6)@(negedge rclk);
    if(sent!=1000||out_valid||write_level!==0)$fatal(1,"control FIFO completion");
    done=1;
  end
endmodule

module style_control_fifo_tb;
  wire address_done,coeff_done;
  style_control_fifo_case #(.WIDTH(40)) address_queue(address_done);
  style_control_fifo_case #(.WIDTH(45),.WT(5),.RT(3.367)) coefficient_queue(coeff_done);
  initial begin
    wait(address_done&&coeff_done);
    $display("PASS 4-entry control CDC FIFOs: 40/45 bits, unrelated clocks in both directions, full backpressure, reset discards, 1000 ordered words each");$finish;
  end
  initial begin #1000000;$fatal(1,"control FIFO timeout");end
endmodule
