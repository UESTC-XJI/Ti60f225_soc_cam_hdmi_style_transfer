`timescale 1ns/1ps
module i2c_owner_mux_tb;
  logic cpu_owner=0,cpu_scl=1,cpu_sda=0,legacy_scl=0,legacy_sda=1,legacy_scl_oe=1,legacy_sda_oe=0;
  logic scl_out,sda_out,scl_oe,sda_oe;
  i2c_owner_mux dut(.cpu_owner(cpu_owner),.cpu_scl_write(cpu_scl),.cpu_sda_write(cpu_sda),.legacy_scl_out(legacy_scl),.legacy_sda_out(legacy_sda),.legacy_scl_oe(legacy_scl_oe),.legacy_sda_oe(legacy_sda_oe),.scl_out(scl_out),.sda_out(sda_out),.scl_oe(scl_oe),.sda_oe(sda_oe));
  initial begin
    #1;
    if({scl_out,sda_out,scl_oe,sda_oe}!==4'b0110) $fatal(1,"legacy ownership failed");
    cpu_owner=1; #1;
    if({scl_out,sda_out,scl_oe,sda_oe}!==4'b1001) $fatal(1,"CPU open-drain ownership failed");
    cpu_scl=0;cpu_sda=1; #1;
    if({scl_out,sda_out,scl_oe,sda_oe}!==4'b0110) $fatal(1,"CPU low/release mapping failed");
    $display("PASS I2C owner mux: CPU and legacy paths are mutually exclusive"); $finish;
  end
endmodule
