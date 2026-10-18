// One physical hard-JTAG channel is shared by Sapphire CPU debug and the
// v7 EDB/logic-analyzer block.  The select is static for a build; asserting
// both enables is an integration error rather than a run-time arbitration.
module soc_jtag_channel_mux(
  input  logic use_soc_jtag,
  input  logic soc_enable, soc_tdi, soc_capture, soc_shift, soc_update,
  input  logic soc_reset, soc_tck, soc_tdo,
  input  logic edb_enable, edb_tdi, edb_capture, edb_shift, edb_update,
  input  logic edb_reset, edb_tck, edb_tdo,
  output logic soc_tdi_o, soc_capture_o, soc_shift_o, soc_update_o,
  output logic soc_reset_o, soc_tck_o,
  output logic edb_tdi_o, edb_capture_o, edb_shift_o, edb_update_o,
  output logic edb_reset_o, edb_tck_o,
  output logic tdo_o,
  output logic conflict
);
  always_comb begin
    conflict = soc_enable && edb_enable;
    soc_tdi_o = use_soc_jtag ? soc_tdi : 1'b0;
    soc_capture_o = use_soc_jtag ? soc_capture : 1'b0;
    soc_shift_o = use_soc_jtag ? soc_shift : 1'b0;
    soc_update_o = use_soc_jtag ? soc_update : 1'b0;
    soc_reset_o = use_soc_jtag ? soc_reset : 1'b1;
    soc_tck_o = use_soc_jtag ? soc_tck : 1'b0;
    edb_tdi_o = use_soc_jtag ? 1'b0 : edb_tdi;
    edb_capture_o = use_soc_jtag ? 1'b0 : edb_capture;
    edb_shift_o = use_soc_jtag ? 1'b0 : edb_shift;
    edb_update_o = use_soc_jtag ? 1'b0 : edb_update;
    edb_reset_o = use_soc_jtag ? 1'b1 : edb_reset;
    edb_tck_o = use_soc_jtag ? 1'b0 : edb_tck;
    tdo_o = use_soc_jtag ? soc_tdo : edb_tdo;
  end
endmodule

