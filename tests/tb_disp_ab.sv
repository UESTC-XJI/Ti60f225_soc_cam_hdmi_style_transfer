// 逐拍 A/B：改动前（style_display_old，由 .pre720p_20261028 只改模块名生成）与改动后并排跑，
// 同一时钟、同一激励，对比模式（single_panel=0）要求 pixel/hs/vs/de/underflow 逐拍相同。
//
// ⚠ 2026-10-31：对比模式几何有意改为“左完整原画 / 右完整风格 + 上下黑边”，
//    本 A/B 的 diff=0 前提不再成立，**已废弃，不要再当回归**。当前回归用
//    tb_disp_720p / tb_disp_toggle / tb_disp_boot_modes。

`timescale 1ns/1ps
module tb_disp_ab;
  reg clk=0,pix_clk=0;always #5 clk=~clk;always #6.734 pix_clk=~pix_clk;
  reg rst_n=0;reg [2:0] display_slot=0;reg display_valid=1;reg single=0;

  function [31:0] value(input [3:0] slot, input right_side, input [8:0] row, input [9:0] x);
    value={8'b0,8'(slot*17+right_side*91),8'(row),8'(x)};
  endfunction
  function [127:0] data_at(input [31:0] a);
    integer slot,off,row,xb,k;reg right;reg [31:0] base;
    begin
      right=a>=32'h05800000;base=right?32'h05800000:32'h05000000;
      slot=(a-base)/32'h140000;off=(a-base)%32'h140000;
      row=right?off/1280:off/2560;
      xb=right?(off%1280)/4:(off%2560)/4;
      for(k=0;k<4;k=k+1)data_at[k*32+:32]=value(slot[3:0],right,row[8:0],xb+k);
    end
  endfunction

  // ---- DUT A：改动前 ----
  wire a_pix, a_hs,a_vs,a_de,a_uf,a_safe,a_fev,a_urg;wire [31:0] a_pixel,a_err;
  wire [31:0] a_araddr;wire [7:0] a_arlen;wire a_arvalid,a_rready;
  reg a_active=0;reg [31:0] a_addr=32'h05000000;reg [7:0] a_beat=0,a_len=0;
  wire a_arready=!a_active;wire a_rvalid=a_active;wire a_rlast=a_beat==a_len;wire [1:0] a_rresp=0;
  wire [127:0] a_rdata=data_at(a_addr);
  style_display_old ua(.clk(clk),.pix_clk(pix_clk),.rst_n(rst_n),
    .single_panel(single),.display_slot(display_slot),.display_valid(display_valid),
    .display_frame_event(a_fev),.display_safe(a_safe),
    .pixel(a_pixel),.hs(a_hs),.vs(a_vs),.de(a_de),.underflow(a_uf),.dma_errors(a_err),
    .read_urgent(a_urg),
    .araddr(a_araddr),.arlen(a_arlen),.arvalid(a_arvalid),.arready(a_arready),
    .rdata(a_rdata),.rresp(a_rresp),.rlast(a_rlast),.rvalid(a_rvalid),.rready(a_rready));
  always @(posedge clk)begin
    if(a_arvalid&&a_arready)begin a_active<=1;a_addr<=a_araddr;a_len<=a_arlen;a_beat<=0;end
    if(a_rvalid&&a_rready)begin a_addr<=a_addr+16;a_beat<=a_beat+1'b1;if(a_rlast)a_active<=0;end
  end

  // ---- DUT B：改动后 ----
  wire b_pix, b_hs,b_vs,b_de,b_uf,b_safe;wire [31:0] b_pixel,b_err;
  wire [31:0] b_araddr;wire [7:0] b_arlen;wire b_arvalid,b_rready;
  reg b_active=0;reg [31:0] b_addr=32'h05000000;reg [7:0] b_beat=0,b_len=0;
  wire b_arready=!b_active;wire b_rvalid=b_active;wire b_rlast=b_beat==b_len;wire [1:0] b_rresp=0;
  wire [127:0] b_rdata=data_at(b_addr);
  style_display ub(.clk(clk),.pix_clk(pix_clk),.rst_n(rst_n),
    .single_panel(single),.display_slot(display_slot),.display_valid(display_valid),
    .display_frame_event(),.display_safe(b_safe),
    .pixel(b_pixel),.hs(b_hs),.vs(b_vs),.de(b_de),.underflow(b_uf),.dma_errors(b_err),
    .read_urgent(),
    .araddr(b_araddr),.arlen(b_arlen),.arvalid(b_arvalid),.arready(b_arready),
    .rdata(b_rdata),.rresp(b_rresp),.rlast(b_rlast),.rvalid(b_rvalid),.rready(b_rready));
  always @(posedge clk)begin
    if(b_arvalid&&b_arready)begin b_active<=1;b_addr<=b_araddr;b_len<=b_arlen;b_beat<=0;end
    if(b_rvalid&&b_rready)begin b_addr<=b_addr+16;b_beat<=b_beat+1'b1;if(b_rlast)b_active<=0;end
  end

  integer frames=0,diff=0,cycles=0,ufs=0;
  always @(posedge pix_clk)if(rst_n)begin
    #1;cycles=cycles+1;
    if({a_pixel,a_hs,a_vs,a_de}!=={b_pixel,b_hs,b_vs,b_de})begin
      diff=diff+1;
      if(diff<=8)$display("DIFF t=%0t a={%08x %0d %0d %0d} b={%08x %0d %0d %0d}",
        $time,a_pixel,a_hs,a_vs,a_de,b_pixel,b_hs,b_vs,b_de);
    end
    if(a_uf!==b_uf)begin ufs=ufs+1;
      if(ufs<=8)$display("UFDIFF t=%0t a=%0d b=%0d",$time,a_uf,b_uf);
    end
  end
  // 帧结束：用 pix_clk 侧的 h/v 计数（DUT 内部）
  always @(posedge pix_clk)begin
    if(rst_n&&ua.h==1649&&ua.v==749)begin
      frames=frames+1;
      $display("FRAME %0d cycles=%0d diff=%0d ufdiff=%0d",frames,cycles,diff,ufs);
      if(frames==2)begin
        if(diff!=0||ufs!=0)$fatal(1,"A/B mismatch");
        $display("AB-PASS");$finish;
      end
    end
  end
  initial begin repeat(4)@(negedge clk);rst_n=1;end
  initial begin #400000000;$fatal(1,"timeout");end
endmodule
