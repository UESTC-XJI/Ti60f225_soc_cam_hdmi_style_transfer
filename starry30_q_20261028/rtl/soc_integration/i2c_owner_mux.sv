// Camera I2C ownership mux.  Sapphire exposes open-drain write values where
// one releases the line and zero pulls it low.  The legacy RTL controller is
// kept for reference/AE logic but is electrically disconnected whenever the
// CPU owner is selected, so two masters can never drive the pad together.
module i2c_owner_mux (
  input  logic cpu_owner,
  input  logic cpu_scl_write, cpu_sda_write,
  input  logic legacy_scl_out, legacy_sda_out,
  input  logic legacy_scl_oe, legacy_sda_oe,
  output logic scl_out, sda_out,
  output logic scl_oe, sda_oe
);
  always_comb begin
    if (cpu_owner) begin
      scl_out = cpu_scl_write;
      sda_out = cpu_sda_write;
      // Open drain: write=0 drives low, write=1 releases the pad.
      scl_oe  = ~cpu_scl_write;
      sda_oe  = ~cpu_sda_write;
    end else begin
      scl_out = legacy_scl_out;
      sda_out = legacy_sda_out;
      scl_oe  = legacy_scl_oe;
      sda_oe  = legacy_sda_oe;
    end
  end
endmodule
