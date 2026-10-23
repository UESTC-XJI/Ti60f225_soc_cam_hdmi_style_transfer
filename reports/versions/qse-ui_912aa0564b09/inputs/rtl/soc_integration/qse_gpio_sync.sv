// QSE inputs: GPIO[3:0] = {selected SW2, selected SW1, KEY1, KEY0}.
// Synchronization only; contact debounce belongs to firmware.
module qse_gpio_sync (
  input wire clk, rst_n,
  input wire io_sw1, io_sw2, io_key0, io_key1,
  output wire [3:0] gpio_read
);
  (* async_reg = "true", syn_preserve = 1 *) reg [3:0] qse_meta;
  (* async_reg = "true", syn_preserve = 1 *) reg [3:0] qse_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qse_meta <= 4'b1100;
      qse_sync <= 4'b1100;
    end else begin
      qse_meta <= {io_sw2, io_sw1, io_key1, io_key0};
      qse_sync <= qse_meta;
    end
  end
  assign gpio_read = qse_sync ^ 4'b1100;
endmodule
