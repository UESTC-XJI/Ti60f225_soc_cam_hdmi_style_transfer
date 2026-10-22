//============================================================================
// rowpipe_engine.v —— B2：**层 FSM + 可综合地址/帧缓冲接口**（64×64 整链）
//
// 一个 rowpipe_layer 核，按 L0→L11 顺序跑完整网络。
//
// ## 相对"行为先导版"的两处可综合化
//   1. **地址全部用计数器**（不再有 `pix/win`、`pix%wout` 这种运行期除法/取模）：
//      - 输入：`ix/iy` 行内/行号；普通层源地址 = `ptr`；上采样层 = `src_base + ix/2`，
//        `src_base` 每 2 个源行加一次 `srcW`。
//      - 输出：`ox/oy`；stride2 的 dst 地址 = `dst_base + (ox/2)`，
//        `dst_base` 每 2 行加一次 `wout/2`。
//      - 恒等支地址 = `ptr`（和输入流同序）。
//   2. **帧缓冲移出模块**：bank 变成 2 读 + 1 写端口（供 BRAM/DDR 后端）；
//      权重仍是 ROM 接口。行为 bank 由 TB/顶层提供。
//
// 其余契约（每层复位、cfg 8 写、PREPUSH、命令两步等、co16 两拍）与先导版一致。
//============================================================================
`timescale 1ns / 1ps

module rowpipe_engine (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,

    // ---- 行为 ROM 接口（TB 按 cur_layer/addr 组合给出）----
    output reg  [3:0]   rom_layer,
    output reg  [7:0]   rom_addr,
    input  wire [127:0] rom_w,
    input  wire [31:0]  rom_b,
    input  wire [31:0]  rom_m,
    input  wire [31:0]  rom_mid,
    input  wire [5:0]   rom_shift,
    input  wire signed [7:0] rom_qlo,
    input  wire [7:0]   rom_qhi,

    // ---- B1g（方案 D）：**权重 blob 流**（DDR 经 AXI 读，128b = 一行权重）----
    //   w_req_addr = blob 内的 16B beat 序号；w_avail 那一拍 w_data 有效；
    //   w_req_ack 与 w_avail **同拍**（valid/ack，不是 ready/valid）。
    output wire         w_req_en,
    output wire [19:0]  w_req_addr,
    output wire         w_req_ack,
    input  wire         w_avail,
    input  wire [127:0] w_data,
    output wire         w_timeout,      // 本帧权重流超时（粘滞；帧首清）

    // ---- 帧缓冲接口：2 读 + 1 写（bank 号 + 20 位像素地址；后端可接 DDR）----
    //   地址是**像素下标**（不是字节），后端自己乘 16。640×480 = 307200 ⇒ 19 位够，留 1 位。
    output wire [1:0]   mem_rd_bank0,
    output wire [19:0]  mem_rd_addr0,
    output wire         mem_rd_en0,      // 本拍地址有效（ptr < hout*wout）
    input  wire         mem_rd_avail0,   // 后端：addr0 的数据这拍有效
    input  wire [127:0] mem_rd_data0,
    output wire         mem_rd_ack0,     // 本拍真的消费了 addr0 这个像素
    output wire [1:0]   mem_rd_bank1,
    output wire [19:0]  mem_rd_addr1,
    output wire         mem_rd_en1,      // 本拍 id 地址有效（res && in_range）
    input  wire         mem_rd_avail1,
    input  wire [127:0] mem_rd_data1,
    output wire         mem_rd_ack1,
    output wire [1:0]   mem_wr_bank,
    output wire [19:0]  mem_wr_addr,
    output wire [127:0] mem_wr_data,
    output wire         mem_wr_we,
    input  wire         mem_wr_ready,    // 后端 FIFO 能收（= 层 o_ready）
    // 后端写通道**已排空**（FIFO 空且 AXI 写空闲）。层末必须等它，否则下一层的读
    // 可能在下层开始时读到"还没落盘"的旧数据（第二帧稳定复现）。
    input  wire         mem_wr_idle,

    // ---- 层描述符（12 × 128 位，组合给出；字段见 apply_desc）----
    input  wire [12*128-1:0] descs,

    // B1j 紧凑化：描述符 [101:100]=src_fmt、[103:102]=dst_fmt、[105:104]=id_fmt
    output wire [1:0]   src_fmt,
    output wire [1:0]   dst_fmt,
    output wire [1:0]   id_fmt,

    output reg          done,
    output wire [3:0]   cur_layer
);
    localparam integer NL = 12;

    // ---- 当前层参数 ----
    reg [3:0]  L;
    // ⚠ 输入总像素 = (s2 ? 4 : 1) * hout * wout。**在 apply_desc 时算一次寄存**
    //   —— 留在数据路径上是个乘法器，会顶到 window 的 CE 路径（实测 145.4MHz）。
    reg [31:0] in_total_r;
    reg [31:0] out_total_r;   // 输出像素数 hout*wout（S_WAITPIX 用）
    integer ci, cout, win, hout, wout, ng, res, resu, xorin, s2, up, srcb, dstb, idb, idxor;
    wire [31:0] srcW = up ? (win/2) : win;
    assign cur_layer = L;
    wire [127:0] dcur = dsel(L);
    assign src_fmt = dcur[101:100];
    assign dst_fmt = dcur[103:102];
    assign id_fmt  = dcur[105:104];

    // ---- 描述符字段（**改布局必须两边一起改**：这里 + TB/驱动的 desc 生成）----
    //   [15:0] ci   [31:16] cout   [47:32] win   [63:48] hout   [79:64] wout
    //   [87:80] ng  [88] res  [89] resu  [90] xorin  [91] s2  [92] up
    //   [94:93] srcb  [96:95] dstb  [98:97] idb  [99] idxor
    function [127:0] dsel;
        input [3:0] l;
        begin dsel = descs[{l, 7'b0} +: 128]; end
    endfunction

    task apply_desc;
        input [3:0] l;
        reg [127:0] d;
        begin
            d = dsel(l);
            ci   <= d[15:0];   cout <= d[31:16];  win <= d[47:32];
            hout <= d[63:48];  wout <= d[79:64];  ng  <= d[87:80];
            res  <= d[88];     resu <= d[89];     xorin <= d[90];
            s2   <= d[91];     up   <= d[92];
            srcb <= d[94:93];  dstb <= d[96:95];  idb <= d[98:97]; idxor <= d[99];
            in_total_r  <= (d[91] ? 32'd4 : 32'd1) * d[63:48] * d[79:64];
            out_total_r <= d[63:48] * d[79:64];
        end
    endtask

    // ---- 层核 ----
    reg         layer_rst_n = 0;
    reg         cfg_we = 0; reg [7:0] cfg_addr = 0; reg [15:0] cfg_data = 0;
    reg         ld_we = 0, ld_be = 0, ld_me = 0;
    reg [7:0]   ld_waddr = 0, ld_baddr = 0, ld_midx = 0;
    reg [127:0] ld_wdata = 0;
    reg signed [31:0] ld_bdata = 0, ld_m = 0, ld_mid = 0;
    reg [5:0]   ld_shift = 0; reg signed [7:0] ld_qlo = 0; reg [7:0] ld_qhi = 0;
    reg         grp_vld = 0, skip_vld = 0;
    reg [127:0] s_col = 0, i_id = 0;
    wire        o_vld, o_row_end, s_ack, o_pix_done;
    wire [127:0] o_col;
    wire [3:0]  o_st;

    // 输入数据这拍可用吗（id 只在 res 层要）—— 赋值在 `in_range` 声明之后（wire 先声明）
    wire data_ok;

    // B1e（2026-10-18）：**ci_tiles=2** —— 窗口 8 通道（ci_par），ci16 层重读行缓冲。
    rowpipe_layer #(.CI(16), .CIW(8), .PIX(16), .CO(16), .COUT(16)) u_layer (
        .clk(clk), .rst_n(layer_rst_n),
        .ld_we(ld_we), .ld_waddr(ld_waddr), .ld_wdata(ld_wdata),
        .ld_be(ld_be), .ld_baddr(ld_baddr), .ld_bdata(ld_bdata),
        .ld_me(ld_me), .ld_midx(ld_midx), .ld_m(ld_m), .ld_mid(ld_mid),
        .ld_shift(ld_shift), .ld_qlo(ld_qlo), .ld_qhi(ld_qhi),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .s_vld(data_ok), .s_col(s_col),
        .grp_vld(grp_vld), .skip_vld(skip_vld),
        .o_vld(o_vld), .o_col(o_col), .o_ready(mem_wr_ready), .o_row_end(o_row_end),
        .o_pix_done(o_pix_done),
        .s_ack(s_ack), .o_st(o_st),
        .i_id(i_id)
    );

    //========================================================================
    // 地址计数器（无运行期除法/取模）
    //========================================================================
    integer ptr = 0;                 // 已消费列数（恒等支地址）
    integer ix = 0, iy = 0;          // 输入行内列 / 行号
    integer ox = 0, oy = 0;          // 输出列 / 行
    integer pix = 0;                 // 输出像素总数
    integer src_base = 0;            // 上采样：源行基址
    integer dst_base = 0;            // stride2：dst 行基址（按 wout/2 宽）
    reg     cnt_clr = 0;

    always @(posedge clk) begin
        if (cnt_clr) begin
            ptr <= 0; ix <= 0; iy <= 0; ox <= 0; oy <= 0; pix <= 0;
            src_base <= 0; dst_base <= 0;
        end else begin
            if (s_ack) begin
                ptr <= ptr + 1;
                if (ix == win - 1) begin
                    ix <= 0;
                    iy <= iy + 1;
                    // 上采样：每 2 个输出行才换一个源行
                    if (up && iy[0]) src_base <= src_base + srcW;
                end else ix <= ix + 1;
            end
            if (o_vld && o_pix_done && mem_wr_ready) begin
                pix <= pix + 1;
                if (ox == wout - 1) begin
                    ox <= 0;
                    oy <= oy + 1;
                    // stride2：每 2 个输出行才换一行 dst
                    if (s2 && oy[0]) dst_base <= dst_base + (wout/2);
                end else ox <= ox + 1;
            end
        end
    end

    // 输入读地址：普通层 = ptr；上采样 = src_base + ix/2
    wire [19:0] src_addr = up ? (src_base[19:0] + ix[19:1]) : ptr[19:0];
    // ---- B1f：stride-2 层的**输入**是 2×hout × 2×wout 的全分辨率图 ----
    //   每个输出行消费 2 个输入行（组里 1 行 + 行间 skip 1 行），
    //   总量 = 4*hout*wout = 2*hout*win；尾部多读 18 列（窗口起始偏移）被竖 halo 丢掉。
    wire        in_range = (ptr < in_total_r);
    wire [127:0] src_word = in_range ? mem_rd_data0 : 128'd0;
    wire [127:0] id_word  = (res && in_range) ? mem_rd_data1 : {16{8'h80}};
    // ⚠ **越界（ptr ≥ hout*wout）那 82 拍尾部填充必须是"有效消费"**：
    //   旧引擎 s_vld 恒 1、源数据被 `in_range` 置 0，层照样把窗口走完；
    //   现在 s_vld 跟着后端，若不在这里放行，尾部 82 拍会**死锁**（实测 pix 卡 4014）。
    assign data_ok = (in_range ? mem_rd_avail0 : 1'b1) &&
                     ((res == 0) || (!in_range) || mem_rd_avail1);

    always @(*) begin
        s_col = xorin ? (src_word ^ {16{8'h80}}) : src_word;
        i_id  = idxor ? (id_word  ^ {16{8'h80}}) : id_word;
    end

    assign mem_rd_bank0 = srcb[1:0];
    assign mem_rd_addr0 = in_range ? src_addr : 20'd0;
    assign mem_rd_en0   = in_range;
    assign mem_rd_ack0  = s_ack && in_range;
    assign mem_rd_bank1 = idb[1:0];
    assign mem_rd_addr1 = (res && in_range) ? ptr[19:0] : 20'd0;
    assign mem_rd_en1   = (res != 0) && in_range;
    assign mem_rd_ack1  = s_ack && (res != 0) && in_range;

    // 输出写：像素完成拍。**B1f 起 s2 层自己就只出 1/4 的像素**（真 stride-2），
    //   不再靠"算 4 倍、只写偶偶"⇒ 每个输出像素都要写，地址就是顺序的 `pix`。
    reg [127:0] lo_col;
    wire [127:0] out_word = (cout > 8) ? {o_col[127:64], lo_col[63:0]} : o_col;
    wire        wr_now = o_vld && o_pix_done && mem_wr_ready;
    assign mem_wr_we   = wr_now;
    assign mem_wr_bank = dstb[1:0];
    assign mem_wr_addr = pix[19:0];
    assign mem_wr_data = out_word;

    always @(posedge clk) if (o_vld && !o_pix_done) lo_col <= o_col;

    //========================================================================
    // FSM（与先导版一致；命令两步等）
    //========================================================================
    localparam S_IDLE=4'd0, S_LRST=4'd1, S_CFG=4'd2, S_W=4'd3, S_B=4'd4,
               S_M=4'd5, S_Q=4'd6, S_PRE=4'd7, S_GRP=4'd8, S_WAITPIX=4'd9,
               S_RPAD=4'd10, S_DONE=4'd11;
    reg [3:0] st = S_IDLE;
    integer i, k, y, g;
    reg [1:0] ph;
    // ---- B1g：权重 blob 装载 ----
    //   每层块（16B 对齐）：[weights ci*9 beat][bias 4 beat][M/mid 8 beat][quant 1 beat]
    //   偏移表**必须与 hw/rowpipe/INTERFACE.md §8 一致**。
    function [19:0] wbase_of;
        input [3:0] l;
        begin
            case (l)
            4'd0:  wbase_of = 20'd0;      // cap8 contiguous
            4'd1:  wbase_of = 20'd40;
            4'd2:  wbase_of = 20'd89;
            4'd3:  wbase_of = 20'd174;
            4'd4:  wbase_of = 20'd259;
            4'd5:  wbase_of = 20'd344;
            4'd6:  wbase_of = 20'd429;
            4'd7:  wbase_of = 20'd514;
            4'd8:  wbase_of = 20'd599;
            4'd9:  wbase_of = 20'd684;
            4'd10: wbase_of = 20'd769;
            default: wbase_of = 20'd854;
            endcase
        end
    endfunction
    wire [19:0] wb   = wbase_of(L);
    wire [19:0] ci9w = ci * 9;
    reg [127:0] whold = 0;
    reg [1:0]   uc = 0;
    // 超时：连续 65535 拍拿不到权重 beat ⇒ 判本帧失败（不挂死）
    reg [15:0]  wtimer = 0;
    reg         w_to = 0;
    assign w_timeout = w_to;

    // ⚠ 地址必须是**组合的当前 beat**：用寄存器"下一拍才更新"的话，等待拍里
    //   stream 会看到旧地址 < head_addr ⇒ need_restart ⇒ flush 到旧地址 ⇒ 死锁
    //   （2026-10-18 实测：engine 要 29、stream 停在 28 互等）。
    wire [19:0] w_addr_now =
        (st == S_W) ? (wb + k) :
        (st == S_B) ? (wb + ci9w + k) :
        (st == S_M) ? (wb + ci9w + 20'd4 + k) :
        (st == S_Q) ? (wb + ci9w + 20'd12) : 20'd0;
    // ⚠ req_en 必须**只在真正等/消费 beat 的拍**拉高：
    //   - 在多 beat 的小表拆包拍（ph=1）里地址停在刚消费的 beat 上，head 已经 +1
    //     ⇒ stream 会判 need_restart 并 flush 回旧地址 ⇒ 死锁（实测）。
    //   - ack 和 req_en 同一个条件，避免"状态还没切走"那拍多 ack 一次。
    wire w_need_beat =
        (st == S_W && (k < ci*9)) ||
        (st == S_B && (k < 4) && (ph == 2'd0)) ||
        (st == S_M && (k < 8) && (ph == 2'd0)) ||
        (st == S_Q && (ph == 2'd0));
    assign w_req_en   = w_need_beat;
    assign w_req_addr = w_addr_now;
    assign w_req_ack  = w_need_beat && w_avail;

    reg [3:0] cfg_i;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= S_IDLE; done <= 0; L <= 0; layer_rst_n <= 0;
        end else begin
            grp_vld <= 0; skip_vld <= 0; cfg_we <= 0; ld_we <= 0; ld_be <= 0; ld_me <= 0;
            cnt_clr <= 0;
            case (st)
            S_IDLE: if (start) begin
                L <= 0; done <= 0; cnt_clr <= 1;
                apply_desc(0);
                w_to <= 0; wtimer <= 0;
                layer_rst_n <= 0; st <= S_LRST; i <= 0;
            end
            S_LRST: begin
                i = i + 1;
                if (i >= 4) begin layer_rst_n <= 1; cfg_i <= 0; st <= S_CFG;
                    cfg_we <= 1; cfg_addr <= 8'd0; cfg_data <= win; end
            end
            S_CFG: begin
                cfg_we <= 1;
                cfg_i <= cfg_i + 1;
                case (cfg_i)
                4'd0: begin cfg_addr <= 8'd0; cfg_data <= win;  end
                4'd1: begin cfg_addr <= 8'd1; cfg_data <= ng;   end
                4'd2: begin cfg_addr <= 8'd2; cfg_data <= hout; end
                4'd3: begin cfg_addr <= 8'd3; cfg_data <= wout; end
                4'd4: begin cfg_addr <= 8'd4; cfg_data <= res;  end
                4'd5: begin cfg_addr <= 8'd5; cfg_data <= resu; end
                4'd6: begin cfg_addr <= 8'd6; cfg_data <= ci;   end
                4'd7: begin cfg_addr <= 8'd7; cfg_data <= cout; end
                4'd8: begin cfg_addr <= 8'd8; cfg_data <= s2;   end   // B1f：stride-2
                4'd9: begin cfg_addr <= 8'd9; cfg_data <= 16'd1; end  // B1f：skip 长度（默认 1）
                default: begin cfg_we <= 0; st <= S_W; k <= 0; ph <= 0; end
                endcase
            end
            // ---- B1g（方案 D）：四段装载全部从权重流读 ----
            //   weights：avail 即落 wrow（一拍一行）；bias/M/quant：先锁存 beat，
            //   再用 ph=1 把这拍拆成多个小表条目逐拍写（bias 4 个 / M-mid 2 个）。
            S_W: begin
                if (k >= ci*9) begin st <= S_B; k <= 0; ph <= 0; end
                else if (w_avail) begin
                    ld_we <= 1; ld_waddr <= k; ld_wdata <= w_data;
                    k <= k + 1;
                end
            end
            S_B: begin
                if (k >= 4) begin st <= S_M; k <= 0; ph <= 0; uc <= 0; end
                else if (ph == 0) begin
                    if (w_avail) begin whold <= w_data; ph <= 1; uc <= 0; end
                end else begin
                    ld_be    <= 1;
                    ld_baddr <= k*4 + uc;
                    ld_bdata <= whold[uc*32 +: 32];
                    if (uc == 2'd3) begin k <= k + 1; ph <= 0; uc <= 0; end
                    else uc <= uc + 1;
                end
            end
            S_M: begin
                if (k >= 8) begin st <= S_Q; k <= 0; ph <= 0; uc <= 0; end
                else if (ph == 0) begin
                    if (w_avail) begin whold <= w_data; ph <= 1; uc <= 0; end
                end else begin
                    ld_me   <= 1;
                    ld_midx <= k*2 + uc;
                    ld_m    <= whold[uc*64 +: 32];
                    ld_mid  <= whold[uc*64 + 32 +: 32];
                    if (uc == 2'd1) begin k <= k + 1; ph <= 0; uc <= 0; end
                    else uc <= uc + 1;
                end
            end
            S_Q: begin
                if (ph == 0) begin
                    if (w_avail) begin whold <= w_data; ph <= 1; end
                end else begin
                    ld_me <= 1; ld_midx <= 8'hFF; ld_m <= 0; ld_mid <= 0;
                    ld_shift <= whold[5:0]; ld_qlo <= whold[13:6]; ld_qhi <= whold[21:14];
                    ph <= 0; i <= 0; st <= S_PRE;
                end
            end            S_PRE: begin
                if (ph == 0) begin
                    if (i >= win + 18) begin
                        i <= 0; y <= 0; g <= 0;
                        // B1f：PREPUSH 用 1 列的 skip（658 条，和旧行为一致）；
                        //   之后行间空跑改用 **win 列的突发**（一条命令一整行）。
                        if (s2) begin cfg_we <= 1; cfg_addr <= 8'd9; cfg_data <= win[15:0]; end
                        st <= S_GRP;
                    end
                    else if (o_st == 4'd0) begin skip_vld <= 1; ph <= 1; end
                end else if (ph == 1) begin
                    if (o_st != 4'd0) ph <= 2;
                end else begin
                    if (o_st == 4'd0) begin i <= i + 1; ph <= 0; end
                end
            end
            S_GRP: begin
                if (ph == 0) begin
                    if (y >= hout) begin st <= S_WAITPIX; end
                    else if (o_st == 4'd0) begin grp_vld <= 1; ph <= 1; end
                end else if (ph == 1) begin
                    if (o_st != 4'd0) ph <= 2;
                end else begin
                    if (o_st == 4'd0) begin
                        if (g == ng-1) begin
                            g <= 0;
                            // B1f：stride-2 两个输出行之间要**空跑一整行输入**
                            //   （输出行 y 用输入行 2y-1..2y+1，下一行用 2y+1..2y+3）
                            if (y == hout-1) y <= y + 1;          // 最后一行：没有 skip
                            else if (s2)      st <= S_RPAD;
                            else              y <= y + 1;
                        end
                        else g <= g + 1;
                        ph <= 0;
                    end
                end
            end
            // B1f：一整行 skip（层里 cfg_skiplen=win ⇒ 一条命令消费 win 列）
            S_RPAD: begin
                if (ph == 0) begin
                    if (o_st == 4'd0) begin skip_vld <= 1; ph <= 1; end
                end else if (ph == 1) begin
                    if (o_st != 4'd0) ph <= 2;
                end else begin
                    if (o_st == 4'd0) begin y <= y + 1; ph <= 0; st <= S_GRP; end
                end
            end
            S_WAITPIX: if ((pix >= out_total_r) && mem_wr_idle) begin
                if (L == NL-1) begin done <= 1; st <= S_DONE; end
                else begin L <= L + 1; apply_desc(L + 1); cnt_clr <= 1;
                           layer_rst_n <= 0; i <= 0; st <= S_LRST; end
            end
            // ⚠ 旧版死锁在 S_DONE（只认 rst_n）⇒ **第二帧的 start 被吞**，driver 永远等不到。
            //   现在 S_DONE 也接受 start，重启流程与 S_IDLE 完全一致。
            S_DONE: begin
                if (start) begin
                    L <= 0; done <= 0; cnt_clr <= 1;
                    apply_desc(0);
                    layer_rst_n <= 0; i <= 0; st <= S_LRST;
                end else done <= 1;
            end
            default: st <= S_IDLE;
            endcase

            // ---- 权重流超时（放在 case 之后：后写覆盖上面的状态转移）----
            if (w_need_beat && !w_avail) begin
                if (wtimer == 16'hFFFF) begin
                    w_to <= 1'b1;
                    done <= 1'b1;
                    st   <= S_DONE;
                end else wtimer <= wtimer + 1'b1;
            end else wtimer <= 16'd0;
        end
endmodule
