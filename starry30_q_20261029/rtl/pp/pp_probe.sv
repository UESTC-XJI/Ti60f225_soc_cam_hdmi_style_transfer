// pp_probe.sv —— 后处理 **资源骨架**（结构/位宽/行缓冲代表，不保证算法逐位）
// 目的：map/PnR 量 Kuwahara aniso + 水彩算子的 ΔXLR/ΔRAM/ΔDSP。
// 输入：显示像素流（74.25MHz）；输出：一个像素（顶层只做 1 点 XOR 保留逻辑）。
`timescale 1ns/1ps
module pp_probe(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_de,
    input  wire [23:0] i_px,
    output reg  [23:0] o_px
);
    // ---- 坐标 / D=2 取样 ----
    reg [10:0] x; reg [9:0] y;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin x <= 0; y <= 0; end
        else if (i_de) begin
            if (x == 11'd1279) begin x <= 0; y <= (y == 10'd719) ? 10'd0 : y + 1'b1; end
            else x <= x + 1'b1;
        end
    wire de2 = i_de && !x[0] && !y[0];
    wire [9:0] x2 = x[10:1];

    // ---- 行环计数（5 行张量 / 3 行 RGB）----
    reg [2:0] r5; reg [1:0] r3;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin r5 <= 0; r3 <= 0; end
        else if (i_de && x == 11'd1279) begin
            r5 <= (r5 == 3'd4) ? 3'd0 : r5 + 1'b1;
            r3 <= (r3 == 2'd2) ? 2'd0 : r3 + 1'b1;
        end

    // ---- 行缓冲（同步读，推断 RAM）----
    //   gbuf 5x320x32：gx/gy（16+16）
    //   rbuf 3x320x24：RGB
    //   ubuf 5x640x8 ：亮度（guide / 纸纹）
    reg [31:0] gbuf [0:1599];
    reg [23:0] rbuf [0:959];
    reg [7:0]  ubuf [0:3199];
    reg [11:0] ga, ra, ua;
    reg [31:0] g_q; reg [23:0] r_q; reg [7:0] u_q;
    reg [7:0]  u_prev;
    wire signed [8:0] gx = $signed({1'b0,u_q}) - $signed({1'b0,u_prev});
    wire signed [8:0] gy = $signed({1'b0,u_q}) - $signed({1'b0,u_prev});
    always @(posedge clk) begin
        ga <= r5 * 12'd320 + x2;
        ra <= r3 * 12'd320 + x2;
        ua <= r5 * 12'd640 + {1'b0, x[10:1]};
        g_q <= gbuf[ga];
        r_q <= rbuf[ra];
        u_q <= ubuf[ua];
        u_prev <= u_q;
        if (de2) gbuf[ga] <= {gx, gy, 14'd0};
        if (de2) rbuf[ra] <= i_px;
        if (i_de) ubuf[ua] <= i_px[15:8];
    end

    // ---- 结构张量 + 特征分解（近似 LUT，量的是乘法/加法/选择）----
    reg [31:0] jxx, jxy, jyy, tmp, l1, l2, aniso, srat;
    reg [31:0] sq_lut;
    always @(posedge clk) begin
        jxx <= g_q[31:16] * g_q[31:16];
        jxy <= g_q[31:16] * g_q[15:0];
        jyy <= g_q[15:0]  * g_q[15:0];
        tmp <= (jxx - jyy) * (jxx - jyy) + (jxy << 2) * jxy;
        l1  <= jxx + jyy + sq_lut;
        l2  <= jxx + jyy - sq_lut;
        srat <= (l1 > 32'd1) ? ((l1 - l2) << 8) / (l1 + l2) : 32'd0;
        aniso <= (srat * l1) / (l1 + 32'd16);
    end
    always @* begin
        case (tmp[31:27])
            5'd0: sq_lut = 32'd0;   5'd1: sq_lut = 32'd256;  5'd2: sq_lut = 32'd512;
            5'd3: sq_lut = 32'd768; 5'd4: sq_lut = 32'd1024; 5'd5: sq_lut = 32'd1280;
            5'd6: sq_lut = 32'd1536;5'd7: sq_lut = 32'd1792; 5'd8: sq_lut = 32'd2048;
            5'd9: sq_lut = 32'd2304;5'd10: sq_lut = 32'd2560;5'd11: sq_lut = 32'd2816;
            5'd12: sq_lut = 32'd3072;5'd13: sq_lut = 32'd3328;5'd14: sq_lut = 32'd3584;
            5'd15: sq_lut = 32'd3840;5'd16: sq_lut = 32'd4096;5'd17: sq_lut = 32'd4352;
            5'd18: sq_lut = 32'd4608;5'd19: sq_lut = 32'd4864;5'd20: sq_lut = 32'd5120;
            5'd21: sq_lut = 32'd5376;5'd22: sq_lut = 32'd5632;5'd23: sq_lut = 32'd5888;
            5'd24: sq_lut = 32'd6144;5'd25: sq_lut = 32'd6400;5'd26: sq_lut = 32'd6656;
            5'd27: sq_lut = 32'd6912;5'd28: sq_lut = 32'd7168;5'd29: sq_lut = 32'd7424;
            5'd30: sq_lut = 32'd7680; default: sq_lut = 32'd7936;
        endcase
    end

    // ---- 12 方向 LUT + 16 点 gather（4 象限 x 4 采样）----
    reg [4:0] ang; reg [7:0] ox, oy;
    always @* begin
        case (ang[3:0])
            4'd0:  begin ox = 8'd3;  oy = 8'd0;  end
            4'd1:  begin ox = 8'd3;  oy = 8'd1;  end
            4'd2:  begin ox = 8'd2;  oy = 8'd2;  end
            4'd3:  begin ox = 8'd1;  oy = 8'd3;  end
            4'd4:  begin ox = 8'd0;  oy = 8'd3;  end
            4'd5:  begin ox = 8'd1;  oy = 8'd3;  end
            4'd6:  begin ox = 8'd2;  oy = 8'd2;  end
            4'd7:  begin ox = 8'd3;  oy = 8'd1;  end
            4'd8:  begin ox = 8'd3;  oy = 8'd0;  end
            4'd9:  begin ox = 8'd3;  oy = 8'd1;  end
            4'd10: begin ox = 8'd2;  oy = 8'd2;  end
            default: begin ox = 8'd1; oy = 8'd3;  end
        endcase
    end
    reg [3:0] smp; // 0..15 sample index
    always @(posedge clk or negedge rst_n)
        if (!rst_n) smp <= 0;
        else if (i_de && x == 11'd1279 && y == 10'd719) smp <= 0;
        else if (i_de) smp <= (smp == 4'd15) ? 4'd0 : smp + 1'b1;
    wire [3:0] quad = smp[3:2];
    wire [1:0] sub  = smp[1:0];
    wire [9:0] sx = (x2 + ((sub[0]? ox:8'd0))) & 10'd319;
    wire [9:0] sy = ((r3 + (sub[1]? oy:8'd0)) % 3);
    wire [11:0] saddr = sx + sy * 12'd320;
    reg [23:0] s_q;
    always @(posedge clk) s_q <= rbuf[saddr];
    reg [31:0] qsum0,qsum1,qsum2,qsum3, qsq0,qsq1,qsq2,qsq3;
    wire [31:0] vr = s_q[23:16]; wire [31:0] vg = s_q[15:8]; wire [31:0] vb = s_q[7:0];
    always @(posedge clk) begin
        case (quad)
            2'd0: begin qsum0 <= qsum0 + vr + vg + vb; qsq0 <= qsq0 + vr*vr + vg*vg + vb*vb; end
            2'd1: begin qsum1 <= qsum1 + vr + vg + vb; qsq1 <= qsq1 + vr*vr + vg*vg + vb*vb; end
            2'd2: begin qsum2 <= qsum2 + vr + vg + vb; qsq2 <= qsq2 + vr*vr + vg*vg + vb*vb; end
            default: begin qsum3 <= qsum3 + vr + vg + vb; qsq3 <= qsq3 + vr*vr + vg*vg + vb*vb; end
        endcase
    end
    reg [31:0] best; reg [1:0] bestq;
    always @(posedge clk) begin
        best <= qsq0; bestq <= 2'd0;
        if (qsq1 < best) begin best <= qsq1; bestq <= 2'd1; end
        if (qsq2 < best) begin best <= qsq2; bestq <= 2'd2; end
        if (qsq3 < best) begin best <= qsq3; bestq <= 2'd3; end
    end

    // ---- guide / 水彩算术（纸纹 LFSR、edge、granule、tooth、humidity、deposit）----
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) lfsr <= 16'hACE1;
        else if (i_de) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire [7:0] paper = lfsr[7:0];
    reg [31:0] edg, gran, tooth, humid, dep;
    always @(posedge clk) begin
        edg   <= (g_q[31:16] > 32'd16) ? 32'd255 : 32'd0;
        gran  <= (qsum0[23:0] * paper) >> 8;
        tooth <= (u_q * paper) >> 8;
        humid <= (u_q * gran) >> 8;
        dep   <= (edg * humid) >> 8;
    end

    // ---- 输出（顶层只取 1 点，保证整条链被保留）----
    always @(posedge clk or negedge rst_n)
        if (!rst_n) o_px <= 24'd0;
        else o_px <= { (qsum0[23:16] + gran[7:0] + tooth[7:0]),
                       (qsum1[23:16] + humid[7:0] + dep[7:0]),
                       (qsum2[23:16] + edg[7:0] + paper) };
endmodule
