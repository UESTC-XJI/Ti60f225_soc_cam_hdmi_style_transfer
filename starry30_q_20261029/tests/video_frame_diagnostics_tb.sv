`timescale 1ns/1ps
module video_frame_diagnostics_tb;
  // Non-aligned clocks; source events can be shorter than a core cycle.
  reg raw_clk=0,resize_clk=0,display_clk=0,core_clk=0,rst_n=0;
  always #7 raw_clk=~raw_clk;
  always #3 resize_clk=~resize_clk;
  always #11 display_clk=~display_clk;
  always #5 core_clk=~core_clk;
  reg raw_vs=0,display_vs=0;
  reg [31:0] resize_completed_frames=0;
  wire raw_event,resize_event,display_event;
  video_frame_diagnostics dut(.*);
  integer raw_expected=0,resize_expected=0,display_expected=0;
  integer raw_seen=0,resize_seen=0,display_seen=0;
  always @(posedge core_clk or negedge rst_n)
    if(!rst_n) begin raw_seen=0;resize_seen=0;display_seen=0;end
    else begin
      if(raw_event) raw_seen=raw_seen+1;
      if(resize_event) resize_seen=resize_seen+1;
      if(display_event) display_seen=display_seen+1;
    end
  task run_sources(input integer n);
    begin
      fork
        begin
          repeat(n) begin
            repeat(7) @(negedge raw_clk);raw_vs=1;
            @(negedge raw_clk);raw_vs=0;raw_expected=raw_expected+1;
          end
        end
        begin
          repeat(n/3) begin
            repeat(17) @(negedge resize_clk);
            resize_completed_frames=resize_completed_frames+1;
            resize_expected=resize_expected+1;
          end
        end
        begin
          repeat(n*2) begin
            repeat(4) @(negedge display_clk);display_vs=1;
            @(negedge display_clk);display_vs=0;display_expected=display_expected+1;
          end
        end
      join
      repeat(10) @(negedge core_clk);
      if(raw_seen!=raw_expected||resize_seen!=resize_expected||display_seen!=display_expected)
        $fatal(1,"CDC event counts got=%0d/%0d/%0d expected=%0d/%0d/%0d",
          raw_seen,resize_seen,display_seen,raw_expected,resize_expected,display_expected);
    end
  endtask
  initial begin
    repeat(4) @(negedge core_clk);rst_n=1;
    repeat(10) @(negedge core_clk);
    run_sources(99);
    repeat(30) @(negedge core_clk);
    if(raw_seen!=99||resize_seen!=33||display_seen!=198) $fatal(1,"idle duplicate events");
    // Reset from odd toggle parity must not inject a phantom frame.
    #2;rst_n=0;resize_completed_frames=0;
    raw_expected=0;resize_expected=0;display_expected=0;
    repeat(5) @(negedge core_clk);rst_n=1;
    repeat(10) @(negedge core_clk);
    if(raw_seen||resize_seen||display_seen) $fatal(1,"phantom reset event");
    run_sources(30);
    $display("PASS frame-event CDC: independent clocks, short pulses, binary carries, 3:1 RAW/RESIZE, idle and reset");
    $finish;
  end
  initial begin #1000000;$fatal(1,"diagnostics timeout");end
endmodule
