//============================================================================
// rowpipe_frame_driver.v —— B2 帧级驱动：**帧协议 ↔ rowpipe_engine ↔ AXI DDR**
//
// 帧级契约（与队友 `style_frame_store` 一致）：
//   start 脉冲 → busy → 跑 12 层 → done（error 表示 AXI 或打包出错）
//
// 数据通路：
//   源帧  = DDR `source_address`，XBGR 4B/像素（R 最低字节）
//         → rowpipe_ddr_banks 的源帧流（bank 3）展开成 128 位/像素字
//   中间  = DDR 3 个 bank（基址见 localparam BANK*_BASE），2 读 + 1 写
//   结果  = L11 的写口（bank2）打包成 XBGR beat → DDR `result_address`
//
// 本模块不再含行为 bank：帧缓冲全部走 `rowpipe_ddr_banks` 的 AXI 口。
// （2026-10-17 之前的版本用 4×4096×128 的行为数组，只够 64×64 仿真。）
//============================================================================
`timescale 1ns / 1ps

module rowpipe_frame_driver (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [31:0]  source_address,
    input  wire [31:0]  result_address,
    // B1g（方案 D）：权重 blob 的 DDR 基址（16B 对齐；布局见 INTERFACE.md §8）
    input  wire [31:0]  weight_address,
    input  wire [9:0]   frame_width,
    input  wire [9:0]   frame_height,

    // ---- 层描述符（12 × 128 位；字段见 rowpipe_engine.apply_desc）----
    input  wire [12*128-1:0] descs,

    output reg          busy,
    output reg          done,
    output wire         error,
    output wire [3:0]   layer_index,
    output reg  [31:0]  cycles,

    // ---- 行为 ROM（权重/BN/收尾；与 rowpipe_engine 同口）----
    output wire [3:0]   rom_layer,
    output wire [7:0]   rom_addr,
    input  wire [127:0] rom_w,
    input  wire [31:0]  rom_b,
    input  wire [31:0]  rom_m,
    input  wire [31:0]  rom_mid,
    input  wire [5:0]   rom_shift,
    input  wire signed [7:0] rom_qlo,
    input  wire [7:0]   rom_qhi,

    // ---- AXI4 master ----
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
    // 中间帧 bank：DDR 空闲区（源/结果各占 8MB 窗口，见 style_accel 地址规则）
    // ⚠⚠ **间隔必须 ≥ 5MB**（2026-10-18 修正，原来 2MB 是错的）：
    //   bank 存储格式是 **16 B/像素**，全分辨率中间帧 = 307,200×16 = **4.9 MB**。
    //   2MB 间隔时 L0 的帧（bank0，0x0600_0000..0x064A_FFFF）会盖住 bank1/bank2 的起点；
    //   L1 一边读 L0（bank0）一边写 bank1（0x0620_0000）⇒ **写进还在读的帧里**。
    //   64×64 仿真每帧才 64KB，碰不到；640×480 必炸。
    localparam [31:0] BANK0_BASE = 32'h0600_0000;   // 0x0600_0000 .. 0x064F_FFFF（5MB）
    localparam [31:0] BANK1_BASE = 32'h0650_0000;   // 0x0650_0000 .. 0x069F_FFFF
    localparam [31:0] BANK2_BASE = 32'h06A0_0000;   // 0x06A0_0000 .. 0x06EF_FFFF

    wire [31:0] total_pixels = frame_width * frame_height;

    // ---- 引擎 ↔ 后端 ----
    wire [1:0]   rd0_bank, rd1_bank, wr_bank;
    wire [19:0]  rd0_addr, rd1_addr, wr_addr;
    wire         rd0_en, rd1_en, wr_we, wr_ready, wr_idle;
    wire         rd0_ack, rd1_ack;
    wire [127:0] rd0_data, rd1_data, wr_data;
    wire         rd0_avail, rd1_avail;

    // ---- B1g：权重 blob 流（引擎 → banks 的权重读流）----
    wire        w_req_en, w_req_ack, w_avail, eng_w_to;
    wire [1:0]  eng_src_fmt, eng_dst_fmt, eng_id_fmt;
    wire [19:0] w_req_addr;
    wire [127:0] w_data;

    wire        eng_done;
    reg         eng_start = 0;
    reg         frame_start = 0;    // 帧首单拍：清后端的帧内计数（见下）
    reg         eng_low = 0;        // 本帧是否已看到 eng_done 落下（防第二帧读到上一帧的 done）
    wire        res_done;
    wire        bank_error;
    // 帧级错误：banks 的粘滞错误 OR 本帧的权重流超时（帧首清）
    reg         err_frame = 0;
    assign error = bank_error | err_frame;

    rowpipe_engine u_eng (
        .clk(clk), .rst_n(rst_n), .start(eng_start),
        .rom_layer(rom_layer), .rom_addr(rom_addr),
        .rom_w(rom_w), .rom_b(rom_b), .rom_m(rom_m), .rom_mid(rom_mid),
        .rom_shift(rom_shift), .rom_qlo(rom_qlo), .rom_qhi(rom_qhi),
        .w_req_en(w_req_en), .w_req_addr(w_req_addr), .w_req_ack(w_req_ack),
        .w_avail(w_avail), .w_data(w_data),
        .w_timeout(eng_w_to),
        .mem_rd_bank0(rd0_bank), .mem_rd_addr0(rd0_addr),
        .mem_rd_en0(rd0_en), .mem_rd_avail0(rd0_avail),
        .mem_rd_data0(rd0_data), .mem_rd_ack0(rd0_ack),
        .mem_rd_bank1(rd1_bank), .mem_rd_addr1(rd1_addr),
        .mem_rd_en1(rd1_en), .mem_rd_avail1(rd1_avail),
        .mem_rd_data1(rd1_data), .mem_rd_ack1(rd1_ack),
        .mem_wr_bank(wr_bank), .mem_wr_addr(wr_addr),
        .mem_wr_data(wr_data), .mem_wr_we(wr_we), .mem_wr_ready(wr_ready),
        .mem_wr_idle(wr_idle),
        .descs(descs),
        .src_fmt(eng_src_fmt), .dst_fmt(eng_dst_fmt), .id_fmt(eng_id_fmt),
        .done(eng_done), .cur_layer(layer_index)
    );

    rowpipe_ddr_banks u_bank (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
        .rd0_bank(rd0_bank), .rd0_addr(rd0_addr), .rd0_en(rd0_en),
        .rd0_ack(rd0_ack), .rd0_data(rd0_data), .rd0_avail(rd0_avail),
        .rd1_bank(rd1_bank), .rd1_addr(rd1_addr), .rd1_en(rd1_en),
        .rd1_ack(rd1_ack), .rd1_data(rd1_data), .rd1_avail(rd1_avail),
        .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we),
        .cur_layer(layer_index), .wr_ready(wr_ready), .wr_idle(wr_idle),
        .source_address(source_address), .result_address(result_address),
        .weight_base(weight_address),
        .rd0_fmt(eng_src_fmt), .rd1_fmt(eng_id_fmt), .wr_fmt(eng_dst_fmt),
        .w_req_en(w_req_en), .w_req_addr(w_req_addr), .w_req_ack(w_req_ack),
        .w_data(w_data), .w_avail(w_avail),
        .bank_base0(BANK0_BASE), .bank_base1(BANK1_BASE), .bank_base2(BANK2_BASE),
        .result_pixels(total_pixels),
        .result_done(res_done), .error(bank_error),
        .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );

    // ---- FSM ----
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FLUSH = 2'd2, S_DONE = 2'd3;
    reg [1:0] st = S_IDLE;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= S_IDLE; busy <= 0; done <= 0; cycles <= 0; eng_start <= 0;
            frame_start <= 0; eng_low <= 0; err_frame <= 0;
        end else begin
            eng_start <= 1'b0;
            // ⚠ 帧间必须清后端的帧内计数（res_words/res_beats/acked_virt）。
            //   它们原来只在 rst_n 清零 ⇒ **第二帧的 result_done 永远不成立**，
            //   driver 会卡死在 S_FLUSH（现有 TB 只跑一帧，所以没暴露）。
            frame_start <= 1'b0;
            case (st)
            S_IDLE: if (start) begin
                busy <= 1; done <= 0; cycles <= 0;
                eng_start <= 1; frame_start <= 1; eng_low <= 0;
                err_frame <= 0; st <= S_RUN;
            end
            // ⚠ 必须**先看到 eng_done 落下**再等它起来：第二帧 start 那一拍
            //   引擎的 done 可能还是上一帧留下的 1（同一个沿才被清）。
            S_RUN: begin
                cycles <= cycles + 1'b1;
                // 权重流超时 ⇒ 本帧判废，直接收尾（不走 result flush，避免挂死）
                if (eng_w_to) begin
                    err_frame <= 1'b1; busy <= 0; done <= 1; st <= S_IDLE;
                end else if (!eng_done) eng_low <= 1'b1;
                else if (eng_low) st <= S_FLUSH;
            end
            S_FLUSH: begin
                cycles <= cycles + 1'b1;
                if (res_done) st <= S_DONE;
            end
            S_DONE: begin busy <= 0; done <= 1; st <= S_IDLE; end
            default: st <= S_IDLE;
            endcase
        end
endmodule
