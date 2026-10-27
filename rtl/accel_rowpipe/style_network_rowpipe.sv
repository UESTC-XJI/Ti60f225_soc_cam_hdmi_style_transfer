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
    parameter [31:0] WEIGHT_ADDRESS = 32'h06F0_0000
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
    localparam [12*128-1:0] DESCS = {
        mk(4, 3, 640,480,640,40, 0,1,1,0,0, 2'd1,2'd2,2'd0,0, 2'd2,2'd0,2'd0), // L11
        mk(8, 4, 640,480,640,40, 0,1,1,0,1, 2'd0,2'd1,2'd0,0, 2'd1,2'd2,2'd0), // L10
        mk(8, 8, 320,240,320,20, 0,1,0,0,1, 2'd2,2'd0,2'd0,0, 2'd1,2'd1,2'd0), // L9 cap8
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

    rowpipe_frame_driver u_drv (
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
    reg [23:0] cyc_rdwait, cyc_wrwait;
    reg [15:0] ar_cnt, rl_cnt;

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
    wire [23:0] cyc_rd = (cyc_rdwait > drv_cycles[23:0]) ? drv_cycles[23:0] : cyc_rdwait;
    assign stat_read_cycles          = {8'd0, cyc_rd};
    assign stat_compute_cycles       = drv_cycles - {8'd0, cyc_rd};
    assign stat_prefetch_starts      = {16'd0, ar_cnt};
    assign stat_prefetch_completions = {16'd0, rl_cnt};
    assign stat_overlap_cycles       = {8'd0, cyc_wrwait};

    // coef 写口本版不使用（权重在 DDR blob）
    wire _unused = coef_we | coef_addr[0] | coef_word[0] | coef_data[0] | rom_addr[0] | rom_layer[0];
endmodule
