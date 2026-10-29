//============================================================================
// conv3x3_core.v —— 3x3 INT8 定点卷积核心（WBS 4.1）
//
//     acc[p][c] = Σ_{cin,ky,kx}  tap[cin][p][ky][kx] · W[cin][ky][kx][c]  +  b'[c]
//
// 全部整数、精确无误差。
//
// ## 并行度与 DSP 映射（这一版的核心）
//     每拍推进一个 (cin,ky,kx)，同时算 PIX 个输出像素 × COUT 个输出通道
//     = PIX·COUT 个 8x8 MAC。
//     每 **两个** 输出通道共用一个 `EFX_DSP48`(DUAL)：
//         A[18:8] x B[17:8] -> O[47:24]   给 cout = 2k
//         A[7:0]  x B[7:0]  -> O[23:0]    给 cout = 2k+1
//     两边用**同一个 tap**、两个不同权重的做法，让 DUAL 的两个子乘法器都吃满。
//     ⇒ PIX=16, COUT=16 时 **256 MAC/拍、128 个 DSP**，正是成本模型的口径
//       （`sim/FPGA-IMPL.md` §2.2/§2.4 的 `INT8_MAC_PER_DSP = 2`）。
//
// ## 为什么 UINT8 激活也能用 8x8（这就是"偏移技巧"）
//     ReLU 层的激活是 uint8（0~255），当有符号用要 **9 位**，塞不进 8x8 子乘法器
//     （两边都必须是 8 位有符号）。向量生成器把无符号层的 tap 预先做成
//         t' = t - 128 ∈ [-128,127]
//     位模式上就是 `t ^ 0x80`，硬件一个 XOR。展开：
//         Σ t·w = Σ (t'+128)·w = Σ t'·w + 128·Σw
//     后一项是**逐输出通道的常数**，已经折进偏置 b'（`sim/tools/make_rtl_vectors.py`）。
//     **数学上精确等价，没有近似。** 有符号层不变，修正项为 0。
//     ⇒ 所以本模块的 taps **一律按 int8 解释**，不需要 in_signed。
//
// ## 权重布局
//     一个 (cin,ky,kx) 对应**一行 COUT 字节**（一拍读一个 128 位字，喂满 16 个
//     乘法器）。按 [c][cin][k] 平铺的话每拍要 72 个读端口，综合不出来。
//
// ## 不在这一版里的
//     行缓冲 / 窗口生成 / halo / 分块 → WBS 4.3。每拍由外部喂 PIX 个 tap。
//     所以**周期数不等于整网**。反射填充在 reflect_pad.v。
//
// ## 握手
//     ① ld_we 载权重行、ld_be 载（修正后的）偏置
//     ② start 一个脉冲 -> 累加器清零、(cin,ky,kx) 计数归零
//     ③ 连打 CIN·K·K 个 step，第 s 拍喂第 s 个 (cin,ky,kx) 的 PIX 个 tap
//     ④ 最后一个 step 之后 acc_vld 拉高一拍，acc_flat 上就是 acc+b'
//
// ⚠ 流水深度 DSP_LAT：DSP 内部 A/B/P/O 四级寄存。改动这个常量必须同步
//   改 TB 的等待（TB 是 `wait(acc_vld)`，所以只要 acc_vld 对就行）。
//============================================================================
`timescale 1ns / 1ps

module conv3x3_core #(
    parameter integer PIX  = 16,   // 并行输出像素数
    parameter integer COUT = 16,   // **MAC 阵列**的输出通道数（= 行流水用的通道数，偶数）
    // ---- B1c（2026-10-17）：存储通道数 ≥ MAC 宽度 ----
    //   co16 层用 COUT=8 的阵列算两遍：0..7 一遍、8..15 一遍。
    //   权重/偏置按 **CO_STORE** 存（16），`co_sel` 选当前半区。
    //   CO_STORE==COUT 时 `csel` 恒 0 ⇒ 与旧行为逐位相同（旧例化不用改参数）。
    parameter integer CO_STORE = COUT,
    parameter integer CIN  = 16,   // 输入通道数（决定权重行数上限）
    parameter integer K    = 3,
    parameter integer WADDR_W = 8, // log2(CIN*K*K)，cin=16 时 144 -> 8 位
    parameter integer DSP_LAT = 3  // 流水延迟；见下面「生产者相位 ↔ 延迟」的说明
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- 权重：地址 = cin*K*K + ky*K + kx，数据 = COUT 个 int8（低位是 cout 0）----
    input  wire                    ld_we,
    input  wire [WADDR_W-1:0]      ld_waddr,
    input  wire [CO_STORE*8-1:0]   ld_wdata,

    // ---- 偏置：int32（**已含无符号层的 128·Σw 修正**），下标 = cout ----
    input  wire                    ld_be,
    input  wire [7:0]              ld_baddr,
    input  wire signed [31:0]      ld_bdata,

    // ---- 步进 ----
    input  wire [15:0]             n_step,        // 本层要推进多少步 = cin*K*K
    input  wire                    start,
    input  wire                    step,          // 推进一个 (cin,ky,kx)
    input  wire [1:0]              co_sel,        // 当前 8 通道半区（CO_STORE>COUT 时有效）
    input  wire [PIX*8-1:0]        taps,          // PIX 个 int8 tap，低位是 p=0

    // ---- 输出 ----
    output reg                     acc_vld,
    output wire [PIX*COUT*32-1:0]  acc_flat       // [p*COUT + c]
);

    localparam integer NSTEP = CIN * K * K;
    localparam integer NACC  = PIX * COUT;
    localparam integer NPAIR = COUT / 2;          // 每像素几个 DSP

    // DSP 延迟：**实测 2 拍**（`tb_dsp_probe.v` 量的），不是按 A/B/P/O 四级寄存器
    // 数出来的 4 —— 模型里有旁路，数寄存器数会错，只有量了才算。
    // ⚠ **生产者相位 ↔ 延迟**（这是个没写清过的契约，踩了半天）：
    //     - taps 与 step **同拍**给（真实 producer：寄存器输出）→ DSP_LAT = 3
    //     - taps **比 step 提前一拍**稳住（很多 tb 的写法）→ DSP_LAT = 2
    //   差一拍的来源：同拍给时，DSP 在采样沿取到的 A/B 要到下一拍才稳定，
    //   有效延迟就多 1。**两个默认值都要对得上，所以 producer 必须和这里一致。**
    //   本项目统一用 3，两个 producer（block_conv / tb_conv3x3）都改成同拍给。

    // ---- 权重 / 偏置存储（B1c：按 CO_STORE 存；CO_STORE==COUT 时与旧版相同）----
    reg [CO_STORE*8-1:0] wrow [0:NSTEP-1];
    reg signed [31:0]    bmem [0:CO_STORE-1];
    wire [1:0] csel = (CO_STORE > COUT) ? co_sel : 2'd0;

    always @(posedge clk) begin
        if (ld_we) wrow[ld_waddr] <= ld_wdata;
        if (ld_be && ld_baddr < CO_STORE) bmem[ld_baddr] <= ld_bdata;
    end

    // ---- 步进计数 ----
    reg [WADDR_W:0] step_cnt;
    reg             busy;

    // 零扩展必须显式写。直接 `step_cnt[15:0]` 是越界片选（reg 只有 9 位），
    // ModelSim 给 x -> `last` 永远不成立 -> 不发 acc_vld -> 仿真死等。
    wire [15:0] cnt16 = {{(16-(WADDR_W+1)){1'b0}}, step_cnt};
    wire last = (cnt16 == n_step - 16'd1);
    wire go   = step & busy;

    // ---- 流水控制：延迟 DSP_LAT 拍 ----
    reg [DSP_LAT-1:0] go_pipe, last_pipe;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_pipe   <= 0;
            last_pipe <= 0;
        end else begin
            go_pipe   <= {go_pipe[DSP_LAT-2:0],   go};
            last_pipe <= {last_pipe[DSP_LAT-2:0], go & last};
        end
    end

    wire go_d   = go_pipe[DSP_LAT-1];     // 累加使能
    wire last_d = last_pipe[DSP_LAT-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_cnt <= 0;
            busy     <= 1'b0;
            acc_vld  <= 1'b0;
        end else begin
            acc_vld <= last_d;            // 最后一次累加在 last_d 那拍落到 acc_r
            if (start) begin
                step_cnt <= 0;
                busy     <= 1'b1;
            end else if (go) begin
                step_cnt <= step_cnt + 1'b1;
                if (last) busy <= 1'b0;
            end
        end
    end

    // ---- 当前这一拍的权重行 ----
    // ⚠ **同步读**（2026-10-11 改）：`wire wpack = wrow[step_cnt]` 是分离 assign
    //   ⇒ 推不出 BRAM，`wrow` 18,432→4,608 bit 全落触发器
    //   （`map.rpt`: `logic memory block 'u_core/wrow' because read port is not synchronous`）。
    //   改法和 `style_accel` 的 `oram` 同构：**下一拍的地址本拍算好**（组合），
    //   读进时钟块 ⇒ 下一拍数据就绪，且和 `step_cnt` 严格同拍。
    //   `step_n` 必须把 `start` 的复位也算进去 —— 否则 `start` 后第一拍会读到
    //   **上一轮残留的 step_cnt**（既不是 0）⇒ 第一行权重是错的。
    wire [WADDR_W-1:0] step_n = start ? {WADDR_W{1'b0}} :
                                go    ? (step_cnt[WADDR_W-1:0] + 1'b1) :
                                        step_cnt[WADDR_W-1:0];
    // ⚠ **同步读整字，半区选择放在寄存器之后**（B1c 实测）：
    //   写成 `wpack_r <= wrow[step_n][csel*COUT*8 +: COUT*8]`（带运行期切片的读）
    //   Efinity 就不再把它推成 RAM —— 18,432 bit 全落 FF（FF 23k→5k 的差别）。
    reg  [CO_STORE*8-1:0] wpack_full_r;
    always @(posedge clk) wpack_full_r <= wrow[step_n];
    wire [COUT*8-1:0] wpack = wpack_full_r[csel*COUT*8 +: COUT*8];

    // ---- PIX x COUT 乘累加：每两个输出通道共用一个 DSP ----
    reg signed [23:0] acc_r [0:NACC-1];

    genvar gp, gk;
    generate
        for (gp = 0; gp < PIX; gp = gp + 1) begin : g_pix
            // tap 一律按 int8（无符号层的偏移已在向量生成阶段做好）
            wire signed [7:0] t = taps[8*gp +: 8];

            for (gk = 0; gk < NPAIR; gk = gk + 1) begin : g_pair
                wire signed [7:0] w_hi = wpack[8*(2*gk)     +: 8];
                wire signed [7:0] w_lo = wpack[8*(2*gk + 1) +: 8];

                wire [47:0] dsp_o;

                EFX_DSP48 #(
                    .MODE    ("DUAL"),
                    .SIGNED  (1),
                    .A_REG   (1),
                    .B_REG   (1),
                    .P_REG   (1),
                    .O_REG   (1),
                    .OP_REG  (1),
                    .SHIFTER (0),
                    .RST_SYNC(1),
                    .M_SEL   ("P"),
                    .N_SEL   ("CONST0")
                ) u_dsp (
                    .A        ({ {3{t[7]}}, t, t }),        // A[18:8]=11位, A[7:0]=8位
                    .B        ({ {2{w_hi[7]}}, w_hi, w_lo }), // B[17:8]=10位, B[7:0]=8位
                    .C        (18'd0),
                    .CASCIN   (48'd0),
                    .OP       (2'b00),
                    .SHIFT_ENA(1'b0),
                    .CLK      (clk),
                    .CE       (1'b1),
                    .RST      (~rst_n),
                    .O        (dsp_o),
                    .CASCOUT  (),
                    .OVFL     ()
                );

                // ⚠ 位切片按扩展后的 48 位 O 取（UG Table 27）：
                //   高路 -> O[47:24]、低路 -> O[23:0]。按内部 37 位取能综合过、
                //   DSP 数也对，但**数值全错**，资源报告里看不出来。
                //   取满 24 位（不是 16 位）：8x8 的 16 位乘积被**符号扩展**到 24 位，
                //   截成 16 位虽然低 16 位仍然对，但一旦哪天真溢出就会静默出错。
                //   这里留 24 位，累加时再按有符号扩到 32。
                wire signed [23:0] prod_hi = dsp_o[47:24];
                wire signed [23:0] prod_lo = dsp_o[23:0];

                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n)     acc_r[gp*COUT + 2*gk]     <= 32'sd0;
                    else if (start) acc_r[gp*COUT + 2*gk]     <= 32'sd0;
                    else if (go_d)  acc_r[gp*COUT + 2*gk]     <=
                                        acc_r[gp*COUT + 2*gk] + prod_hi;
                end
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n)     acc_r[gp*COUT + 2*gk + 1] <= 32'sd0;
                    else if (start) acc_r[gp*COUT + 2*gk + 1] <= 32'sd0;
                    else if (go_d)  acc_r[gp*COUT + 2*gk + 1] <=
                                        acc_r[gp*COUT + 2*gk + 1] + prod_lo;
                end
            end
        end
    endgenerate

    // ---- 输出：acc + b' ----
    // last_d 与最后一次累加同拍，acc_r 在下一拍落定，acc_vld 也是下一拍 ——
    // 所以这里 acc_r 已经含了最后一拍，**不要再加一次乘积**（第一版就是这么错的）。
    genvar gp2, gc2;
    generate
        for (gp2 = 0; gp2 < PIX; gp2 = gp2 + 1) begin : g_op
            for (gc2 = 0; gc2 < COUT; gc2 = gc2 + 1) begin : g_oc
                assign acc_flat[32*(gp2*COUT + gc2) +: 32] =
                       $signed(acc_r[gp2*COUT + gc2]) + bmem[csel*COUT + gc2];
            end
        end
    endgenerate

endmodule
