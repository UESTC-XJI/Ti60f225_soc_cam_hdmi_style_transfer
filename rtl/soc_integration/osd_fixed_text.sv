// Fixed HELLO SOC renderer for the first integration milestone.
// All video signals pass through the same one-cycle registered stage.
module osd_fixed_text #(
  parameter integer FRAME_WIDTH=1280,
  parameter integer FRAME_HEIGHT=720,
  parameter integer BASE_X=16,
  parameter integer BASE_Y=16,
  parameter integer TEXT_LEN=9,
  parameter logic [23:0] FG_RGB=24'h20_FF_40
)(
  input  logic clk,
  input  logic rst_n,
  input  logic i_vs,
  input  logic i_hs,
  input  logic i_de,
  input  logic [7:0] i_r,
  input  logic [7:0] i_g,
  input  logic [7:0] i_b,
  input  logic i_enable,
  output logic o_vs,
  output logic o_hs,
  output logic o_de,
  output logic [7:0] o_r,
  output logic [7:0] o_g,
  output logic [7:0] o_b,
  output logic o_char_pixel
);
  logic [11:0] x;
  logic [11:0] y;
  logic vs_d, de_d;
  logic [7:0] ch;
  logic [3:0] glyph_row;
  logic [7:0] glyph_bits;
  logic in_text;
  logic draw;

  function automatic [7:0] text_char(input integer idx);
    case (idx)
      0: text_char="H"; 1: text_char="E"; 2: text_char="L";
      3: text_char="L"; 4: text_char="O"; 5: text_char=" ";
      6: text_char="S"; 7: text_char="O"; 8: text_char="C";
      default: text_char=" ";
    endcase
  endfunction

  always_comb begin
    ch = " ";
    if (x >= BASE_X && x < BASE_X + TEXT_LEN*8 &&
        y >= BASE_Y && y < BASE_Y + 16) begin
      ch = text_char((x-BASE_X) >> 3);
      glyph_row = y-BASE_Y;
      in_text = 1'b1;
    end else begin
      glyph_row = 4'd0;
      in_text = 1'b0;
    end
    // MSB is the left-most pixel of the 8-pixel glyph cell.
    draw = i_enable && i_de && in_text && glyph_bits[7-((x-BASE_X)&7)];
  end

  osd_font8x16 font(.ch(ch),.row(glyph_row),.bits(glyph_bits));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x <= 0; y <= 0; vs_d <= 0; de_d <= 0;
      o_vs <= 0; o_hs <= 0; o_de <= 0;
      o_r <= 0; o_g <= 0; o_b <= 0; o_char_pixel <= 0;
    end else begin
      o_vs <= i_vs; o_hs <= i_hs; o_de <= i_de;
      o_char_pixel <= draw;
      if (draw) begin
        o_r <= FG_RGB[23:16]; o_g <= FG_RGB[15:8]; o_b <= FG_RGB[7:0];
      end else begin
        o_r <= i_r; o_g <= i_g; o_b <= i_b;
      end
      vs_d <= i_vs; de_d <= i_de;
      // CVO uses active-high VS.  Coordinates restart at the beginning of
      // the vertical sync interval and advance on valid pixels/line ends.
      if (i_vs && !vs_d) begin
        x <= 0; y <= 0;
      end else if (i_de) begin
        x <= x + 1'b1;
      end else if (de_d) begin
        x <= 0; y <= y + 1'b1;
      end
    end
  end
endmodule

