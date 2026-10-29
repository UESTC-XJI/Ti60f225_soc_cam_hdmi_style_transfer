//============================================================================
// rowpipe_layer.v —— **单层**行流水（功能版第一块）
//
// 一层的完整通路：**列流进 → 2 行环形缓冲 → 3×3 窗口 → 256 MAC → requant → 列流出**
//
// ## ⚠ tap 结构的红线（探针逼出来的，不是风格选择）
//
// 探针（`rowpipe_probe.v`）实测：
//   - `CI=16` 打包 + **变量下标** `w[kx+p]` → LUT 35,732，**PnR 装不下**（v2）
//   - `CI=4`（窗口位宽 = `ci_par`）→ 24,286 LUT，239.177MHz 收敛（v4）
//
// ⇒ 两条硬要求：
//   1. **窗口位宽 = `ci_par`，不是全部输入通道 `CI`**
//   2. **列方向（kx）不许出现变量下标** —— 用"扁平向量 + 常数宽度切片"
//
//     row  = 3 行里选 1 行                        ← 3:1 mux（允许）
//     taps = w[gi*3+row][kx*CW +: PIX*CW]         ← **常数宽度切片**，不是 [idx]
//
//   写成 `row[kx+p]`（变量下标取单元素）会综合出一组 18:1 宽 mux → 回到 v2。
//   **实现完必须 grep：tap 路径不许有 `[变量]` 形式的下标。**
//
// ## ⚠ 窗口的三个约定（和 TB 成对，改一个必须改另一个）
//
// **(a) 每行的列方向：col0 = 最旧，col(WN-1) = 最新。**
//     所以移位是 `{ newbyte, w[WN*8-1:8] }`——新字节进**高位 = col17**，
//     老的往低位挤、col0 最旧会掉出去。
//     这样 `w[kx*8 +: PIX*8]` 才是"kx 越大、列号越大"，和 `conv3x3`
//     的 kx 约定（`tb_conv3x3.v:171-182`：`+ (g+p)*stride + kx`）一致。
//     ⚠ 写成 `{ w[WN*8-9:0], newbyte }`（新字节进 col0）会让 kx 方向整个反过来，
//       单看 RTL 看不出来，只有对数值才炸。**这一行别凭手感改。**
//
// **(b) 三行必须都寄存。** 行缓冲读要走 BRAM，BRAM 输出必须打一拍；
//     `s_col` 若直接用组合值，row2 会比 row0/row1 **新一列**。
//     所以 `q_c <= s_col`，三行一起在同一个"消费位置"上取样。
//
// **(c) 行缓冲按「消费」推进，不按拍。** `wp`/`lb` 的使能是 `adv`，
//     `adv = (S_SER || S_SKIP) && s_vld`——即**每消费一列走一格**。
//     若写成 `if (s_vld)`（s_vld 通常恒 1），wp 会按**拍**跑，
//     而列只在 `adv` 时被消费 ⇒ "两行前"的偏移变成按拍算，整层全错。
//     ⇒ 接口契约：**`s_col`/`s_vld` 是"本拍要消费的那一列"，不是自由流动的流。**
//        （层的连续性/背压留给层间的抖动队列，见 README「调度/抖动预算」。）
//
// **(d) `q_c/q_a/q_b` 三个读寄存器必须用 `adv` 门控。**
//     它们记的是"上一个 adv 的地址"上的值；组间有空档（`wp` 不动）时若不门控，
//     它们会被刷成"当前地址"的值 ⇒ 每次续流的第一拍多推一列。
//     现象很有辨识度：**每组的头 3 列、尾 2 列错，中间 13 列全对。**
//
// ### 由此定出的对齐常数（TB 必须一致）
//
//     消费完 n 列后，窗口里 row0 col j = 填充张量 pin[n-151+j]。
//     ⇒ 输出 (y,x) 的一组，必须在 n = **y*66 + x + 151** 时开跑。
//     ⇒ TB 开局预推 **151** 拍，之后每行 = 4 组 × 16 列 + 2 个 skip = 66。
//
// ## ⚠ core 是**批处理**的，不是流式的（查过 `conv3x3_core` 的握手）
//
//     start 一个脉冲 → busy=1；step × n_step；acc_vld 在最后一步后 3 拍**拉高一次**
//
// 一次 start 只出**一组** PIX×CO 个累加器 —— **没有"每拍出结果"**。
// 所以本层每组必须重新 start。
//
// **`core_step` 是组合的**（`step_go`）：core 在**看到 step 的那一拍**采 taps，
// 所以 taps 和 step 必须同拍。若把 `core_step` 做成寄存器、又在本拍推进
// `s_kx/s_ky/ci_cnt`，core 第一次看到 step=1 时计数器已经走了一格 ——
// tap 比权重永远超前一步，最后一步落到 `tsel[CI*9]` **越界出 x**，
// 整个累加器变 x，输出整片 xx。（2026-10-06 实测的坑。）
//
// ## requant 只有一份，按像素时分复用
//
// 一组要出 PIX 个像素 × CO 个通道。PIX 份 requant 要多 16 倍乘法器 ⇒
// 只留一份，**喂 16 拍**（每拍选 `acc_flat` 里的第 `ser` 个像素）。
// requant 两级流水 ⇒ 输出比喂晚 2 拍：
//
//     S_SER   16 拍：喂像素 0..15（同时把窗口往前推 16 列，给下一组）
//     S_DRAIN  2 拍：只吐最后两个像素，**不推窗口**
//
// 每组周期 = 1(idle) + 1(start) + ci×9(step) + 3(DSP_LAT) + 16(喂+推窗) + 2(排空) + 1
//
// ## 输出布局（**和 chain 不一致，TB 要重排**）
//
// 本模块流出的顺序 = `y → x → c`（每拍一个像素的 CO 个字节）；
// `L{i}_chain.hex` 的顺序 = `c → y → x`（x 最快、c 最慢）。
//   chain[c*hout*wout + y*wout + x]  ←  第 y 行第 x 列的第 c 个字节
//============================================================================
`timescale 1ns / 1ps

module rowpipe_layer #(
    parameter integer CI   = 4,        // 输入通道 = 端口/行缓冲宽度（**全部 cin**）
    // ---- B1e（2026-10-18）：**ci_tiles=2** ----
    //   窗口只存 CIW 个通道（= ci_par）。CIW < CI 时，cfg_ci > CIW 的层分两遍算：
    //   窗口先装 Ci 0..CIW-1、走 CIW×9 步；再**重读行缓冲**把同一批列换成
    //   Ci CIW..15（18 拍），继续走剩下的步（core 不停、累加器接着累）。
    //   ⇒ 窗口 FF 减半（16→8 通道），代价≈每 tile 边界 18 拍。
    //   默认 CIW=CI ⇒ 旧实例（单层 TB / style_accel）**逐位不变**。
    parameter integer CIW  = CI,       // 窗口通道（ci_par，必须能整除 CI 或 ≥CI）
    parameter integer PIX  = 16,       // 空间并行
    parameter integer CO   = 16,       // **输出端口的通道数上限**（o_col 宽度 = CO*8）
    // ---- B1c（2026-10-17）：阵列 8 通道，输出可到 16 ----
    //   conv/requant 的 MAC 阵列固定 **CO_ARR=8**（64 DSP）；`COUT` 是**本层实际输出通道**
    //   （1..CO）。COUT>8 时每个像素分两遍算：第 1 拍低 8 通道、第 2 拍高 8 通道。
    //   COUT<=8 时一拍一个像素（与旧行为一致）。
    parameter integer COUT = CO,
    parameter integer RQW  = 6         // requant 的 shift 位宽
    // ---- B1a（2026-10-17）：几何 / 残差 **运行期化** ----
    //   原来的 `WIN/WOUT/HOUT/RES/RESU` 参数已删 —— 12 层时分复用同一套核，
    //   这些量每层不同，必须由 `cfg_*` 在开跑前加载。
    //   ⚠ `CI/CO/PIX` 仍是编译期（B1b 才做 CI 运行期化）。
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- 权重 / 偏置 / 收尾参数（透传）----
    input  wire                ld_we,
    input  wire [7:0]          ld_waddr,
    input  wire [CO*8-1:0]     ld_wdata,
    input  wire                ld_be,
    input  wire [7:0]          ld_baddr,
    input  wire signed [31:0]  ld_bdata,
    input  wire                ld_me,
    input  wire [7:0]          ld_midx,
    input  wire signed [31:0]  ld_m,
    input  wire signed [31:0]  ld_mid,
    input  wire [RQW-1:0]      ld_shift,
    input  wire signed [7:0]   ld_qlo,
    input  wire [7:0]          ld_qhi,
    // 2026-10-27：末层由 rowpipe_engine 强制置 1（= 不 ReLU，输出原样透传）。
    // 原设计里"是否 ReLU"只看 qlo 的符号，于是末层写成 qlo=0（offset-binary）
    // 就静默把输出负半轴夹成 0 —— redsky v4、starry g075/g085 都中过。见 requant.v。
    input  wire                ld_relu_dis,

    // ---- B1a：运行期几何 / 残差配置（层开始前一次加载；接口仿 `ld_*`）----
    //   addr：0 = WIN（未填充行宽）、1 = NG（每行组数 = WIN/PIX）、
    //         2 = HOUT、3 = WOUT、4 = RES、5 = RESU
    //   ⚠ 必须在第一个 skip/grp 之前写完；运行中改值行为未定义（不做动态重配）。
    input  wire                cfg_we,
    input  wire [7:0]          cfg_addr,
    input  wire [15:0]         cfg_data,

    // ---- 列流输入：`s_vld` 拉高时 `s_col` 即"本拍要消费的那一列" ----
    input  wire                s_vld,
    // 2026-10-27 更正：**s_col 是一个像素的 CI 个通道字节**（见 :502 `q_c <= s_col`
    //   和 :524 `q_c[8*gi +: 8]` 按通道取），不是"PIX 个像素"。
    //   宽度写成 PIX*8（=128）而不是 CI*8，是为了让 engine 的 128 位 AXI beat 完整连进来、
    //   由 `q_c <= s_col` 显式截到 CI 个通道；CI=PIX=16 时两者相同，CI=8 时行为等价
    //   但端口上不产生隐式截断。
    //   （我曾把这里的注释写成"s_col 是像素宽"，是错的 —— 特此更正，别照旧注释改。）
    input  wire [PIX*8-1:0]    s_col,

    // ---- 组启动：开始下一组 PIX 个输出列 ----
    input  wire                grp_vld,
    // ---- 只推窗口、不出结果（补 halo：填充后行宽 66，而每组只推 PIX=16 列）----
    input  wire                skip_vld,

    // ---- 列流输出：**带背压**，每拍一个像素的 CO 个字节，顺序 y → x → c ----
    // ⚠ 契约 3（`README.md` 层间契约）：**下游不接时必须能挂起**，否则串层直接丢数据。
    //   `o_ready=1` = 下游这一拍收下了；`=0` = 挂起（`o_vld` 保持、`o_col` 冻结、不丢拍）。
    output wire                o_vld,
    output wire [CO*8-1:0]     o_col,
    input  wire                o_ready,      // ← 契约 3
    output wire                o_row_end,    // ← 契约 4：**每 WOUT 个像素一次的真行末**
    // 像素完成拍（co16 的**第二拍** / co<=8 的每一拍）——给上层引擎算写地址用。
    // ⚠ 必须是端口：Efinity 不允许层次化引用子模块内部网（VDB-1011）。
    output wire                o_pix_done,
    // ---- 契约 1/7：**上游握手**（只加不改的加法项）----
    //   `s_ack` = 本拍**真的消费了** `s_col` 这一列（= `adv`）。
    //   为什么必须有：层的消费是**自己的节奏**（S_SER 的 feed 受输出 FIFO 背压、
    //   S_SKIP 只推窗口），上游**看不到** `feed`/`st` —— 之前 TB 靠 `dut.feed ||
    //   dut.st==S_SKIP` 偷看内部信号来推进指针，真实上游（前一层/抖动队列）做不到。
    //   ⇒ 把"消费了一列"做成端口，上游据 `s_ack` 推进即可。
    //   ⚠ **纯加法**：`s_ack` 就是 `adv`，不参与任何内部逻辑 ⇒ 行为逐位不变。
    output wire                s_ack,
    // ---- 状态机状态只读引出（给上层驱动/观测用）----
    //   ⚠ 为什么要有这个口：Efinity **不允许**读子模块内部的 reg
    //     （`u_rp.st` 在 TB 里能读，综合报 `external connection to net 'st[3]' is not allowed`）。
    //     `style_accel.v` 就靠它驱动上游。**纯读出、不参与内部逻辑** ⇒ 行为逐位不变。
    output wire [3:0]          o_st,

    // ---- 残差恒等支（2026-10-14 加；**`RES=0` 时全部闲置 ⇒ 旧 TB 不用改**）----
    //   `o_id` = 本层**输入**在输出像素 (y,x) 那一格的值 = **输入列流延迟 `PUSH` 列**
    //     （`PUSH = WIN + PIX + 2`）。残差块 c2 的恒等支 = **c1 的输入** = 第 i-2 层的输出
    //     （`README.md` 表 B 踩过这个坑：曾误写成 c1 的**输出**）。
    //   ⚠⚠ **契约（2026-10-16 定）**：
    //     ① `o_id` 从**输出 FIFO 头**出，和 `o_col` **同一个槽** ⇒ 与 `o_col` 是**同一个像素**，
    //        `o_vld` 拉高时有效（挂起时保持、与 `o_row_end` 对齐）。
    //        （旧写法是"组合值直接出引脚"，数据要过 3 拍流水才出来 ⇒ **配错像素**。）
    //     ② `o_id` **已经延迟了 `PUSH` 列**（见 ③b）⇒ 下游**直接把它当 `i_id` 接**，
    //        **不要再自己做延迟**。这条是残差串接唯一需要的对齐约定。
    output wire [CI*8-1:0]     o_id,        // 残差 id = **通道宽**（来自行缓冲），不是像素宽
    //   `i_id` = 恒等支，**必须和累加器同拍**（RTL 里已经和 `rq_pix_acc_r` 同时寄存；
    //     上游在"喂这个像素"那一拍给即可）。域处理照抄 `net_engine.v:270-279`（那两种写法
    //     差一步就静默错，且只在残差层露出）。
    input  wire [CI*8-1:0]     i_id         // 残差 id = 通道宽（写进 id_rb[CI*8]），不是像素宽
);

    localparam integer CW = CI * 8;
    localparam integer WN = PIX + 2;            // 窗口每行的列数（= 18，PIX=16）
    // ---- B1e：tile 参数 ----
    localparam integer TILED = (CIW < CI) ? 1 : 0;
    //   第二 tile 的字节基址（编译期）。TILED=0 时 = 0 ⇒ 两片切片完全相同、tile 恒 0。
    localparam integer CIX   = TILED ? CIW : 0;
    localparam [4:0]   CIWV  = CIW;             // ⚠ 别用整数参数的位选（integer 位选 = 0 的老坑）
    localparam [4:0]   CIW1V = CIW - 1;

    // ---- B1c：8 通道阵列 / 两遍拼接 ----
    localparam integer CO_ARR = 8;                                // MAC 阵列宽度
    // ⚠ 存储通道数必须 ≥ 阵列宽度：style_accel 的 CO=4，但阵列固定 8。
    //   否则 `wrow[..][0 +: 8*8]` 会越出 4 字节的存储（静默 x）。
    localparam integer CO_FILL = CO_ARR; // cap8 static
    localparam integer CO_EXTRA = (CO > CO_ARR) ? (CO - CO_ARR) : 0;   // 高半区的空字节
    localparam integer OW     = CO*8 + CI*8 + 2;                  // FIFO 槽：o_col+o_id+2 tag（o_id 是通道宽）

    //========================================================================
    // B1a：**固定最大缓冲 + 运行期几何**（2026-10-17）
    //========================================================================
    //   一套核时分复用跑 12 层 ⇒ 缓冲按最大档 640×480 建死，几何量开跑前加载。
    //   `D` 的旧定义（随 WIN 变）已删：固定 `D = max(2*WIN_MAX, PUSH_MAX+1) = 1280`。
    //   对旧档位（WIN=16/32/64/66）三个定点抽头的**值**不变，只是环变大（索引不同）。
    localparam integer WIN_MAX  = 640;
    localparam integer HOUT_MAX = 480;
    localparam integer PUSH_MAX = WIN_MAX + WN;                    // 658
    localparam integer D        = (2*WIN_MAX > PUSH_MAX) ? (2*WIN_MAX) : (PUSH_MAX + 1);  // 1280

    // ---- cfg 寄存器（层开始前一次加载）----
    localparam [7:0] CFG_WIN = 8'd0, CFG_NG = 8'd1, CFG_HOUT = 8'd2,
                     CFG_WOUT = 8'd3, CFG_RES = 8'd4, CFG_RESU = 8'd5,
                     CFG_CI = 8'd6,          // B1b：本层实际输入通道（3/4/8/16）
                     CFG_COUT = 8'd7,        // B1b：本层实际输出通道（1..16，运行期）
                     // ---- B1f（2026-10-18）：**真 stride-2** ----
                     CFG_S2 = 8'd8,          // 1 = 本层输出按 stride 2（每组 8 像素）
                     CFG_SKIP = 8'd9;        // S_SKIP 一次命令消费多少列（默认 1）
    reg [15:0] cfg_win, cfg_ng, cfg_hout, cfg_wout, cfg_ci, cfg_cout;
    reg [15:0] cfg_skiplen;
    reg        cfg_res, cfg_resu, cfg_s2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            cfg_win <= 16'd0; cfg_ng <= 16'd0; cfg_hout <= 16'd0; cfg_wout <= 16'd0;
            cfg_ci <= 16'd0;
            cfg_cout <= COUT;               // 参数只作为**复位默认**（旧 TB 不改也能跑）
            cfg_res <= 1'b0;  cfg_resu <= 1'b1;
            cfg_s2  <= 1'b0;                // 默认 stride-1 ⇒ 旧 TB 逐位不变
            cfg_skiplen <= 16'd1;
        end else if (cfg_we) begin
            case (cfg_addr)
            CFG_WIN:  cfg_win  <= cfg_data;
            CFG_NG:   cfg_ng   <= cfg_data;
            CFG_HOUT: cfg_hout <= cfg_data;
            CFG_WOUT: cfg_wout <= cfg_data;
            CFG_RES:  cfg_res  <= cfg_data[0];
            CFG_RESU: cfg_resu <= cfg_data[0];
            CFG_CI:   cfg_ci   <= cfg_data;
            CFG_COUT: cfg_cout <= cfg_data;
            CFG_S2:   cfg_s2   <= cfg_data[0];
            CFG_SKIP: cfg_skiplen <= cfg_data;
            default: ;
            endcase
        end

    // B1b：COUT 运行期化（cfg_cout 复位默认 = 参数 COUT）
    wire       npass2   = 1'b0; // cap8 static: no co16 two-pass
    // ---- B1f：stride-2 ----
    //   每组只出 PIX/2 = 8 个像素（输出间隔 2），但窗口仍只有 18 列：
    //     output p 的 tap = 窗口列 {2p, 2p+1, 2p+2}（常数接线 gather，见 ③ 段）。
    //   每组仍**消费 16 列**（窗宽不变）⇒ S_SER 的"推进拍数"恒 = PIX，
    //   只是 feed 的拍数减半（co16 层正好 2 拍/像素 × 8 = 16 拍，不用空转）。
    localparam integer PIXH = PIX / 2;
    localparam [4:0]   PIXV1 = PIX - 1;      // 一组推窗的拍数恒 = PIX
    wire [4:0] pix_eff  = cfg_s2 ? PIXH : PIX;
    wire [5:0] ser_end  = npass2 ? (2*pix_eff - 1) : (pix_eff - 1);

    localparam S_IDLE = 4'd0, S_SKIP = 4'd1, S_START = 4'd2, S_STEP = 4'd3,
               S_WAIT = 4'd4, S_SER  = 4'd5, S_DRAIN = 4'd6, S_NEXT = 4'd7,
               S_RLD  = 4'd8;   // B1e：tile 重载（18 拍，core 挂起但不清零）

    reg [3:0]  st;
    reg [4:0]  ci_cnt;
    reg [4:0]  ser;             // B1c：co16 层 0..31（每像素 2 拍）
    reg [4:0]  scyc;            // B1f：S_SER 里已消费的列数（0..PIX-1）
    reg [15:0] skip_cnt;        // B1f：S_SKIP 突发计数（cfg_skiplen 列）
    reg [3:0]  drain;
    reg        pass;            // 0 = 低 8 通道，1 = 高 8 通道
    reg  [1:0] co_sel;          // 送给 core 的半区
    reg [5:0]  grp_in_row;      // 本行第几组（跟**消费**走，不跟拍）；NG max 40 ⇒ 6 位
    reg [8:0]  out_row;         // 输出第几行（只给垂直 halo 用）；HOUT max 480 ⇒ 9 位
    // B1e：窗口当前装的是哪个 tile（0 = Ci 0..CIW-1，1 = Ci CIW..2CIW-1）
    reg        tile;
    reg [4:0]  rld_cnt;         // 重载 0..WN-1（0 = 最老那一列）
    reg [3:0]  rld_nxt;         // 重载完回到哪个状态（S_STEP/S_START/S_SER）
    reg [15:0] nstep;
    reg  [1:0] s_ky, s_kx;

    assign o_st = st;   // ⚠ 必须在 `reg st` **声明之后**（ModelSim 报 Undefined variable）

    // core 的输出（FSM 的 S_WAIT 要等 acc_vld，所以先声明）
    wire                       acc_vld;
    wire [PIX*CO_ARR*32-1:0]   acc_flat;

    // ---- B1c：第 0 遍的累加结果（co16 层第 1 遍算高 8 通道时要用低 8 的）----
    //   co<=8 层不建（常数剪掉 ⇒ 与旧版逐位/面积一致）。
    // B1b：cfg_cout 运行期 ⇒ 两遍缓冲**总是建**（co<=8 时不用它）。
    reg  [PIX*CO_ARR*32-1:0] acc_lo_r;
    wire [PIX*CO_ARR*32-1:0] acc_lo = acc_lo_r;
    always @(posedge clk) if (acc_vld && !pass) acc_lo_r <= acc_flat;

    //========================================================================
    // ① 行缓冲：2 行 × WIN 列（一列一个 BRAM 字）
    //========================================================================
    // 环形回绕用真取模，不限 2 的幂。**按列消费推进**（见文件头 (c)）。
    // ---- 输出 FIFO（**契约 3 的落点**，声明在前：`feed` 要用 `o_cnt`）----
    // ⚠ **深度 4 是推出来的，不是随手写的**（2026-10-12 在"插流水那版"上重推过一遍）。
    //   判据：门控是 `o_cnt + inflight < OD`，而一次落地 `o_cnt` +1 / `inflight` −1
    //   ⇒ **`o_cnt + inflight` 跨落地是恒定的** ⇒ 只要 **OD > inflight 最大值**，
    //   既不溢出、也不丢。`o_push` 要被挡掉必须 `o_cnt ≥ OD`，而那已经蕴含
    //   `inflight = 0`（没东西在飞）⇒ **出数据那拍永远推得进**。
    //   - requant 内部 2 级在飞（`in_vld → vld1 → out_vld`）；
    //     **mux 前插了一级流水**（`rq_pix_acc_r`/`feed_d`）⇒ 在飞 max = **3**。
    //   - ⇒ **OD ≥ 4**。OD = 4 时门控退化成 `c + f < 4`，稳态 c=1/f=2，
    //     加上 o_take 仍是 **1 列/拍**，没有降速。背压时只是 stall，不丢。
    //   ⚠ **深度必须是 2 的幂，而且指针位宽要正好回绕在深度上**：
    //      `o_q [0:OD-1]` 的深度 与 `o_hd/o_tl` 的回绕点**必须相等**，
    //      否则写到 / 读到越界槽 = **x**。
    //      踩过的坑：把 OD 改成 **6** 而 `o_hd/o_tl` 仍是 3 位（回绕 8）
    //      ⇒ 槽 6/7 越界 ⇒ **每 8 个输出错 2 个 x**（实测 enc1 不符 4096/16384，
    //      四个用例全红，症状一模一样）。OD=4 配 2 位指针是自洽的；
    //      真要加大就取 **8 配 3 位**，别取 6。
    //   ⚠ 另：`OD[2:0]` 这种 **integer 参数位选**会把 8 截成 0（本文件第 3 次踩）。
    //      真要改 OD，先 `localparam [3:0] ODV = OD;` 再用 ODV 比较。
    wire             rq_out_vld;   // 前置声明（FIFO 先用，实例在后面驱动）
    wire [CO_ARR*8-1:0] rq_q;
    // ---- 残差恒等支：**和数据同一个槽**进输出 FIFO（2026-10-16）----
    //   理由同 `rowpipe_queue` 的「tag 与数据同槽」：`o_id` 若单独走线，就会和 `o_col`
    //   **解耦**（引脚上直接出组合值，而数据要过 3 拍流水）⇒ 下游配到的不是同一个像素。
    //   ⚠ 槽宽从 `CO*8` 加到 `CO*8 + CI*8`。`RES=0`/`o_id` 悬空时高半不可观测 ⇒ 综合剪掉 ⇒
    //     **对已验过的层零影响**（`run.sh`/`run_l1.sh`/`run_chain.sh` 逐位不变）。
    //   ⚠ 恒等支的 3 级流水寄存器**必须声明在 FIFO 之前**（本仓"声明顺序"踩过 8 次）。
    localparam integer OD = 4;      // ARCH=1 requant 多一拍 ⇒ 在飞 max=4，OD=8
    localparam [4:0]  ODV = OD;     // ⚠ 别再用 OD[2:0]（integer 位选 = 0）
    // OW 已在头部定义为 CO*8 + CI*8 + 2（B1c 多两个 tag：half / pix_done）
    reg [OW-1:0]     o_q [0:OD-1];
    reg [CI*8-1:0]   rq_id_r1, rq_id_r2, rq_id_r3, rq_id_r4, rq_id_r5;
    // B1c 的流水 tag：half（高/低半区）与 pix_done（像素最后一拍）
    reg              half_d1, half_d2, half_d3, half_d4, half_d5;
    reg              pdon_d1, pdon_d2, pdon_d3, pdon_d4, pdon_d5;
    wire             half_feed = npass2 ? ser[0] : 1'b0;
    wire             pdon_feed = npass2 ? ser[0] : 1'b1;
    // 半区拼接：co16 时 128 位；CO<8（style_accel）时截到低 CO 个通道。
    wire [CO_ARR*8+CO_EXTRA*8-1:0] rq_col_full =
            half_d5 ? {rq_q, {CO_EXTRA*8{1'b0}}} : {{CO_EXTRA*8{1'b0}}, rq_q};
    reg [1:0]        o_hd, o_tl;
    reg [3:0]        o_cnt;
    wire o_take = (o_cnt != 0) && o_ready;
    wire o_push = rq_out_vld && ({1'b0,o_cnt} < ODV);
    wire o_hold_v = (o_cnt != 0);
    integer oi;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin o_hd <= 0; o_tl <= 0; o_cnt <= 0; for (oi=0;oi<OD;oi=oi+1) o_q[oi] <= 0; end
        else begin
            // B1c：co16 层两拍拼成一个像素（低半区进 byte0..7、高半区进 byte8..15），
            //       槽里带 half / pix_done 两个 tag。
            if (o_push) begin
                o_q[o_tl] <= {rq_id_r5, pdon_d5, half_d5, rq_col_full[CO*8-1:0]};
                o_tl <= o_tl + 1'b1;
            end
            if (o_take) o_hd <= o_hd + 1'b1;
            o_cnt <= o_cnt + (o_push ? 4'd1 : 4'd0) - (o_take ? 4'd1 : 4'd0);
        end

    // ⚠ 契约 3：`adv` 必须跟着**真正喂进去的那一拍**，不能只看状态 ——
    //   挂起时窗口/行缓冲都不能动，否则背压一松就错位。
    // ⚠ **必须把 requant 里"在飞的"也数进去**：`o_cnt` 只反映 FIFO 里已有的，
    //   而刚喂进去的还要 2 拍才出来。组尾那两拍喂的时候 FIFO 可能已经满了 ⇒
    //   出来时 `o_push` 被 `o_cnt<OD` 挡掉 ⇒ **组尾丢像素**（实测：错全在组边界）。
    // 已有的 + 在飞的 < 深度 ⇒ 在飞的全都落地时也不会溢出
    reg [3:0] inflight;
    reg [3:0] s_drain_cyc;   // S_DRAIN 里待了几拍（观测用）
    // ⚠ **必须再 `&& s_vld`**：`ser` 跟 `feed` 走，而 `adv = feed && s_vld`。
    //   不看 `s_vld` 的话，`s_vld=0` 那一拍 **`ser` 照样 +1、组照样走完，但那一列没被消费**
    //   ⇒ 上游每缺一拍，整条流就**错开一列**（实测：接真视频流时 ack 比目标少 642 列）。
    //   和 `S_SKIP` 那条**同一个病根：完成条件 != 消费条件**。
    //   ⚠ 现有 TB 里 `s_vld` **恒 1** ⇒ 这一条对它们是**逐位不变**的（加完四绿照旧）。
    wire fifo_ok = ((o_cnt + inflight) < ODV);
    // ---- B1f：stride-2 的 S_SER 拆成"喂区"和"纯推窗" ----
    //   `scyc` = 本组 S_SER 里**已消费的列数**（0..PIX-1）。
    //   喂区 = scyc ≤ ser_end（s2 时 = 前 8 拍，co≤8；co16 时全 16 拍）。
    //   喂区外只推窗不喂 requant（像素已经算完了）。
    wire in_feed_zone = (!cfg_s2) || (scyc <= ser_end);
    wire feed = (st == S_SER) && fifo_ok && s_vld && in_feed_zone;

    // ---- B1c：co16 层每像素 2 拍 ----
    //   ser[0]=0 拍 = 低 8 通道（不推窗口），ser[0]=1 拍 = 高 8 通道（推 1 列）。
    //   co<=8 层 ser 就是像素号，每拍推 1 列（旧行为）。
    wire [1:0] beat_sel = npass2 ? {1'b0, ser[0]} : 2'd0;
    wire [1:0] rq_sel   = (st == S_SER) ? beat_sel : co_sel;
    wire [3:0] px_idx   = npass2 ? ser[4:1] : ser[3:0];
    always @(posedge clk or negedge rst_n)
        if (!rst_n) inflight <= 4'd0;
        else inflight <= inflight + (feed ? 4'd1 : 4'd0) - (rq_out_vld ? 4'd1 : 4'd0);

    // ⚠ B1c：co16 层只在**高半区那一拍**推窗口/行缓冲（每像素 1 列，不是 2 列）。
    // ⚠ B1f：s2 时**每拍都推窗**（喂区里要等 FIFO，喂区外只管 s_vld）——
    //   一组恒推 PIX=16 列，和 stride-1 的窗口推进量完全相同。
    wire adv_ser = (st == S_SER) && s_vld &&
                   ( cfg_s2 ? (in_feed_zone ? fifo_ok : 1'b1)
                            : (fifo_ok && ((!npass2) || ser[0])) );
    wire adv  = adv_ser || ((st == S_SKIP) && s_vld);

    // 契约 1/7：把"消费了一列"送给上游（**只读出，不参与内部逻辑**）
    assign s_ack = adv;

    // ---- 行缓冲（**B1a：深度建死 `D=1280`，抽头偏移运行期**）----
    //   它是**输入列流的延迟线**，深度决定了三个定点抽头能取多"旧"的列：
    //     q_b（两行前）= 2*WIN 列前 ；q_a（一行前）= WIN 列前 ；**恒等支 = PUSH 列前**（见 ③b）
    //   ⇒ 需要 `D ≥ max(2*WIN, PUSH+1)`。`PUSH = WIN + WN = WIN + PIX + 2`。
    //   B1a 固定 `D = 1280`（= 2×640，也 ≥ 658+1），偏移量改成 `cfg_win` 的组合值。
    //   ⚠ 对旧档位（WIN=16/32/64/66）三个抽头取到的**历史值完全不变** ——
    //     环大小只影响物理索引，不影响到读哪一列。18 个单层 TB 是这条的兜底。
    //   ⚠ 求模用"加 D、减一次"而不是 `%`：中间值 < 2D，一次条件减法就够
    //     （也避免综合出大除法器）。
    reg [CW-1:0] lb [0:D-1];
    reg [10:0]   wp;                              // 0..D-1
    always @(posedge clk) if (adv) lb[wp] <= s_col;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) wp <= 0;
        else if (adv) wp <= (wp == 11'd1279) ? 0 : wp + 1'b1;

    // 同一列 x，往前两行 / 一行 —— 靠定点偏移。
    // ⚠ 按**写序**定位：`lb[wp]` = 最旧（本拍要被覆写的那格）= **D 列前**；
    //   `lb[(wp + D - k) % D]` = **k 列前**。
    // ⚠ 三行**都寄存**（BRAM Tco + 对齐），见文件头 (b)。
    wire [12:0] rdA_s = {2'b00, wp} + 13'd1280 - {3'b000, cfg_win};
    wire [12:0] rdB_s = {2'b00, wp} + 13'd1280 - {2'b00, cfg_win, 1'b0};
    wire [10:0] rdA = (rdA_s >= 13'd1280) ? (rdA_s - 13'd1280) : rdA_s[10:0];
    wire [10:0] rdB = (rdB_s >= 13'd1280) ? (rdB_s - 13'd1280) : rdB_s[10:0];
    // ⚠ **必须用 adv 门控**，否则消费流一断（组间有 S_DRAIN/S_WAIT 的空档，wp 不动）
    //   这三个寄存器就会把"当前地址"的值锁住，下一次 adv 拿到的不是"上一个 adv 的地址"
    //   ⇒ 每次续流的第一拍多推一列。门控后空档对它们透明，续流首拍 == 组内任意拍。
    //   （不门控时：每组的头 3 列和尾 2 列全错，正好是 18 列的两端。）
    // ---- 恒等支抽头地址（PUSH 列前）----
    //   ⚠ B1e 起**提前算**（原来在 ③b 段）：tile 重载要借 `oid_a` 这个读口读 row2。
    //   `PUSH_eff = cfg_win + WN`（运行期；旧 `PUSH` 参数已删）。
    wire [12:0] push_eff = {2'b00, cfg_win} + WN;
    wire [12:0] oid_s    = {2'b00, wp} + 13'd1280 - push_eff;
    wire [10:0] oid_a    = (oid_s >= 13'd1280) ? (oid_s - 13'd1280) : oid_s[10:0];

    //========================================================================
    // B1e：**tile 重载地址**（ci_tiles=2 时窗口换通道组）
    //========================================================================
    //   wp = 当前写指针（= 最近消费列的下一格）。窗口 col j 是第
    //   (t_last-17+j) 次 adv 移进来的，那次移进来的是第 (t_last-18+j) 列
    //   ⇒ 物理地址 = wp-19+j；row1/row0 再各减 W/2W（W=cfg_win）。
    //   ⚠ 全程 mod 1280：值域 [0, 3D) ⇒ 先减 2560 再减 1280（组合，只在 S_RLD 有效）。
    wire rld = (st == S_RLD);
    wire [13:0] rld_j    = {9'd0, rld_cnt};
    wire [13:0] cfg_win14 = {2'b0, cfg_win[13:0]};
    wire [13:0] rld_r2   = {2'b0, wp} + 14'd3821 + rld_j;   // wp + 3840 - 19 + j
    wire [13:0] rld_r1   = rld_r2 - cfg_win14;
    wire [13:0] rld_r0   = rld_r1 - cfg_win14;
    function [10:0] wrap1280;
        input [13:0] v;
        reg   [13:0] u;
        begin
            u = (v >= 14'd2560) ? (v - 14'd2560) : v;
            wrap1280 = (u >= 14'd1280) ? (u[10:0] - 11'd1280) : u[10:0];
        end
    endfunction
    wire [10:0] rld_a2 = wrap1280(rld_r2);       // row2 = 本拍输入列
    wire [10:0] rld_a1 = wrap1280(rld_r1);       // row1 = 一行前
    wire [10:0] rld_a0 = wrap1280(rld_r0);       // row0 = 两行前
    // ⚠⚠ **前提：`2*cfg_win < D`（严格小于）**。
    //   D=1280 ⇒ 可行档位 WIN ≤ 639。WIN=640 时 row0 的物理地址和 row2 **重合**
    //   （两行前那格已被本行覆写）⇒ 重载拿不到两行前的数据，静默出错。
    //   现有 12 层里 ci16（唯一会走 tile 的）最宽 WIN=320 ⇒ 成立；
    //   **将来若加 ci16@640 的层，必须先把 D 加到 ≥1281**。
    // synthesis translate_off
    always @(posedge clk)
        if (rst_n && TILED && (st == S_RLD) && ({1'b0, cfg_win} * 2 >= D))
            $display("** rowpipe_layer: ci_tiles 要求 2*WIN < D（WIN=%0d, D=%0d）", cfg_win, D);
    // synthesis translate_on
    // 重载时借用现有三个读口（**不新增 RAM 端口**）：
    //   rdA←row1、rdB←row0、oid_a←row2。
    //   ⚠ 最后一个重载拍（rld_cnt==WN）地址**切回正常值**：wp 在重载期间冻结，
    //     所以重读一遍 rdA/rdB 正好把 q_a/q_b 恢复成重载前的值（下一次 adv 要用）。
    wire rld_rd   = rld && (rld_cnt != WN);      // 重载取数拍（0..WN-1）
    wire rld_sh   = rld && (rld_cnt != 5'd0);    // 有上一拍捕获数据的拍才移窗（1..WN）
    // ⚠⚠ **恢复拍必须用 `rdA-1`/`rdB-1`**：q_a/q_b 在 adv 拍采的是
    //   "本拍写指针" 的地址，采完 wp 才 +1 ⇒ 用当前的 rdA 会读到**新一列**，
    //   重载后的下一次移窗就错一列（实测：每行前几列错，L3 190/4096）。
    wire [10:0] rdA_m1 = (rdA == 11'd0) ? 11'd1279 : (rdA - 11'd1);
    wire [10:0] rdB_m1 = (rdB == 11'd0) ? 11'd1279 : (rdB - 11'd1);
    wire [10:0] rdA_use = rld ? (rld_rd ? rld_a1 : rdA_m1) : rdA;
    wire [10:0] rdB_use = rld ? (rld_rd ? rld_a0 : rdB_m1) : rdB;
    wire [10:0] oid_use = rld_rd ? rld_a2 : oid_a;
    wire [CW-1:0] lbA_w = lb[rdA_use];
    wire [CW-1:0] lbB_w = lb[rdB_use];
    wire [CW-1:0] lbO_w = lb[oid_use];

    // ⚠⚠ **每个 RAM 读口只能有"一个"目的寄存器**（2026-10-18 实测）：
    //   把 lb 的组合读出再拼一份进窗口（或加影子寄存器）⇒ Efinity 判
    //   "read port is not synchronous" ⇒ lb 163,840 bit 落 logic memory
    //   ⇒ XLR 42k→**177k**、PnR 直接爆容量。
    //   ⇒ 三个读口**各只喂一个现有寄存器**：
    //     rdA→q_a、rdB→q_b、oid→rq_id_r1（恒等支那条流水，重载期间 feed=0 不会被消费）。
    //   重载时 q_a/q_b 由 S_RLD 捕获（下面），row2 从 `rq_id_r1` 取。
    reg [CW-1:0] q_c, q_a, q_b;
    always @(posedge clk) begin
        if (rld)      begin q_a <= lbA_w; q_b <= lbB_w; end   // 重载取数（末拍=恢复）
        else if (adv) begin q_c <= s_col; q_a <= lbA_w; q_b <= lbB_w; end
    end

    //========================================================================
    // ② 窗口：**按通道拆** —— CI 份 × 3 行 × WN 列 × 8 位
    //========================================================================
    // ⚠ ci 是**第三根轴**（步序 ci*9+ky*3+kx 里 ci 最外层，9 个 tap 同属一个通道）。
    //   core 的 `taps` 是 **PIX*8 位（每像素一个字节）**，所以窗口不能打包成
    //   "一列 CW 字节" —— 那样 tap 得用 (kx+p)*CW+ci*8 的**双变量下标**，正是被否决的选项 2。
    //   定案：窗口按通道拆，tap 做**三轴分选**（行 3:1 + 列 3:1 + 通道 ci_par:1）。
    //
    //   行 0 = 两行前（最早 = 上），行 2 = 本拍输入 —— ky=0/1/2 直接对上。
    //   ⚠ B1e：窗口只有 **CIW** 个通道槽；tile=1 时槽里装的是 Ci CIW..2CIW-1
    //     （字节基址 CIX，编译期常量 ⇒ 仍是常数切片，红线不破）。
    reg [WN*8-1:0] w [0:CIW*3-1];             // w[ci*3 + row]

    genvar gi, gj, gs;
    generate
        for (gi = 0; gi < CIW; gi = gi + 1) begin : g_win
            // 正常推进：新字节进 col17，取 q_* 的当前 tile 字节
            wire [7:0] sb_b = tile ? q_b[8*(gi+CIX) +: 8] : q_b[8*gi +: 8];
            wire [7:0] sb_a = tile ? q_a[8*(gi+CIX) +: 8] : q_a[8*gi +: 8];
            wire [7:0] sb_c = tile ? q_c[8*(gi+CIX) +: 8] : q_c[8*gi +: 8];
            // 重载：row0/row1 取 q_b/q_a（S_RLD 里从 rdB/rdA 捕获），
            //       row2 取 rq_id_r1（oid 口的寄存读，重载期间不被消费）
            wire [7:0] rb_b = tile ? q_b[8*(gi+CIX) +: 8] : q_b[8*gi +: 8];
            wire [7:0] rb_a = tile ? q_a[8*(gi+CIX) +: 8] : q_a[8*gi +: 8];
            wire [7:0] rb_c = tile ? rq_id_r1[8*(gi+CIX) +: 8] : rq_id_r1[8*gi +: 8];
            for (gj = 0; gj < 3; gj = gj + 1) begin : g_row
                // ⚠ **新字节进 col17**（= `{newbyte, w[len-1:8]}`），col0 = 最旧。
                //   反过来写（新字节进 col0）会让 col j = pin[base−j]，taps 整个反了。
                // ⚠ **halo 自合成（契约：层间不带填充列）**，放在**换组那一拍写一次**：
                //   padded 列 p ↔ 真实列 reflect(p-1)，而真实列 r 对应 padded r+1 ⇒
                //     行首组：padded 0 → 真实 1 → padded 2  ⇒ **col0 应 == col2**
                //     行尾组：padded 65 → 真实 62 → padded 63 ⇒ **col17 应 == col15**
                //   只在组边界写一次（**不是**每拍组合替换）⇒ 探针 239MHz 那条 tap 路径不动。
                //   行界层内已有（`o_row_end` 是自己产生的）⇒ **自己数组号，不加端口**
                //   （加端口 = 行数两处各数一遍 = 解耦坑）。
                // ⚠ **halo 一个字都不写进窗口寄存器** —— 全在 tap 段做（见下）。
                //   试过的错法：在 S_START 把 col0←col2 / col17←col15 写回寄存器。
                //   col0 那半边无害（下一拍就掉出去），但 **col17 那半边会顺着移位往下走**：
                //   本组 16 拍走完，它正好停在 **col1** ⇒ 污染下一组的 col1
                //   （实测：每行组 0 只有 col1 一个字节错，且 row0 恰好没有）。
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) w[gi*3+gj] <= 0;
                    else if (rld_sh)                     // B1e：整窗重载（移 18 列）
                        w[gi*3+gj] <= { (gj == 0) ? rb_b :
                                        (gj == 1) ? rb_a :
                                                    rb_c,
                                        w[gi*3+gj][WN*8-1:8] };
                    else if (adv)                        // 正常推进（列流）
                        w[gi*3+gj] <= { (gj == 0) ? sb_b :
                                        (gj == 1) ? sb_a :
                                                    sb_c,
                                        w[gi*3+gj][WN*8-1:8] };
                end
            end
        end
    endgenerate

    //========================================================================
    // ③b 残差恒等支出口 `o_id` —— **行缓冲的定点抽头**（PUSH 列前）
    //========================================================================
    //   恒等支 = 残差块的**输入** (y,x)（`README.md` 表 B）。它**就是本层的输入列流**，
    //   所以 = 列流延迟 `PUSH` 列 —— 直接用行缓冲的定点抽头拿，**不经过窗口**。
    //
    //   ⚠⚠ 为什么是 `PUSH` 列、不是"窗口抽头"：
    //      恒等支是**按「输出位置」**要的，而队列/上游给的是**按「消费位置」**。
    //      一层要先灌 `PUSH = WIN + PIX + 2` 列窗口才开始出第一组 ⇒ 两者差 `PUSH` 列。
    //      实测（`tb/tb_l4dly.v` 把 c1 的 o_id 流延迟 D 列再喂 c2）：
    //      **D=34 唯一通过**，33 / 36 / 32 全 Some-Fail ⇒ 常数就是 `PUSH`，不是"大概一行"。
    //
    //   ⚠⚠ **曾经写错的两种写法（都别再走）**：
    //     ① `w[OROW][(ser + OCOL)*8 +: 8]` —— **组合读活窗口 + `ser`**。`ser` 和窗口
    //        同进同退 ⇒ 下标被移位抵消 ⇒ **每拍读回同一格**。实测：一行 16 个像素只有
    //        ～4 个不同值，与输入同位置 3267/4096 不符，按 (行,偏移) 搜最佳匹配
    //        **每一行都不同、最多解释 10/16 列** ⇒ **无解**（所以 12 组矩阵谁也过不了）。
    //     ② `w[OROW][OCOL*8 +: 8]`（常数列）—— **值对了**（TB 在 `S_START` 锁
    //        `w[1]` 第 1..16 列 = 本层输入同位置，**256/256 逐位相等**），
    //        但**时间不对**：窗口抽头只延迟了窗口深度，够不到 `PUSH` 列。
    //   ⇒ 正解就是这里：**读行缓冲的 `PUSH` 列前那一格**。前提是 `D ≥ PUSH+1`，见上面 `D` 的定义。
    //
    //   ⚠ 读出来的值**只在 `feed` 那一拍有意义**；下面 ⑤ 段把它和累加器同拍寄存、
    //     并随输出 FIFO 的**同一个槽**送达（保证与 `o_col` 是同一个像素）。
    //   B1a：`PUSH_eff = cfg_win + WN`（运行期；旧 `PUSH` 参数已删）。
    //   ⚠ B1e：`push_eff`/`oid_s`/`oid_a` 已上移到 ① 段（tile 重载要借这个读口）。
    wire [CI*8-1:0] o_id_c = lbO_w;
    //   ⚠ `o_id` 是**位置正确**的（槽 j 送出的就是输入位置 j 的值），
    //     **额外那 `PUSH` 个槽的延迟由 `RES=1` 层内部的恒等支历史做**（见 ⑤ 段的 `g_iddly`）。
    //     为什么必须拆开做：c2 要消费 `PUSH + 256` 列而 c1 只出 256 个槽 ⇒ 若把延迟塞在
    //     c1 的 o_id 里，最后 `PUSH` 个槽就**没人补**（实测：串接尾部 3 行全错）。
    //     放在消费侧用**按 `adv` 移位的历史**（不是 FIFO）就没有这个问题 ——
    //     历史按消费计数，读回来的是自己 34 拍前收到的值，永远取得到。

    //========================================================================
    // ③ tap：三轴分选，作用在 PIX*8 = 128 位上
    //========================================================================
    // 每 (通道,行) 先切出 3 个**常数偏移切片**（列对齐 kx=0/1/2），再做一级大 mux。
    // col0 = 最旧 ⇒ `w[kx*8 +: PIX*8]` 就是"kx 越大取越大的列号"，与 conv3x3 一致。
    // ~1K LUT 在每拍路径上 —— 探针 v4 已在同口径下 239.177 PASS，可接受。
    // ---- 垂直 halo：**在行选这一级做，不动寄存器/喂法** ----
    //   头一行（out_row=0）：ky=0 要的是 padded 行 0 = padded 行 2，而 row0 寄存器此刻
    //     拿的是"两行前"= 环里还没写过的 X ⇒ **ky=0 改取 row2**（它=当前行=真实行1=padded 行2）。
    //   末一行（out_row=HOUT-1）：ky=2 要的是 padded 行 65 = padded 行 63 ⇒ **ky=2 改取 row0**。
    //   ⚠ 试过的错法：改**喂进寄存器的字节**（row0←q_c）。寄存器有 18 列移位历史，
    //     被喂歪以后要 18 拍才冲干净 ⇒ 污染下一行的头两列（实测 419→417 打不动，g=4 整段错）。
    //   ⚠ 这里多了一级 2:1 行选（同一拍路径形状，只是 3:1 变 4:1 含重复输入），
    //     PnR 后要重新看 tap 路径的时序。
    wire first_grp = (grp_in_row == 6'd0);                    // 行首组：左 halo
    wire last_grp  = (grp_in_row == cfg_ng - 16'd1);          // 行尾组：右 halo（运行期 NG）

    //========================================================================
    // B1d：**tap 选择降维**（2026-10-17）
    //========================================================================
    //   旧写法：先给 CI*3*3 = 144 个 (ci,row,kx) 组合各切一份 128 位，再做 144:1 mux
    //   ⇒ 约 144×128 = 18.4k bit-mux。这是行流水里最大的一块组合逻辑。
    //   新写法：**先选 (ci,ky) 那一整行**（CI*3 = 48:1 × 144 位 ≈ 6.9k），
    //   再在选中的 18 列上做水平 halo，最后做 **3:1 列切片**（128 位）。
    //   ⇒ 选择位数约 7.3k（2.5× 下降）；**周期不变**：全是组合选择，S_STEP 仍一拍一步。
    //   ⚠ 列方向仍是"常数宽度切片 + 运行期基址"（`wf[s_kx*8 +: PIX*8]`），
    //     不是 `wf[变量]` 的单元素下标 —— 红线仍然成立。
    wire first_row = (out_row == 9'd0);
    // ⚠ B1f：**stride-2 层没有末行反射**。输出行 y=hout-1 用的是输入行
    //   hin-3,hin-2,hin-1（全都真实存在）⇒ ky=2 不许改取 row0，否则会用 hin-3。
    wire last_row  = cfg_s2 ? 1'b0 : (out_row == cfg_hout - 16'd1);
    // 垂直 halo：头行 ky=0 取 row2；末行 ky=2 取 row0（与旧版逐 ky 判据一致）
    wire [1:0] ky_eff = ((s_ky == 2'd0) && first_row) ? 2'd2 :
                        ((s_ky == 2'd2) && last_row)  ? 2'd0 : s_ky;
    // B1e：窗口槽号 = 绝对输入通道 − tile 基址（tile 内 0..CIW-1）
    wire [4:0] wci      = TILED ? (ci_cnt - (tile ? CIWV : 5'd0)) : ci_cnt;
    wire [5:0] wsel_idx = wci[3:0]*3 + ky_eff;         // 0..CIW*3-1
    wire [WN*8-1:0] wrow_sel = w[wsel_idx];
    // 水平 halo：行首组 col0←col2；行尾组 col17←col15（只作用于本次 tap，寄存器不动）
    wire [WN*8-1:0] wf = {
        last_grp  ? wrow_sel[WN*8-17:WN*8-24] : wrow_sel[WN*8-1:WN*8-8],  // col17
        wrow_sel[WN*8-9:8],                                               // col1..16
        first_grp ? wrow_sel[23:16]           : wrow_sel[7:0]             // col0
    };
    wire [PIX*8-1:0] taps_s1 = wf[s_kx*8 +: PIX*8];

    // ---- B1f：stride-2 的 **常数接线 gather** ----
    //   像素 p（输出列 2p）的 tap = 窗口列 {2p, 2p+1, 2p+2}（见 README「真 stride-2」）。
    //   `g0/g1/g2` 是按 kx 预先接好的三份 8 字节，**纯布线**；S_STEP 里只做 3:1 选择。
    //   ⚠ 像素 8..15 填 0（core 的 16 像素阵列只用低 8 个，requant 也只喂 8 个）。
    wire [PIXH*8-1:0] g0, g1, g2;
    generate
        for (gs = 0; gs < PIXH; gs = gs + 1) begin : g_s2g
            assign g0[8*gs +: 8] = wf[16*gs      +: 8];   // 列 2p
            assign g1[8*gs +: 8] = wf[16*gs +  8 +: 8];   // 列 2p+1
            assign g2[8*gs +: 8] = wf[16*gs + 16 +: 8];   // 列 2p+2
        end
    endgenerate
    wire [PIXH*8-1:0] gsel = (s_kx == 2'd0) ? g0 :
                             (s_kx == 2'd1) ? g1 : g2;
    wire [PIX*8-1:0] taps_s2 = {{(PIXH){8'd0}}, gsel};
    wire [PIX*8-1:0] taps    = cfg_s2 ? taps_s2 : taps_s1;

    //========================================================================
    // ④ 步进 / 组时序
    //========================================================================
    // ⚠ `start`/`step` **都必须是组合的**，两个理由：
    //   1) core 在"看到 step 的那一拍"采 taps。若 `core_step` 是寄存器、又在本拍
    //      推进 `s_kx/s_ky/ci_cnt`，core 第一次看到 step=1 时计数器已经走了一格
    //      ⇒ tap 比权重永远超前一步，最后一步落到 `tsel[CI*9]` 越界出 x。
    //   2) 若 `start` 是寄存器，它要到 **S_STEP 的第一拍**才变高，那一拍 `busy` 还是 0
    //      ⇒ 27 步只发出 26 拍，`last` 永不成立、`acc_vld` 永不来，FSM 卡在 S_WAIT。
    //      （2026-10-06 实测：步数少 1，整层 16384 个全 x。）
    wire start_go = (st == S_START);
    // B1b：步进按 **运行期 cfg_ci** 停（硬件窗口仍按最大 CI 建）
    wire step_go  = (st == S_STEP) && (ci_cnt < cfg_ci);
    wire [1:0] s_ky_nxt_w = (s_ky == 2'd2) ? 2'd0 : s_ky + 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            s_ky <= 0; s_kx <= 0; ci_cnt <= 0; nstep <= 0;
            ser <= 0; drain <= 0; grp_in_row <= 6'd0; out_row <= 9'd0;
            pass <= 1'b0; co_sel <= 2'd0;
            tile <= 1'b0; rld_cnt <= 5'd0; rld_nxt <= S_STEP;
            scyc <= 5'd0; skip_cnt <= 16'd0;
        end else begin
            case (st)
            // 只推窗口（补 halo），不出结果
            // ⚠ **契约 6 修正：离开 S_SKIP 的条件 = 消费条件。**
            //   原来是**无条件** `st <= S_IDLE`，而 `adv` 要 `s_vld`
            //   （`adv = (feed || st==S_SKIP) && s_vld`，S_SKIP 里 feed=0 ⇒ adv 就等于 s_vld）
            //   ⇒ `s_vld=0` 那一拍 `skip_vld` 被**静默吞掉**：不消费、状态机却照样退出。
            //   **"完成条件 ≠ 消费条件"**。
            //   看不见的原因：单层 TB 里 `s_vld` **恒 1**；串接里只有 c2 上游是队列。
            //   ⚠ **铺 12 层时每层上游都是抖动队列（契约 5）⇒ 每层都落到 c2 那个位置**。
            //   不是死锁：`S_FILL`/`S_WAIT` 同样等输入，S_SKIP 等 `s_vld` 是同一回事。
            // B1f：`cfg_skiplen` = 一次 skip 命令消费的列数（默认 1）。
            //   stride-2 层每输出一行要"空跑"一整行输入（win 列）——
            //   逐条命令发的话引擎的手续费（~4 拍/条）会把省下的拍全吃掉。
            S_SKIP:  if (s_vld) begin
                         if (skip_cnt == cfg_skiplen - 16'd1) st <= S_IDLE;
                         else skip_cnt <= skip_cnt + 16'd1;
                     end
            S_IDLE:  if (skip_vld) begin skip_cnt <= 16'd0; st <= S_SKIP; end
                     else if (grp_vld) begin
                         nstep <= cfg_ci * 16'd9;      // B1b：运行期 ci × 9
                         s_ky <= 0; s_kx <= 0; ci_cnt <= 0;
                         scyc <= 5'd0;                 // B1f：S_SER 列计数
                         pass <= 1'b0; co_sel <= 2'd0;  // B1c：先算低 8 通道
                         tile <= 1'b0;                 // B1e：每组都从 Ci 0..CIW-1 起
                         st <= S_START;
                     end
            // 打 start（start 与 step 必须不同拍）
            S_START: begin s_ky <= 0; s_kx <= 0; ci_cnt <= 0; st <= S_STEP; end
            // ⚠ 上面这行是 S_START；**窗口的边缘反射在这里做**（见 generate 里那段）
            // ci×9 步：**不在这里推窗口**（窗口只在 S_SER/S_SKIP 推）
            // ⚠ B1e：tile 边界要在**发完前半最后一步的那一拍**切走 —— 判据用
            //   当前 ci_cnt/s_kx/s_ky（本拍正要发的就是 (CIW-1,2,2) 这一步）。
            S_STEP:  if (ci_cnt < cfg_ci) begin
                         s_kx <= s_kx + 1'b1;
                         if (s_kx == 2'd2) begin
                             s_kx <= 0;
                             s_ky <= s_ky_nxt_w;
                             if (s_ky == 2'd2) ci_cnt <= ci_cnt + 1'b1;
                         end
                         // ⚠ 必须带 `cfg_ci > CIW`：cfg_ci==CIW（L2 的 ci8）时这里
                         //   是**本 pass 的最后一步**，再插重载会把 acc_vld 脉冲吞掉
                         //   （实测 L2 卡死在 S_WAIT）。
                         if (TILED && (cfg_ci > CIWV) && !tile && (ci_cnt == CIW1V) &&
                             (s_kx == 2'd2) && (s_ky == 2'd2)) begin
                             // 窗口换到 Ci CIW..2CIW-1；core 的累加器/step_cnt 不动
                             tile    <= 1'b1;
                             rld_cnt <= 5'd0;
                             rld_nxt <= S_STEP;
                             st      <= S_RLD;
                         end else
                             st <= S_STEP;                // 连续打 step，中间不夹拍
                     end else st <= S_WAIT;           // ci×9 步打完，等 acc_vld
            // B1c：co16 层第 1 遍算完 → 换半区、再打一遍 start；第 2 遍算完才进 S_SER。
            // ⚠ B1e：两处都要先确认窗口回到 **tile 0** —— S_SER 的推进字节、以及
            //   下一组的第 0 个输入通道，都只认 tile 0。tile 1 就插一次 18 拍重载。
            S_WAIT:  if (acc_vld) begin
                         if (npass2 && !pass) begin
                             pass <= 1'b1; co_sel <= 2'd1;
                             if (TILED && tile) begin
                                 tile <= 1'b0; rld_cnt <= 5'd0; rld_nxt <= S_START; st <= S_RLD;
                             end else st <= S_START;
                         end else begin
                             ser <= 0;
                             if (TILED && tile) begin
                                 tile <= 1'b0; rld_cnt <= 5'd0; rld_nxt <= S_SER; st <= S_RLD;
                             end else st <= S_SER;
                         end
                     end
            // B1e：整窗重载 WN=18 列（0 最老 → WN-1 最新）。
            //   ⚠ **19 拍**：第 0 拍只给地址（RAM 同步读捕获到 rl_*），第 1..18 拍移窗。
            //   core 在这 19 拍里 step=0 ⇒ `step_cnt`/累加器全部冻结，start 不用再打。
            S_RLD:   if (rld_cnt == WN) st <= rld_nxt;
                     else begin rld_cnt <= rld_cnt + 5'd1; st <= S_RLD; end
            // 喂 requant 像素 0..15；**同时**把窗口往前滑 PIX 列（下一组用）
            // ⚠ 只在这拍**真的喂了**才推进；否则原地挂起（ser / 窗口 / 行缓冲全冻）
            // B1f：退出判据从「ser 喂完」改成「**推满 PIX 列**」（scyc）。
            //   stride-1 两者同拍（每像素推 1 列）；stride-2 是 16 拍推 16 列、只喂 8 个
            //   像素 —— 用 ser 判会**只推 8 列**，下一组的窗口整个错位。
            S_SER: begin
                         if (adv_ser) begin
                             if (scyc == PIXV1) begin
                                 // ---- A-2（2026-10-28）：**不再进 S_DRAIN/S_NEXT**，直接回 S_IDLE ----
                                 //   为什么可以跳过（不是"省事"，是"本来就不必要"）：
                                 //   ① FIFO 安全性由 **feed 门控**保证，与 S_DRAIN 无关：
                                 //      喂之前查 `fifo_ok = (o_cnt+inflight) < OD`（L380），而一次落地
                                 //      `o_cnt`+1 / `inflight`−1 ⇒ **`o_cnt+inflight` 跨落地恒定**
                                 //      ⇒ 任何落地的使能拍都有 `o_cnt ≤ OD−1 < OD` ⇒ `o_push`
                                 //      （L350 `o_cnt < ODV`）**永远不会被挡** ⇒ 不存在"在飞像素丢失"。
                                 //      （这正是本文件 L309-310 自己写的那条不变式。）
                                 //   ② S_DRAIN 只等 `inflight==0`，不改任何计数器、不推窗口、不喂 requant；
                                 //      组计数 grp_in_row/out_row 在**上面这个分支**里已经随最后消费列推进完了。
                                 //   ③ S_NEXT 的清零（ci_cnt/pass/co_sel/tile）在 S_IDLE 的 `grp_vld` 分支里
                                 //      逐项重复（见 L700-710 附近）⇒ 完全冗余。
                                 //   ④ 下一组的 S_STEP 有 ci*9 ≥ 27 拍，远大于 requant 剩余的 5 拍在飞 ⇒
                                 //      在飞的像素在下一组开始后自然落地，顺序与内容都不变。
                                 //   ⇒ 只改变"什么时候开始下一组"，不改变任何输出。收益 9 拍/组。
                                 scyc <= 5'd0; ser <= 0; drain <= 0; st <= S_IDLE;
                                 // ⚠ 组计数**跟最后消费的那一列走**（不跟拍）：背压挂起时全冻
                                 //   —— 硬约束 10「按消费推进不按拍」的同构
                                 grp_in_row <= (grp_in_row == cfg_ng - 16'd1) ? 6'd0 : grp_in_row + 6'd1;
                                 if (grp_in_row == cfg_ng - 16'd1)
                                     out_row <= (out_row == cfg_hout - 16'd1) ? 9'd0 : out_row + 9'd1;
                             end else scyc <= scyc + 5'd1;
                         end
                         // ⚠ `ser` 跟 **feed** 走，不跟 adv 走：co16 的低半区那一拍
                         //   feed=1 / adv=0（每像素 2 拍只推 1 列）。把它塞进 adv 分支里
                         //   ⇒ ser 永远停在偶数 ⇒ adv 永不发生 ⇒ 死锁（2026-10-18 实测）。
                         if (feed && (ser != ser_end)) ser <= ser + 1'b1;
                     end
            // 排空 requant 的流水（不再推窗口）
            // ⚠ **A-2（2026-10-28）起 S_DRAIN / S_NEXT 是【不可达状态】**：
            //   S_SER 喂完最后一列后直接回 S_IDLE（见上）。保留状态与逻辑只为**回退方便**
            //   （把 S_SER 里那行 `st <= S_IDLE` 改回 `st <= S_DRAIN` 即恢复旧行为）；
            //   综合会把这两个状态、以及 drain/s_drain_cyc 一起剪掉。
            //   历史：S_DRAIN 原来只按拍数走（2 拍）不等输出侧 ⇒ 最后两个像素可能赶上 FIFO 满而静默丢；
            //   当时改成判 `inflight==0`（而不是字面的 `o_ready`，那个反而没意义）是**正确但非必需**的加固：
            //   真正保证不丢的是 `fifo_ok` 门控 + `o_cnt+inflight` 跨落地恒定这条不变式（见 S_SER 注释）。
            S_DRAIN: if (inflight != 4'd0) s_drain_cyc <= s_drain_cyc + 1'b1;                     // 等在飞的落地
                     // 3 拍 (不是 2): 上面多了一级流水, 最后两个像素晚一拍
                     else if (drain == 2'd2) st <= S_NEXT;
                     else begin drain <= drain + 1'b1; st <= S_DRAIN; end
            S_NEXT:  begin ci_cnt <= 0; s_drain_cyc <= 4'd0; pass <= 1'b0; co_sel <= 2'd0;
                           tile <= 1'b0; st <= S_IDLE; end
            default: st <= S_IDLE;
            endcase
        end
    end

    //========================================================================
    // ⑤ 卷积核心 + requant（都已验证过的模块）
    //========================================================================
    conv3x3_core #(.PIX(PIX), .COUT(CO_ARR), .CO_STORE(CO_FILL), .CIN(16), .K(3), .WADDR_W(8)) u_core (
        .clk(clk), .rst_n(rst_n),
        .ld_we(ld_we), .ld_waddr(ld_waddr), .ld_wdata(ld_wdata[CO_FILL*8-1:0]),
        .ld_be(ld_be), .ld_baddr(ld_baddr), .ld_bdata(ld_bdata),
        .n_step(nstep), .start(start_go), .step(step_go), .co_sel(co_sel),
        .taps(taps),
        .acc_vld(acc_vld), .acc_flat(acc_flat)
    );

    // requant **按像素时分复用**：S_SER 的 16 拍里每拍选一个像素。
    // ⚠ 这一级是 512 位 × 16:1 的组合 mux，压在 requant 的乘法器前面。
    //   功能先过；若 233MHz 不过，就在 `rq_pix_acc` 上插一级寄存器并把
    //   S_DRAIN 改成 3 拍（对齐推导见文件头）。
    // ---- 残差恒等支 → requant 的接线（生成逻辑见文件尾 ⑤ 段）----
    //   ⚠ **这两个 wire 必须在 requant 例化之前声明**：写成"先用后声明"的话，
    //     Verilog 把第一次出现当**隐式 1 位网**，文件尾再显式声明就变
    //     `already declared in this scope`（实测 vlog-2388 ×2，四个 TB 全挂）。
    // ---- 残差恒等支的 **PUSH 深历史**（2026-10-16：对齐搬到消费侧）----
    //   ⚠ 为什么必须有：c1 的 `o_id` 是**位置正确**的（槽 j = 输入位置 j），
    //     但 c2 在喂自己的输出位置 (g,p) 那一拍，手上那个队列槽是 `PUSH + g*WOUT + p`
    //     （它先灌了 `PUSH` 列窗口），**需要的恒等值是位置 (g,p) 的** ⇒ 差 `PUSH` 个槽。
    //   ⇒ 在**消费侧**存一份按**消费**移位的历史，取 `PUSH` 拍前收到的那个值。
    //   ⚠ 用**移位历史**而不是 FIFO：FIFO 保持"进了多少出多少"，而 c2 要消费
    //     `PUSH + 256` 列、c1 只发 256 个 ⇒ FIFO 末尾会**跑干**（实测：尾部 3 行全错）。
    //     历史按消费计数，读的永远是自己早先收到的值 ⇒ 取得到。
    //   ⚠ 只在 `RES=1` 的层建（`RES=0` 走直通，面积为零 ⇒ 旧 TB 零回归）。
    // ---- B1a：**环形缓冲**替代"658 级移位链 + 658:1 宽 mux" ----
    //   旧写法按 `PUSH` 建移位链；B1a 固定最大深度 `PUSH_MAX=658`（640 档），
    //   若照搬就是 658×CI*8 个 FF，每个 adv 全链翻转 —— 面积/功耗都不可接受
    //   （CI=16 时 84,224 位）。环形缓冲 = 一小块 RAM + 读写指针，读端没有宽 mux。
    //
    //   语义与旧移位链**逐位相同**：adv 时写 `i_id`；读指针 = `写指针 − PUSH_eff`（mod 658），
    //   即"`PUSH_eff` 次 adv 之前收到的值"。旧链的复位值 `0x80` 用 `initial` 预置
    //   （对 BRAM 是上电初值；不要用同步复位清整块 RAM —— 那会把它推成寄存器）。
    //   `cfg_res=0` 时**不写不推**（读回恒为初值 0x80），下游 `rq_use_id=0` 不采它。
    wire [CI*8-1:0] id_in_used;
    // ---- 2026-10-19：深度**只跟 res 层走**（rq_use_id=cfg_res ⇒ 非残差层不写、读了也不采）：
    //   res 层最宽 win=160（640 档描述符 L4/6/8）⇒ 不再按 WIN_MAX=640 全图最宽分配
    //   （PUSH_MAX=658 → 13 块 EFX_RAM10），改 IDRB_MAX=338（320+18，留 320 宽 res 余量；
    //   ≤512 档 ⇒ 每 lane 深度 2→1，RAM_BUDGET.md 账本预期 −5~6 块）。
    //   ⚠ 深度必须 ≥ push_eff+1：==push_eff 时读址==写址，BRAM 读写同址行为未定 ⇒ 用 338。
    //   ⚠ 非残差层 push_eff 可达 658 > 338 ⇒ 读址钳到自身 wp 防下溢（值无意义，反正不采）。
    localparam integer ID_WIN_MAX = 320;                 // res 层 win 上限（含余量，别随手改小）
    localparam integer IDRB_MAX   = ID_WIN_MAX + WN;     // 338（PIX=8 实例 = 330）
    // synthesis translate_off
    always @(posedge clk)
        if (rst_n && cfg_res && (cfg_win + WN + 1 > IDRB_MAX))
            $display("** rowpipe_layer: id_rb 深度不足 cfg_win=%0d 需 %0d > IDRB_MAX=%0d **",
                     cfg_win, cfg_win + WN + 1, IDRB_MAX);
    // synthesis translate_on
    reg [CI*8-1:0] id_rb [0:IDRB_MAX-1];
    reg [10:0]     id_wp;
    integer si;
    initial for (si = 0; si < IDRB_MAX; si = si + 1) id_rb[si] = {CI{8'h80}};
    // ⚠ 深度参数化：IDRB_MAX 随 WN 走（PIX=8 实例自动 330），不要写死数字。
    localparam [12:0] IDRB_MAXV = IDRB_MAX;
    wire [12:0] push_eff_id = cfg_res ? push_eff : 13'd0;   // 非残差层钳位防下溢
    wire [12:0] id_rp_s = {2'b00, id_wp} + IDRB_MAXV - push_eff_id;
    wire [10:0] id_rp   = (id_rp_s >= IDRB_MAXV) ? (id_rp_s - IDRB_MAXV) : id_rp_s[10:0];
    always @(posedge clk or negedge rst_n)
        if (!rst_n) id_wp <= 11'd0;
        else if (adv && cfg_res) begin
            id_rb[id_wp] <= i_id;
            id_wp <= (id_wp == IDRB_MAXV[10:0] - 11'd1) ? 11'd0 : id_wp + 1'b1;
        end
    // ⚠⚠ **读口必须寄存**（B1a 实测）：组合读 `id_rb[id_rp]` 在 Efinity 里会被判
    //   "read port is not synchronous" ⇒ 整块 84,224 位落进 **logic memory**
    //   （658:1 读 mux + 大量 FF），根本装不下。加一级输出寄存器就变成 BRAM 读。
    //   对齐：读地址在 adv 那拍给 `t−PUSH`，数据在下一拍出；requant 正好在下一拍采样
    //   （`in_vld = feed_d`）⇒ 与原来的 `rq_id_r` 完全同拍，故那一级寄存器删掉。
    reg [CI*8-1:0] id_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) id_q <= {CI{8'h80}};
        else        id_q <= id_rb[id_rp];
    assign id_in_used = id_q;

    wire rq_use_id   = cfg_res;
    wire [CO*32-1:0] rq_id_full;   // 16 通道的域转换结果（文件尾生成）
    // ⚠ 半区选择必须**和数据同一条流水**：requant 在 `feed_d` 那拍采样，
    //   而那时 `ser` 已经走了一格。用当拍的 rq_sel 会选错半区（实测会静默错）。
    reg  [1:0] rq_sel_d;
    wire [CO_ARR*32-1:0] rq_id_arr;
    genvar gh;
    generate
        for (gh = 0; gh < CO_ARR; gh = gh + 1) begin : g_idhalf
            assign rq_id_arr[32*gh +: 32] =
                   rq_id_full[32*(rq_sel_d*CO_ARR + gh) +: 32];
        end
    endgenerate

    // 在 mux 与 requant 之间插一级寄存器 (README 文件头早就预言过):
    //   最差路径 = u_core/bmem -> acc_flat (PIX*COUT*32 位宽组合总线)
    //   -> requant 进位链, Slack -0.791ns, Logic Level 20.
    //   ⚠ 插完 **在飞从 2 变 3** (多这一级) ⇒ OD 与指针必须同步重推, 见下面 FIFO 段。
    // B1c：co16 层一拍 8 通道；低半区从第 0 遍的 acc_lo 取，高半区从第 1 遍的 acc_flat 取。
    wire [CO_ARR*32-1:0] rq_pix_acc = (npass2 && !ser[0])
        ? acc_lo[px_idx*CO_ARR*32 +: CO_ARR*32]
        : acc_flat[px_idx*CO_ARR*32 +: CO_ARR*32];
    reg  [CO_ARR*32-1:0] rq_pix_acc_r;
    reg              feed_d;
    // ---- 残差恒等支的 **3 级流水**（2026-10-16）----
    //   要和数据走**同一条延迟链**，否则出来时配的不是同一个像素：
    //     feed 那拍：`rq_pix_acc` / `o_id_c`            （级 0）
    //     +1 拍    ：`rq_pix_acc_r` / `rq_id_r1`        （mux 后那级寄存器）
    //     +2 拍    ：requant 级①（`prod_r`/`vld1`）/ `rq_id_r2`
    //     +3 拍    ：requant 级②（`q_out`/`out_vld`）/ `rq_id_r3`
    //   ⇒ `rq_id_r3` 与 `rq_q` / `rq_out_vld` **同拍**，一起进输出 FIFO 的同一个槽。
    //   ⚠ **不许门控**（和 `rq_pix_acc_r` 一样无条件打拍）：门控了就会在背压/空档时
    //     和数据链错开。
    always @(posedge clk) begin
        rq_pix_acc_r <= rq_pix_acc;
        rq_sel_d     <= rq_sel;
        feed_d       <= feed;
        rq_id_r1     <= o_id_c;
        rq_id_r2     <= rq_id_r1;
        rq_id_r3     <= rq_id_r2;
        rq_id_r4     <= rq_id_r3;
        rq_id_r5     <= rq_id_r4;
        half_d1      <= half_feed;  half_d2 <= half_d1;  half_d3 <= half_d2;
        half_d4      <= half_d3;
        half_d5      <= half_d4;
        pdon_d1      <= pdon_feed;  pdon_d2 <= pdon_d1;  pdon_d3 <= pdon_d2;
        pdon_d4      <= pdon_d3;
        pdon_d5      <= pdon_d4;
    end

    requant #(.COUT(CO_ARR), .CO_STORE(CO_FILL), .PW(RQW), .ARCH(1)) u_rq (
        .clk(clk), .rst_n(rst_n),
        .ld_e(ld_me), .ld_idx(ld_midx), .ld_m(ld_m), .ld_mid(ld_mid),
        .ld_shift(ld_shift), .ld_qlo(ld_qlo), .ld_qhi(ld_qhi), .ld_relu_dis(ld_relu_dis),
        .use_id(rq_use_id), .id_in(rq_id_arr), .co_sel(rq_sel_d),
        .in_vld(feed_d), .acc_in(rq_pix_acc_r),
        .out_vld(rq_out_vld), .q_out(rq_q)
    );

    // ---- 输出 skid（**契约 3 的落点**）----
    // requant 的输出进一级 holding，`o_vld/o_col` 从它出：
    //   下游 `o_ready=0` 时 **`o_vld` 保持 1、`o_col` 冻结**，一个像素都不丢。

    // ---- 契约 4：真行末 = 每 WOUT 个**被接走**的像素一次，且和 o_vld 对齐 ----
    reg [15:0] px_cnt;
    // B1c：**按像素**计数（co16 层两拍只算一个像素）——行末位置与旧版一致。
    wire head_pdon = o_q[o_hd][CO*8+1];
    assign o_pix_done = head_pdon;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) px_cnt <= 16'd0;
        else if (o_take && head_pdon) px_cnt <= (px_cnt == cfg_wout - 16'd1) ? 16'd0 : px_cnt + 16'd1;

    assign o_row_end = o_take && head_pdon && (px_cnt == cfg_wout - 16'd1);
    assign o_vld     = o_hold_v;          // ← 从 FIFO 头出（清理时误删过一次）
    assign o_col     = o_q[o_hd][CO*8-1:0];
    // ⚠ **契约变更（2026-10-16）**：`o_id` 从**输出 FIFO 头**出，和 `o_col` **同一个槽**
    //   ⇒ 它和 `o_col` 是**同一个像素**的恒等值。旧写法是"和正在喂的那个像素同拍"
    //   （组合值直接出引脚）—— 那既读错格（见 ③b）、又和数据差 3 拍。
    //   ⇒ 新契约：**`o_id` 只在 `o_vld` 拉高时有效**，语义与 `o_col` 完全一致
    //     （挂起时保持、与 `o_row_end` 同槽对齐）。
    assign o_id      = o_q[o_hd][CO*8+2 +: CI*8];

    //========================================================================
    // ⑤ 残差恒等支 → requant（2026-10-14 加）
    //========================================================================
    //   域处理**照抄 `net_engine.v:270-279`**（那边已经验过整网 12 层含残差）：
    //     无符号张量在 bank 里存的是 `q ^ 0x80`，而行流水里 `i_id` 走的是**真实 u8**
    //     ⇒ 要**反异或**回偏移域再零扩展；有符号张量存原样补码 ⇒ **符号扩展**。
    //   ⚠ 两者写反了会**静默错**（`net_engine` 注释的原话：对负字节给出 0xFFFF00xx，
    //     中 16 位是 0），而且**只在残差层露出** —— 普通层根本没有这条支路。
    //   `RES=0` 时 `rq_use_id` 是常量 0 ⇒ 整块被剪，对已验过的层**零影响**。
    genvar gri;
    generate
        for (gri = 0; gri < CO; gri = gri + 1) begin : g_rid
            if (gri < CI) begin : g_ok
                wire [7:0] ib = id_in_used[8*gri +: 8];
                // B1b：**运行期 cfg_ci 之外**的通道恒 0（高位不污染）
                assign rq_id_full[32*gri +: 32] = (gri < cfg_ci)
                    ? (cfg_resu ? {24'd0, ib ^ 8'h80}
                                : $signed({{24{ib[7]}}, ib}))
                    : 32'sd0;
            end else begin : g_zero
                assign rq_id_full[32*gri +: 32] = 32'sd0;
            end
        end
    endgenerate

endmodule
