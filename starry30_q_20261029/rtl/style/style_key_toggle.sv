// Board-key debounce with a toggle output so one press flips the display mode.
// The pin is asynchronous, so it is first passed through a two-flop
// synchroniser.  A level only becomes the "stable" level after it has been seen
// continuously for DEBOUNCE_COUNT clocks (5 ms at 100 MHz), and the toggle
// fires on the accepted falling edge.
module style_key_toggle #(
  parameter integer DEBOUNCE_COUNT = 500000   // 5 ms at 100 MHz
)(
  input  wire clk,
  input  wire rst_n,
  input  wire key_in,                     // async, active-low on this board
  output reg  toggle                      // flips on each accepted press
);
  reg        key_sync1, key_sync2;
  reg [19:0] cnt;                         // 20 bits covers 500000
  reg        stable;                      // debounced level
  reg        stable_d;                    // previous debounced level

  // Two-flop synchroniser for the asynchronous key pin.
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin key_sync1 <= 1'b1; key_sync2 <= 1'b1; end
    else        begin key_sync1 <= key_in; key_sync2 <= key_sync1; end

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      cnt <= 20'd0; stable <= 1'b1; stable_d <= 1'b1; toggle <= 1'b0;
    end else begin
      stable_d <= stable;
      if (key_sync2 != stable) begin
        // Pin disagrees with the accepted level: wait for it to hold.
        if (cnt == DEBOUNCE_COUNT-1) begin
          stable <= key_sync2;
          cnt    <= 20'd0;
        end else begin
          cnt <= cnt + 20'd1;
        end
      end else begin
        cnt <= 20'd0;                     // agrees again: restart the window
      end
      // Accepted 1->0 transition is one press.
      if (stable_d && !stable) toggle <= ~toggle;
    end
endmodule
