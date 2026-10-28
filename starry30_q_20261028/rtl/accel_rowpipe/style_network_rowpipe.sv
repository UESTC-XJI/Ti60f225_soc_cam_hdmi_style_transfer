//============================================================================
// style_network_rowpipe.sv —— 壳内原位替换 wrapper（D 线交付物 B 项的仿真版）
//
//   端口 = 队友 `style_network` 同款 ⇒ 直接替 style_accel 里的那一个实例。
//   内部 = rowpipe_frame_driver（12 层整网，B1g 权重 blob 流）。
//
//   差异/约束：
//   - 权重不在 coef_* 写口，必须预置在 DDR 的 WEIGHT_ADDRESS（默认 0x06F0_0000，
//     与 640 帧级 TB 的 WGT_A 一致）。
//   - rowpipe_frame_driver 的 done 是电平（保持到下次 start），而 style_accel
//     用边沿累加 done_toggle ⇒ 本 wrapper 把 done 转成单拍脉冲。
//   - rom_* 是 bench 的假 ROM 口，B1g 模式不用 ⇒ 全 0。
//   - 本模块只做集成；功能判据 = 640 帧级 TB 逐位对拍（见 tb/tb_style_network_640.v）。
//============================================================================
`timescale 1ns / 1ps

module style_network_rowpipe #(
    parameter [31:0] WEIGHT_ADDRESS = 32'h06F0_0000,
    // ---- Track3 算力优化开关（2026-10-27）----------------------------------
    // 0 = 现状：L10/L11 都在 640x480 卷积（L10 用 up=1 读 L9 的 320x240）
    // 1 = 方案 A：L10 降到 320x240 卷积（up=0），L11 保持 640x480 但用 up=1
    //     读 L10 的 320x240 输出。**输出分辨率不变、权重原样复用**。
    //     算力 33.16ms -> 24.63ms（-25.7%），代价是输出高频细节变少（画面更柔）。
    // 设计依据见 reports/TRACK3_COMPUTE_RESTRUCTURE.md。
    // 3x3 卷积权重与分辨率无关 ⇒ 换这个开关不需要换任何权重文件。
    parameter integer TAIL_LOWRES = 0,
    // ---- 仿真专用：微小几何（2026-10-27，CI/CO 等价性 A/B 用）-------------
    //   1 = 把 12 层描述符的 win/hout/wout/ng 换成微小尺寸（结果帧 64x48），
    //       **ci/cout/res/resu/xorin/s2/up/srcb/dstb/idb/idxor/srcf/dstf/idf 全部不变**。
    //       目的是把一帧从 4.9M 拍压到 ~8 万拍，好让 iverilog 能跑 A/B。
    //       尺寸关系仍是设计允许的那一套：s2=0 层 win==wout 且 win%16==0（ng=win/16）；
    //       s2=1 层 win==2*wout 且 ng=wout/8；up=1 层 hout%2==0。
    //   ⚠ **默认 0 ⇒ 与现状逐位相同**，综合/时序/面积零影响（只多一个常量选择器，
    //      综合按 TB_TINY=0 折叠）。
    parameter integer TB_TINY = 0
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [31:0]  source_address,
    input  wire [31:0]  result_address,
    input  wire [9:0]   frame_width,
    input  wire [9:0]   frame_height,
    // coef 写口：本核权重走 DDR blob，这里接收但忽略（double-style 的 plan B 以后接）
    input  wire         coef_we,
    input  wire [7:0]   coef_addr,
    input  wire [4:0]   coef_word,
    input  wire [31:0]  coef_data,
    output wire         busy,
    output wire         done,
    output wire         error,
    output wire [4:0]   layer_index,
    output wire [31:0]  cycles,
    output wire [31:0]  stat_read_cycles,
    output wire [31:0]  stat_compute_cycles,
    output wire [31:0]  stat_prefetch_starts,
    output wire [31:0]  stat_prefetch_completions,
    output wire [31:0]  stat_overlap_cycles,
    output wire [31:0]  araddr,
    output wire [7:0]   arlen,
    output wire         arvalid,
    input  wire         arready,
    input  wire [127:0] rdata,
    input  wire [1:0]   rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,
    output wire [31:0]  awaddr,
    output wire [7:0]   awlen,
    output wire         awvalid,
    input  wire         awready,
    output wire [127:0] wdata,
    output wire [15:0]  wstrb,
    output wire         wlast,
    output wire         wvalid,
    input  wire         wready,
    input  wire [1:0]   bresp,
    input  wire         bvalid,
    output wire         bready
);

    // ---- 12 层描述符（与 tb_rowpipe_frame640 的 descs 逐位相同）----
    function [127:0] mk;
        input integer ci, cout, win, hout, wout, ng;
        input res, resu, xorin, s2, up;
        input [1:0] srcb, dstb, idb;
        input idxor;
        input [1:0] srcf, dstf, idf;
        begin
            mk = {22'd0, idf, dstf, srcf, idxor, idb, dstb, srcb, up, s2, xorin, resu, res,
                  ng[7:0], wout[15:0], hout[15:0], win[15:0], cout[15:0], ci[15:0]};
        end
    endfunction

    // 注意拼接顺序：左高右低 ⇒ DESCS[0 +: 128] = L0
    localparam [12*128-1:0] DESCS_FULL = {
        // ---- A-3（2026-10-28）：L11 也降到半分辨率 ---------------------------
        //   TAIL_LOWRES=1 时：L11 直读 L10 的 320x240（up=0），卷积 320x240（4,800 组，原 19,200 组）
        //   ⇒ 算力 7.37 ms → 1.82 ms（省 5.55 ms）。
        //   **结果帧仍是 640x480**：由 rowpipe_ddr_banks 的结果写通道做 2x2 复制
        //   （每个源 beat 铺 2 个水平 beat、每个源行写两遍），总写 beat 数不变（76,800）。
        //   ⚠ 成对约束：这里的 320/240 与 rowpipe_ddr_banks.v 的 `RESULT_X2 / X2_SRC_W` 必须一致；
        //     不一致时 `result_done` 永远不会成立 ⇒ driver 卡在 S_FLUSH（响铃式失败，不会画错图）。
        //   TAIL_LOWRES=0 时保持原样（640x480 全分辨率、up=1 读 L10 的 320x240 上采样）。
        mk(4, 3, TAIL_LOWRES?320:640, TAIL_LOWRES?240:480, TAIL_LOWRES?320:640, TAIL_LOWRES?20:40,
              0,1,1,0, TAIL_LOWRES?0:1, 2'd1,2'd2,2'd0,0, 2'd2,2'd0,2'd0), // L11
        // Track3：TAIL_LOWRES=1 时 L10 降到 320x240 卷积。
        //   A-1 之后 L9 也是半分辨率，所以 L10 始终 up=1（上采样接回 320x240）。
        mk(8, 4, TAIL_LOWRES?320:640, TAIL_LOWRES?240:480, TAIL_LOWRES?320:640, TAIL_LOWRES?20:40,
              0,1,1,0, 1, 2'd0,2'd1,2'd0,0, 2'd1,2'd2,2'd0), // L10  up 恒为 1：L9 半分辨率后靠上采样接回
        // A-1（2026-10-28）：TAIL_LOWRES=1 时 L9 也降到半分辨率（读 L8 的 160x120 直通，up=0），
        //   输出 160x120 -> 由 L10 的 up=1 上采样接回 320x240。省 2.24 ms。
        //   链路一致性：L9 输出 160x120 后，L10 用 srcW=win/2=160、输入行 hout/2=120 正好接上；
        //   L9 的 res=0，所以不存在残差尺寸不匹配。
        mk(8, 8, TAIL_LOWRES?160:320, TAIL_LOWRES?120:240, TAIL_LOWRES?160:320, TAIL_LOWRES?10:20,
              0,1,0,0, TAIL_LOWRES?0:1, 2'd2,2'd0,2'd0,0, 2'd1,2'd1,2'd0), // L9 cap8
        mk(8,8, 160,120,160,10, 1,0,1,0,0, 2'd1,2'd2,2'd0,0, 2'd1,2'd1,2'd1), // L8 cap8
        mk(8, 8, 160,120,160,10, 0,1,0,0,0, 2'd0,2'd1,2'd0,0, 2'd1,2'd1,2'd0), // L7 cap8
        mk(8, 8, 160,120,160,10, 1,0,1,0,0, 2'd2,2'd0,2'd1,0, 2'd1,2'd1,2'd1), // L6 cap8
        mk(8, 8, 160,120,160,10, 0,1,0,0,0, 2'd1,2'd2,2'd0,0, 2'd1,2'd1,2'd0), // L5 cap8
        mk(8, 8, 160,120,160,10, 1,1,1,0,0, 2'd0,2'd1,2'd2,1, 2'd1,2'd1,2'd1), // L4 cap8
        mk(8, 8, 160,120,160,10, 0,1,1,0,0, 2'd2,2'd0,2'd0,0, 2'd1,2'd1,2'd0), // L3 cap8
        mk(8, 8, 320,120,160,20, 0,1,1,1,0, 2'd1,2'd2,2'd0,0, 2'd1,2'd1,2'd0), // L2 cap8
        mk(4, 8, 640,240,320,40, 0,1,1,1,0, 2'd0,2'd1,2'd0,0, 2'd2,2'd1,2'd0), // L1
        mk(3, 4, 640,480,640,40, 0,1,1,0,0, 2'd3,2'd0,2'd0,0, 2'd0,2'd2,2'd0)  // L0
    };

    // ---- TB_TINY 用的一套微小几何（结果帧 64x48；标志位与上面逐层一一对应）----
    //   缩放关系：640→64、320→32、160→16；hout 全部 /10（up 层保持偶数）。
    //   ng：s2=0 ⇒ win/16；s2=1 ⇒ wout/8。
    //   A-3（2026-10-28）：尾部三层按 A-3 的形状等比缩小 ——
    //     L9 16x12（up=0，1:1 读 L8）→ L10 32x24（up=1，上采样接回）→ L11 32x24（up=0，1:1 读 L10）
    //     → 结果帧 64x48 由 rowpipe_ddr_banks 的 2×2 复制产生（X2_SRC_W=32 / X2_TGT_W=64）。
    //   中间六层随之降到 16x12（ng=1），保证 L9 能 1:1 直读。
    localparam [12*128-1:0] DESCS_TINY = {
        mk(4, 3, 32,24,32,2,   0,1,1,0,0,   2'd1,2'd2,2'd0,0, 2'd2,2'd0,2'd0), // L11  A-3：半分辨率 + 2× 复制
        mk(8, 4, 32,24,32,2,   0,1,1,0,1,   2'd0,2'd1,2'd0,0, 2'd1,2'd2,2'd0), // L10  up=1 接回 32x24
        mk(8, 8, 16,12,16,1,   0,1,0,0,0,   2'd2,2'd0,2'd0,0, 2'd1,2'd1,2'd0), // L9  cap8  A-3：up=0 直读 L8
        mk(8, 8, 16,12,16,1,   1,0,1,0,0,   2'd1,2'd2,2'd0,0, 2'd1,2'd1,2'd1), // L8  cap8
        mk(8, 8, 16,12,16,1,   0,1,0,0,0,   2'd0,2'd1,2'd0,0, 2'd1,2'd1,2'd0), // L7  cap8
        mk(8, 8, 16,12,16,1,   1,0,1,0,0,   2'd2,2'd0,2'd1,0, 2'd1,2'd1,2'd1), // L6  cap8
        mk(8, 8, 16,12,16,1,   0,1,0,0,0,   2'd1,2'd2,2'd0,0, 2'd1,2'd1,2'd0), // L5  cap8
        mk(8, 8, 16,12,16,1,   1,1,1,0,0,   2'd0,2'd1,2'd2,1, 2'd1,2'd1,2'd1), // L4  cap8
        mk(8, 8, 16,12,16,1,   0,1,1,0,0,   2'd2,2'd0,2'd0,0, 2'd1,2'd1,2'd0), // L3  cap8
        mk(8, 8, 32,12,16,2,   0,1,1,1,0,   2'd1,2'd2,2'd0,0, 2'd1,2'd1,2'd0), // L2  cap8
        mk(4, 8, 64,24,32,4,   0,1,1,1,0,   2'd0,2'd1,2'd0,0, 2'd2,2'd1,2'd0), // L1
        mk(3, 4, 64,48,64,4,   0,1,1,0,0,   2'd3,2'd0,2'd0,0, 2'd0,2'd2,2'd0)  // L0
    };

    // TB_TINY=0 ⇒ DESCS == DESCS_FULL（与改动前逐位相同）
    localparam [12*128-1:0] DESCS = TB_TINY ? DESCS_TINY : DESCS_FULL;

    wire [127:0] rom_w   = 128'd0;
    wire [31:0]  rom_b   = 32'd0;
    wire [31:0]  rom_m   = 32'd0;
    wire [31:0]  rom_mid = 32'd0;
    wire [5:0]   rom_shift = 6'd0;
    wire signed [7:0] rom_qlo = 8'sd0;
    wire [7:0]   rom_qhi = 8'd0;
    wire [3:0]   rom_layer;
    wire [7:0]   rom_addr;

    wire drv_busy, drv_done, drv_error;
    wire [3:0] drv_layer;
    wire [31:0] drv_cycles;

    // TAIL_LOWRES 同时驱动描述符几何与写通道 2x2 复制（单一来源，见 frame_driver 模块头）
    rowpipe_frame_driver #(.TAIL_LOWRES(TAIL_LOWRES)) u_drv (
        .clk(clk), .rst_n(rst_n), .start(start),
        .source_address(source_address), .result_address(result_address),
        .weight_address(WEIGHT_ADDRESS),
        .frame_width(frame_width), .frame_height(frame_height),
        .descs(DESCS),
        .busy(drv_busy), .done(drv_done), .error(drv_error),
        .layer_index(drv_layer), .cycles(drv_cycles),
        .rom_layer(rom_layer), .rom_addr(rom_addr),
        .rom_w(rom_w), .rom_b(rom_b), .rom_m(rom_m), .rom_mid(rom_mid),
        .rom_shift(rom_shift), .rom_qlo(rom_qlo), .rom_qhi(rom_qhi),
        .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );

    // done：driver 保持电平 → 单拍脉冲（style_accel 按边沿累加 done_toggle）
    reg done_seen;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) done_seen <= 1'b0;
        else        done_seen <= drv_done;
    assign done = drv_done && !done_seen;

    assign busy      = drv_busy;
    assign error     = drv_error;
    assign layer_index = {1'b0, drv_layer};
    assign cycles    = drv_cycles;

    // ==========================================================================
    // 性能快照（2026-10-27 恢复，采用**修正后的口径**）
    //
    // 历史：这 5 个口一直硬接 32'd0，导致固件从 APB 0xa8/ac/b0/b4/b8 读到的永远是 0。
    // 上一版曾按"AXI 反压"实现，被回退 —— 因为那个口径看不见本设计的主导现象
    // （burst 在飞、但 beat 还没到），会与 style_ddr_profiler 打出互相矛盾的数据
    // （RPMS 0 / CPMS 57 对 B 86）。本版口径与 profiler 的 counter[3]/counter[8] 一致。
    //
    // 口径（全部按 cnn_clk = 148.5 MHz 累计，每帧 start 清零）：
    //   read_cycles          = AR 未被接受 或 (burst 在飞但本拍没有 beat)
    //   compute_cycles       = drv_cycles − read_cycles   （drv_cycles 只在 S_RUN/S_FLUSH 自增）
    //   prefetch_starts      = AR 握手次数（发出的读 burst 数）
    //   prefetch_completions = R 末拍握手次数（完成的读 burst 数）
    //   overlap_cycles       = 【已改用】W 发完、等 B 回来的拍数（= profiler counter[8]）
    //
    // 位宽：一帧约 7.4M 拍 ⇒ 24 位够（16.7M）；burst 数约 39k ⇒ 16 位够（65.5k）。
    // ==========================================================================
    reg        rd_active, wr_pend;
    reg [23:0] cyc_rdwait, cyc_wrwait;   // 24 位=16.7M 拍@148.5MHz=113ms，对当前 50ms 帧够用
    reg [15:0] ar_cnt, rl_cnt;   // 16 位=65,535 burst，当前 39k；网络放大会先撞这个

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active <= 1'b0; wr_pend <= 1'b0;
            cyc_rdwait <= 24'd0; cyc_wrwait <= 24'd0; ar_cnt <= 16'd0; rl_cnt <= 16'd0;
        end else if (start) begin
            rd_active <= 1'b0; wr_pend <= 1'b0;
            cyc_rdwait <= 24'd0; cyc_wrwait <= 24'd0; ar_cnt <= 16'd0; rl_cnt <= 16'd0;
        end else begin
            if (arvalid && arready)            rd_active <= 1'b1;
            if (rvalid && rready && rlast)     rd_active <= 1'b0;
            if (wvalid && wready && wlast)     wr_pend   <= 1'b1;
            if (bvalid && bready)              wr_pend   <= 1'b0;

            if (drv_busy) begin
                // ⚠ 24 位计数在 148.5MHz 下 113ms 满量程。当前帧 50ms（7.4M 拍），
                //   有 2.2 倍余量。**若将来帧时间超过 113ms，这里会静默回绕** ——
                //   试过加饱和比较器，但那个组合逻辑进了 vid_clk_dvi2（6.734ns）域
                //   的使能路径，实测把该域 setup slack 从 +0.252 打到 -0.710 ns，
                //   所以退回简单自增。要用满 32 位宽计数器必须先腾面积（CI/CO 16→8）。
                if ((arvalid && !arready) || (rd_active && !rvalid))
                    cyc_rdwait <= cyc_rdwait + 1'b1;
                if (wr_pend && !bvalid)
                    cyc_wrwait <= cyc_wrwait + 1'b1;
            end
            if (arvalid && arready)            ar_cnt <= ar_cnt + 1'b1;
            if (rvalid && rready && rlast)     rl_cnt <= rl_cnt + 1'b1;
        end
    end

    // drv_cycles 只在 S_RUN/S_FLUSH 自增，与 drv_busy 等价 ⇒ 不必再单独维护一个 32 位计数器
    // 24 位计数 → 与 32 位的 drv_cycles 对齐后再钳一次，
    // 防 power-on 后首帧尚未 start 就已有残值的极端情形。
    wire [31:0] cyc_rd = ({8'd0, cyc_rdwait} > drv_cycles) ? drv_cycles : {8'd0, cyc_rdwait};
    assign stat_read_cycles          = cyc_rd;
    assign stat_compute_cycles       = drv_cycles - cyc_rd;
    assign stat_prefetch_starts      = {16'd0, ar_cnt};
    assign stat_prefetch_completions = {16'd0, rl_cnt};
    assign stat_overlap_cycles       = {8'd0, cyc_wrwait};

    // coef 写口本版不使用（权重在 DDR blob）
    wire _unused = coef_we | coef_addr[0] | coef_word[0] | coef_data[0] | rom_addr[0] | rom_layer[0];
endmodule
