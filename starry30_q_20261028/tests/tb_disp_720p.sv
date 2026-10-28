// ①a 回归 TB（2026-10-28）
//   模式 0（对比）：逐像素校验「原画左 640 + 风格右 640」，用于改前/改后比对。
//   模式 1（单画面）：校验 320×240 结果 4× 最近邻 + 垂直裁 30 行后铺满 1280×720。
//   +single=0/1 选择；每帧打印 CHECKSUM。
`timescale 1ns/1ps
module tb_disp_720p;
  reg clk=0,pix_clk=0;always #5 clk=~clk;always #6.734 pix_clk=~pix_clk;
  reg rst_n=0;reg [2:0] display_slot=0;reg display_valid=1;reg single=0;
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
  // 结果帧：风格基址 = slot 基址 + 0x0080_0000，跨距 1280 B（320 px），240 行
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
    .single_panel(single),.display_slot(display_slot),.display_valid(display_valid),
    .display_frame_event(display_frame_event),.display_safe(display_safe),
    .pixel(pixel),.hs(hs),.vs(vs),.de(de),.underflow(underflow),.dma_errors(dma_errors),
    .read_urgent(read_urgent),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
    .rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready));

  integer frames=0,bad=0,good=0,uf=0;integer target_frames=2;
  reg [31:0] sum=0,cx=0; reg [63:0] n=0;
  integer oldh,oldv;

  always @(posedge clk)begin
    if(arvalid&&arready)begin
      if(araddr[3:0]!=0||arlen>31||(araddr[11:0]+(arlen+1)*16)>4096)$fatal(1,"AXI boundary");
      read_active<=1;address<=araddr;len<=arlen;beat<=0;
    end
    if(rvalid&&rready)begin
      address<=address+16;beat<=beat+1'b1;if(rlast)read_active<=0;
    end
  end

  function [31:0] expect_pix(input integer vv, input integer hh);
    integer sy,sx;begin
      if(!single)begin
        if(hh<900)expect_pix=value(0,0,(vv-145),hh-260);
        else begin sy=(vv-145)>>1;sx=(hh-900)>>1;expect_pix=value(0,1,sy,sx)^32'h00808080;end
      end else begin
        sy=(vv-25)/3;sx=(hh-420)/3;
        expect_pix=value(0,1,sy,sx)^32'h00808080;
      end
    end
  endfunction

  always @(posedge pix_clk)if(rst_n)begin
    oldh=dut.h;oldv=dut.v;
    #1;
    if(hs!==(oldh<40)||vs!==(oldv<5)||de!==(oldv>=25&&oldv<745&&oldh>=260&&oldh<1540))
      $fatal(1,"720p sync stopped h=%0d v=%0d",oldh,oldv);
    // 帧首锁存的模式还不等于请求模式时（复位后第一帧），整帧不检查
    if(de&&(dut.sp_lat===single))begin
      n=n+1;sum=sum+pixel;cx=cx^pixel;
      if((!single&&(oldv<145||oldv>=625))||(single&&(oldh<420||oldh>=1380)))begin
        if(pixel!==0)$fatal(1,"letterbox not black v=%0d",oldv);
      end else if(underflow)begin
        uf=uf+1;
        if(pixel!==0)$fatal(1,"underflow not black v=%0d h=%0d",oldv,oldh);
      end else begin
        if(pixel!==expect_pix(oldv,oldh))begin
          bad=bad+1;
          if(bad<=8)$display("  ✗ v=%0d h=%0d got=%08x exp=%08x",oldv,oldh,pixel,expect_pix(oldv,oldh));
        end else good=good+1;
      end
    end
    if(oldh==1649&&oldv==749)begin
      // ①a：single_panel 在**帧首**锁存（dut.sp_lat）。复位后的第一帧仍是复位默认模式，
      // 所以只统计「整帧都在请求模式」的那些帧。
      if(dut.sp_lat===single)begin
        frames=frames+1;
        $display("CHECKSUM frame=%0d single=%0d sum=%08x xor=%08x n=%0d good=%0d bad=%0d uf=%0d err=%0d",
                 frames,single,sum,cx,n,good,bad,uf,dma_errors);
        if(frames==target_frames)begin
          if(bad!=0)$fatal(1,"pixel mismatch");
          // ①a：underflow 也是失败。像素值全对但黑点仍在，不能算回归通过。
          if(uf!=0)$fatal(1,"underflow pixels uf=%0d",uf);
          $display("PASS mode=%0d",single);$finish;
        end
      end else $display("SKIP frame (single_panel not latched yet) sum=%08x n=%0d good=%0d bad=%0d uf=%0d",sum,n,good,bad,uf);
      sum=0;cx=0;n=0;good=0;bad=0;uf=0;
    end
  end
  initial begin
    if(!$value$plusargs("single=%d",single))single=0;
    if(!$value$plusargs("frames=%d",target_frames))target_frames=2;
    repeat(4)@(negedge clk);rst_n=1;
  end
  initial begin #400000000;$fatal(1,"timeout");end
endmodule
