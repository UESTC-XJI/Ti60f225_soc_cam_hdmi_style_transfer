//============================================================================
// tb_ci_co_equiv.v —— CI/CO 16→8 功能等价性 A/B 仿真（Track3 面积前置验证）
//
// 源自 tests/tb_rowpipe_diff.v（Lead 写的版本），改动：
//   1. **TINY=1**：用 style_network_rowpipe 的 TB_TINY 参数把 12 层几何换成
//      64x48（结果帧），一帧从 ~4.9M 拍降到 ~8 万拍 ⇒ iverilog 能跑 A/B。
//   2. **CAP8=1**：用 defparam 把 rowpipe_layer 的 CI/CO/COUT 覆盖成 8
//      （**不改任何 RTL 的通道参数**；defparam 的 RHS 允许常量表达式）。
//   3. **所有地址都返回确定性数据**（不只源帧）：原 TB 对中间 bank 的读返回 0，
//      而残差恒等支 i_id 正是从中间 bank 读的 ⇒ 全 0 会让"128→64 位截断"
//      这个待验证点完全测不出来。这里按地址生成模式数据。
//   4. 每层写通道 hash + 计数：即使最终结果帧偶然相同，也能定位**第一个发散层**。
//   5. `+CYCLES=n` 仿真拍数上限（测速用）。
//
// 用法（在 _sim/ 下，见 _sim/run_ab.sh）：
//   iverilog -g2012 -s tb_ci16 -o ci16.vvp <rtl...> tests/tb_ci_co_equiv.v
//   vvp ci16.vvp +WGT=wgt.hex +OUT=out_ci16.txt
// 顶层：tb_ci16（TINY=1,CAP8=0） / tb_ci8（TINY=1,CAP8=1） / tb_full16（TINY=0）
//============================================================================
`timescale 1ns / 1ps

module tb_ci_co_equiv #(
    parameter integer TINY = 1,
    parameter integer CAP8 = 0
);

    // ---- 帧参数：TINY=1 ⇒ L11 输出 64x48（结果帧 4 B/像素）----
    localparam integer FRAME_W  = TINY ? 64 : 640;
    localparam integer FRAME_H  = TINY ? 48 : 480;
    localparam integer FRAME_B  = FRAME_W * FRAME_H * 4;
    localparam integer BEATS    = FRAME_B / 16;

    localparam integer WGT_B    = 14448;
    localparam integer WGT_BEATS= WGT_B / 16;      // 903

    localparam [31:0] SRC_ADDR = 32'h0500_0000;
    localparam [31:0] RES_ADDR = 32'h0580_0000;

    reg clk = 0, rst_n = 0;
    always #3.367 clk = ~clk;                      // 148.5 MHz

    reg         start = 0;
    wire        busy, done, error;
    wire [4:0]  layer_index;
    wire [31:0] cycles;

    wire [31:0]  araddr;
    wire [7:0]   arlen;
    wire         arvalid;
    reg          arready = 0;
    reg  [127:0] rdata_r = 0;
    reg  [1:0]   rresp = 0;
    reg          rlast_r = 0, rvalid = 0;
    wire         rready;

    wire [31:0]  awaddr;
    wire [7:0]   awlen;
    wire         awvalid;
    reg          awready = 0;
    wire [127:0] wdata;
    wire [15:0]  wstrb;
    wire         wlast, wvalid;
    reg          wready = 0;
    reg  [1:0]   bresp = 0;
    reg          bvalid = 0;
    wire         bready;

    parameter [31:0] WEIGHT_ADDRESS = 32'h06F0_0000;

    style_network_rowpipe #(.WEIGHT_ADDRESS(WEIGHT_ADDRESS), .TB_TINY(TINY)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .source_address(SRC_ADDR), .result_address(RES_ADDR),
        .frame_width(FRAME_W[9:0]), .frame_height(FRAME_H[9:0]),
        .coef_we(1'b0), .coef_addr(8'd0), .coef_word(5'd0), .coef_data(32'd0),
        .busy(busy), .done(done), .error(error),
        .layer_index(layer_index), .cycles(cycles),
        .stat_read_cycles(), .stat_compute_cycles(), .stat_prefetch_starts(),
        .stat_prefetch_completions(), .stat_overlap_cycles(),
        .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rdata(rdata_r), .rresp(rresp), .rlast(rlast_r), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );

    //========================================================================
    // CAP8：把 rowpipe_layer 的通道参数覆盖成 8（**唯一改动点**，不动 RTL）
    //   RHS 是常量表达式（CAP8 是 parameter）⇒ 合法 defparam。
    //   这与"把 rowpipe_engine.v:138 的 .CI(16) 改成 .CI(8)"在网表上等价：
    //   s_col/i_id 端口 128→64（高位被剪）、o_col 64（高位补 0）、
    //   lb 宽 128→64、OW 258→194、rq_id_r* 128→64。
    //========================================================================
    defparam dut.u_drv.u_eng.u_layer.CI   = CAP8 ? 8 : 16;
    defparam dut.u_drv.u_eng.u_layer.CO   = CAP8 ? 8 : 16;
    defparam dut.u_drv.u_eng.u_layer.COUT = CAP8 ? 8 : 16;

    // ---- A-3：结果帧 2×2 复制的几何参数（按 TB 几何等比缩放）----
    //   生产默认（TINY=0）是 320→640；TB_TINY 的 L11 是 32×24、结果帧 64×48 ⇒ 32→64。
    //   基线编译时这些参数不存在 ⇒ iverilog 只报 warning（不生效），A/B 仍可比。
`ifdef TB_A3
    defparam dut.u_drv.u_bank.RESULT_X2 = 1;
    defparam dut.u_drv.u_bank.X2_SRC_W  = TINY ? 32 : 320;
    defparam dut.u_drv.u_bank.X2_TGT_W  = TINY ? 64 : 640;
`endif

    //========================================================================
    // 存储模型
    //   wmem：903 个 128 位 beat（权重 blob）
    //   rmem：结果帧捕获（只收 RES_ADDR 区间）
    //========================================================================
    reg [127:0] wmem [0:WGT_BEATS-1];
    reg [127:0] rmem [0:BEATS-1];
    integer i;

    // 确定性模式数据：只依赖**地址**（与运行次数、层、时间无关）
    function [127:0] pat_beat(input [31:0] byte_addr);
        integer k;
        reg [127:0] v;
        reg [31:0] bi;
        begin
            bi = byte_addr >> 4;
            for (k = 0; k < 16; k = k + 1)
                v[8*k +: 8] = ((bi * 37 + k * 101 + (bi >> 5) * 7 + (bi >> 11) * 13) & 8'hFF);
            pat_beat = v;
        end
    endfunction

    //========================================================================
    // AXI 读从端
    //========================================================================
    localparam RS_IDLE = 2'd0, RS_DATA = 2'd1;
    reg [1:0]   rstate = RS_IDLE;
    reg [31:0]  rd_base = 0;
    reg [7:0]   rd_len = 0, rd_cnt = 0;
    wire [31:0] rd_byte = rd_base + {20'd0, rd_cnt, 4'b0};
    reg  [31:0] widx;                       // 权重 beat 下标（组合临时量）

    // rdata/rlast 与 rvalid 同拍有效 ⇒ 组合生成
    always @* begin
        widx = (rd_base - WEIGHT_ADDRESS + {20'd0, rd_cnt, 4'b0}) >> 4;
        if (rd_base >= WEIGHT_ADDRESS && rd_base < WEIGHT_ADDRESS + WGT_B && widx < WGT_BEATS)
            rdata_r = wmem[widx];
        else
            rdata_r = pat_beat(rd_byte);    // ★ 所有非权重地址都给确定性模式数据
        rlast_r = (rstate == RS_DATA) && (rd_cnt == rd_len);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= RS_IDLE; arready <= 1'b0; rvalid <= 1'b0; rd_cnt <= 0;
        end else begin
            case (rstate)
            RS_IDLE: begin
                arready <= 1'b1; rvalid <= 1'b0;
                if (arvalid && arready) begin
                    rd_base <= araddr; rd_len <= arlen; rd_cnt <= 0;
                    arready <= 1'b0; rstate <= RS_DATA;
                end
            end
            RS_DATA: begin
                arready <= 1'b0; rvalid <= 1'b1;
                if (rvalid && rready) begin
                    if (rd_cnt == rd_len) rstate <= RS_IDLE;
                    else                  rd_cnt <= rd_cnt + 1'b1;
                end
            end
            default: rstate <= RS_IDLE;
            endcase
        end
    end

    //========================================================================
    // AXI 写从端：抓结果帧 + 每层 hash/count
    //========================================================================
    reg [31:0] wr_base = 0;
    reg        lst_seen = 0;
    integer    wr_cnt = 0;

    reg [63:0] lyr_hash  [0:15];
    integer    lyr_wcnt  [0:15];
    integer    lyr_seen  [0:15];
    integer    k;
    reg [63:0] mix;

    initial begin
        for (k = 0; k < 16; k = k + 1) begin
            lyr_hash[k] = 64'd0; lyr_wcnt[k] = 0; lyr_seen[k] = 0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0; wready <= 1'b1; bvalid <= 1'b0; bresp <= 2'd0; lst_seen <= 1'b0;
        end else begin
            awready <= 1'b1;
            if (awvalid && awready) begin
                wr_base <= awaddr; awready <= 1'b0; wready <= 1'b1; lst_seen <= 1'b0;
            end
            if (wvalid && wready) begin
                if (wr_base >= RES_ADDR && wr_base < RES_ADDR + FRAME_B)
                    rmem[(wr_base - RES_ADDR) / 16] <= wdata;
                // 每层写 hash（用于定位第一个发散层）
                mix = {awaddr[15:0], wdata[95:64]} ^ {wdata[63:0]} ^ {32'd0, wr_base};
                lyr_hash[layer_index] <= lyr_hash[layer_index] ^ mix ^ {lyr_hash[layer_index][62:0], 1'b0};
                lyr_wcnt[layer_index] <= lyr_wcnt[layer_index] + 1;
                lyr_seen[layer_index] <= 1;
                wr_cnt = wr_cnt + 1;
                wr_base <= wr_base + 32'd16;
                if (wlast) begin
                    lst_seen <= 1'b1; wready <= 1'b0; bvalid <= 1'b1;
                end
            end
            if (bvalid && bready) begin
                bvalid <= 1'b0; awready <= 1'b1;
            end
        end
    end

    //========================================================================
    // 主流程
    //========================================================================
    integer out_fh;
    integer nbeats_written;
    integer max_layer = 99;
    integer cyc_limit = 0;
    reg [1023:0] wgt_file, out_file;

    initial begin
        if (!$value$plusargs("WGT=%s", wgt_file)) wgt_file = "wgt.hex";
        void'($value$plusargs("MAXLAYER=%d", max_layer));
        void'($value$plusargs("CYCLES=%d", cyc_limit));
        if (!$value$plusargs("OUT=%s", out_file)) out_file = "out.txt";

        for (i = 0; i < WGT_BEATS; i = i + 1) wmem[i] = 128'd0;
        for (i = 0; i < BEATS;     i = i + 1) rmem[i] = 128'd0;
        $readmemh(wgt_file, wmem);

        $display("=== TINY=%0d CAP8=%0d  frame=%0dx%0d  result_beats=%0d ===",
                 TINY, CAP8, FRAME_W, FRAME_H, BEATS);

        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n <= 1;
        repeat (4) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        fork : wait_end
            begin
                wait ((done === 1'b1) || (layer_index >= max_layer));
                disable wait_end;
            end
            begin
                repeat (20000000) @(posedge clk);
                $display("TIMEOUT: 20M 拍内没有 done");
                disable wait_end;
            end
            begin
                if (cyc_limit > 0) begin
                    repeat (cyc_limit) @(posedge clk);
                    $display("CYCLE LIMIT %0d 到达（测速模式）", cyc_limit);
                    disable wait_end;
                end
            end
        join

        repeat (8) @(posedge clk);

        // 每层写 hash/count
        for (k = 0; k < 12; k = k + 1)
            if (lyr_seen[k])
                $display("  L%0d  writes=%0d  hash=%016h", k, lyr_wcnt[k], lyr_hash[k]);

        out_fh = $fopen(out_file, "w");
        nbeats_written = 0;
        for (i = 0; i < BEATS; i = i + 1) begin
            $fdisplay(out_fh, "%032h", rmem[i]);
            if (rmem[i] !== 128'd0) nbeats_written = nbeats_written + 1;
        end
        $fclose(out_fh);

        $display("DONE  error=%0d  cycles=%0d  wr_beats=%0d  nonzero=%0d/%0d",
                 error, cycles, wr_cnt, nbeats_written, BEATS);
        $finish;
    end

    // 进度：每进入新的一层打一行
    reg [4:0] last_layer_seen = 5'h1F;
    always @(posedge clk) begin
        if (busy && layer_index !== last_layer_seen) begin
            last_layer_seen <= layer_index;
            $display("  [%0t] layer %0d  cycles=%0d", $time, layer_index, cycles);
        end
    end

endmodule

// ---- 三个顶层：同一份源码，靠 -s 选择 ----
module tb_ci16;    tb_ci_co_equiv #(.TINY(1), .CAP8(0)) u(); endmodule
module tb_ci8;     tb_ci_co_equiv #(.TINY(1), .CAP8(1)) u(); endmodule
module tb_full16;  tb_ci_co_equiv #(.TINY(0), .CAP8(0)) u(); endmodule

