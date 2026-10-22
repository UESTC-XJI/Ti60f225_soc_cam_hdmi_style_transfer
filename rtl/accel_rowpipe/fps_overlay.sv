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

    // fps 两级同步（慢变量；显示值最多晚 2 拍）
    reg [15:0] fps1, fps2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fps1 <= 0; fps2 <= 0; end
        else begin fps1 <= i_fps; fps2 <= fps1; end
    end
    wire [3:0] d1 = (fps2 / 10) % 10;   // 十位
    wire [3:0] d0 = fps2 % 10;          // 个位

    // 文本框内？
    wire in_box = i_de && (x >= TEX_X0) && (x < TEX_X0+BOX_W) &&
                           (y >= TEX_Y0) && (y < TEX_Y0+BOX_H);
    wire in_text = in_box && (x >= TEX_X0+2) && (y >= TEX_Y0+2) &&
                            (x < TEX_X0+2+5*12) && (y < TEX_Y0+2+GH*SCALE);

    wire [10:0] tx = (x - TEX_X0 - 2);
    wire [9:0]  ty = (y - TEX_Y0 - 2);
    wire [2:0]  ch = tx / (GW*SCALE + 2);       // 0..4：F,P,S,十位,个位
    wire [10:0] cx = tx % (GW*SCALE + 2);
    wire [9:0]  cy = ty;
    wire [3:0]  gx = cx[4:1];                   // /SCALE = /2，0..5
    wire [3:0]  gy = cy[3:1];                   // /2，0..7

    // 5×7 字模（行 0..6，列 0..4，MSB=左）
    function automatic lit;
        input [2:0] c;
        input [2:0] col;
        input [2:0] row;
        reg [4:0] r0,r1,r2,r3,r4,r5,r6;
        begin
            r0=0; r1=0; r2=0; r3=0; r4=0; r5=0; r6=0;
            case (c)
            3'd0: begin // F
                r0=5'b11111; r1=5'b10000; r2=5'b10000; r3=5'b11110;
                r4=5'b10000; r5=5'b10000; r6=5'b10000;
            end
            3'd1: begin // P
                r0=5'b11110; r1=5'b10001; r2=5'b10001; r3=5'b11110;
                r4=5'b10000; r5=5'b10000; r6=5'b10000;
            end
            3'd2: begin // S
                r0=5'b01111; r1=5'b10000; r2=5'b10000; r3=5'b01110;
                r4=5'b00001; r5=5'b00001; r6=5'b11110;
            end
            3'd3: begin // tens
                case (d1)
                4'd0: begin r0=5'b01110;r1=5'b10001;r2=5'b10011;r3=5'b10101;r4=5'b11001;r5=5'b10001;r6=5'b01110; end
                4'd1: begin r0=5'b00100;r1=5'b01100;r2=5'b00100;r3=5'b00100;r4=5'b00100;r5=5'b00100;r6=5'b01110; end
                4'd2: begin r0=5'b01110;r1=5'b10001;r2=5'b00001;r3=5'b00010;r4=5'b00100;r5=5'b01000;r6=5'b11111; end
                4'd3: begin r0=5'b11111;r1=5'b00010;r2=5'b00100;r3=5'b00010;r4=5'b00001;r5=5'b10001;r6=5'b01110; end
                4'd4: begin r0=5'b00010;r1=5'b00110;r2=5'b01010;r3=5'b10010;r4=5'b11111;r5=5'b00010;r6=5'b00010; end
                4'd5: begin r0=5'b11111;r1=5'b10000;r2=5'b11110;r3=5'b00001;r4=5'b00001;r5=5'b10001;r6=5'b01110; end
                4'd6: begin r0=5'b01110;r1=5'b10000;r2=5'b11110;r3=5'b10001;r4=5'b10001;r5=5'b10001;r6=5'b01110; end
                4'd7: begin r0=5'b11111;r1=5'b00001;r2=5'b00010;r3=5'b00100;r4=5'b01000;r5=5'b01000;r6=5'b01000; end
                4'd8: begin r0=5'b01110;r1=5'b10001;r2=5'b10001;r3=5'b01110;r4=5'b10001;r5=5'b10001;r6=5'b01110; end
                default: begin r0=5'b01110;r1=5'b10001;r2=5'b10001;r3=5'b01111;r4=5'b00001;r5=5'b00001;r6=5'b01110; end
                endcase
            end
            3'd4: begin // ones
                case (d0)
                4'd0: begin r0=5'b01110;r1=5'b10001;r2=5'b10011;r3=5'b10101;r4=5'b11001;r5=5'b10001;r6=5'b01110; end
                4'd1: begin r0=5'b00100;r1=5'b01100;r2=5'b00100;r3=5'b00100;r4=5'b00100;r5=5'b00100;r6=5'b01110; end
                4'd2: begin r0=5'b01110;r1=5'b10001;r2=5'b00001;r3=5'b00010;r4=5'b00100;r5=5'b01000;r6=5'b11111; end
                4'd3: begin r0=5'b11111;r1=5'b00010;r2=5'b00100;r3=5'b00010;r4=5'b00001;r5=5'b10001;r6=5'b01110; end
                4'd4: begin r0=5'b00010;r1=5'b00110;r2=5'b01010;r3=5'b10010;r4=5'b11111;r5=5'b00010;r6=5'b00010; end
                4'd5: begin r0=5'b11111;r1=5'b10000;r2=5'b11110;r3=5'b00001;r4=5'b00001;r5=5'b10001;r6=5'b01110; end
                4'd6: begin r0=5'b01110;r1=5'b10000;r2=5'b11110;r3=5'b10001;r4=5'b10001;r5=5'b10001;r6=5'b01110; end
                4'd7: begin r0=5'b11111;r1=5'b00001;r2=5'b00010;r3=5'b00100;r4=5'b01000;r5=5'b01000;r6=5'b01000; end
                4'd8: begin r0=5'b01110;r1=5'b10001;r2=5'b10001;r3=5'b01110;r4=5'b10001;r5=5'b10001;r6=5'b01110; end
                default: begin r0=5'b01110;r1=5'b10001;r2=5'b10001;r3=5'b01111;r4=5'b00001;r5=5'b00001;r6=5'b01110; end
                endcase
            end
            default: ;
            endcase
            case (row)
            3'd0: lit = r0[4-col];
            3'd1: lit = r1[4-col];
            3'd2: lit = r2[4-col];
            3'd3: lit = r3[4-col];
            3'd4: lit = r4[4-col];
            3'd5: lit = r5[4-col];
            default: lit = r6[4-col];
            endcase
        end
    endfunction

    wire px_lit = in_text && (gx < GW) && (gy < GH) && lit(ch, gx, gy);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_vs<=0; o_hs<=0; o_de<=0; o_r<=0; o_g<=0; o_b<=0;
        end else begin
            o_vs <= i_vs; o_hs <= i_hs; o_de <= i_de;
            if (in_box) begin
                if (px_lit) begin o_r<=8'hff; o_g<=8'hff; o_b<=8'hff; end
                else        begin o_r<=8'h00; o_g<=8'h00; o_b<=8'h00; end
            end else begin
                o_r <= i_r; o_g <= i_g; o_b <= i_b;
            end
        end
    end

    // coef 口不使用
    wire _unused = i_fps[15];
endmodule
