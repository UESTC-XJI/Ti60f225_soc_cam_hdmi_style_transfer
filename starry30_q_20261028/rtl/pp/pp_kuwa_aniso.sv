// pp_kuwa_aniso.sv —— 2b 各向异性 Kuwahara（D=2, r=1, angles=12, tensor_r=2）
//   结构张量(5x5) -> 特征分解(Q8) -> 12 向离散 -> 16 点 gather -> 4 象限选最小方差
//   整数公式与 sim/tools/pp_kuwa_aniso_golden.py 逐位一致；偏移上限 ±4（9 行 RGB 环）。
//   行批处理：每完成一个 D 行 -> 先补 Sobel 行，再处理输出行 r-4。
//   判据区：x,y ∈ [4, W2/H2-5]（golden 同此）；TB: 128x128 -> W2=64。
//   注：本版特征除法用组合 `/`（仿真/功能验证）；PnR 前换迭代除法器。
`timescale 1ns/1ps
module pp_kuwa_aniso #(
    parameter integer W2  = 64,
    parameter integer H2  = 64,
    parameter integer FSW = 128,
    parameter integer FSH = 128
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_px,
    output reg         o_de,
    output reg  [23:0] o_px
);
    localparam integer MARGIN = 4;
    localparam integer OFFC   = 4;
    localparam integer COH    = 650;
    localparam integer SHARP  = 3;

    localparam integer XW = (W2 > 2) ? $clog2(W2) : 1;
    localparam integer YW = (H2 > 2) ? $clog2(H2) : 1;
    localparam integer FW = (FSW > 2) ? $clog2(FSW) : 1;
    localparam integer FHW = (FSH > 2) ? $clog2(FSH) : 1;

    // ---------------- 输入坐标 / D=2 采样 ----------------
    reg [FW-1:0] x;
    reg [FHW-1:0] y;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin x <= 0; y <= 0; end
        else if (i_vs) begin x <= 0; y <= 0; end
        else if (i_de) begin
            if (x == FSW-1) begin x <= 0; y <= (y == FSH-1) ? 0 : y + 1'b1; end
            else x <= x + 1'b1;
        end
    wire de2 = i_de && !x[0] && !y[0];
    wire [XW-1:0] x2 = x[XW:1];
    wire [YW-1:0] y2 = y[YW:1];

    // ---------------- 行环缓冲 ----------------
    reg [23:0] rring [0:9*W2-1];
    reg [7:0]  yring [0:3*W2-1];
    reg [31:0] gring [0:7*W2-1];

    reg [3:0]  rs;          // RGB/Y 写槽 0..8
    reg [2:0]  gs;          // g 写槽 0..4
    reg [YW-1:0] last_row;
    reg        pend;
    reg [YW-1:0] pend_row;
    reg        ovf;
    reg        row_pulse;
    reg [7:0] sy0_1, sy0_2, sy1_1, sy1_2, sy2_1, sy2_2;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            rs <= 0; last_row <= 0; row_pulse <= 0;
        end else begin
            row_pulse <= 0;
            if (i_vs) begin
                rs <= 0; last_row <= 0;
            end else if (de2) begin
                rring[rs*W2 + x2] <= i_px;
                yring[mod3(y2)*W2 + x2] <= (77*i_px[23:16] + 150*i_px[15:8] + 29*i_px[7:0]) >> 8;
                if (x2 == W2-1) begin
                    rs        <= (rs == 8) ? 0 : rs + 1'b1;
                    last_row  <= y2;
                    row_pulse <= 1'b1;
                end
            end
        end

    // ---------------- 主 FSM ----------------
    localparam S_IDLE=0, S_SOBEL=1, S_SOBEL_END=2, S_PIX_INIT=3, S_TENSOR=4,
               S_TDIV=5, S_SQRT=6, S_FEAT=7, S_GATHER=8, S_STAT=9, S_PICK=10, S_OUT=11,
               S_DIV=12, S_DIV_END=13, S_FIN=14, S_SOBEL_FLUSH=15;
    reg [3:0] st;

    reg [YW-1:0] r, ycur;
    reg [XW-1:0] xcur;
    reg [XW:0]   sob_c;

    reg signed [15:0] sgy, sgx;

    reg [31:0] acc_xx, acc_yy;
    reg signed [31:0] acc_xy;
    reg [4:0] tcnt;
    reg [2:0] tdy, tdx;

    reg signed [31:0] jxx, jxy, jyy;
    reg [47:0] tval, sq_rem;
    reg [23:0] sq_root;
    reg [5:0]  sq_i;

    reg [31:0] l1, l2, coh_q8, gate_q8, aniso_q8;
    reg [6:0]  s_q4;
    reg [3:0]  dir;
    reg signed [15:0] ct, sn;
    reg [15:0] inv_s;

    reg [4:0] gi;
    reg [23:0] samp;
    reg [1:0]  samp_q;
    reg        samp_v;

    reg [31:0] qr0,qg0,qb0, qr1,qg1,qb1, qr2,qg2,qb2, qr3,qg3,qb3;
    reg [31:0] ql0,ql1,ql2,ql3, qs0,qs1,qs2,qs3;

    function [3:0] mod9; input [YW:0] v; reg [31:0] q; begin q=(v*32'd57)>>9; mod9 = v - q*9; end endfunction
    function [1:0] mod3; input [YW:0] v; reg [31:0] q; begin q=(v*32'd171)>>9; mod3 = v - q*3; end endfunction
    function [2:0] mod7; input [YW:0] v; reg [31:0] q; begin q=(v*32'd293)>>11; mod7 = v - q*7; end endfunction

    function signed [31:0] rnd8; input signed [31:0] v;
        begin
            if (v >= 0) rnd8 = (v + 128) >>> 8;
            else        rnd8 = -(((-v) + 128) >>> 8);
        end
    endfunction

    function signed [31:0] csz; input signed [31:0] v; input integer lo, hi;
        begin
            if (v < lo) csz = lo; else if (v > hi) csz = hi; else csz = v;
        end
    endfunction

    // 12 向 sin/cos（Q8）
    task get_cs; input [3:0] d; output signed [15:0] c; output signed [15:0] s;
        begin
            case (d)
                4'd0:  begin c= 16'sd256; s= 16'sd0;   end
                4'd1:  begin c= 16'sd247; s= 16'sd66;  end
                4'd2:  begin c= 16'sd222; s= 16'sd128; end
                4'd3:  begin c= 16'sd181; s= 16'sd181; end
                4'd4:  begin c= 16'sd128; s= 16'sd222; end
                4'd5:  begin c= 16'sd66;  s= 16'sd247; end
                4'd6:  begin c= 16'sd0;   s= 16'sd256; end
                4'd7:  begin c=-16'sd66;  s= 16'sd247; end
                4'd8:  begin c=-16'sd128; s= 16'sd222; end
                4'd9:  begin c=-16'sd181; s= 16'sd181; end
                4'd10: begin c=-16'sd222; s= 16'sd128; end
                4'd11: begin c=-16'sd247; s= 16'sd66;  end
                default: begin c=16'sd256; s=16'sd0; end
            endcase
        end
    endtask

    // ---------------- 组合：张量 5x5 读值 ----------------
    integer ty, tx;
    reg signed [15:0] tgx, tgy;

    // ---------------- 组合：l1/l2 + 顺序除法器 ----------------
    reg [31:0] l1_c, l2_c;
    always @* begin
        l1_c = (jxx + jyy + sq_root) >> 1;
        l2_c = (jxx + jyy - sq_root) >> 1;
    end
    reg [31:0] div_n, div_d;
    reg [47:0] div_rem;
    reg [8:0]  div_q;
    reg [3:0]  div_k;
    reg        div_phase;
    reg [31:0] coh_r, gate_r;
    integer aniso_i2;

    // 1/s LUT（s_q4=16..64，round(65536/s)）
    function [15:0] inv_lut; input [6:0] sv;
        begin
            case (sv)
                7'd16: inv_lut = 16'd4096;
                7'd17: inv_lut = 16'd3855;
                7'd18: inv_lut = 16'd3641;
                7'd19: inv_lut = 16'd3449;
                7'd20: inv_lut = 16'd3277;
                7'd21: inv_lut = 16'd3121;
                7'd22: inv_lut = 16'd2979;
                7'd23: inv_lut = 16'd2849;
                7'd24: inv_lut = 16'd2731;
                7'd25: inv_lut = 16'd2621;
                7'd26: inv_lut = 16'd2521;
                7'd27: inv_lut = 16'd2427;
                7'd28: inv_lut = 16'd2341;
                7'd29: inv_lut = 16'd2260;
                7'd30: inv_lut = 16'd2185;
                7'd31: inv_lut = 16'd2114;
                7'd32: inv_lut = 16'd2048;
                7'd33: inv_lut = 16'd1986;
                7'd34: inv_lut = 16'd1928;
                7'd35: inv_lut = 16'd1872;
                7'd36: inv_lut = 16'd1820;
                7'd37: inv_lut = 16'd1771;
                7'd38: inv_lut = 16'd1725;
                7'd39: inv_lut = 16'd1680;
                7'd40: inv_lut = 16'd1638;
                7'd41: inv_lut = 16'd1598;
                7'd42: inv_lut = 16'd1560;
                7'd43: inv_lut = 16'd1524;
                7'd44: inv_lut = 16'd1489;
                7'd45: inv_lut = 16'd1456;
                7'd46: inv_lut = 16'd1425;
                7'd47: inv_lut = 16'd1394;
                7'd48: inv_lut = 16'd1365;
                7'd49: inv_lut = 16'd1337;
                7'd50: inv_lut = 16'd1311;
                7'd51: inv_lut = 16'd1285;
                7'd52: inv_lut = 16'd1260;
                7'd53: inv_lut = 16'd1237;
                7'd54: inv_lut = 16'd1214;
                7'd55: inv_lut = 16'd1192;
                7'd56: inv_lut = 16'd1170;
                7'd57: inv_lut = 16'd1150;
                7'd58: inv_lut = 16'd1130;
                7'd59: inv_lut = 16'd1111;
                7'd60: inv_lut = 16'd1092;
                7'd61: inv_lut = 16'd1074;
                7'd62: inv_lut = 16'd1057;
                7'd63: inv_lut = 16'd1040;
                7'd64: inv_lut = 16'd1024;
                default: inv_lut = 16'd1024;
            endcase
        end
    endfunction

    // ---------------- 组合：方向 ----------------
    reg [3:0] dir_c;
    always @* begin
        begin : dirc
            reg signed [31:0] num, den;
            reg [31:0] aa, bb;
            reg [1:0] qq, sb;
            reg [63:0] la, lb;
            num = jxy <<< 1;
            den = jxx - jyy;
            dir_c = 0;
            if (!(num == 0 && den == 0)) begin
                if (den > 0 && num >= 0)      begin qq=0; aa=num; bb=den;  end
                else if (den <= 0 && num > 0) begin qq=1; aa=num; bb=-den; end
                else if (den < 0 && num <= 0) begin qq=2; aa=-num; bb=-den; end
                else                          begin qq=3; aa=-num; bb=den; end
                la = aa; lb = bb;
                if (la*1024 < lb*274)       sb=0;
                else if (aa < bb)           sb=1;
                else if (la*1024 < lb*3822) sb=2;
                else                        sb=3;
                if (qq*3 + sb >= 12) dir_c = 0; else dir_c = qq*3 + sb;
            end
        end
    end

    // ---------------- 组合：16 点 gather 地址/样本 ----------------
    reg [XW-1:0] gcol_c;
    reg [YW-1:0] grow_c;
    reg [1:0]    gq_c;
    always @* begin
        begin : gatc
            integer qx, qy, ii, jj;
            reg signed [31:0] du, dv, a_, b_, as_, bi_, oxq, oyq, ox, oy;
            reg signed [31:0] s32, inv32, xc32, yc32;
            qx = (gi[3:2] == 2'd0 || gi[3:2] == 2'd2) ? -1 : 1;
            qy = (gi[3:2] == 2'd0 || gi[3:2] == 2'd1) ? -1 : 1;
            ii = gi[1] ? 1 : 0;
            jj = gi[0] ? 1 : 0;
            du = qx * ii;
            dv = qy * jj;
            s32 = s_q4;      // 显式 signed，避免无符号移位
            inv32 = inv_s;
            a_  = ct*du + sn*dv;
            b_  = -sn*du + ct*dv;
            as_ = (a_ * s32) >>> 4;
            bi_ = (b_ * inv32) >>> 12;
            oxq = (ct*as_ - sn*bi_) >>> 8;
            oyq = (sn*as_ + ct*bi_) >>> 8;
            ox  = csz(rnd8(oxq), -OFFC, OFFC);
            oy  = csz(rnd8(oyq), -OFFC, OFFC);
            xc32 = xcur;
            yc32 = ycur;
            gcol_c = csz(xc32 + ox, 0, W2-1);
            grow_c = csz(yc32 + oy, 0, H2-1);
            gq_c   = gi[3:2];
        end
    end
    wire [23:0] samp_c = rring[mod9(grow_c)*W2 + gcol_c];

    // ---------------- 主状态机 ----------------
    integer si;
    reg signed [31:0] tmp_ox, tmp_oy;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= S_IDLE; o_de <= 0; o_px <= 0; gs <= 0; pend <= 0; pend_row <= 0; ovf <= 0;
            r <= 0; ycur <= 0; xcur <= 0; sob_c <= 0; sgx <= 0; sgy <= 0;
            acc_xx <= 0; acc_xy <= 0; acc_yy <= 0; tcnt <= 0; tdy <= 0; tdx <= 0;
            jxx <= 0; jxy <= 0; jyy <= 0; tval <= 0; sq_rem <= 0; sq_root <= 0; sq_i <= 0;
            l1 <= 0; l2 <= 0; coh_q8 <= 0; gate_q8 <= 0; aniso_q8 <= 0;
            s_q4 <= 16; dir <= 0; ct <= 256; sn <= 0; inv_s <= 4096;
            gi <= 0; samp <= 0; samp_q <= 0; samp_v <= 0;
            sy0_1<=0; sy0_2<=0; sy1_1<=0; sy1_2<=0; sy2_1<=0; sy2_2<=0;
            qr0<=0;qg0<=0;qb0<=0;qr1<=0;qg1<=0;qb1<=0;qr2<=0;qg2<=0;qb2<=0;qr3<=0;qg3<=0;qb3<=0;
            ql0<=0;ql1<=0;ql2<=0;ql3<=0;qs0<=0;qs1<=0;qs2<=0;qs3<=0;
        end else begin
            o_de <= 1'b0;
            if (i_vs) begin st <= S_IDLE; gs <= 0; pend <= 0; pend_row <= 0; ovf <= 0; end
            else begin
            if (row_pulse) begin
                if (pend) ovf <= 1'b1;
                else begin pend <= 1'b1; pend_row <= last_row; end
            end
            case (st)
            S_IDLE: begin
                samp_v <= 0;
                if (pend) begin
                    r  <= pend_row;
                    pend <= 1'b0;
                    if (pend_row >= 1) begin sob_c <= 0; st <= S_SOBEL; end
                end
            end

            // ---- Sobel 一行（g 行 = r-1）：每拍读 3 行同列，列窗口靠移位 ----
            S_SOBEL: begin
                begin : sc
                    reg [YW:0] t0, t1, t2;
                    reg [XW-1:0] c0;
                    reg [7:0] a0, a1, a2;
                    reg signed [15:0] gxc16, gyc16;
                    t0 = (r >= 2) ? (r-2) : 0;
                    t1 = r - 1;
                    t2 = r;
                    c0 = sob_c[XW-1:0];
                    a0 = yring[mod3(t0)*W2 + c0];
                    a1 = yring[mod3(t1)*W2 + c0];
                    a2 = yring[mod3(t2)*W2 + c0];
                    if (sob_c == 0) begin
                        sy0_1 <= a0; sy0_2 <= a0;
                        sy1_1 <= a1; sy1_2 <= a1;
                        sy2_1 <= a2; sy2_2 <= a2;
                    end else begin
                        gxc16 = (a0 + 2*a1 + a2) - (sy0_2 + 2*sy1_2 + sy2_2);
                        gyc16 = (sy2_2 + 2*sy2_1 + a2) - (sy0_2 + 2*sy0_1 + a0);
                        gring[gs*W2 + (sob_c[XW-1:0] - 1'b1)] <= {gxc16, gyc16};
                        sy0_2 <= sy0_1; sy0_1 <= a0;
                        sy1_2 <= sy1_1; sy1_1 <= a1;
                        sy2_2 <= sy2_1; sy2_1 <= a2;
                    end
                end
                if (sob_c == W2-1) st <= S_SOBEL_FLUSH;
                else sob_c <= sob_c + 1'b1;
            end
            S_SOBEL_FLUSH: begin
                // 最后一列：右边沿 clamp 到中心列
                gring[gs*W2 + (W2-1)] <= { (sy0_1 + 2*sy1_1 + sy2_1) - (sy0_2 + 2*sy1_2 + sy2_2),
                                           (sy2_2 + 2*sy2_1 + sy2_1) - (sy0_2 + 2*sy0_1 + sy0_1) };
                st <= S_SOBEL_END;
            end
            S_SOBEL_END: begin
                gs <= (gs == 6) ? 0 : gs + 1'b1;
                if (r >= 8) begin
                    ycur <= r - 4;
                    xcur <= MARGIN;
                    st <= S_PIX_INIT;
                end else st <= S_IDLE;
            end

            // ---- 像素初始化 ----
            S_PIX_INIT: begin
                acc_xx <= 0; acc_xy <= 0; acc_yy <= 0;
                tdy <= 0; tdx <= 0; tcnt <= 0;
                st <= S_TENSOR;
            end

            // ---- 5x5 张量 ----
            S_TENSOR: begin
                ty = ycur + tdy - 2;
                tx = xcur + tdx - 2;
                if (ty < 0) ty = 0; if (ty > H2-1) ty = H2-1;
                if (tx < 0) tx = 0; if (tx > W2-1) tx = W2-1;
                tgx = $signed(gring[mod7(ty)*W2 + tx][31:16]);
                tgy = $signed(gring[mod7(ty)*W2 + tx][15:0]);
                begin : tenmul
                    reg signed [31:0] gx32, gy32;
                    gx32 = tgx;   // 显式 32 位符号扩展，避免 16 位乘法截断
                    gy32 = tgy;
                    acc_xx <= acc_xx + gx32*gx32;
                    acc_xy <= acc_xy + gx32*gy32;
                    acc_yy <= acc_yy + gy32*gy32;
                end
                if (tcnt == 24) st <= S_TDIV;
                else begin
                    tcnt <= tcnt + 1'b1;
                    if (tdx == 4) begin tdx <= 0; tdy <= tdy + 1'b1; end
                    else tdx <= tdx + 1'b1;
                end
            end

            // ---- j 值 + 装 sqrt ----
            S_TDIV: begin
                jxx <= acc_xx / 25;
                jyy <= acc_yy / 25;
                jxy <= (acc_xy >= 0) ? (acc_xy / 32'sd25) : -(((-acc_xy) + 32'sd24) / 32'sd25);
                // 用组合除法结果直接装 tval（与 acc 同拍）
                begin : td
                    reg signed [31:0] a, b, c_;
                    reg signed [63:0] d_;
                    a = acc_xx / 25;
                    b = (acc_xy >= 0) ? (acc_xy / 32'sd25) : -(((-acc_xy) + 32'sd24) / 32'sd25);
                    c_ = acc_yy / 25;
                    d_ = a - c_;
                    tval <= d_*d_ + 4*b*b;
                end
                sq_rem <= 0; sq_root <= 0; sq_i <= 23;
                st <= S_SQRT;
            end

            // ---- 24 拍整数 sqrt ----
            S_SQRT: begin
                begin : sq
                    reg [47:0] rem_n;
                    reg [23:0] root_n;
                    rem_n  = (sq_rem << 2) | ((tval >> (2*sq_i)) & 2'b11);
                    root_n = sq_root << 1;
                    if (rem_n >= ((root_n << 1) + 1)) begin
                        rem_n  = rem_n - ((root_n << 1) + 1);
                        root_n = root_n + 1;
                    end
                    sq_rem  <= rem_n;
                    sq_root <= root_n;
                end
                if (sq_i == 0) st <= S_FEAT;
                else sq_i <= sq_i - 1'b1;
            end

            // ---- 特征：l1/l2 -> 顺序除法（coh, gate）----
            S_FEAT: begin
                l1 <= l1_c; l2 <= l2_c;
                dir <= dir_c;
                get_cs(dir_c, ct, sn);
                div_n   <= (l1_c - l2_c) << 8;
                div_d   <= l1_c + l2_c;
                div_rem <= (l1_c - l2_c) << 8;
                div_q   <= 0; div_k <= 8; div_phase <= 0;
                st <= S_DIV;
            end
            S_DIV: begin
                if (div_rem >= ({16'd0, div_d} << div_k)) begin
                    div_rem <= div_rem - ({16'd0, div_d} << div_k);
                    div_q <= div_q | (9'd1 << div_k);
                end
                if (div_k == 0) st <= S_DIV_END;
                else div_k <= div_k - 1'b1;
            end
            S_DIV_END: begin
                if (div_phase == 0) begin
                    coh_r   <= div_q;
                    div_n   <= l1 << 8;
                    div_d   <= l1 + COH;
                    div_rem <= l1 << 8;
                    div_q   <= 0; div_k <= 8; div_phase <= 1;
                    st <= S_DIV;
                end else begin
                    gate_r <= div_q;
                    st <= S_FIN;
                end
            end
            S_FIN: begin
                aniso_q8 <= (coh_r * gate_r) >> 8;
                aniso_i2  = 16 + ((((coh_r * gate_r) >> 8) * SHARP * 16) >> 8);
                if (aniso_i2 < 16) aniso_i2 = 16;
                if (aniso_i2 > 64) aniso_i2 = 64;
                s_q4 <= aniso_i2[6:0];
                inv_s <= inv_lut(aniso_i2[6:0]);
                gi <= 0; samp_v <= 0;
                qr0<=0;qg0<=0;qb0<=0;qr1<=0;qg1<=0;qb1<=0;qr2<=0;qg2<=0;qb2<=0;qr3<=0;qg3<=0;qb3<=0;
                ql0<=0;ql1<=0;ql2<=0;ql3<=0;qs0<=0;qs1<=0;qs2<=0;qs3<=0;
                st <= S_GATHER;
            end

            // ---- 16 点 gather（读 1 拍，累加上一拍样本）----
            S_GATHER: begin
                // 累加上一拍样本
                if (samp_v) begin
                    begin : ac
                        reg [31:0] rr_,gg_,bb_,ll_,ll2;
                        rr_ = samp[23:16]; gg_ = samp[15:8]; bb_ = samp[7:0];
                        ll_ = (77*rr_ + 150*gg_ + 29*bb_) >> 8;
                        ll2 = 0; ll2 = ll_*ll_;
                        case (samp_q)
                            2'd0: begin qr0<=qr0+rr_; qg0<=qg0+gg_; qb0<=qb0+bb_; ql0<=ql0+ll_; qs0<=qs0+ll2; end
                            2'd1: begin qr1<=qr1+rr_; qg1<=qg1+gg_; qb1<=qb1+bb_; ql1<=ql1+ll_; qs1<=qs1+ll2; end
                            2'd2: begin qr2<=qr2+rr_; qg2<=qg2+gg_; qb2<=qb2+bb_; ql2<=ql2+ll_; qs2<=qs2+ll2; end
                            default: begin qr3<=qr3+rr_; qg3<=qg3+gg_; qb3<=qb3+bb_; ql3<=ql3+ll_; qs3<=qs3+ll2; end
                        endcase
                    end
                end
                // 读下一拍样本
                samp   <= samp_c;
                samp_q <= gq_c;
                if (gi == 15) begin
                    samp_v <= 1'b1;
                    st <= S_STAT;
                end else begin
                    samp_v <= 1'b1;
                    gi <= gi + 1'b1;
                end
            end

            // ---- 统计（含最后一拍样本累加后 1 拍）----
            S_STAT: begin
                if (samp_v) begin
                    begin : ac2
                        reg [31:0] rr_,gg_,bb_,ll_,ll2;
                        rr_ = samp[23:16]; gg_ = samp[15:8]; bb_ = samp[7:0];
                        ll_ = (77*rr_ + 150*gg_ + 29*bb_) >> 8;
                        ll2 = ll_*ll_;
                        case (samp_q)
                            2'd0: begin qr0<=qr0+rr_; qg0<=qg0+gg_; qb0<=qb0+bb_; ql0<=ql0+ll_; qs0<=qs0+ll2; end
                            2'd1: begin qr1<=qr1+rr_; qg1<=qg1+gg_; qb1<=qb1+bb_; ql1<=ql1+ll_; qs1<=qs1+ll2; end
                            2'd2: begin qr2<=qr2+rr_; qg2<=qg2+gg_; qb2<=qb2+bb_; ql2<=ql2+ll_; qs2<=qs2+ll2; end
                            default: begin qr3<=qr3+rr_; qg3<=qg3+gg_; qb3<=qb3+bb_; ql3<=ql3+ll_; qs3<=qs3+ll2; end
                        endcase
                    end
                end
                samp_v <= 0;
                st <= S_PICK;
            end

            // ---- 选象限（组合，严格 <，Q0..Q3）----
            S_PICK: begin
                begin : pk
                    reg [31:0] vv0,vv1,vv2,vv3;
                    integer bst;
                    vv0 = (qs0>>2) - ((ql0>>2)*(ql0>>2));
                    vv1 = (qs1>>2) - ((ql1>>2)*(ql1>>2));
                    vv2 = (qs2>>2) - ((ql2>>2)*(ql2>>2));
                    vv3 = (qs3>>2) - ((ql3>>2)*(ql3>>2));
                    bst = 0;
                    if (vv1 < vv0) bst = 1;
                    if (vv2 < ((bst==0)?vv0:vv1)) bst = 2;
                    if (vv3 < ((bst==0)?vv0:(bst==1)?vv1:vv2)) bst = 3;
                    case (bst)
                        0: o_px <= {qr0[9:2], qg0[9:2], qb0[9:2]};
                        1: o_px <= {qr1[9:2], qg1[9:2], qb1[9:2]};
                        2: o_px <= {qr2[9:2], qg2[9:2], qb2[9:2]};
                        default: o_px <= {qr3[9:2], qg3[9:2], qb3[9:2]};
                    endcase
                end
                st <= S_OUT;
            end

            S_OUT: begin
                o_de <= 1'b1;
                if (xcur == W2-1-MARGIN) st <= S_IDLE;
                else begin xcur <= xcur + 1'b1; st <= S_PIX_INIT; end
            end

            default: st <= S_IDLE;
            endcase
            end
        end
endmodule
