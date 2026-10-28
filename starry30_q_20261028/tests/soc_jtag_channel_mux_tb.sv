`timescale 1ns/1ps
module soc_jtag_channel_mux_tb;
  logic use_soc=1, se=1, ee=0;
  logic si=1,sc=1,ss=1,su=1,sr=0,sk=1,st=1;
  logic ei=0,ec=0,es=0,eu=0,er=1,ek=0,et=0;
  logic sti, scc, ssh, suu, srr, skk, eti, ecc, ess, euu, err, ekk, tdo, conflict;
  soc_jtag_channel_mux dut(.use_soc_jtag(use_soc),.soc_enable(se),.soc_tdi(si),.soc_capture(sc),.soc_shift(ss),.soc_update(su),.soc_reset(sr),.soc_tck(sk),.soc_tdo(st),.edb_enable(ee),.edb_tdi(ei),.edb_capture(ec),.edb_shift(es),.edb_update(eu),.edb_reset(er),.edb_tck(ek),.edb_tdo(et),.soc_tdi_o(sti),.soc_capture_o(scc),.soc_shift_o(ssh),.soc_update_o(suu),.soc_reset_o(srr),.soc_tck_o(skk),.edb_tdi_o(eti),.edb_capture_o(ecc),.edb_shift_o(ess),.edb_update_o(euu),.edb_reset_o(err),.edb_tck_o(ekk),.tdo_o(tdo),.conflict);
  initial begin
    #1;
    if(!sti || !scc || !ssh || !suu || srr || !skk || !tdo || eti || ecc || ess || euu || !err || ekk || conflict) $fatal(1,"SoC JTAG selection failed");
    use_soc=0; se=0; ee=1; ei=1; ec=1; es=1; eu=1; er=0; ek=1; et=1; #1;
    if(sti || scc || ssh || suu || !srr || skk || !eti || !ecc || !ess || !euu || err || !ekk || !tdo || conflict) $fatal(1,"EDB JTAG selection failed");
    se=1; #1; if(!conflict) $fatal(1,"JTAG conflict was not reported");
    $display("PASS JTAG channel ownership mux"); $finish;
  end
endmodule
