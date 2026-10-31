// 运行时切模式（板上按键等效）：在帧中间把 single 翻转，看要几帧恢复、恢复前丢多少。
//   期望模型按「帧首锁存的模式」算；如果 DUT 不在帧首切，切的那一帧会大面积 uf/bad。
`timescale 1ns/1ps
module tb_disp_boot_modes;
  reg clk=0,pix_clk=0;always #5 clk=~clk;always #6.734 pix_clk=~pix_clk;
  reg rst_n=0;reg [2:0] display_slot=0;reg display_valid=1;reg single=1;reg raw_single=1;
  wire display_frame_event,display_safe;wire [31:0] pixel,dma_errors;wire hs,vs,de,underflow;
  wire read_urgent;
  wire [31:0] araddr;wire [7:0] arlen;wire arvalid,rready;
  reg read_active=0;reg [31:0] address=32'h05000000;reg [7:0] beat=0,len=0;
  wire arready=!read_active;
  wire rvalid=read_active;
  wire rlast=beat==len;wire [1:0] rresp=0;

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
  wire [127:0] rdata=data_at(address);

  style_display dut(.clk(clk),.pix_clk(pix_clk),.rst_n(rst_n),
    .single_panel(single),.original_single(raw_single),.display_slot(display_slot),.display_valid(display_valid),
    .display_frame_event(display_frame_event),.display_safe(display_safe),
    .pixel(pixel),.hs(hs),.vs(vs),.de(de),.underflow(underflow),.dma_errors(dma_errors),
    .read_urgent(read_urgent),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready));

  always @(posedge clk)begin
    if(arvalid&&arready)begin read_active<=1;address<=araddr;len<=arlen;beat<=0;end
    if(rvalid&&rready)begin address<=address+16;beat<=beat+1'b1;if(rlast)read_active<=0;end
  end

  //   md=0 对比（左完整原画/右完整风格，v=205..564）；md=1 风格单画面 4×；
  //   md=2 raw_single（boot splash，960×720 原画）。
  function [31:0] expect_pix(input integer md, input integer vv, input integer hh);
    integer sy,sx;begin
      if(md==0)begin
        if(vv<205||vv>=565)expect_pix=0;
        else if(hh<900)expect_pix=value(0,0,60+(vv-205),hh-260);
        else begin sy=30+((vv-205)>>1);sx=(hh-900)>>1;expect_pix=value(0,1,sy,sx)^32'h00808080;end
      end else if(md==2)begin
        sy=((vv-25)*2)/3;sx=((hh-420)*2)/3;
        expect_pix=value(0,0,sy,sx);
      end else begin
        sy=30+((vv-25)>>2);sx=(hh-260)>>2;
        expect_pix=value(0,1,sy,sx)^32'h00808080;
      end
    end
  endfunction

  integer frames=0,bad=0,uf=0;integer mode_at_frame=0;
  integer oldh,oldv;
  // 帧号 1,2 对比；3 起单画面；5 起回对比。切换点在帧中间（v=300），模拟按键。
  always @(posedge pix_clk)if(rst_n)begin
    oldh=dut.h;oldv=dut.v;
    #1;
    if(oldh==0&&oldv==0)mode_at_frame=dut.raw_sync&&dut.sp_sync ? 2 : (dut.sp_sync ? 1:0);   // 帧首锁存期望模式
    if(de)begin
      if(underflow)uf=uf+1;
      // 对比：v=205..564 之外是黑边；风格单画面满屏；raw_single 左右各 160 黑边
      else if((mode_at_frame==0&&(oldv<205||oldv>=565))||(mode_at_frame==2&&(oldh<420||oldh>=1380)))begin
        if(pixel!==0)bad=bad+1;
      end else if(pixel!==expect_pix(mode_at_frame,oldv,oldh))bad=bad+1;
    end
    if(oldh==1649&&oldv==749)begin
      frames=frames+1;
      $display("FRAME %0d mode=%0d uf=%0d bad=%0d",frames,mode_at_frame,uf,bad);
      if(frames>=2&&(uf!=0||bad!=0))$fatal(1,"mode regression");
      uf=0;bad=0;
      if(frames==8)begin $display("DONE");$finish;end
    end
  end
  // 帧中间翻转（真正的按键场景）：在第 3 帧 v=300 时把 single 拉高，第 5 帧 v=300 拉低
  always @(posedge pix_clk)if(rst_n)begin
    #2;
    if(dut.v==300&&dut.h==0)begin
      if(frames==1)begin single=0;raw_single=0;$display("RAW -> COMPARE mid-frame");end
      if(frames==3)begin single=1;raw_single=0;$display("COMPARE -> STYLE mid-frame");end
      if(frames==5)begin single=1;raw_single=1;$display("STYLE -> RAW mid-frame");end
    end
  end
  initial begin repeat(4)@(negedge clk);rst_n=1;end
  initial begin #600000000;$fatal(1,"timeout");end
endmodule
