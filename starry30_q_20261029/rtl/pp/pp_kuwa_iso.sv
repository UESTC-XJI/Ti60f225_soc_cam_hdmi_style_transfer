// pp_kuwa_iso.sv —— Kuwahara 各向同性（D=2, r=1, 4 象限 x 4 点）
//   3 行 D=2 行缓冲；每像素 9 拍串行读 3x3；4 象限均值/亮度方差，取最小方差象限的均值。
//   Python golden: sim/tools/pp_kuwa_golden.py（同整数公式/同象限顺序）
`timescale 1ns/1ps
module pp_kuwa_iso #(parameter integer W2 = 32, parameter integer FSW = 64)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_px,
    output reg         o_de,
    output reg  [23:0] o_px
);
    // ---- 全分辨率坐标 -> D=2 ----
    reg [10:0] x; reg [9:0] y;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin x<=0; y<=0; end
        else if (i_vs) begin x<=0; y<=0; end
        else if (i_de) begin
            if (x == FSW-1) begin x<=0; y<=y+1'b1; end else x<=x+1'b1;
        end
    wire de2 = i_de && !x[0] && !y[0];
    wire [5:0] x2 = x[6:1];
    wire [5:0] y2 = y[6:1];

    // ---- 3 行行缓冲（同步读/写；一行一个 D=2 行）----
    reg [23:0] lb [0:3*W2-1];
    reg [1:0] slot;                 // y2 % 3
    wire [1:0] prev1 = (slot==0) ? 2'd2 : (slot==1) ? 2'd0 : 2'd1;
    wire [1:0] prev2 = (slot==0) ? 2'd1 : (slot==1) ? 2'd2 : 2'd0;
    always @(posedge clk) if (de2) lb[slot*W2 + x2] <= i_px;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) slot <= 0;
        else if (de2 && x2 == W2-1) slot <= (slot==2) ? 0 : slot+1'b1;

    // ---- 9 拍读窗口 + 4 象限选择 ----
    localparam S_IDLE=0, S_RD=1, S_CALC=2;
    reg [1:0] st; reg [3:0] ri;
    reg [5:0] cx, cy;
    reg [1:0] rs0, rs1, rs2;        // grid dy=0/1/2 的 row slot
    reg [23:0] gr [0:8];
    wire interior = de2 && (x2>=2) && (y2>=2);
    wire [1:0] gdx = (ri==0||ri==3||ri==6) ? 2'd0 : (ri==1||ri==4||ri==7) ? 2'd1 : 2'd2;
    wire [1:0] gdy = (ri<3) ? 2'd0 : (ri<6) ? 2'd1 : 2'd2;
    wire [1:0] gs  = (gdy==0) ? rs0 : (gdy==1) ? rs1 : rs2;
    wire [11:0] gaddr = gs*W2 + (cx - 6'd2 + gdx);

    // luma / 象限统计（组合）
    function [15:0] lum; input [23:0] p; begin lum = (77*p[23:16] + 150*p[15:8] + 29*p[7:0]) >> 8; end endfunction
    // 象限索引（3x3 展平）：q0:4,5,7,8  q1:3,4,6,7  q2:1,2,4,5  q3:0,1,3,4
    wire [23:0] q0a=gr[4], q0b=gr[5], q0c=gr[7], q0d=gr[8];
    wire [23:0] q1a=gr[3], q1b=gr[4], q1c=gr[6], q1d=gr[7];
    wire [23:0] q2a=gr[1], q2b=gr[2], q2c=gr[4], q2d=gr[5];
    wire [23:0] q3a=gr[0], q3b=gr[1], q3c=gr[3], q3d=gr[4];
    function [23:0] qmean; input [23:0] a,b,c,d;
        reg [15:0] sr,sg,sb;
        begin
            sr = a[23:16]+b[23:16]+c[23:16]+d[23:16];
            sg = a[15:8] +b[15:8] +c[15:8] +d[15:8];
            sb = a[7:0]  +b[7:0]  +c[7:0]  +d[7:0];
            qmean = {sr[9:2], sg[9:2], sb[9:2]};
        end endfunction
    function [31:0] qvar; input [23:0] a,b,c,d;
        reg [15:0] s; reg [31:0] s2;
        begin
            s  = lum(a)+lum(b)+lum(c)+lum(d);
            s2 = lum(a)*lum(a)+lum(b)*lum(b)+lum(c)*lum(c)+lum(d)*lum(d);
            qvar = (s2 >> 2) - ((s >> 2) * (s >> 2));
        end endfunction
    wire [31:0] v0=qvar(q0a,q0b,q0c,q0d), v1=qvar(q1a,q1b,q1c,q1d);
    wire [31:0] v2=qvar(q2a,q2b,q2c,q2d), v3=qvar(q3a,q3b,q3c,q3d);
    wire [31:0] v01 = (v1 < v0) ? v1 : v0;
    wire [31:0] v23 = (v3 < v2) ? v3 : v2;
    wire [31:0] vmin = (v23 < v01) ? v23 : v01;
    reg [23:0] qsel;
    always @* begin
        if      (v0 == vmin) qsel = qmean(q0a,q0b,q0c,q0d);
        else if (v1 == vmin) qsel = qmean(q1a,q1b,q1c,q1d);
        else if (v2 == vmin) qsel = qmean(q2a,q2b,q2c,q2d);
        else                 qsel = qmean(q3a,q3b,q3c,q3d);
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin st<=0; ri<=0; o_de<=0; o_px<=0; cx<=0; cy<=0; rs0<=0; rs1<=0; rs2<=0; end
        else begin
            o_de <= 0;
            if (i_vs) st <= S_IDLE;
            else case (st)
                S_IDLE: if (interior) begin
                    cx<=x2; cy<=y2; rs0<=prev2; rs1<=prev1; rs2<=slot; ri<=0; st<=S_RD;
                end
                S_RD: begin
                    gr[ri] <= lb[gaddr];
                    if (ri == 8) st <= S_CALC; else ri <= ri + 1'b1;
                end
                S_CALC: begin
                    o_px <= qsel; o_de <= 1'b1; st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
endmodule
