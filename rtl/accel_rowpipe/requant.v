//============================================================================
// requant.v —— 逐层再量化（WBS 4.2）
//
// 把 int32 累加器变成下一层的 int8/uint8 输入：
//
//     浮点：q = clamp( round( relu?(acc · s_a · s_w) / s_out ) )
//     定点：q = clamp( RHE( relu?(acc) · M , shift ) )      M/2^shift ≈ s_a·s_w/s_out
//
// （M 和 shift 由 `sim/tools/make_requant.py` 从 `spec.json` 算出来。）
//
// ## ⚠ RHE = 四舍六入五成双（round half to even），不是四舍五入
//
//     torch.round 用的是 half-to-even。硬件要是用"四舍五入"（.5 一律进位），
//     **落在 .5 上的像素会系统性偏 1**，而且只在特定像素上出现 —— 静默错。
//
//         RHE(n,s) = (n + 2^(s-1) - 1 + ((n >> s) & 1)) >> s
//
//     验证（rem 是低 s 位）：
//         rem >  half -> 进位     rem <  half -> 舍去
//         rem == half -> 末位是 1 才进位（取偶）
//     **写成 `(n + 2^(s-1)) >> s` 就是四舍五入，在 .5 上会和模型系统性不符。**
//
// ## 流水
//     两级：① 乘（32×32→64，寄存）② 移位+取偶+饱和（寄存）。
//     再量化不是瓶颈（一拍一个像素就够），但乘法器装进 DSP 更省 Fabric。
//
// ## 接口
//     一拍一个**像素**的全部 COUT 个通道（和 conv3x3_core 的 acc_flat 对齐）。
//============================================================================
`timescale 1ns / 1ps

module requant #(
    parameter integer COUT = 16,    // **MAC 阵列**的通道数（B1c 起用 8）
    parameter integer CO_STORE = COUT, // 存储的 M/mid 通道数（co16 层 = 16，分两半区）
    parameter integer PW   = 6,     // shift 位宽（shift 上限 < 64）
    // 0 = 旧两级流水（net_engine 等保持原样）
    // 1 = **三拍流水**（rowpipe 用）：把"移位 + 加 + 再移位 + 饱和"拆成两拍，
    //     关键路径从 ~40 级降到 ~25 级。数值**逐位相同**，只多 1 拍延迟。
    parameter integer ARCH = 0
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- 载入本层参数 ----
    input  wire                  ld_e,
    input  wire [7:0]            ld_idx,        // cout
    input  wire signed [31:0]    ld_m,
    input  wire [PW-1:0]         ld_shift,
    input  wire signed [31:0]    ld_mid,       // 恒等支的乘数（非残差层给 0）
    input  wire signed [7:0]     ld_qlo,
    input  wire [7:0]            ld_qhi,      // ⚠ **无符号**（0..255）
    // 2026-10-27：**显式关闭 ReLU**。原本是否 ReLU 只看 `qlo` 的符号，
    // 于是"末层写成 qlo=0（offset-binary）"就静默把输出负半轴全夹成 0
    // —— 这是本项目复发过一次的故障（redsky v4、starry g075/g085 都中过）。
    // 末层由 rowpipe_engine 置 1 强制透传：对 offset-binary 无影响（qlo=0 本来
    // 就把负数夹到 0），对有符号输出则是必需的。其余层保持 0，行为不变。
    input  wire                  ld_relu_dis,

    // ---- 数据：一拍一个像素的 COUT 个 int32 累加器 ----
    input  wire                  use_id,       // 本层要不要加残差恒等支
    input  wire signed [COUT*32-1:0] id_in,    // 恒等支（**int32，有符号**：逐层符号不同）
    input  wire [1:0]            co_sel,       // B1c：8 通道半区（CO_STORE>COUT 时有效）
    input  wire                  in_vld,
    input  wire [COUT*32-1:0]    acc_in,        // [c] 低位是 c=0

    output reg                   out_vld,
    output reg  [COUT*8-1:0]     q_out
);

    reg signed [31:0] m_r     [0:CO_STORE-1];
    reg signed [31:0] mid_r   [0:CO_STORE-1];
    reg        [PW-1:0] shift_r;
    reg signed [7:0]  qlo_r;
    reg        [7:0]  qhi_r;
    reg               relu_dis_r;      // 见端口注释：末层强制透传，不 ReLU
    // B1c：半区选择（CO_STORE==COUT 时恒 0 ⇒ 旧行为不变）
    wire [1:0] csel = (CO_STORE > COUT) ? co_sel : 2'd0;
    localparam integer H1 = (CO_STORE > COUT) ? COUT : 0; // cap8: high-half base

    always @(posedge clk) begin
        if (ld_e && ld_idx < CO_STORE) m_r[ld_idx] <= ld_m;
        if (ld_e && ld_idx < CO_STORE) mid_r[ld_idx] <= ld_mid;
        if (ld_e) begin shift_r <= ld_shift; qlo_r <= ld_qlo; qhi_r <= ld_qhi;
                      relu_dis_r <= ld_relu_dis; end
    end

    // ---- 级 ①：ReLU（按 qlo 判断是否无符号） + 乘 ----
    reg signed [63:0] prod_r [0:COUT-1];
    reg               vld1;

    genvar gc;
    generate
    if (ARCH == 0) begin : g_mul0
        for (gc = 0; gc < COUT; gc = gc + 1) begin : g_mul
            wire signed [31:0] a = $signed(acc_in[32*gc +: 32]);
            // 无符号层（qlo>=0）先 ReLU。M 恒正，所以"先 ReLU 再乘"与
            // 模型里"先乘再 ReLU"等价，而且省一级。
            wire signed [31:0] ar = (relu_dis_r || (qlo_r < 0)) ? a : ((a > 0) ? a : 32'sd0);
            // 恒等支：和卷积支共用同一分母（同一 shift），所以两支**先加后舍**
            // —— 只舍入一次，与模型 round((x+y)/s_out) 形状一致。
            wire signed [31:0] xi = $signed(id_in[32*gc +: 32]);
            wire signed [31:0] xr = use_id ? xi : 32'sd0;
            always @(posedge clk)
                prod_r[gc] <= $signed(ar) * $signed(m_r[csel*COUT + gc])
                            + $signed(xr) * $signed(mid_r[csel*COUT + gc]);
        end
        always @(posedge clk or negedge rst_n)
            if (!rst_n) vld1 <= 1'b0; else vld1 <= in_vld;
    end else begin : g_mul1
        // ARCH=1：**ReLU/符号/use_id 单独打一拍**。
        // 实测关键路径：cfg_ci → 10 级 LUT（32 位 ReLU 比较 + 符号扩展）
        // → DSP 级联 → 64 位加 → prod_r ⇒ 138MHz。把前面那 10 级隔离掉。
        reg signed [31:0] ar_r [0:COUT-1];
        reg signed [31:0] xr_r [0:COUT-1];
        reg signed [31:0] m_h0 [0:COUT-1];
        reg signed [31:0] m_h1 [0:COUT-1];
        reg signed [31:0] mid_h0 [0:COUT-1];
        reg signed [31:0] mid_h1 [0:COUT-1];
        reg               vld0;
        for (gc = 0; gc < COUT; gc = gc + 1) begin : g_mul
            wire signed [31:0] a = $signed(acc_in[32*gc +: 32]);
            wire signed [31:0] ar = (relu_dis_r || (qlo_r < 0)) ? a : ((a > 0) ? a : 32'sd0);
            wire signed [31:0] xi = $signed(id_in[32*gc +: 32]);
            wire signed [31:0] xr = use_id ? xi : 32'sd0;
            always @(posedge clk) begin
                ar_r[gc] <= ar;
                xr_r[gc] <= xr;
                m_h0[gc]   <= m_r[gc];
                m_h1[gc]   <= m_r[H1 + gc];
                mid_h0[gc] <= mid_r[gc];
                mid_h1[gc] <= mid_r[H1 + gc];
            end
            wire signed [31:0] m_sel   = csel[0] ? m_h1[gc] : m_h0[gc];
            wire signed [31:0] mid_sel = csel[0] ? mid_h1[gc] : mid_h0[gc];
            always @(posedge clk)
                prod_r[gc] <= $signed(ar_r[gc]) * m_sel
                            + $signed(xr_r[gc]) * mid_sel;
        end
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin vld0 <= 1'b0; vld1 <= 1'b0; end
            else        begin vld0 <= in_vld; vld1 <= vld0; end
    end
    endgenerate

    // ---- 级 ②：RHE 移位 + 饱和 ----
    function signed [63:0] rhe;
        input signed [63:0] n;
        input [PW-1:0]      s;
        reg   signed [63:0] half;
        begin
            if (s == 0) rhe = n;
            else begin
                half = 64'sd1 <<< (s - 1'b1);
                rhe  = (n + half - 64'sd1 + ((n >>> s) & 64'sd1)) >>> s;
            end
        end
    endfunction

    genvar gq;
    generate
    if (ARCH == 0) begin : g_rq2
        for (gq = 0; gq < COUT; gq = gq + 1) begin : g_sat
            wire signed [63:0] qs = rhe(prod_r[gq], shift_r);
            // ⚠ qhi **零扩展**（它是无符号的 0..255）；qlo **符号扩展**（可能 -127）。
            //   把 qhi 当有符号读的话 255 会变成 -1，所有输出被夹到 -1 ——
            //   实测：196607 个比较里 187770 个不符，而且错得很"整齐"，像缩放问题。
            wire signed [63:0] qhv = $signed({56'd0, qhi_r});
            wire signed [63:0] qlv = $signed({{56{qlo_r[7]}}, qlo_r});
            wire signed [63:0] qc = (qs > qhv) ? qhv : (qs < qlv) ? qlv : qs;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) q_out[8*gq +: 8] <= 8'h00;
                else        q_out[8*gq +: 8] <= qc[7:0];
        end

        always @(posedge clk or negedge rst_n)
            if (!rst_n) out_vld <= 1'b0; else out_vld <= vld1;
    end else begin : g_rq3
        // ---- 三拍：①乘 ②(移位 q0 ∥ 加 half-1) ③(+q0[0], 再移位, 饱和) ----
        //   RHE(n,s) = (n + (2^(s-1)-1) + ((n>>>s)&1)) >>> s = (sum1+q0b) >>> s
        //   `half_m1` 在装参数时算好（不在数据路径上）。
        reg signed [63:0] half_m1_r;
        always @(posedge clk)
            if (ld_e)
                half_m1_r <= (ld_shift == {PW{1'b0}}) ? 64'sd0
                          : ((64'sd1 << (ld_shift - 1'b1)) - 64'sd1);

        reg signed [63:0] sum1_r [0:COUT-1];
        reg               q0b_r  [0:COUT-1];
        reg        [PW-1:0] s_r2;
        reg                 vld2;

        for (gq = 0; gq < COUT; gq = gq + 1) begin : g_p2
            wire signed [63:0] q0 = prod_r[gq] >>> shift_r;
            always @(posedge clk) begin
                sum1_r[gq] <= prod_r[gq] + half_m1_r;
                q0b_r[gq]  <= (shift_r == {PW{1'b0}}) ? 1'b0 : q0[0];
            end
        end
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin vld2 <= 1'b0; s_r2 <= {PW{1'b0}}; end
            else        begin vld2 <= vld1; s_r2 <= shift_r; end

        for (gq = 0; gq < COUT; gq = gq + 1) begin : g_sat3
            wire signed [63:0] t  = sum1_r[gq] + {{63{1'b0}}, q0b_r[gq]};
            wire signed [63:0] qs = t >>> s_r2;
            wire signed [63:0] qhv = $signed({56'd0, qhi_r});
            wire signed [63:0] qlv = $signed({{56{qlo_r[7]}}, qlo_r});
            wire signed [63:0] qc = (qs > qhv) ? qhv : (qs < qlv) ? qlv : qs;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) q_out[8*gq +: 8] <= 8'h00;
                else        q_out[8*gq +: 8] <= qc[7:0];
        end
        always @(posedge clk or negedge rst_n)
            if (!rst_n) out_vld <= 1'b0; else out_vld <= vld2;
    end
    endgenerate

endmodule
