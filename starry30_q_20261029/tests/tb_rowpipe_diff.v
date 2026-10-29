//============================================================================
// tb_rowpipe_diff.v —— rowpipe 整网差分仿真（用于验证 CI/CO 等参数改动的功能等价性）
//
// 思路：**不比对参考模型，比对两次运行**。
//   同一套激励（相同权重、相同源帧、相同种子）分别用 CI/CO=16 和 CI/CO=8 跑一遍，
//   把输出帧逐字节 diff。逐位相同 ⇒ 改动功能等价；有差异 ⇒ 改动破坏了数据通路。
//   这比"对参考模型"简单得多，而且正好回答"这个参数改动安全吗"。
//
// 与真实硬件的对应：
//   - AXI 读从端：serve WEIGHT_ADDRESS 起的 903 个 128 位 beat（权重 blob），
//     以及 source_address 起的源帧。零等待（真实 DDR 有延迟，但这里只比数据正确性）。
//   - AXI 写从端：把结果帧抓进 rmem，结束时 dump 成文本。
//   - 其余端口按真实接法驱动。
//
// 用法（见 tools/run_diff_sim.sh）：
//   iverilog -g2012 -o tb.vvp tb_rowpipe_diff.v <rtl 文件...> efx_dsp48.v
//   vvp tb.vvp +WGT=wgt.hex +OUT=out_ci16.txt
//============================================================================
`timescale 1ns / 1ps

module tb_rowpipe_diff;

    // ---- 帧参数（与描述符一致：640x480）----
    localparam integer FRAME_W  = 640;
    localparam integer FRAME_H  = 480;
    localparam integer FRAME_B  = FRAME_W * FRAME_H * 4;      // 1,228,800 B
    localparam integer BEATS    = FRAME_B / 16;               // 76,800
    localparam integer WGT_B    = 14448;
    localparam integer WGT_BEATS= WGT_B / 16;                 // 903

    localparam [31:0] SRC_ADDR = 32'h0500_0000;
    localparam [31:0] RES_ADDR = 32'h0580_0000;

    reg clk = 0, rst_n = 0;
    always #3.367 clk = ~clk;                                 // 148.5 MHz

    // ---- DUT ----
    reg         start = 0;
    wire        busy, done, error;
    wire [4:0]  layer_index;
    wire [31:0] cycles;
    wire [31:0] st_rd, st_cmp, st_pf, st_pfc, st_ov;

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

    style_network_rowpipe #(.WEIGHT_ADDRESS(WEIGHT_ADDRESS)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .source_address(SRC_ADDR), .result_address(RES_ADDR),
        .frame_width(FRAME_W[9:0]), .frame_height(FRAME_H[9:0]),
        .coef_we(1'b0), .coef_addr(8'd0), .coef_word(5'd0), .coef_data(32'd0),
        .busy(busy), .done(done), .error(error),
        .layer_index(layer_index), .cycles(cycles),
        .stat_read_cycles(st_rd), .stat_compute_cycles(st_cmp),
        .stat_prefetch_starts(st_pf), .stat_prefetch_completions(st_pfc),
        .stat_overlap_cycles(st_ov),
        .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rdata(rdata_r), .rresp(rresp), .rlast(rlast_r), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );

    //========================================================================
    // 存储模型
    //   wmem：903 个 128 位 beat（权重 blob，从文件载入）
    //   smem：源帧，程序化生成（固定公式 ⇒ 两次运行完全一致）
    //   rmem：结果帧，由写通道填充，结束时 dump
    //========================================================================
    reg [127:0] wmem [0:WGT_BEATS-1];
    reg [127:0] rmem [0:BEATS-1];

    integer i, j;

    function [127:0] src_beat(input integer bi);
        integer k;
        reg [127:0] v;
        begin
            // 确定性伪随机：只依赖 beat 序号，与运行次数无关
            v = 128'd0;
            for (k = 0; k < 16; k = k + 1) begin
                v[8*k +: 8] = ((bi * 37 + k * 101 + (bi >> 5) * 7) & 8'hFF);
            end
            src_beat = v;
        end
    endfunction

    //========================================================================
    // AXI 读从端
    //========================================================================
    localparam RS_IDLE = 2'd0, RS_DATA = 2'd1;
    reg [1:0]   rstate = RS_IDLE;
    reg [31:0]  rd_base = 0;
    reg [7:0]   rd_len = 0, rd_cnt = 0;

    // rdata/rlast 组合生成：必须与 rvalid 同拍有效
    always @* begin
        if (rd_base >= WEIGHT_ADDRESS && rd_base < WEIGHT_ADDRESS + WGT_B)
            rdata_r = wmem[(rd_base - WEIGHT_ADDRESS + 16*rd_cnt) / 16];
        else if (rd_base >= SRC_ADDR && rd_base < SRC_ADDR + FRAME_B)
            rdata_r = src_beat((rd_base - SRC_ADDR) / 16 + rd_cnt);
        else
            rdata_r = 128'd0;
        rlast_r = (rstate == RS_DATA) && (rd_cnt == rd_len);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= RS_IDLE; arready <= 1'b0; rvalid <= 1'b0;
            rd_cnt <= 0;
        end else begin
            case (rstate)
            RS_IDLE: begin
                arready <= 1'b1;
                rvalid  <= 1'b0;
                if (arvalid && arready) begin
                    rd_base <= araddr;
                    rd_len  <= arlen;
                    rd_cnt  <= 0;
                    arready <= 1'b0;
                    rstate  <= RS_DATA;
                end
            end
            RS_DATA: begin
                arready <= 1'b0;
                rvalid  <= 1'b1;
                // ⚠ rdata / rlast 必须**与握手同拍**有效，所以从 rstate+rd_cnt 组合生成
                //   （见下方 assign）。这里只推进计数。
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
    // AXI 写从端（抓结果帧）
    //========================================================================
    reg [31:0] wr_base = 0;
    reg        lst_seen = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0; wready <= 1'b1; bvalid <= 1'b0; bresp <= 2'd0;
            lst_seen <= 1'b0;
        end else begin
            // AW
            awready <= 1'b1;
            if (awvalid && awready) begin
                wr_base  <= awaddr;
                awready  <= 1'b0;
                wready   <= 1'b1;
                lst_seen <= 1'b0;
            end
            // W
            if (wvalid && wready) begin
                if (wr_base >= RES_ADDR && wr_base < RES_ADDR + FRAME_B)
                    rmem[(wr_base - RES_ADDR) / 16] <= wdata;
                wr_base <= wr_base + 32'd16;
                if (wlast) begin
                    lst_seen <= 1'b1;
                    wready   <= 1'b0;
                    bvalid   <= 1'b1;
                end
            end
            // B
            if (bvalid && bready) begin
                bvalid <= 1'b0;
                awready <= 1'b1;
            end
        end
    end

    //========================================================================
    // 主流程
    //========================================================================
    integer fh, out_fh;
    integer nbeats_written;
    reg [1023:0] wgt_file, out_file;

    integer max_layer = 99;
    initial begin
        if (!$value$plusargs("WGT=%s", wgt_file)) wgt_file = "wgt.hex";
        void'($value$plusargs("MAXLAYER=%d", max_layer));
        if (!$value$plusargs("OUT=%s", out_file)) out_file = "out.txt";

        for (i = 0; i < WGT_BEATS; i = i + 1) wmem[i] = 128'd0;
        for (i = 0; i < BEATS;     i = i + 1) rmem[i] = 128'd0;

        $readmemh(wgt_file, wmem);

        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n <= 1;

        repeat (4) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // 等 done（带超时：整网约 5M 拍，给 20M 拍余量）
        fork : wait_done
            begin
                wait ((done === 1'b1) || (layer_index >= max_layer));
                disable wait_done;
            end
            begin
                repeat (20000000) @(posedge clk);
                $display("TIMEOUT: 20M 拍内没有 done");
                $finish;
            end
        join

        repeat (8) @(posedge clk);

        // dump 结果帧
        out_fh = $fopen(out_file, "w");
        nbeats_written = 0;
        for (i = 0; i < BEATS; i = i + 1) begin
            $fdisplay(out_fh, "%032h", rmem[i]);
            if (rmem[i] !== 128'd0) nbeats_written = nbeats_written + 1;
        end
        $fclose(out_fh);

        $display("DONE  error=%0d  cycles=%0d", error, cycles);
        $display("      read=%0d compute=%0d pf=%0d pfc=%0d wr=%0d",
                 st_rd, st_cmp, st_pf, st_pfc, st_ov);
        $display("      非零 beat: %0d / %0d", nbeats_written, BEATS);
        $finish;
    end


    // ---- 进度：每进入新的一层打一行（否则整网跑起来像卡死）----
    reg [4:0] last_layer_seen = 5'h1F;
    always @(posedge clk) begin
        if (busy && layer_index !== last_layer_seen) begin
            last_layer_seen <= layer_index;
            $display("  [%0t] layer %0d  cycles=%0d", $time, layer_index, cycles);
        end
    end

    // ---- 调试探针：卡住时把仲裁器/权重流的状态打出来 ----
    integer dbg = 0;
    always @(posedge clk) begin
        if (busy) begin
            dbg = dbg + 1;
            if (dbg <= 8 || dbg == 200 || dbg == 2000 || dbg == 20000) begin
                $display("[%0d] slave rstate=%0d rd_cnt=%0d rd_len=%0d rvalid=%b rready=%b rlast=%b | arb ast=%0d sel=%0d brv=%b",
                    dbg, rstate, rd_cnt, rd_len, rvalid, rready, rlast_r,
                    dut.u_drv.u_bank.u_arb.ast, dut.u_drv.u_bank.u_arb.sel,
                    dut.u_drv.u_bank.u_arb.brv);
            end
        end
    end

    // 死锁保护：busy 长期不变也报出来
    reg [31:0] last_cycles = 0;
    integer stall = 0;
    always @(posedge clk) begin
        if (busy && cycles == last_cycles) begin
            stall = stall + 1;
            if (stall > 2000000) begin
                $display("STALL: cycles 卡在 %0d 超过 2M 拍，layer=%0d", cycles, layer_index);
                $finish;
            end
        end else begin
            stall = 0;
            last_cycles = cycles;
        end
    end

endmodule
