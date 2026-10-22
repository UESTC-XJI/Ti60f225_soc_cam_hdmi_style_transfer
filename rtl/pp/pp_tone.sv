// pp_tone.sv —— 后处理第一段（真实实现，逐像素，无行缓冲）
//   顺序：BT.601 Y -> 饱和 -> 对比 -> 抬黑 -> 纸纹(LFSR) -> 颗粒(LFSR)
//   整数固定参数；Python golden: sim/tools/pp_tone_golden.py（同公式/同 LFSR）
`timescale 1ns/1ps
module pp_tone(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_vs,
    input  wire        i_de,
    input  wire [23:0] i_px,
    output reg         o_de,
    output reg  [23:0] o_px
);
    localparam integer SAT   = 282;  // 1.10*256
    localparam integer CON   = 384;  // 1.50*256
    localparam integer PIVOT = 111;  // 0.434*255
    localparam integer LIFT  = 44;   // 0.171*256
    localparam integer PAPER = 51;   // 0.05*1024
    localparam integer GRAN  = 307;  // 0.30*1024

    // ---- LFSR（纸纹/颗粒）----
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) lfsr <= 16'hACE1;
        else if (i_vs) lfsr <= 16'hACE1;   // 每帧复位：纸纹/颗粒帧间静态，可逐位回归
        else if (i_de) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    // ---- stage0 ----
    reg de0;
    reg [7:0] r0,g0,b0,p0,q0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin de0<=0; r0<=0; g0<=0; b0<=0; p0<=0; q0<=0; end
        else begin
            de0 <= i_de;
            if (i_de) begin
                r0 <= i_px[23:16]; g0 <= i_px[15:8]; b0 <= i_px[7:0];
                p0 <= lfsr[7:0];  q0 <= lfsr[15:8];
            end
        end
    wire [16:0] ysum = 17'd77 * r0 + 17'd150 * g0 + 17'd29 * b0;
    wire [15:0] ycomb = ysum[16:8];
    wire signed [15:0] ycomb_s = ycomb;

    // ---- stage1: Y + 饱和 ----
    reg de1; reg signed [15:0] y1, rs, gs, bs;
    reg [7:0] p1,q1;
    always @(posedge clk)
        if (de0) begin
            y1 <= ycomb; p1 <= p0; q1 <= q0;
            rs <= $signed({8'd0,r0}) + ((($signed({8'd0,r0}) - ycomb_s) * SAT) >>> 8);
            gs <= $signed({8'd0,g0}) + ((($signed({8'd0,g0}) - ycomb_s) * SAT) >>> 8);
            bs <= $signed({8'd0,b0}) + ((($signed({8'd0,b0}) - ycomb_s) * SAT) >>> 8);
        end
    always @(posedge clk or negedge rst_n)
        if (!rst_n) de1 <= 0; else de1 <= de0;

    // ---- stage2: 对比 ----
    reg de2; reg signed [15:0] y2, rc, gc, bc;
    reg [7:0] p2,q2;
    wire signed [15:0] y2c = ((y1 - PIVOT) * CON >>> 8) + PIVOT;
    always @(posedge clk)
        if (de1) begin
            y2 <= y2c; p2 <= p1; q2 <= q1;
            rc <= rs + (y2c - y1);
            gc <= gs + (y2c - y1);
            bc <= bs + (y2c - y1);
        end
    always @(posedge clk or negedge rst_n)
        if (!rst_n) de2 <= 0; else de2 <= de1;

    // ---- stage3: 抬黑 + 纸纹 + 颗粒 + clamp（de2 同拍输出）----
    wire signed [15:0] y3c = y2 + ((LIFT * (16'sd255 - y2)) >>> 8);
    wire signed [15:0] rl = rc + (y3c - y2);
    wire signed [15:0] gl = gc + (y3c - y2);
    wire signed [15:0] bl = bc + (y3c - y2);
    wire signed [15:0] pd = (($signed({8'd0,p2}) - 16'sd128) * PAPER) >>> 10;
    wire signed [15:0] qd = (($signed({8'd0,q2}) - 16'sd128) * GRAN)  >>> 10;
    wire signed [15:0] rf = rl + pd + qd;
    wire signed [15:0] gf = gl + pd + qd;
    wire signed [15:0] bf = bl + pd + qd;
    wire [7:0] rcl = (rf < 0) ? 8'd0 : (rf > 255) ? 8'd255 : rf[7:0];
    wire [7:0] gcl = (gf < 0) ? 8'd0 : (gf > 255) ? 8'd255 : gf[7:0];
    wire [7:0] bcl = (bf < 0) ? 8'd0 : (bf > 255) ? 8'd255 : bf[7:0];
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin o_de<=0; o_px<=0; end
        else begin
            o_de <= de2;
            if (de2) o_px <= {rcl,gcl,bcl};
        end
endmodule
