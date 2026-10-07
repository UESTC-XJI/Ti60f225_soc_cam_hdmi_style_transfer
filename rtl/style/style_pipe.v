//============================================================================
// style_pipe.v —— 上板线第一刀：插在 v7 显示链里的风格迁移占位内核
//
// ## 插在哪（`ti60f225_oob_top.v` 实测，别按旧记录理解）
//
//     CSI-2 RX(RAW) → frame_buffer(DDR 三缓冲) → cvo_axi → debayer_top
//       → rgb_datax2(48b,2像素/拍) ──【★本模块★】──→ vid_cnt 选择块 → dvi_encoder → TMDS
//
// ⚠ **debayer 不在存储路径上**（RAW 直接进 DDR），风格迁移**只能**插在
//   `rgb_datax2` 与 `vid_cnt` 选择块之间。之前"Debayer→风格→cvo_axi"的顺序是错的。
//
// ## 信号约定（和 v7 现成逻辑对齐，改一处必须核另一处）
//
//   i_rgb = `{p1B,p1G,p1R, p0B,p0G,p0R}` —— 每像素 `{B,G,R}`，**R 是最低字节**。
//     ⚠ 证据取**源码那一行**，不是注释：
//       `rtl/debayer/debayer_top_2to1.v:148`
//         `rgb_datax2_o = {b[15:8],g[15:8],r[15:8], b[7:0],g[7:0],r[7:0]}`
//       ⇒ 低字节 = r ✓。（顶层那行旁边的 `//b,g,r,b,g,r` 注释是**误导源**，别按它走。）
//   i_vs/i_hs/i_de 与 i_rgb **同拍**（同一域、同一拍有效）。
//
// ## 时钟域（SDC 实测，不是猜的）
//
//   `vid_clk_dvi2` 13.468ns = 74.25MHz （debayer / AE / frame_buffer 读侧）
//   `hdmi_tx_slow_clk` 6.734ns = 148.5MHz （vid_cnt 选择块 / dvi_encoder）
//   两条是**各自独立的 create_clock**，只差 2:1；而 v7 的 vid_cnt 块**本来就直接采**
//   vid_clk_dvi2 域的 `rgb_datax2/rgb_vs/rgb_hs/rgb_de` ⇒ 本模块**按原样同域处理**
//   （clk 接 `hdmi_tx_slow_clk`，与下游采样域一致），**第一版不加 CDC FIFO**。
//   若 PnR 报跨域，那是 v7 既有的边界，不是本模块引入的。
//
// ## 为什么第 1 版是**组合直通**（`o_rgb = i_rgb`）
//
//   vid_cnt 块把 `rgb_datax2` 与 `rgb_vs/hs/de` **同拍组合**消费。若本模块把数据打一拍，
//   数据就比同步信号晚一周期 ⇒ 画面错位一格。**直通必须是零延迟**。
//   （第 3 步接真内核时，延迟不再是 0 —— 那时要给 vs/hs/de 配**等量的行延迟**，
//     见 README「第 3 步的坑」。）
//
// ## 接口（第 1 步就按这个例化，后面两步只改内部/顶层接线）
//============================================================================
`timescale 1ns / 1ps

module style_pipe #(
    parameter PIXELS_PER_CLK = 2,        // 每拍像素数（v7 固定 2）
    parameter CH_WIDTH       = 8         // 每通道位宽
)(
    input  wire                     clk,        // hdmi_tx_slow_clk（与下游 vid_cnt 同域）
    input  wire                     rst_n,      // vid_rst_n
    input  wire                     i_vs,       // rgb_vs
    input  wire                     i_hs,       // rgb_hs
    input  wire                     i_de,       // rgb_de
    input  wire [6*CH_WIDTH-1:0]    i_rgb,      // {p1B,p1G,p1R,p0B,p0G,p0R}，R 最低字节
    output wire [6*CH_WIDTH-1:0]    o_rgb,      // 同格式，喂 vid_cnt 选择块
    input  wire                     style_sel,  // 0=直通 1=风格（第 2 步接 VIO）
    input  wire                     start,      // 帧启动（接 `pos_vs`）
    output wire                     busy,       // 处理中（直通版恒 0）
    output wire                     done        // 帧完成脉冲（直通版随 i_vs 下落）
);

    //------------------------------------------------------------------------
    // 第 1 步：直通。**零延迟** —— 见文件头，打一拍会与 vs/hs/de 错位。
    // 第 2 步：style_sel=1 时做 R/B 交换（每个像素内首尾字节对调，G 不动）。
    //         ⚠ 它必须仍是**组合**的：vid_cnt 块对 i_rgb 的组合消费方式不能变。
    //
    // ⚠⚠ **一个像素是 3 个通道 = `3*CH_WIDTH` 位，不是 `2*CH_WIDTH`。**
    //    第一版就写成 `2*CH_WIDTH`（= 16 位）——把 B 字节整个丢掉、G 当成了尾字节。
    //    Verilog **不报错**：16 位拼接赋给 24 位返回值只是零扩展。
    //    而第 1 步 `style_sel` 是常量 0 ⇒ 整块被综合剪掉 ⇒ **PnR 全绿也照样带着它出厂**。
    //    以后凡"桶/字宽"常量，先数一遍是几个通道。
    //------------------------------------------------------------------------
    localparam integer PW = 3 * CH_WIDTH;      // 每像素位宽 = 24

    function [PW-1:0] swap_rb;
        input [PW-1:0] px;                     // {B,G,R}
        begin
            swap_rb = {px[CH_WIDTH-1:0],                 // R
                       px[2*CH_WIDTH-1:CH_WIDTH],        // G
                       px[3*CH_WIDTH-1:2*CH_WIDTH]};     // B
        end
    endfunction

    wire [PW-1:0] px0 = i_rgb[PW-1:0];               // 低 24 位 = p0
    wire [PW-1:0] px1 = i_rgb[2*PW-1:PW];            // 高 24 位 = p1

    assign o_rgb = style_sel ? { swap_rb(px1), swap_rb(px0) } : i_rgb;

    //------------------------------------------------------------------------
    // 帧边界握手（第 3 步接真内核时 busy/done 才有内容；现在先给下游/VIO 一个可用电平）
    //
    //   `vs_rise` / `vs_fall`：i_vs 的上升/下降沿，**在本时钟域**打拍后做边沿检测
    //   （与 v7 顶层算 `pos_vs` 的手法一致）。
    //
    // ⚠ **`done` 做成"电平"，不是"一拍脉冲"** —— 这是对指示文档 §2 的有意偏离：
    //   本模块跑在 **148.5MHz**，一拍 = 6.7ns，而 JTAG VIO 的采样率是 **kHz 级**，
    //   **一个脉冲根本采不到**（现象＝"done 一直是 0"，会被误判成模块没跑完）。
    //   所以：**帧末拉高、下一帧开始拉低**，整个场消隐期都保持高 ⇒ VIO 能看见、
    //   第 3 步软件轮询也能用。（第 3 步若真需要脉冲，让消费侧自己取边沿。）
    //------------------------------------------------------------------------
    reg vs_d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= i_vs;

    wire vs_rise = ~vs_d &  i_vs;     // 帧开始
    wire vs_fall =  vs_d & ~i_vs;     // 帧结束

    reg done_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)        done_r <= 1'b0;
        else if (vs_rise)  done_r <= 1'b0;
        else if (vs_fall)  done_r <= 1'b1;

    assign done = done_r;
    assign busy = 1'b0;               // 直通版恒 0

    // ⚠ 本版**故意不消费** `start` / `i_hs` / `i_de`：
    //   v7 的 vid_cnt 块直接用 `rgb_vs/rgb_hs/rgb_de`，数据通路只重定向 i_rgb→o_rgb，
    //   所以这里不需要把它们转发出去。合成报 unused port 是**预期**的，不是漏接。
    //   `start`（接 pos_vs）从第 3 步起用来启动真内核。

endmodule
