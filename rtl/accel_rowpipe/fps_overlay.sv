//============================================================================
// fps_overlay.sv —— LUT 版 FPS 叠加（0 RAM），替换原 osd_db/osd_font 文本栈
//
//   输入：单像素/拍的视频流（hdmi_tx_slow_clk，de 有效区 = 1280×720）
//   输出：在左图左上角画 "FPS xx"（5×7 字模 ×2 放大，白字黑底）
//
//   位置（de 坐标）：x 8..71，y 128..143（de 的 y=120 对应左图第 0 行）
//   字模：F / P / S / 0-9，5×7，逐像素组合逻辑（无 ROM）。
//   注意：i_fps 来自 core_clk（1Hz 级慢变量），这里两级同步后使用。
//============================================================================
`timescale 1ns / 1ps

module fps_overlay(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_enable,
    input  wire        i_vs,
    input  wire        i_hs,
    input  wire        i_de,
    input  wire [7:0]  i_r,
    input  wire [7:0]  i_g,
    input  wire [7:0]  i_b,
    input  wire [15:0] i_fps,
    output reg         o_vs,
    output reg         o_hs,
    output reg         o_de,
    output reg  [7:0]  o_r,
    output reg  [7:0]  o_g,
    output reg  [7:0]  o_b
);

    localparam integer TEX_X0 = 8;
    localparam integer TEX_Y0 = 128;
    localparam integer GW = 5, GH = 7, SCALE = 2;
    localparam integer BOX_W = 72;   // 覆盖 5 个字符 + 边框
    localparam integer BOX_H = GH*SCALE + 4;

    // de 坐标系
    reg [10:0] x;   // 0..1279
    reg [9:0]  y;   // 0..719
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x <= 0; y <= 0; end
        else if (i_vs) begin x <= 0; y <= 0; end
        else if (i_de) begin
            if (x == 11'd1279) begin x <= 0; y <= y + 1'b1; end
            else x <= x + 1'b1;
        end
    end

    (* async_reg="true" *) reg enable_meta, enable_sync;
    reg enable_frame;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin enable_meta<=1;enable_sync<=1;enable_frame<=1;end
        else begin
            enable_meta<=i_enable;enable_sync<=enable_meta;
            if(i_vs) enable_frame<=enable_sync;
        end
    end

    // fps 两级同步（慢变量；显示值最多晚 2 拍）
    reg [15:0] fps1, fps2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fps1 <= 0; fps2 <= 0; end
        else begin fps1 <= i_fps; fps2 <= fps1; end
    end
    wire [3:0] d1 = (fps2 / 10) % 10;   // 十位
    wire [3:0] d0 = fps2 % 10;          // 个位

    // 文本框内？
    wire in_box = enable_frame && i_de && (x >= TEX_X0) && (x < TEX_X0+BOX_W) &&
                           (y >= TEX_Y0) && (y < TEX_Y0+BOX_H);
    wire in_text = in_box && (x >= TEX_X0+2) && (y >= TEX_Y0+2) &&
                            (x < TEX_X0+2+5*12) && (y < TEX_Y0+2+GH*SCALE);

    wire [10:0] tx = (x - TEX_X0 - 2);
    wire [9:0]  ty = (y - TEX_Y0 - 2);
    wire [2:0]  ch = tx / (GW*SCALE + 2);       // 0..4: F,P,S,tens,ones
    wire [10:0] cx = tx % (GW*SCALE + 2);
    wire [9:0]  cy = ty;
    wire [3:0]  gx = cx[4:1];                   // /SCALE = /2, 0..5
    wire [3:0]  gy = cy[3:1];                   // /2, 0..7

    // Glyph ROM: 0=F,1=P,2=S, 3..12=digits 0..9.  128x5 bits = one BRAM.
    wire [3:0] glyph = (ch==3'd0)?4'd0 : (ch==3'd1)?4'd1 : (ch==3'd2)?4'd2 :
                       (ch==3'd3)?(4'd3+d1) : (4'd3+d0);
    wire [6:0] font_addr = {glyph, gy[2:0]};
    (* ram_style="block" *) reg [4:0] font_rom [0:127];
    initial $readmemh("assets/fps_font.hex", font_rom);
    reg [4:0] font_q;

    reg s_vs,s_hs,s_de;reg [7:0] s_r,s_g,s_b;
    reg s_in_box,s_in_text,s_gx_ok,s_gy_ok;reg [3:0] s_gx;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            font_q<=5'd0;s_vs<=0;s_hs<=0;s_de<=0;s_r<=0;s_g<=0;s_b<=0;
            s_in_box<=0;s_in_text<=0;s_gx_ok<=0;s_gy_ok<=0;s_gx<=0;
        end else begin
            font_q <= font_rom[font_addr];
            s_vs<=i_vs;s_hs<=i_hs;s_de<=i_de;
            s_r<=i_r;s_g<=i_g;s_b<=i_b;
            s_in_box<=in_box;s_in_text<=in_text;
            s_gx_ok<=(gx<GW);s_gy_ok<=(gy<GH);s_gx<=gx;
        end
    end

    wire [2:0] s_col = (s_gx<4'd5)?s_gx[2:0]:3'd0;
    wire px_lit = s_in_text && s_gx_ok && s_gy_ok && font_q[4-s_col];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_vs<=0; o_hs<=0; o_de<=0; o_r<=0; o_g<=0; o_b<=0;
        end else begin
            o_vs<=s_vs; o_hs<=s_hs; o_de<=s_de;
            if (s_in_box) begin
                if (px_lit) begin o_r<=8'hff; o_g<=8'hff; o_b<=8'hff; end
                else        begin o_r<=8'h00; o_g<=8'h00; o_b<=8'h00; end
            end else begin
                o_r<=s_r; o_g<=s_g; o_b<=s_b;
            end
        end
    end

    // coef port unused
    wire _unused = i_fps[15];
endmodule
