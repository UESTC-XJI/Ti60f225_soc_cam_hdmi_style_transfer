// pp_wc_finish.sv —— 水彩收尾（3a guide + 3b 精简纸纹/颗粒）整数实现
//   guide: grad=|dY/dx|+|dY/dy| -> 5x5 盒均值 e=(sum*82)>>11
//          t=clamp((e-20)*256/62,0,256)  w=t^2(3-2t)
//          blend=(ku*(256-w)+pre*w)>>8
//   paper/granule/tooth: LFSR 每输出像素推进；零均值乘性调制（不整体压暗）
//   省：humidity / deposit / 边缘积色（v1，见 PP_RTL_SPEC §9）
//   行批处理：输入行 r 完成 -> 输出行 y=r-2（grad 窗口 y±2 = r-4..r 已齐）。
//   golden: sim/tools/pp_wc_finish_golden.py（同公式/同 LFSR）
`timescale 1ns/1ps
module pp_wc_finish #(
    parameter integer W  = 64,
    parameter integer H  = 64
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_pre,
    input  wire [23:0] i_ku,
    output reg         o_de,
    output reg  [23:0] o_px
);
    localparam integer XW = (W > 2) ? $clog2(W) : 1;
    localparam integer YW = (H > 2) ? $clog2(H) : 1;

    reg [XW-1:0] x;
    reg [YW-1:0] y;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin x <= 0; y <= 0; end
        else if (i_vs) begin x <= 0; y <= 0; end
        else if (i_de) begin
            if (x == W-1) begin x <= 0; y <= (y == H-1) ? 0 : y + 1'b1; end
            else x <= x + 1'b1;
        end

    function [3:0] mod5; input [YW:0] v; reg [31:0] q; begin q=(v*32'd205)>>10; mod5 = v - q*5; end endfunction
    function [1:0] mod3; input [YW:0] v; reg [31:0] q; begin q=(v*32'd171)>>9; mod3 = v - q*3; end endfunction

    // ---- 缓冲 ----
    reg [8:0]  gring [0:5*W-1];     // grad 5 行 x 9b
    reg [23:0] pring [0:3*W-1];     // pre 3 行
    reg [23:0] kring [0:3*W-1];     // ku  3 行
    reg [7:0]  yrow0 [0:W-1];
    reg [7:0]  yrow1 [0:W-1];
    reg        parity;              // 0: prev=yrow0 cur=yrow1

    reg [7:0]  yprev_px;
    reg [YW-1:0] last_row;
    reg        row_pulse;
    reg        ovf;

    wire [7:0] ycur_px = (77*i_pre[23:16] + 150*i_pre[15:8] + 29*i_pre[7:0]) >> 8;
    wire [7:0] yrow_prev = parity ? yrow1[x] : yrow0[x];
    wire [8:0] gx_w = (x == 0) ? 9'd0 : ((ycur_px > yprev_px) ? (ycur_px - yprev_px) : (yprev_px - ycur_px));
    wire [8:0] gy_w = (y == 0) ? 9'd0 : ((ycur_px > yrow_prev) ? (ycur_px - yrow_prev) : (yrow_prev - ycur_px));
    wire [9:0] grad_w = gx_w + gy_w;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            last_row <= 0; row_pulse <= 0; parity <= 0; yprev_px <= 0;
        end else begin
            row_pulse <= 0;
            if (i_vs) begin
                last_row <= 0; parity <= 0; yprev_px <= 0;
            end else if (i_de) begin
                yprev_px <= ycur_px;
                gring[mod5(y)*W + x] <= grad_w[8:0];
                pring[mod3(y)*W + x] <= i_pre;
                kring[mod3(y)*W + x] <= i_ku;
                if (parity) yrow0[x] <= ycur_px; else yrow1[x] <= ycur_px;
                if (x == W-1) begin
                    last_row  <= y;
                    parity    <= ~parity;
                    row_pulse <= 1'b1;
                end
            end
        end

    // ---- LFSR（每个输出像素推进；每帧 VS 复位）----
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) lfsr <= 16'hACE1;
        else if (i_vs) lfsr <= 16'hACE1;
        else if (o_de) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    // blend 单通道（显式 32 位，避免乘法截断）
    function [7:0] blend_ch; input [7:0] k; input [7:0] p; input [8:0] w;
        reg [31:0] t;
        begin t = k*(256 - w) + p*w; blend_ch = t >> 8; end
    endfunction

    // guide 权重（整数 smoothstep）
    function [8:0] smooth_w; input [9:0] e;
        reg [31:0] t, tt;
        begin
            if (e <= 10'd20) smooth_w = 9'd0;
            else if (e >= 10'd82) smooth_w = 9'd256;
            else begin
                t = ((e - 10'd20) * 32'd256) / 32'd62;
                if (t > 32'd256) t = 32'd256;
                tt = (t*t) >> 8;
                smooth_w = (tt * (32'd768 - 2*t)) >> 8;
            end
        end
    endfunction

    // ---- 主处理：行批 ----
    localparam S_IDLE=0, S_PROC=1;
    reg st;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) ovf <= 0;
        else if (i_vs) ovf <= 0;
        else if (row_pulse && st != S_IDLE) ovf <= 1;   // 处理跟不上行率 => 行环被覆盖
    reg [YW-1:0] r, ycur;
    reg [XW-1:0] xcur;
    reg [2:0] tdy, tdx;
    reg [4:0] tcnt;
    reg [13:0] gsum;
    reg [8:0] wgt;
    reg [8:0] t_q8;
    integer ty, tx;
    reg [8:0] gv;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= S_IDLE; o_de <= 0; o_px <= 0;
            r <= 0; ycur <= 0; xcur <= 0; tdy <= 0; tdx <= 0; tcnt <= 0;
            gsum <= 0; wgt <= 0; t_q8 <= 0;
        end else begin
            o_de <= 1'b0;
            if (i_vs) st <= S_IDLE;
            else case (st)
            S_IDLE: begin
                if (row_pulse) begin
                    r <= last_row;
                    if (last_row >= 4) begin
                        ycur <= last_row - 2;
                        xcur <= 0;
                        tdy <= 0; tdx <= 0; tcnt <= 0; gsum <= 0;
                        st <= S_PROC;
                    end
                end
            end
            S_PROC: begin
                ty = ycur + tdy - 2;
                tx = xcur + tdx - 2;
                if (ty < 0) ty = 0; if (ty > H-1) ty = H-1;
                if (tx < 0) tx = 0; if (tx > W-1) tx = W-1;
                gv = gring[mod5(ty)*W + tx];
                gsum <= gsum + gv;
                if (tcnt == 24) begin
                    begin : outp
                        reg [13:0] e5;
                        reg [8:0] ww;
                        reg [23:0] pre_px, ku_px;
                        reg [7:0] blr, blg, blb, yb, p;
                        reg [8:0] mid, hi, wg, wt, wsum;
                        reg signed [9:0] mt;
                        reg signed [31:0] mtmp;
                        reg [9:0] mod;
                        reg [31:0] vout;
                        reg [31:0] etmp, wtmp;
                        etmp = (gsum + gv) * 32'd82;
                        e5 = etmp >> 11;
                        ww = smooth_w(e5);
                        pre_px = pring[mod3(ycur)*W + xcur];
                        ku_px  = kring[mod3(ycur)*W + xcur];
                        blr = blend_ch(ku_px[23:16], pre_px[23:16], ww);
                        blg = blend_ch(ku_px[15:8],  pre_px[15:8],  ww);
                        blb = blend_ch(ku_px[7:0],   pre_px[7:0],   ww);
                        yb = (77*blr + 150*blg + 29*blb) >> 8;
                        p  = lfsr[7:0];
                        mid = (4*yb*(255-yb)) >> 8;
                        if (yb > 8'd184) begin
                            hi = ((yb - 8'd184) * 32'd256) / 32'd71;
                            if (hi > 9'd256) hi = 9'd256;
                        end else hi = 0;
                        wg = (32'd77 * mid) >> 8;
                        wt = (32'd38 * (32'd90 + ((32'd166 * hi) >> 8))) >> 8;
                        wsum = wg + wt;
                        mt = $signed({1'b0,p}) - 10'sd128;
                        mtmp = $signed({1'b0,wsum}) * mt;
                        mod = 10'd256 - (mtmp >>> 8);
                        vout = blr * mod;
                        o_px[23:16] <= (vout >> 8 > 255) ? 8'd255 : vout[15:8];
                        vout = blg * mod;
                        o_px[15:8]  <= (vout >> 8 > 255) ? 8'd255 : vout[15:8];
                        vout = blb * mod;
                        o_px[7:0]   <= (vout >> 8 > 255) ? 8'd255 : vout[15:8];
                    end
                    o_de <= 1'b1;
                    tcnt <= 0; gsum <= 0; tdy <= 0; tdx <= 0;
                    if (xcur == W-1) st <= S_IDLE;
                    else xcur <= xcur + 1'b1;
                end else begin
                    tcnt <= tcnt + 1'b1;
                    if (tdx == 4) begin tdx <= 0; tdy <= tdy + 1'b1; end
                    else tdx <= tdx + 1'b1;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
endmodule
