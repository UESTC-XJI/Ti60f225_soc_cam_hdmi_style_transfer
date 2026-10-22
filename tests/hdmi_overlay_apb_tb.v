`timescale 1ns/1ps
module hdmi_overlay_apb_tb;
  reg clk=0,rst=0,sel=0,en=0,wr=0;reg [11:0] addr=0;reg [31:0] data=0;
  wire [31:0] rd;wire ready,err,hist,text;wire [1:0] mode;
  hdmi_info_overlay_apb dut(.pclk(clk),.preset_n(rst),.psel(sel),.penable(en),.pwrite(wr),
    .paddr(addr),.pwdata(data),.prdata(rd),.pready(ready),.pslverr(err),
    .o_hist_enable(hist),.o_text_enable(text),.o_hist_mode(mode),
    .i_hist_valid(1'b1),.i_hist_samples(16'd16200));
  always #5 clk=~clk;
  initial begin
    repeat(3) @(negedge clk);rst=1;@(negedge clk);
    if(rd!=1 || !hist || mode!=0 || text || !ready || err) $fatal(1,"APB reset");
    sel=1;wr=1;data=32'hffffffff;@(negedge clk);
    if(rd!=1) $fatal(1,"APB setup committed write");
    en=1;@(negedge clk);
    if(rd!=15 || !hist || !text || mode!=3 || err) $fatal(1,"APB control write");
    en=0;wr=0;addr=4;@(negedge clk);en=1;#1;
    if(rd!=1 || err) $fatal(1,"APB valid read");
    @(negedge clk);addr=8;#1;
    if(rd!=16200 || err) $fatal(1,"APB sample read");
    wr=1;data=0;#1;if(!err) $fatal(1,"APB read-only write accepted");
    @(negedge clk);addr=12;#1;if(!err || rd!=0) $fatal(1,"APB unmapped access");
    @(negedge clk);addr=1;#1;if(!err) $fatal(1,"APB unaligned access");
    @(negedge clk);addr=0;sel=0;en=0;#1;if(rd!=15 || err) $fatal(1,"APB failed writes changed control");
    $display("PASS overlay APB: reset, setup/access distinction, control packing, status, RO/unmapped/unaligned errors");$finish;
  end
endmodule
