//============================================================================
// tb_layer_ci_trunc.v —— 单元级证明：CI/CO 16→8 的**位宽截断**是否安全
//
// 待验证的核心风险（Lead 点名）：
//   rowpipe_layer 的 i_id / s_col 端口宽 = CI*8。CI 16→8 时端口从 128 位缩到 64 位，
//   而 rowpipe_engine 仍然用 128 位的 id_word / 数据字驱动它 ⇒ **只取低 64 位**。
//   这条是否正确，取决于"通道 ≥ 8 的字节会不会影响输出"。
//
// 本 TB 用三个 DUT 同时吃**同一套激励**（s_vld/grp/skip/cfg 完全共享）：
//   A：CI=16/CO=16，s_col/i_id 的**高 64 位 = 0xAA 图案**
//   B：CI=16/CO=16，s_col/i_id 的**高 64 位 = 0x55 图案**（只有高通道不同）
//   C：CI=8 /CO=8 ，端口 64 位（高 64 位被剪掉 = 真实的 CI=8 情形）
//   断言 1：A 的 o_col 流 == B 的 o_col 流   ⇒ 高通道字节对输出**无影响**
//   断言 2：A 的 o_col 流 == C 的 o_col 流   ⇒ 截断到 64 位**等价**
//   断言 3：三者的 s_ack 序列相同           ⇒ 消费节奏不受影响（这条若不成立，
//           说明宽度影响了 advance 逻辑，那问题就大了）
//
// 配置取**残差层**（cfg_res=1, resu=1），因为恒等支 i_id 正是待验证的端口；
// 权重/M/mid 全部用确定性图案装载，保证输出是数据相关、且不饱和（能看见差异）。
//
// 编译：见 _sim/run_unit.sh
//============================================================================
`timescale 1ns / 1ps

module tb_layer_ci_trunc;

    localparam integer WIN  = 32;
    localparam integer NG   = 2;
    localparam integer HOUT = 12;
    localparam integer WOUT = 32;
    localparam integer NGRP = NG * HOUT;          // 24 组
    localparam integer NPIX = NGRP * 16;          // 384 像素

    reg clk = 0, rst_n = 0;
    always #3.367 clk = ~clk;

    // ---- 共享激励 ----
    reg         s_vld = 0, grp_vld = 0, skip_vld = 0, cfg_we = 0, ld_we = 0, ld_be = 0, ld_me = 0;
    reg  [7:0]  cfg_addr = 0, ld_waddr = 0, ld_baddr = 0, ld_midx = 0;
    reg  [15:0] cfg_data = 0;
    reg  [31:0] ld_bdata = 0, ld_m = 0, ld_mid = 0;
    reg  [5:0]  ld_shift = 0;
    reg  signed [7:0] ld_qlo = 0;
    reg  [7:0]  ld_qhi = 0;
    reg  [127:0] ld_wdata128 = 0;

    // 输入数据：低 64 位 = 数据，高 64 位 = 图案（A/B 不同）
    reg  [63:0]  dat_low = 0;     // s_col 低半
    reg  [63:0]  id_low  = 0;     // i_id  低半
    localparam [63:0] HIGH_A = 64'hA5A5_A5A5_A5A5_A5A5;
    localparam [63:0] HIGH_B = 64'h5A5A_5A5A_5A5A_5A5A;

    wire [127:0] s_col_A = {HIGH_A, dat_low};
    wire [127:0] s_col_B = {HIGH_B, dat_low};
    wire [127:0] i_id_A  = {HIGH_A, id_low};
    wire [127:0] i_id_B  = {HIGH_B, id_low};

    wire [63:0]  dat_low_d = dat_low ^ 64'h0000_0000_0000_0001;   // 负向对照：翻通道0的LSB
    wire [127:0] ocol_D;
    wire         o_vld_D, ack_D;
    wire [3:0]   st_D;

    // ---- DUT A / B / C ----
    wire [127:0] ocol_A, ocol_B;
    wire [63:0]  ocol_C;
    wire o_vld_A, o_vld_B, o_vld_C;
    wire ack_A, ack_B, ack_C;
    wire [3:0] st_A, st_B, st_C;

    rowpipe_layer #(.CI(16), .CIW(8), .PIX(16), .CO(16), .COUT(16)) uA (
        .clk(clk), .rst_n(rst_n),
        .ld_we(ld_we), .ld_waddr(ld_waddr), .ld_wdata(ld_wdata128),
        .ld_be(ld_be), .ld_baddr(ld_baddr), .ld_bdata(ld_bdata),
        .ld_me(ld_me), .ld_midx(ld_midx), .ld_m(ld_m), .ld_mid(ld_mid),
        .ld_shift(ld_shift), .ld_qlo(ld_qlo), .ld_qhi(ld_qhi),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .s_vld(s_vld), .s_col(s_col_A), .grp_vld(grp_vld), .skip_vld(skip_vld),
        .o_vld(o_vld_A), .o_col(ocol_A), .o_ready(1'b1), .o_row_end(), .o_pix_done(),
        .s_ack(ack_A), .o_st(st_A), .o_id(), .i_id(i_id_A)
    );

    rowpipe_layer #(.CI(16), .CIW(8), .PIX(16), .CO(16), .COUT(16)) uB (
        .clk(clk), .rst_n(rst_n),
        .ld_we(ld_we), .ld_waddr(ld_waddr), .ld_wdata(ld_wdata128),
        .ld_be(ld_be), .ld_baddr(ld_baddr), .ld_bdata(ld_bdata),
        .ld_me(ld_me), .ld_midx(ld_midx), .ld_m(ld_m), .ld_mid(ld_mid),
        .ld_shift(ld_shift), .ld_qlo(ld_qlo), .ld_qhi(ld_qhi),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .s_vld(s_vld), .s_col(s_col_B), .grp_vld(grp_vld), .skip_vld(skip_vld),
        .o_vld(o_vld_B), .o_col(ocol_B), .o_ready(1'b1), .o_row_end(), .o_pix_done(),
        .s_ack(ack_B), .o_st(st_B), .o_id(), .i_id(i_id_B)
    );

    // DUT D：**负向对照** —— 与 A 完全相同，只把通道 0 的最低位取反。
    //   它必须与 A **不同**，否则说明本比对/激励根本没有判别力。
    rowpipe_layer #(.CI(16), .CIW(8), .PIX(16), .CO(16), .COUT(16)) uD (
        .clk(clk), .rst_n(rst_n),
        .ld_we(ld_we), .ld_waddr(ld_waddr), .ld_wdata(ld_wdata128),
        .ld_be(ld_be), .ld_baddr(ld_baddr), .ld_bdata(ld_bdata),
        .ld_me(ld_me), .ld_midx(ld_midx), .ld_m(ld_m), .ld_mid(ld_mid),
        .ld_shift(ld_shift), .ld_qlo(ld_qlo), .ld_qhi(ld_qhi),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .s_vld(s_vld), .s_col({HIGH_A, dat_low_d}), .grp_vld(grp_vld), .skip_vld(skip_vld),
        .o_vld(o_vld_D), .o_col(ocol_D), .o_ready(1'b1), .o_row_end(), .o_pix_done(),
        .s_ack(ack_D), .o_st(st_D), .o_id(), .i_id(i_id_A)
    );

    // DUT C：真实 CI=8 情形（端口 64 位，高 64 位被剪）
    rowpipe_layer #(.CI(16), .CIW(8), .PIX(16), .CO(16), .COUT(16)) uC (
        .clk(clk), .rst_n(rst_n),
        .ld_we(ld_we), .ld_waddr(ld_waddr), .ld_wdata(ld_wdata128[63:0]),
        .ld_be(ld_be), .ld_baddr(ld_baddr), .ld_bdata(ld_bdata),
        .ld_me(ld_me), .ld_midx(ld_midx), .ld_m(ld_m), .ld_mid(ld_mid),
        .ld_shift(ld_shift), .ld_qlo(ld_qlo), .ld_qhi(ld_qhi),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .s_vld(s_vld), .s_col(dat_low), .grp_vld(grp_vld), .skip_vld(skip_vld),
        .o_vld(o_vld_C), .o_col(ocol_C), .o_ready(1'b1), .o_row_end(), .o_pix_done(),
        .s_ack(ack_C), .o_st(st_C), .o_id(), .i_id(id_low)
    );
    defparam uC.CI   = 8;
    defparam uC.CO   = 8;
    defparam uC.COUT = 8;

    //========================================================================
    // 输入列流：按 A 的 s_ack 推进（并检查三个 DUT 的 s_ack 每拍一致）
    //========================================================================
    integer cidx = 0;
    integer ack_err = 0;
    integer ack_cnt_A = 0;
    reg [63:0] ack_hash_A = 0, ack_hash_B = 0, ack_hash_C = 0;

    function [63:0] col_low(input integer ci);      // 128→64 位数据（8 通道）
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                col_low[8*b +: 8] = ((ci * 29 + b * 53 + (ci >> 3) * 11) & 8'hFF);
        end
    endfunction
    function [63:0] id_low_f(input integer ci);
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                id_low_f[8*b +: 8] = ((ci * 17 + b * 31 + (ci >> 2) * 5) & 8'hFF);
        end
    endfunction

    always @(posedge clk) begin
        if (s_vld && rst_n) begin
            // 三者的消费节奏必须完全一致
            if (ack_A !== ack_B || ack_A !== ack_C) ack_err <= ack_err + 1;
            if (ack_A) begin
                ack_cnt_A   <= ack_cnt_A + 1;
                ack_hash_A  <= ack_hash_A  ^ {63'd0, ack_A} ^ {ack_hash_A[62:0], 1'b0};
                cidx        <= cidx + 1;
            end
        end
    end

    always @* begin
        dat_low = col_low(cidx);
        id_low  = id_low_f(cidx);
    end

    //========================================================================
    // 输出捕获
    //========================================================================
    reg [127:0] capA [0:NPIX-1];
    reg [127:0] capB [0:NPIX-1];
    reg [127:0] capC [0:NPIX-1];
    reg [127:0] capD [0:NPIX-1];
    integer nA = 0, nB = 0, nC = 0, nD = 0;

    always @(posedge clk) begin
        if (o_vld_A && 1'b1) begin if (nA < NPIX) capA[nA] <= ocol_A; nA <= nA + 1; end
        if (o_vld_B && 1'b1) begin if (nB < NPIX) capB[nB] <= ocol_B; nB <= nB + 1; end
        if (o_vld_C && 1'b1) begin if (nC < NPIX) capC[nC] <= {64'd0, ocol_C}; nC <= nC + 1; end
        if (o_vld_D && 1'b1) begin if (nD < NPIX) capD[nD] <= ocol_D; nD <= nD + 1; end
    end

    //========================================================================
    // 主流程
    //========================================================================
    integer i, k;
    integer dAB = 0, dAC = 0, dAD = 0, firstAB = -1, firstAC = -1, firstAD = -1;
    integer cyc0;

    task cfg_write(input [7:0] a, input [15:0] d);
        begin
            @(posedge clk); cfg_we <= 1'b1; cfg_addr <= a; cfg_data <= d;
            @(posedge clk); cfg_we <= 1'b0;
        end
    endtask

    task wait_idle;
        integer guard;
        begin
            guard = 0;
            @(posedge clk);
            while ((st_A !== 4'd0) && (guard < 100000)) begin
                @(posedge clk); guard = guard + 1;
            end
            if (guard >= 100000) begin
                $display("** ERROR: 等 S_IDLE 超时（st_A=%0d）", st_A);
                $finish;
            end
        end
    endtask

    initial begin
        for (i = 0; i < NPIX; i = i + 1) begin capA[i] = 0; capB[i] = 0; capC[i] = 0; capD[i] = 0; end

        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n <= 1;
        repeat (4) @(posedge clk);

        // ---- cfg（残差层，ci=8/cout=8，win=32，ng=2，hout=12）----
        cfg_write(8'd0, WIN);
        cfg_write(8'd1, NG);
        cfg_write(8'd2, HOUT);
        cfg_write(8'd3, WOUT);
        cfg_write(8'd4, 16'd1);      // RES  = 1  ⇒ 走恒等支（i_id）
        cfg_write(8'd5, 16'd1);      // RESU = 1
        cfg_write(8'd6, 16'd8);      // CI   = 8
        cfg_write(8'd7, 16'd8);      // COUT = 8
        cfg_write(8'd8, 16'd0);      // S2   = 0
        cfg_write(8'd9, 16'd1);      // SKIPLEN = 1

        // ---- 权重：144 行 × 8 通道（低 64 位有效）----
        for (i = 0; i < 144; i = i + 1) begin
            for (k = 0; k < 8; k = k + 1)
                ld_wdata128[8*k +: 8] <= ((i * 13 + k * 37) & 8'hFF);
            ld_wdata128[127:64] <= 64'hDEAD_BEEF_DEAD_BEEF;   // 高半必须被忽略
            ld_waddr <= i[7:0]; ld_we <= 1'b1;
            @(posedge clk);
            ld_we <= 1'b0;
        end
        // ---- bias 8 通道 ----
        for (i = 0; i < 8; i = i + 1) begin
            ld_baddr <= i[7:0]; ld_bdata <= i * 1234 - 4000; ld_be <= 1'b1;
            @(posedge clk);
            ld_be <= 1'b0;
        end
        // ---- M / mid 8 通道 + 量化头 ----
        //   M=8/shift=14 ⇒ acc 项 ≈ ±36；mid=2048 ⇒ 恒等项 = id/8 ≈ 0..31
        for (i = 0; i < 8; i = i + 1) begin
            ld_midx <= i[7:0]; ld_m <= 32'sd8; ld_mid <= 32'sd2048; ld_me <= 1'b1;
            @(posedge clk);
            ld_me <= 1'b0;
        end
        @(posedge clk);
        ld_me <= 1'b1; ld_midx <= 8'hFF; ld_m <= 0; ld_mid <= 0;
        ld_shift <= 6'd14; ld_qlo <= -8'sd128; ld_qhi <= 8'd127;
        @(posedge clk);
        ld_me <= 1'b0;

        s_vld <= 1'b1;              // 恒 1（老 TB 的约定）
        @(posedge clk);

        // ---- PREPUSH：win+18 = 50 列 ----
        for (i = 0; i < WIN + 18; i = i + 1) begin
            skip_vld <= 1'b1;
            @(posedge clk);
            skip_vld <= 1'b0;
            wait_idle;
        end

        // ---- 24 组 ----
        cyc0 = cidx;
        for (i = 0; i < NGRP; i = i + 1) begin
            grp_vld <= 1'b1;
            @(posedge clk);
            grp_vld <= 1'b0;
            wait_idle;
        end

        // ---- 排空 ----
        repeat (40) @(posedge clk);

        // ---- 比对 ----
        $display("----------------------------------------------------------");
        $display("消费列数=%0d (期望 %0d)  像素数 A/B/C = %0d/%0d/%0d (期望 %0d)",
                 cidx, WIN + 18 + NGRP * 16, nA, nB, nC, NPIX);
        $display("s_ack 三路不一致拍数 = %0d", ack_err);

        for (i = 0; i < NPIX; i = i + 1) begin
            if (capA[i] !== capB[i]) begin if (firstAB < 0) firstAB = i; dAB = dAB + 1; end
            if (capA[i] !== capC[i]) begin if (firstAC < 0) firstAC = i; dAC = dAC + 1; end
            if (capA[i] !== capD[i]) begin if (firstAD < 0) firstAD = i; dAD = dAD + 1; end
        end

        // 非退化检查：输出不能全 0、也不能全相同（否则本测试没有判别力）
        k = 0;
        for (i = 1; i < NPIX; i = i + 1) if (capA[i] !== capA[0]) k = k + 1;
        $display("输出非退化：与 capA[0] 不同的像素 = %0d / %0d（0 说明测试无效）", k, NPIX);
        if (capA[0] === 128'd0) $display("** WARNING: capA[0] 全 0，可能未真正跑起来");

        $display("----------------------------------------------------------");
        if (dAB == 0) $display("PASS-1: 高通道字节(A=0xA5.. / B=0x5A..)对输出**无影响**");
        else begin
            $display("FAIL-1: A vs B 有 %0d 个像素不同，首个 idx=%0d", dAB, firstAB);
            $display("        A=%032h", capA[firstAB]);
            $display("        B=%032h", capB[firstAB]);
        end
        if (dAC == 0) $display("PASS-2: CI/CO 16→8 截断后输出**逐位相同**");
        else begin
            $display("FAIL-2: A vs C 有 %0d 个像素不同，首个 idx=%0d", dAC, firstAC);
            $display("        A=%032h", capA[firstAC]);
            $display("        C=%032h", capC[firstAC]);
        end
        // 负向对照：D 与 A 只差通道 0 的 1 个 bit，**必须**不同
        if (dAD > 0) $display("PASS-0(负向对照): 只翻通道0的LSB ⇒ A vs D 有 %0d 个像素不同（比对有判别力）", dAD);
        else         $display("** FAIL-0: A 与 D 完全相同 ⇒ 本测试没有判别力，结论无效 **");

        if (ack_err == 0) $display("PASS-3: s_ack 消费节奏三路一致（共 %0d 列）", cidx);
        else              $display("FAIL-3: s_ack 有 %0d 拍不一致", ack_err);

        $display("样本：A[0]=%032h A[1]=%032h A[2]=%032h", capA[0], capA[1], capA[2]);
        $finish;
    end

endmodule



