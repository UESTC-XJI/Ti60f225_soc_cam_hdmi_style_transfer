`timescale 1ns/1ps
module qse_gpio_tb;
  reg clk=0, rst_n=0;
  reg [3:0] pins=4'b1100;
  wire [3:0] gpio;
  always #5 clk=~clk;
  qse_gpio_sync dut(.clk(clk),.rst_n(rst_n),.io_sw2(pins[3]),.io_sw1(pins[2]),.io_key1(pins[1]),.io_key0(pins[0]),.gpio_read(gpio));
  task tick; begin @(posedge clk); #1; end endtask
  integer i;
  initial begin
    tick(); if(gpio!==0) $fatal(1,"reset not inactive");
    @(negedge clk); rst_n=1;
    tick(); tick(); if(gpio!==0) $fatal(1,"idle polarity");
    for(i=0;i<16;i=i+1) begin
      @(negedge clk); pins=i[3:0];
      #1; if(gpio!==(i==0 ? 4'b0000 : ((i-1)^4'b1100))) $fatal(1,"asynchronous leakage");
      tick();
      if(gpio!==(i==0 ? 4'b0000 : ((i-1)^4'b1100))) $fatal(1,"one-stage CDC");
      tick(); if(gpio!==(i[3:0]^4'b1100)) $fatal(1,"mapping/polarity %d",i);
    end
    @(negedge clk); rst_n=0; #1;
    if(gpio!==0) $fatal(1,"reset assertion");
    $display("PASS qse GPIO: 16 combinations, two-stage latency, polarity, reset"); $finish;
  end
endmodule
