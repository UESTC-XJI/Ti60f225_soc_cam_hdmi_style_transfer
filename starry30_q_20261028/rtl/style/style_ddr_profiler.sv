//============================================================================
// style_ddr_profiler.v —— AXI 总线事件计数器
//
// 2026-10-27 说明：本模块原有 12 个 32 位计数器（提交 4fdc3c8 引入，之后被移出
// 实例化，导致固件读 APB 0x58..0x84 恒得 0）。恢复 12 个时 PnR 直接失败：
//   XLR 59,132(97.26%) → 60,689(99.82%)，峰值拥塞 2.54，
//   "Routing FAILED; could not resolve congestion"
// 实测该模块占 661 FF / 384 LUT / 2 RAM —— 本设计只剩 111 XLR，装不下。
//
// 因此只保留回答「一帧 8.5M 拍花在哪」必需的 5 项，**APB 索引与原版保持一致**
// （未实现的索引读回 0，将来有面积了再补，不必改固件地址）：
//
//   index 0 = T     : 无条件计数 = 总拍数（百分比的分母）
//   index 1 = ARST  : CNN 侧 AR 有效但未被接受（AR 反压）
//   index 2 = DARST : 显示侧 AR 反压
//   index 3 = RGAP  : 读 burst 在飞但没有 beat 到达（AR→首拍往返）
//   index 8 = BW    : 写数据发完、等 B 响应回来的拍数  ← 历史实测占整帧 86%
//   其余索引（4/5/6/7/9/10/11）本版未实现，读回 0。
//
// ⚠ 编号来源（勿再搞反）：events 是 Verilog 拼接，**最后一个元素落在 bit0**，
//   所以原版 events 的 bit0=1'b1（总拍数）、bit8=write_response&&!c_bvalid。
//   固件侧的标签序列（style_driver.c:75,78-85）与位序一致：delta[0]="T" 当分母、
//   delta[10]="RB"、delta[11]="DRB"。
//
// 计数口径：100 MHz AXI 时钟；累计不自动清零（靠 freeze 连贯读 + 固件差分）；
//           clear 只清本模块计数，不影响 AXI 跟踪。
//============================================================================
module style_ddr_profiler(
  input  wire        clk,rst_n,enable,freeze,clear,network_idle,
  input  wire        c_arvalid,c_arready,c_rvalid,c_rready,c_rlast,
  input  wire        c_awvalid,c_awready,c_wvalid,c_wready,c_wlast,c_bvalid,c_bready,
  input  wire        arvalid,arready,v_rvalid,v_rready,
  input  wire [3:0]  index,
  output wire [31:0] value
);
  reg        read_active,write_response;
  reg [31:0] c_total,c_ar_stall,c_dar_stall,c_rgap,c_bwait;

  // 读 burst 在飞：AR 被接受置位，最后一拍 R 清掉
  wire ar_stall  = c_arvalid && !c_arready;      // CNN 侧 AR 反压
  wire dar_stall = arvalid   && !arready;        // 显示侧 AR 反压
  wire rd_gap    = read_active && c_rready && !c_rvalid;  // burst 在飞但无 beat
  wire b_wait    = write_response && !c_bvalid;  // W 发完等 B

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      read_active<=1'b0; write_response<=1'b0;
      c_total<=32'd0; c_ar_stall<=32'd0; c_dar_stall<=32'd0; c_rgap<=32'd0; c_bwait<=32'd0;
    end else begin
      if(c_arvalid&&c_arready)           read_active<=1'b1;
      if(c_rvalid&&c_rready&&c_rlast)    read_active<=1'b0;
      if(c_wvalid&&c_wready&&c_wlast)    write_response<=1'b1;
      if(c_bvalid&&c_bready)             write_response<=1'b0;

      if(clear) begin
        c_total<=32'd0; c_ar_stall<=32'd0; c_dar_stall<=32'd0; c_rgap<=32'd0; c_bwait<=32'd0;
      end else if(enable&&!freeze) begin
        c_total     <= c_total     + 1'b1;
        if(ar_stall)  c_ar_stall  <= c_ar_stall  + 1'b1;
        if(dar_stall) c_dar_stall <= c_dar_stall + 1'b1;
        if(rd_gap)    c_rgap      <= c_rgap      + 1'b1;
        if(b_wait)    c_bwait     <= c_bwait     + 1'b1;
      end
    end
  end

  assign value = index==4'd0 ? c_total     :
                 index==4'd1 ? c_ar_stall  :
                 index==4'd2 ? c_dar_stall :
                 index==4'd3 ? c_rgap      :
                 index==4'd8 ? c_bwait     : 32'd0;

  // 保留但未使用的端口（避免例化处报错、便于将来补全）
  wire _unused = &{1'b0, network_idle, c_awvalid, c_awready, v_rvalid, v_rready};
endmodule
