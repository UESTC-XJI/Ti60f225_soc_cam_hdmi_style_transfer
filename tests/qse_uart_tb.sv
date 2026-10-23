`timescale 1ns/1ps
// Exercise the actual generated UART controller through its BMB register port.
module qse_uart_tb;
  reg clk=0, reset=1, valid=0;
  reg [5:0] addr=0;
  reg [31:0] data=0;
  reg opcode=0;
  wire ready, rspvalid, tx;
  wire [31:0] rspdata;
  always #5 clk=~clk;
  BmbUartCtrl dut(
    .io_systemClk(clk),.systemCd_logic_outputReset(reset),
    .io_bus_cmd_valid(valid),.io_bus_cmd_ready(ready),
    .io_bus_cmd_payload_last(1'b1),.io_bus_cmd_payload_fragment_opcode(opcode),
    .io_bus_cmd_payload_fragment_address(addr),.io_bus_cmd_payload_fragment_length(2'd3),
    .io_bus_cmd_payload_fragment_data(data),.io_bus_cmd_payload_fragment_context(4'd0),
    .io_bus_rsp_valid(rspvalid),.io_bus_rsp_ready(1'b1),.io_bus_rsp_payload_fragment_data(rspdata),
    .io_uart_txd(tx),.io_uart_rxd(tx));
  task access(input bit wr,input [5:0] a,input [31:0] d, output [31:0] r);
    begin
      @(negedge clk); valid=1; opcode=wr; addr=a; data=d;
      @(posedge clk); while(!ready) @(posedge clk);
      @(negedge clk); valid=0;
      while(!rspvalid) @(negedge clk);
      r=rspdata;
    end
  endtask
  reg [31:0] result;
  integer i;
  initial begin
    repeat(10) @(posedge clk);
    @(negedge clk); reset=0;
    access(1,6'h08,32'd3,result); // 100 MHz / (8 * (3+1)) for fast simulation
    access(1,6'h0c,32'd7,result); // 8N1
    repeat(300) @(posedge clk);
    if(tx!==1) $fatal(1,"TX not idle high");
    access(1,6'h00,32'ha5,result);
    repeat(500) @(posedge clk);
    access(0,6'h04,0,result);
    if(result[31:24]!==1) $fatal(1,"RX occupancy %h",result);
    access(0,6'h00,0,result);
    if(result[7:0]!==8'ha5) $fatal(1,"RX payload %h",result);
    $display("PASS Efinity-generated UART1 controller: BMB config, 8N1 TX/RX loopback A5");
    $finish;
  end
  initial begin #100000; $fatal(1,"timeout"); end
endmodule
