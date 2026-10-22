//============================================================================
// rowpipe_ddr_banks.v —— 帧缓冲后端：**3 个 DDR bank + 源帧流 + 结果帧流**
//
// 引擎（rowpipe_engine）只给"bank 号 + 像素下标"，这里负责：
//
//   读口 0: bank 3 → **源帧流**（DDR 里 XBGR 4B/像素，展开成 128 位/像素字）
//           bank 0/1/2 → **中间结果顺序读流**（16B/像素 = 1 个 AXI beat）
//   读口 1: 残差恒等支的顺序读流（同 bank 0/1/2）
//   写口  : bank 0/1/2 → 顺序写流；**L11 的 bank2 → 结果帧流**
//           （4 个 16B 像素字打包成 1 个 128 位 XBGR beat，4B/像素）
//
// ## 为什么是"顺序流"而不是通用随机访问
// 引擎的访问序列是**单调递增**的（`ptr`/`pix` 每次 s_ack 加 1）；上采样层的
// `src_base + ix/2` 只在**每两行回跳一次**（同一源行读两遍）。所以每个口只要
// 一条 FIFO + 预取，遇到回跳就 flush 重取。回跳多花的读带宽 = 上采样两层的
// 输入行（< 1MB/帧），可以接受。
//
// ## 读流水（**和引擎的组合读对齐**）
// 引擎在本拍用 `mem_rd_addr` 要数据。这里：
//   - FIFO 头地址 = `head_addr`，`cur_addr` 是 `cur_data` 对应的地址；
//   - 每个时钟都用 `rd_idx+pop` 去读 RAM ⇒ **下一拍**的 `cur_data` 正好是
//     下一格的数据 ⇒ 引擎 ack 那一拍数据已经就位，不需要额外握手等待。
//   - `out_avail = cur_valid && req_addr==cur_addr`。
//
// ## AXI
// 128 位 beat、INCR、≤16 beat、不跨 4KB。读口 0/1 和源帧流 **共用一条 AR**，
// 在 burst 粒度上仲裁；写通道独立（AXI 读写本来就能并行）。
//============================================================================
`timescale 1ns / 1ps

//----------------------------------------------------------------------------
// 3 选 1 读仲裁：**burst 粒度**（选中后一直占着直到 rlast）
//   beat 总线是**组合**的（bv + rdata 同拍有效），客户端在收到的同一拍落盘。
//----------------------------------------------------------------------------
module rowpipe_axir_arb4 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         w0,
    input  wire [31:0]  a0,
    input  wire [7:0]   l0,
    input  wire         br0,
    input  wire         w1,
    input  wire [31:0]  a1,
    input  wire [7:0]   l1,
    input  wire         br1,
    input  wire         w2,
    input  wire [31:0]  a2,
    input  wire [7:0]   l2,
    input  wire         br2,
    // B1g：第 4 个客户 = **权重 blob 读流**（方案 D）
    input  wire         w3,
    input  wire [31:0]  a3,
    input  wire [7:0]   l3,
    input  wire         br3,
    output wire [31:0]  araddr,
    output wire [7:0]   arlen,
    output wire         arvalid,
    input  wire         arready,
    input  wire [127:0] rdata,
    input  wire [1:0]   rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,
    output wire         bv0, bv1, bv2, bv3
);
    localparam A_IDLE = 2'd0, A_AR = 2'd1, A_R = 2'd2;
    reg [1:0] ast = A_IDLE;
    reg [1:0] sel = 0;
    reg [1:0] last = 2'd3;

    reg [1:0] p0, p1, p2, p3;
    always @* begin
        p0 = (last == 2'd3) ? 2'd0 : (last + 2'd1);
        p1 = (p0   == 2'd3) ? 2'd0 : (p0 + 2'd1);
        p2 = (p1   == 2'd3) ? 2'd0 : (p1 + 2'd1);
        p3 = (p2   == 2'd3) ? 2'd0 : (p2 + 2'd1);
    end
    reg [3:0] wv;
    reg [1:0] pick;
    reg       pick_v;
    always @* begin
        wv = {w3, w2, w1, w0};
        pick_v = 1'b0; pick = 2'd0;
        if      (wv[p0]) begin pick = p0; pick_v = 1'b1; end
        else if (wv[p1]) begin pick = p1; pick_v = 1'b1; end
        else if (wv[p2]) begin pick = p2; pick_v = 1'b1; end
        else if (wv[p3]) begin pick = p3; pick_v = 1'b1; end
    end

    wire [31:0] sel_a = (sel == 2'd0) ? a0 : (sel == 2'd1) ? a1 : (sel == 2'd2) ? a2 : a3;
    wire [7:0]  sel_l = (sel == 2'd0) ? l0 : (sel == 2'd1) ? l1 : (sel == 2'd2) ? l2 : l3;
    wire [3:0]  brv   = {br3, br2, br1, br0};

    assign araddr  = sel_a;
    assign arlen   = sel_l;
    assign arvalid = (ast == A_AR);
    assign rready  = (ast == A_R) && brv[sel];

    assign bv0 = (ast == A_R) && (sel == 2'd0) && rvalid;
    assign bv1 = (ast == A_R) && (sel == 2'd1) && rvalid;
    assign bv2 = (ast == A_R) && (sel == 2'd2) && rvalid;
    assign bv3 = (ast == A_R) && (sel == 2'd3) && rvalid;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ast <= A_IDLE; sel <= 0; last <= 2'd3;
        end else begin
            case (ast)
            A_IDLE: if (pick_v) begin sel <= pick; ast <= A_AR; end
            A_AR:   if (arready) ast <= A_R;
            A_R:    if (rvalid && rready && rlast) begin
                        last <= sel; ast <= A_IDLE;
                    end
            default: ast <= A_IDLE;
            endcase
        end
endmodule

//----------------------------------------------------------------------------
// 顺序读流（中间 bank：1 像素 = 1 beat）
//----------------------------------------------------------------------------
module rowpipe_rd_stream #(
    parameter integer DEPTH = 64,
    parameter integer MAXB  = 16
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,          // 帧首：清 last-beat 影子（防跨帧 replay 到旧数据）
    input  wire [1:0]   req_bank,
    input  wire [19:0]  req_addr,       // **像素下标**（不是 beat）
    input  wire [1:0]   fmt,            // 0=16B/px, 1=8B/px, 2=4B/px
    input  wire         req_en,
    input  wire         req_ack,
    input  wire [31:0]  bank_base,
    output wire [127:0] out_data,
    output wire         out_avail,
    output wire         want,
    output reg  [31:0]  want_addr,
    output reg  [7:0]   want_len,
    input  wire         beat_valid,
    input  wire [127:0] beat_data,
    input  wire         beat_last,
    output wire         beat_ready
);
    localparam integer IDXW = 6;       // DEPTH=64
    reg [127:0] mem [0:DEPTH-1];
    reg [IDXW-1:0] wr_idx, rd_idx;
    reg [7:0]  count;
    reg [19:0] head_addr;
    reg [19:0] next_fetch;
    reg [7:0]  inflight;
    reg [7:0]  cur_len1;
    reg [127:0] cur_data;
    reg [19:0]  cur_addr;
    reg         cur_valid;
    reg [1:0]   cur_bank;
    reg         want_r;

    // ---- B1h（2026-10-18）：**上采样层会把同一列读两遍** ----
    //   `src_addr = src_base + ix/2` ⇒ 连续两列同地址。旧判据第二次读时
    //   req == head-1 ⇒ 判"回头" ⇒ flush 掉预取（实测 L10 单层 2,081 次，
    //   帧级读饿死占 +35% 拍数）。
    //   修法：**保留最后弹掉的那一拍**（last_addr/last_data），同地址再来直接
    //   从影子出（不 pop、不 flush）；只有比它更旧的地址才真回卷。
    reg  [19:0]  last_addr;
    reg  [127:0] last_data;
    reg          last_valid;
    wire replay = last_valid && (req_addr == last_addr) && (req_bank == cur_bank);
    // ---- 紧凑格式：pixel -> beat ----
    //   fmt=0: 1 px/beat；1: 2 px/beat（8B）；2: 4 px/beat（4B）。
    //   FIFO/head/预取仍按 **beat** 走，只有对外接口按像素。
    wire [19:0] req_beat = req_addr >> fmt;
    wire        pix_last = (fmt == 2'd0) ? 1'b1 :
                           (fmt == 2'd1) ? req_addr[0] :
                                           (req_addr[1:0] == 2'd3);
    // 展开：把 beat 里本像素的槽零扩展到 128 位
    reg [127:0] exp_w;
    always @* begin
        case (fmt)
        2'd0: exp_w = cur_data;
        2'd1: exp_w = req_addr[0] ? {64'd0, cur_data[127:64]} : {64'd0, cur_data[63:0]};
        default: case (req_addr[1:0])
                 2'd0: exp_w = {96'd0, cur_data[31:0]};
                 2'd1: exp_w = {96'd0, cur_data[63:32]};
                 2'd2: exp_w = {96'd0, cur_data[95:64]};
                 default: exp_w = {96'd0, cur_data[127:96]};
                 endcase
        endcase
    end
    wire need_restart = req_en && ((req_bank != cur_bank) ||
                                   ((req_beat < cur_addr) && !replay));

    assign out_data   = replay ? last_data : exp_w;
    assign out_avail  = replay || (cur_valid && (req_beat == cur_addr) && (req_bank == cur_bank));
    assign want       = want_r;
    assign beat_ready = 1'b1;

    wire flush_now    = need_restart && (inflight == 0);
    // 只有"从 FIFO 头取"才 pop；影子重放不 pop；**紧凑格式要等 beat 的最后一个像素**
    wire pop          = req_ack && cur_valid && (req_beat == cur_addr) &&
                        (req_bank == cur_bank) && pix_last;
    wire [IDXW-1:0] ridx_n = rd_idx + pop;

    wire [31:0] fetch_byte = bank_base + {next_fetch, 4'b0000};
    wire [12:0] room_bytes = 13'h1000 - {1'b0, fetch_byte[11:0]};
    wire [8:0]  room_beats = room_bytes >> 4;
    wire [8:0]  bst_beats  = (room_beats > MAXB) ? MAXB : room_beats;
    wire        free_ok    = ((count + inflight) < (DEPTH - MAXB));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_idx <= 0; rd_idx <= 0; count <= 0; head_addr <= 0; next_fetch <= 0;
            inflight <= 0; cur_len1 <= 0; cur_addr <= 0;
            cur_valid <= 0; cur_bank <= 0; want_r <= 0;
            want_addr <= 0; want_len <= 0;
            last_addr <= 0; last_data <= 0; last_valid <= 0;
        end else if (clear) begin
            last_valid <= 1'b0;             // ⚠ 跨帧不能 replay 上一帧最后一拍
        end else if (flush_now) begin
            // ⚠ 内部指针是 **beat**；对外 req_addr 是**像素** ⇒ 这里必须用 req_beat
            wr_idx <= 0; rd_idx <= 0; count <= 0;
            head_addr <= req_beat; next_fetch <= req_beat;
            inflight <= 0; cur_len1 <= 0; cur_addr <= req_beat;
            cur_valid <= 0; cur_bank <= req_bank; want_r <= 0;
            last_valid <= 1'b0;          // 大回卷/换 bank：影子作废
        end else begin
            // ---- 读流水（寄存读在下方独立 always，RAM 推断）----
            cur_addr  <= head_addr + (pop ? 20'd1 : 20'd0);
            cur_valid <= ((count - {7'b0, pop}) != 0);
            if (pop) begin
                rd_idx <= rd_idx + 1'b1;
                head_addr <= head_addr + 20'd1;
                last_addr  <= req_addr;
                last_data  <= exp_w;
                last_valid <= 1'b1;
            end
            // ---- 收 beat ----
            if (beat_valid && beat_ready) begin
                wr_idx <= wr_idx + 1'b1;
                if (inflight != 0) inflight <= inflight - 1'b1;
                if (beat_last) begin
                    want_r <= 1'b0;
                    next_fetch <= next_fetch + {12'd0, cur_len1};
                end
            end
            case ({beat_valid && beat_ready, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            if (req_en && !need_restart && !want_r && free_ok) begin
                want_r    <= 1'b1;
                want_addr <= fetch_byte;
                want_len  <= bst_beats[7:0] - 8'd1;
                cur_len1  <= bst_beats[7:0];
                inflight  <= inflight + bst_beats[7:0];
            end
        end
    end

    // ⚠ 存/读**分开放**：同一个 always 里既写又读，Efinity 不认 RAM 模板 ⇒
    //   64×128 整块落 FF（实测单流 8,447 FF）。写一口 + 读口寄存 = BRAM。
    always @(posedge clk) if (beat_valid && beat_ready) mem[wr_idx] <= beat_data;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cur_data <= 0;
        else        cur_data <= mem[ridx_n];
endmodule

//----------------------------------------------------------------------------
// 源帧流（bank 3）：DDR 里 4 字节 XBGR/像素 → 128 位/像素字
//   一个 beat = 4 个像素；展开按 4 拍写。展开期间 beat_ready=0 ——
//   引擎正好 1 字/拍消费，4 拍/beat 是稳态平衡的。
//----------------------------------------------------------------------------
module rowpipe_src_stream #(
    parameter integer DEPTH = 64,
    parameter integer MAXB  = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [19:0]  req_addr,
    input  wire         req_en,
    input  wire         req_ack,
    input  wire [31:0]  frame_base,
    output wire [127:0] out_data,
    output wire         out_avail,
    output wire         want,
    output reg  [31:0]  want_addr,
    output reg  [7:0]   want_len,
    input  wire         beat_valid,
    input  wire [127:0] beat_data,
    input  wire         beat_last,
    output wire         beat_ready
);
    localparam integer IDXW = 6;
    reg [127:0] mem [0:DEPTH-1];
    reg [IDXW-1:0] wr_idx, rd_idx;
    reg [7:0]  count;
    reg [19:0] head_addr, next_fetch;
    reg [7:0]  inflight;                // 已请求未到达的**字数**
    reg [7:0]  cur_len1;                // 当前 burst 的 beat 数
    reg [127:0] cur_data;
    reg [19:0]  cur_addr;
    reg         cur_valid;
    reg         want_r;

    reg [127:0] exp_data;
    reg [1:0]   exp_cnt;
    reg         expanding;

    assign out_data   = cur_data;
    assign out_avail  = cur_valid && (req_addr == cur_addr);
    assign want       = want_r;
    assign beat_ready = !expanding;

    // 同 rd_stream：保留原判据（改动见上面的注释）
    wire need_restart = req_en && (req_addr < head_addr);
    wire flush_now    = need_restart && (inflight == 0);
    wire pop          = req_ack && out_avail;
    wire [IDXW-1:0] ridx_n = rd_idx + pop;
    wire write_word   = expanding;

    wire [31:0] fetch_byte = frame_base + {next_fetch, 2'b00};
    wire [12:0] room_bytes = 13'h1000 - {1'b0, fetch_byte[11:0]};
    wire [8:0]  room_beats = room_bytes >> 4;
    wire [8:0]  bst_beats  = (room_beats > MAXB) ? MAXB : room_beats;
    wire [9:0]  bst_words  = {1'b0, bst_beats, 2'b00};
    wire        free_ok    = ((count + inflight) < (DEPTH - 32));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_idx <= 0; rd_idx <= 0; count <= 0; head_addr <= 0; next_fetch <= 0;
            inflight <= 0; cur_len1 <= 0; cur_addr <= 0;
            cur_valid <= 0; want_r <= 0; want_addr <= 0; want_len <= 0;
            exp_data <= 0; exp_cnt <= 0; expanding <= 0;
        end else if (flush_now) begin
            wr_idx <= 0; rd_idx <= 0; count <= 0;
            head_addr <= req_addr; next_fetch <= req_addr;
            inflight <= 0; cur_len1 <= 0; cur_addr <= req_addr;
            cur_valid <= 0; want_r <= 0;
            exp_cnt <= 0; expanding <= 0;
        end else begin
            // ---- 读流水（寄存读在下方独立 always）----
            cur_addr  <= head_addr + (pop ? 20'd1 : 20'd0);
            cur_valid <= ((count - {7'b0, pop}) != 0);
            if (pop) begin
                rd_idx <= rd_idx + 1'b1;
                head_addr <= head_addr + 20'd1;
            end

            // ---- 展开写 ----
            if (write_word) begin
                wr_idx <= wr_idx + 1'b1;
                if (exp_cnt == 2'd3) begin exp_cnt <= 0; expanding <= 0; end
                else exp_cnt <= exp_cnt + 1'b1;
            end

            // ---- 收 beat ----
            if (beat_valid && beat_ready) begin
                exp_data <= beat_data;
                exp_cnt <= 0;
                expanding <= 1'b1;
                if (inflight >= 4) inflight <= inflight - 4;
                if (beat_last) begin
                    want_r <= 1'b0;
                    next_fetch <= next_fetch + {4'b0, cur_len1, 2'b00};
                end
            end

            case ({write_word, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase

            if (req_en && !want_r && free_ok && !need_restart) begin
                want_r    <= 1'b1;
                want_addr <= fetch_byte;
                want_len  <= bst_beats[7:0] - 8'd1;
                cur_len1  <= bst_beats[7:0];
                inflight  <= inflight + bst_words[7:0];
            end
        end
    end

    // 存/读分离（同 rd_stream）
    always @(posedge clk)
        if (expanding) mem[wr_idx] <= {104'd0, exp_data[exp_cnt*32 +: 24]};
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cur_data <= 0;
        else        cur_data <= mem[ridx_n];
endmodule

//----------------------------------------------------------------------------
// 写引擎：beat FIFO + **合并连续地址**成 burst（≤16 beat、不跨 4KB）
//----------------------------------------------------------------------------
module rowpipe_wr_engine #(
    parameter integer DEPTH = 32
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,          // 帧首：清 acked/acked_virt 与 FIFO 指针
    input  wire [31:0]  p_addr,
    input  wire [127:0] p_data,
    input  wire         p_virt,
    input  wire         p_we,
    output wire         p_ready,
    output wire         idle,
    output reg          error,
    output reg  [31:0]  acked,
    output reg  [31:0]  acked_virt,
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
    output reg          bready
);
    // **单 beat 突发**（awlen=0）。16B = DDR3 BL8×16bit 的一次访问粒度；
    // 牺牲一点命令开销，换 RAM 推断（不 peek 队列、不异步读地址阵列）。
    // ⚠ 2026-10-19：试过 ≤4 beat 合并 burst（512 位移位寄存器 + 连续地址检查），
    //   帧级 TB **两帧都不对**（先反向、后顺序，都错）⇒ 已回退。真要做必须单独立项、
    //   带逐 beat 写入 trace 对着看。
    localparam integer IDXW = 5;        // DEPTH=32
    localparam W_IDLE = 2'd0, W_ADDR = 2'd1, W_DATA = 2'd2, W_RESP = 2'd3;

    reg [31:0]  amem [0:DEPTH-1];
    reg [127:0] dmem [0:DEPTH-1];
    reg         vmem [0:DEPTH-1];
    reg [IDXW-1:0] wptr, rptr;
    reg [6:0]   count;
    reg [1:0]   st;
    reg [31:0]  h_addr;
    reg [127:0] h_data;
    reg         h_virt;
    reg         h_valid;

    assign p_ready = (count < (DEPTH - 2));
    assign idle    = (count == 0) && (st == W_IDLE);
    assign awaddr  = h_addr;
    assign awlen   = 8'd0;
    assign awvalid = (st == W_ADDR);
    assign wdata   = h_data;
    assign wstrb   = 16'hFFFF;
    assign wvalid  = (st == W_DATA);
    assign wlast   = (st == W_DATA);

    wire pop = (st == W_RESP) && bvalid;
    wire [IDXW-1:0] rnext = rptr + pop;

    always @(posedge clk)
        if (p_we && p_ready) begin
            amem[wptr] <= p_addr;
            dmem[wptr] <= p_data;
            vmem[wptr] <= p_virt;
        end

    // 读头寄存（和读流同一套：每拍读 rptr+pop，下一拍正好是对的头）
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            h_addr <= 0; h_data <= 0; h_virt <= 0; h_valid <= 0;
        end else begin
            h_addr  <= amem[rnext];
            h_data  <= dmem[rnext];
            h_virt  <= vmem[rnext];
            h_valid <= ((count - {6'b0, pop}) != 0);
        end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= W_IDLE; wptr <= 0; rptr <= 0; count <= 0;
            bready <= 0; error <= 0; acked <= 0; acked_virt <= 0;
        end else if (clear) begin
            // 帧首清计数；error 故意保持粘滞（靠 rst_n 清）
            st <= W_IDLE; wptr <= 0; rptr <= 0; count <= 0;
            bready <= 0; acked <= 0; acked_virt <= 0;
        end else begin
            case ({p_we && p_ready, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            if (p_we && p_ready) wptr <= wptr + 1'b1;
            if (pop) rptr <= rptr + 1'b1;

            case (st)
            W_IDLE: if ((count != 0) && h_valid) st <= W_ADDR;
            W_ADDR: if (awready) st <= W_DATA;
            W_DATA: if (wready) begin bready <= 1'b1; st <= W_RESP; end
            W_RESP: if (bvalid) begin
                bready <= 1'b0;
                acked <= acked + 1'b1;
                if (h_virt) acked_virt <= acked_virt + 1'b1;
                if (bresp != 0) error <= 1'b1;
                st <= W_IDLE;
            end
            default: st <= W_IDLE;
            endcase
        end
endmodule

//----------------------------------------------------------------------------
// 权重 blob 直通读（方案 D 的 ΔRAM=0 约束）
//   **没有 FIFO**：AXI 的 rvalid 数据直接就是引擎的 w_data；引擎不 ack 时
//   把 rready 拉低，让 AXI 自己保持 beat（合法背压）。
//   只在层间空隙用，所以"卡住 AR 总线几拍"不影响图像流。
//----------------------------------------------------------------------------
module rowpipe_wmem_stream #(parameter FILE="weights_blob.hex")(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         req_en,
    input  wire [19:0]  req_addr,
    input  wire         req_ack,
    output wire [127:0] out_data,
    output wire         out_avail,
    input  wire         we,
    input  wire [10:0]  waddr,
    input  wire [127:0] wdata
);
    (* syn_ramstyle="block_ram" *) reg [127:0] mem [0:1406];
    initial $readmemh(FILE, mem);
    reg [10:0]  ra;
    reg         rav;
    reg [127:0] rd;
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        ra  <= req_addr[10:0];
        rav <= req_en;
        rd  <= mem[req_addr[10:0]];
    end
    assign out_data  = rd;
    assign out_avail = rav;
endmodule

module rowpipe_wstream (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [31:0]  base,
    input  wire         req_en,
    input  wire [19:0]  req_addr,
    input  wire         req_ack,
    output wire [127:0] out_data,
    output wire         out_avail,
    output wire         want,
    output wire [31:0]  want_addr,
    output wire [7:0]   want_len,
    input  wire         beat_valid,
    input  wire [127:0] beat_data,
    input  wire         beat_last,
    output wire         beat_ready
);
    reg [19:0] cur;          // 下一次要交付的 beat 序号
    reg        busy;         // 一个 burst 在飞

    wire rewind = req_en && (req_addr < cur);
    wire match  = req_en && (req_addr == cur);
    wire take   = beat_valid && (busy || rewind || (match && req_ack));

    assign out_data   = beat_data;
    assign out_avail  = beat_valid && match && !rewind;
    assign beat_ready = take;

    wire [31:0] cur_byte = base + {12'd0, cur, 4'b0000};
    wire [12:0] room     = 13'h1000 - {1'b0, cur_byte[11:0]};
    wire [8:0]  nb       = room >> 4;
    wire [7:0]  blen     = (nb > 16) ? 8'd16 : nb[7:0];

    assign want      = req_en && !busy && !rewind && (req_addr >= cur);
    assign want_addr = cur_byte;
    assign want_len  = blen - 8'd1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            cur <= 0; busy <= 0;
        end else begin
            if (beat_valid && beat_ready) begin
                cur <= cur + 1'b1;
                busy <= !beat_last;
            end else if (!busy && req_en && (req_addr < cur)) begin
                cur <= req_addr;         // 帧首回卷：等 burst 排空后再回到 req_addr
            end
        end
endmodule

//----------------------------------------------------------------------------
// 后端顶层
//----------------------------------------------------------------------------
module rowpipe_ddr_banks (
    input  wire         clk,
    input  wire         rst_n,
    // 帧首单拍：清**帧内**计数（结果打包计数 + 写引擎的 beat 计数）。
    // ⚠ 不清的话第二帧 result_done 永远不成立（旧版只在 rst_n 清）。
    //   只在上一帧已经 idle（result_done 的前提）时来，清 FIFO 指针是安全的。
    input  wire         frame_start,

    input  wire [1:0]   rd0_fmt,        // B1j 紧凑化：输入 bank 格式（0=16B/1=8B/2=4B）
    input  wire [1:0]   rd1_fmt,        // 恒等支 bank 格式
    input  wire [1:0]   wr_fmt,         // 输出 bank 格式
    input  wire [1:0]   rd0_bank,
    input  wire [19:0]  rd0_addr,
    input  wire         rd0_en,
    input  wire         rd0_ack,
    output wire [127:0] rd0_data,
    output wire         rd0_avail,
    input  wire [1:0]   rd1_bank,
    input  wire [19:0]  rd1_addr,
    input  wire         rd1_en,
    input  wire         rd1_ack,
    output wire [127:0] rd1_data,
    output wire         rd1_avail,
    input  wire [1:0]   wr_bank,
    input  wire [19:0]  wr_addr,
    input  wire [127:0] wr_data,
    input  wire         wr_we,
    input  wire [3:0]   cur_layer,
    output wire         wr_ready,
    output wire         wr_idle,        // 写通道已排空（层末同步用）

    input  wire [31:0]  source_address,
    input  wire [31:0]  result_address,
    input  wire [31:0]  bank_base0,
    input  wire [31:0]  bank_base1,
    input  wire [31:0]  bank_base2,
    input  wire [31:0]  result_pixels,
    // ---- B1g（方案 D）：权重 blob = DDR 里一段连续 16B 对齐的数据 ----
    input  wire [31:0]  weight_base,
    input  wire         w_req_en,
    input  wire [19:0]  w_req_addr,     // blob 内的 16B beat 序号
    input  wire         w_req_ack,
    output wire [127:0] w_data,
    output wire         w_avail,
    output wire         result_done,
    output wire         error,

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
    // ---- bank 基址 ----
    wire [31:0] rd0_base = (rd0_bank == 2'd1) ? bank_base1 :
                           (rd0_bank == 2'd2) ? bank_base2 : bank_base0;
    wire [31:0] rd1_base = (rd1_bank == 2'd1) ? bank_base1 :
                           (rd1_bank == 2'd2) ? bank_base2 : bank_base0;
    wire [31:0] wr_base  = (wr_bank  == 2'd1) ? bank_base1 :
                           (wr_bank  == 2'd2) ? bank_base2 : bank_base0;

    // ---- 读 ----
    wire         src_en   = rd0_en && (rd0_bank == 2'd3);
    wire         ddr0_en  = rd0_en && (rd0_bank != 2'd3);
    wire [127:0] src_data;
    wire         src_avail;
    wire         src_want, rd0_want, rd1_want;
    wire [31:0]  src_waddr, rd0_waddr, rd1_waddr;
    wire [7:0]   src_wlen, rd0_wlen, rd1_wlen;
    wire         src_br, rd0_br, rd1_br;
    wire         bv_src, bv_rd0, bv_rd1;
    wire [127:0] rd0_stream_data;
    wire         rd0_stream_avail;

    rowpipe_src_stream u_src (
        .clk(clk), .rst_n(rst_n),
        .req_addr(rd0_addr), .req_en(src_en), .req_ack(rd0_ack),
        .frame_base(source_address),
        .out_data(src_data), .out_avail(src_avail),
        .want(src_want), .want_addr(src_waddr), .want_len(src_wlen),
        .beat_valid(bv_src), .beat_data(rdata), .beat_last(rlast),
        .beat_ready(src_br)
    );

    rowpipe_rd_stream u_rd0 (
        .clk(clk), .rst_n(rst_n), .clear(frame_start),
        .req_bank(rd0_bank), .req_addr(rd0_addr), .fmt(rd0_fmt), .req_en(ddr0_en),
        .req_ack(rd0_ack), .bank_base(rd0_base),
        .out_data(rd0_stream_data), .out_avail(rd0_stream_avail),
        .want(rd0_want), .want_addr(rd0_waddr), .want_len(rd0_wlen),
        .beat_valid(bv_rd0), .beat_data(rdata), .beat_last(rlast),
        .beat_ready(rd0_br)
    );

    rowpipe_rd_stream u_rd1 (
        .clk(clk), .rst_n(rst_n), .clear(frame_start),
        .req_bank(rd1_bank), .req_addr(rd1_addr), .fmt(rd1_fmt), .req_en(rd1_en),
        .req_ack(rd1_ack), .bank_base(rd1_base),
        .out_data(rd1_data), .out_avail(rd1_avail),
        .want(rd1_want), .want_addr(rd1_waddr), .want_len(rd1_wlen),
        .beat_valid(bv_rd1), .beat_data(rdata), .beat_last(rlast),
        .beat_ready(rd1_br)
    );

    assign rd0_data  = (rd0_bank == 2'd3) ? src_data : rd0_stream_data;
    assign rd0_avail = (rd0_bank == 2'd3) ? src_avail : rd0_stream_avail;

    // ---- 2026-10-19：权重走 DDR blob（方案 D，ΔRAM=0），与 WEIGHT_ADDRESS 契约一致 ----
    wire         w_want;
    wire [31:0]  w_waddr;
    wire [7:0]   w_wlen;
    wire         w_br;
    wire         bv_w;

    rowpipe_wstream u_wstream (
        .clk(clk), .rst_n(rst_n), .base(weight_base),
        .req_en(w_req_en), .req_addr(w_req_addr), .req_ack(w_req_ack),
        .out_data(w_data), .out_avail(w_avail),
        .want(w_want), .want_addr(w_waddr), .want_len(w_wlen),
        .beat_valid(bv_w), .beat_data(rdata), .beat_last(rlast),
        .beat_ready(w_br)
    );

    rowpipe_axir_arb4 u_arb (
        .clk(clk), .rst_n(rst_n),
        .w0(src_want), .a0(src_waddr), .l0(src_wlen), .br0(src_br),
        .w1(rd0_want), .a1(rd0_waddr), .l1(rd0_wlen), .br1(rd0_br),
        .w2(rd1_want), .a2(rd1_waddr), .l2(rd1_wlen), .br2(rd1_br),
        .w3(w_want), .a3(w_waddr), .l3(w_wlen), .br3(w_br),
        .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .bv0(bv_src), .bv1(bv_rd0), .bv2(bv_rd1), .bv3(bv_w)
    );

    // ---- 写 ----
    //   结果帧（L11 bank2）：4 像素打包成 1 个 XBGR beat（原逻辑不变）。
    //   中间 bank（B1j 紧凑化）：按 `wr_fmt` 把 1<<fmt 个像素打包成一个 beat。
    //   fmt=0 时直通（1 像素 = 1 beat）。
    wire         virt = (wr_bank == 2'd2) && (cur_layer == 4'd11);
    wire [1:0]   pf   = virt ? 2'd2 : wr_fmt;
    wire [1:0]   pk_last = (pf == 2'd1) ? 2'd1 : 2'd3;   // 非 virt 的 fmt=1 是 2 像素/beat
    reg [1:0]    pk_cnt;
    reg [127:0]  pk_acc;
    reg          beat_push;
    reg [31:0]   beat_addr;
    reg [127:0]  beat_data;
    reg [31:0]   res_words;
    reg [31:0]   res_beats;

    wire [31:0] bank_push_addr = wr_base + {wr_addr, 4'b0000};
    wire        pack_can_emit  = (pf != 2'd0) && (pk_cnt == pk_last);
    wire        wr_p_ready;

    wire         push_we   = virt ? beat_push :
                             ((wr_fmt == 2'd0) ? wr_we : beat_push);
    wire [31:0]  push_addr = virt ? beat_addr :
                             ((wr_fmt == 2'd0) ? bank_push_addr : beat_addr);
    wire [127:0] push_data = virt ? beat_data :
                             ((wr_fmt == 2'd0) ? wr_data : beat_data);
    assign wr_ready = (pf == 2'd0) ? wr_p_ready : (!pack_can_emit || wr_p_ready);

    // 紧凑 beat：像素下标 -> beat 地址
    reg [31:0] comp_addr;
    always @* begin
        case (wr_fmt)
        2'd1:    comp_addr = wr_base + {wr_addr[19:1], 4'b0000};
        2'd2:    comp_addr = wr_base + {wr_addr[19:2], 4'b0000};
        default: comp_addr = bank_push_addr;
        endcase
    end
    // 紧凑 beat：把本像素的低 B 字节并入槽位
    reg [127:0] comp_data;
    always @* begin
        comp_data = pk_acc;
        if (wr_fmt == 2'd1) begin
            if (pk_cnt[0]) comp_data[127:64] = wr_data[63:0];
            else           comp_data[63:0]   = wr_data[63:0];
        end else if (wr_fmt == 2'd2) begin
            case (pk_cnt)
            2'd0:    comp_data[31:0]    = wr_data[31:0];
            2'd1:    comp_data[63:32]   = wr_data[31:0];
            2'd2:    comp_data[95:64]   = wr_data[31:0];
            default: comp_data[127:96]  = wr_data[31:0];
            endcase
        end
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            pk_cnt <= 0; pk_acc <= 0; beat_push <= 0; beat_addr <= 0;
            beat_data <= 0; res_words <= 0; res_beats <= 0;
        end else if (frame_start) begin
            // ⚠ 帧间清零：否则第二帧的 result_done 永远不成立
            pk_cnt <= 0; pk_acc <= 0; beat_push <= 1'b0;
            res_words <= 0; res_beats <= 0;
        end else begin
            beat_push <= 1'b0;
            if (virt) begin
                if (wr_we && wr_ready) begin
                    pk_acc[32*pk_cnt +: 32] <= {8'h00, wr_data[23:0]};
                    res_words <= res_words + 1'b1;
                    if (pk_cnt == 2'd3) begin
                        beat_push <= 1'b1;
                        beat_addr <= result_address + {wr_addr[19:2], 4'b0000};
                        beat_data <= {8'h00, wr_data[23:0], pk_acc[95:0]};
                        pk_cnt <= 0;
                        res_beats <= res_beats + 1'b1;
                    end else pk_cnt <= pk_cnt + 1'b1;
                end
            end else if (wr_fmt != 2'd0) begin
                if (wr_we && wr_ready) begin
                    pk_acc <= comp_data;
                    if (pk_cnt == pk_last) begin
                        beat_push <= 1'b1;
                        beat_addr <= comp_addr;
                        beat_data <= comp_data;
                        pk_cnt <= 0;
                    end else pk_cnt <= pk_cnt + 1'b1;
                end
            end else begin
                pk_cnt <= 0; pk_acc <= 0;
            end
        end

    wire w_idle, w_error;
    assign wr_idle = w_idle;
    wire [31:0] w_acked, w_acked_virt;

    rowpipe_wr_engine u_wr (
        .clk(clk), .rst_n(rst_n), .clear(frame_start),
        .p_addr(push_addr), .p_data(push_data), .p_virt(virt),
        .p_we(push_we), .p_ready(wr_p_ready),
        .idle(w_idle), .error(w_error), .acked(w_acked), .acked_virt(w_acked_virt),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );

    // 读通道 RESP 错也计数
    reg rd_err;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rd_err <= 0;
        else if (rvalid && rready && (rresp != 0)) rd_err <= 1;

    assign error = w_error | rd_err;

    // 结果：所有字都打包完 + 所有 beat ACK + 写引擎空闲
    assign result_done = (res_words == result_pixels) &&
                         (res_beats == (result_pixels >> 2)) &&
                         (w_acked_virt == res_beats) &&
                         w_idle && !beat_push;
endmodule
