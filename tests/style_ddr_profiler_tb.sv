`timescale 1ns/1ps
module style_ddr_profiler_tb;
  reg clk=0,rst_n=0;always #5 clk=~clk;
  reg enable=0,freeze=0,clear=0,network_idle=0;
  reg c_arvalid=0,c_arready=0,c_rvalid=0,c_rready=0,c_rlast=0;
  reg c_awvalid=0,c_awready=0,c_wvalid=0,c_wready=0,c_wlast=0,c_bvalid=0,c_bready=0;
  reg arvalid=0,arready=0,v_rvalid=0,v_rready=0;
  reg [3:0] index=0;wire [31:0] value;
  style_ddr_profiler dut(.*);
  task clocks(input integer n);repeat(n)@(negedge clk);endtask
  task check(input integer i,input integer expected);
    begin index=i;#1;if(value!==expected)$fatal(1,"counter %0d got=%0d expected=%0d",i,value,expected);end
  endtask
  initial begin
    clocks(3);rst_n=1;enable=1;
    c_arvalid=1;clocks(5);c_arready=1;clocks(1);c_arvalid=0;c_arready=0;
    c_rready=1;clocks(7);c_rvalid=1;c_rready=0;clocks(5);
    c_rready=1;c_rlast=1;clocks(1);c_rvalid=0;c_rlast=0;
    v_rvalid=1;clocks(9);v_rready=1;clocks(1);v_rvalid=0;
    c_awvalid=1;clocks(4);c_awready=1;clocks(1);c_awvalid=0;
    c_wvalid=1;clocks(3);c_wready=1;c_wlast=1;clocks(1);c_wvalid=0;
    c_bready=1;clocks(6);c_bvalid=1;clocks(1);c_bvalid=0;
    arvalid=1;network_idle=1;clocks(8);arvalid=0;network_idle=0;
    freeze=1;clocks(10);
    check(0,53);check(1,5);check(2,8);check(3,7);check(4,5);check(5,9);
    check(6,4);check(7,3);check(8,6);check(9,8);check(10,1);check(11,1);
    // Clearing while frozen resets every count, not transaction tracking.
    clear=1;clocks(1);clear=0;
    for(integer i=0;i<12;i=i+1)check(i,0);
    @(negedge clk);freeze=0;enable=0;network_idle=1;clocks(4);check(0,0);
    @(negedge clk);dut.counters[0]=32'hfffffffe;enable=1;clocks(3);freeze=1;check(0,1);
    index=15;#1;if(value!==0)$fatal(1,"invalid index");
    // AXI tracking continues while counting is frozen or disabled. Clear
    // must not forget a read accepted before the measurement interval.
    @(negedge clk);clear=1;c_arvalid=1;c_arready=1;c_rready=0;
    clocks(1);clear=0;c_arvalid=0;c_arready=0;c_rready=1;
    clocks(3);check(0,0);check(3,0);
    @(negedge clk);freeze=0;clocks(4);freeze=1;check(0,4);check(3,4);
    @(negedge clk);c_rvalid=1;c_rlast=1;clocks(1);c_rvalid=0;c_rlast=0;
    freeze=0;clocks(2);freeze=1;check(0,6);check(3,4);
    // A clear during an outstanding write preserves response-wait state.
    @(negedge clk);c_wvalid=1;c_wready=1;c_wlast=1;clocks(1);c_wvalid=0;
    clear=1;clocks(1);clear=0;freeze=0;clocks(3);freeze=1;check(8,3);
    @(negedge clk);enable=0;c_bvalid=1;c_bready=1;clocks(1);c_bvalid=0;
    enable=1;freeze=0;clocks(2);freeze=1;check(8,3);
    $display("PASS DDR profiler: exact event counts, coherent freeze, clear, disabled windows, uint32 wrap, invalid index");$finish;
  end
endmodule
