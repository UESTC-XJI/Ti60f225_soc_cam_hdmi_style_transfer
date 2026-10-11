//============================================================================
// tb_style_pipe.v —— style_pipe 的最小自检
//
// 判据：
//   ① style_sel=0 ⇒ `o_rgb === i_rgb` **逐位**（直通，且**零延迟**：同拍即出）
//   ② style_sel=1 ⇒ 每像素首尾字节对调（{B,G,R} → {R,G,B}），**G 不动**
//   ③ `o_rgb` 是**组合**的：同一拍改 i_rgb，o_rgb 同拍跟着变（打一拍就会在板上错位）
//   ④ `done` 在 `i_vs` **下落沿**出**一拍**脉冲；`busy` 恒 0
//
// 跑法（ModelSim）：
//   vlib work && vlog -work work rtl/style/style_pipe.v rtl/style/tb_style_pipe.v
//   vsim -c work.tb_style_pipe -do "run -all; quit -f"
//
// ⚠ 这个 TB 存在的理由：第一版把"一个像素"写成 2 字节（应 3 字节），
//   第 1 步 style_sel=0 把它整块剪掉 ⇒ **综合/PnR 全绿也看不出来**。
//   凡"通道数/字宽"类错误，只有拨到非 0 那条支路才现形。
//============================================================================
`timescale 1ns / 1ps

module tb_style_pipe;

    localparam integer CH = 8;
    localparam integer PW = 3*CH;         // 24 —— 一像素

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;                 // 100MHz，跑功能

    reg  style_sel = 0, i_vs = 0, i_hs = 0, i_de = 0;
    reg  [2*PW-1:0] i_rgb = 0;
    wire [2*PW-1:0] o_rgb;
    wire busy, done;

    style_pipe #(.PIXELS_PER_CLK(2), .CH_WIDTH(CH)) dut (
        .clk(clk), .rst_n(rst_n),
        .i_vs(i_vs), .i_hs(i_hs), .i_de(i_de), .i_rgb(i_rgb),
        .o_rgb(o_rgb), .style_sel(style_sel), .start(1'b0),
        .busy(busy), .done(done)
    );

    function [PW-1:0] swap_rb;            // {B,G,R} -> {R,G,B}
        input [PW-1:0] px;
        begin
            swap_rb = {px[7:0], px[15:8], px[23:16]};
        end
    endfunction

    integer nerr = 0, k;
    reg [2*PW-1:0] expect;

    task chk; input [8*16-1:0] tag; input [2*PW-1:0] got, exp;
        begin
            if (got !== exp) begin
                nerr = nerr + 1;
                $display("  ✗ %0s: 得到 %012x 期望 %012x", tag, got, exp);
            end
        end
    endtask

    integer i, npulse = 0;
    initial begin
        rst_n = 0;
        repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

        // ---- ① 直通 + ③ 组合（同一拍改输入，输出同拍跟） ----
        style_sel = 0;
        for (k = 0; k < 64; k = k + 1) begin
            @(negedge clk);
            i_rgb = {$random, $random};           // 64 位 → 48 位自动截断
            #1;                                   // 组合路径延时后看
            chk("直通", o_rgb, i_rgb);
        end

        // ---- ② R/B 交换 ----
        style_sel = 1;
        i_rgb = {24'h665544, 24'h332211};         // p1=B66 G55 R44 ; p0=B33 G22 R11
        #1;
        expect = {swap_rb(24'h665544), swap_rb(24'h332211)};   // {445566, 112233}
        chk("R/B 交换", o_rgb, expect);
        // 定点核对「G 不动」——单独看中间字节
        if (o_rgb[15:8] !== 8'h22 || o_rgb[39:32] !== 8'h55) begin
            nerr = nerr + 1;
            $display("  ✗ 交换把 G 也动了: p0.G=%02x p1.G=%02x", o_rgb[15:8], o_rgb[39:32]);
        end
        // ⚠ 低字节是 **B**（R 在最高字节）—— 别写反（第一版就在这里写反过一次）
        if (o_rgb[7:0] !== 8'h33 || o_rgb[23:16] !== 8'h11 ||
            o_rgb[31:24] !== 8'h66 || o_rgb[47:40] !== 8'h44) begin
            nerr = nerr + 1;
            $display("  ✗ 交换的 R/B 位置不对: %012x", o_rgb);
        end

        // ---- ④ done 是**电平**：帧末拉高、下一帧开始拉低；busy 恒 0 ----
        //   （不是一拍脉冲 —— VIO 在 kHz 级采不到 148.5MHz 的一拍）
        style_sel = 0;
        @(negedge clk); i_vs = 1; i_de = 1;              // 帧开始
        repeat (4) @(negedge clk);
        if (done !== 1'b0) begin nerr = nerr + 1; $display("  ✗ 帧中 done 不该高"); end
        @(negedge clk); i_vs = 0; i_de = 0;              // 帧结束
        repeat (4) @(negedge clk);
        if (done !== 1'b1) begin nerr = nerr + 1; $display("  ✗ 帧末 done 没拉高"); end

        // 下一帧开始 ⇒ done 落回 0
        @(negedge clk); i_vs = 1;
        repeat (3) @(negedge clk);
        if (done !== 1'b0) begin nerr = nerr + 1; $display("  ✗ 下一帧开始 done 没落回"); end
        if (busy !== 1'b0) begin nerr = nerr + 1; $display("  ✗ busy 不是恒 0"); end

        if (nerr == 0) $display("ALL-PASS");
        else           $display("SOME-FAIL n=%0d", nerr);
        $finish;
    end

    initial begin #200_000; $display("TIMEOUT-HANG ###"); $finish; end

endmodule
