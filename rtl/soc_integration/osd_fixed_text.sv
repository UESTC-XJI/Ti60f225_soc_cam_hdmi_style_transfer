// Fixed text compositor.  Coordinates advance only on active pixels and are
// reset at the first line after VS.  The synchronous 8x16 ROM adds one cycle;
// RGB, DE, HS and VS use the same two-stage pipeline as the glyph lookup.
module osd_fixed_text #(
  parameter integer FRAME_WIDTH=1280, FRAME_HEIGHT=720, BASE_X=16, BASE_Y=16,
  parameter integer TEXT_LEN=9, parameter logic [23:0] FG_RGB=24'h20ff40
)(
  input logic clk, rst_n, input logic i_vs, i_hs, i_de,
  input logic [7:0] i_r,i_g,i_b, input logic i_enable,
  output logic o_vs,o_hs,o_de, output logic [7:0] o_r,o_g,o_b,
  output logic o_char_pixel
);
  logic [11:0] x,y; logic vs_d;
  logic [11:0] sx,sy; logic s_de,s_hs,s_vs,s_enable; logic [7:0] sr,sg,sb;
  logic [7:0] font_bits; logic [7:0] ch; logic [3:0] row;
  logic s_in_text; logic s_bit; logic [2:0] glyph_col;
  function automatic [7:0] text_char(input integer idx);
    case(idx)
      0:text_char="H"; 1:text_char="E"; 2:text_char="L"; 3:text_char="L";
      4:text_char="O"; 5:text_char=" "; 6:text_char="S"; 7:text_char="O";
      8:text_char="C"; default:text_char=" ";
    endcase
  endfunction
  always_comb begin
    ch=" "; row=0; s_in_text=0;
    if(sx>=BASE_X && sx<BASE_X+TEXT_LEN*8 && sy>=BASE_Y && sy<BASE_Y+16) begin
      ch=text_char((sx-BASE_X)>>3); row=sy-BASE_Y; s_in_text=1;
    end
    glyph_col = (sx-BASE_X) & 12'h007;
    s_bit = s_enable && s_de && s_in_text && font_bits[7-glyph_col];
  end
  osd_font8x16 font(.clk(clk),.ch(ch),.row(row),.bits(font_bits));
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      x<=0;y<=0;vs_d<=0;sx<=0;sy<=0;s_de<=0;s_hs<=0;s_vs<=0;s_enable<=0;sr<=0;sg<=0;sb<=0;
      o_vs<=0;o_hs<=0;o_de<=0;o_r<=0;o_g<=0;o_b<=0;o_char_pixel<=0;
    end else begin
      // Output is the previous input pixel and the glyph addressed in the
      // previous cycle, so all timing signals have exactly the same latency.
      o_vs<=s_vs; o_hs<=s_hs; o_de<=s_de; o_char_pixel<=s_bit;
      if(s_bit) begin o_r<=FG_RGB[23:16]; o_g<=FG_RGB[15:8]; o_b<=FG_RGB[7:0]; end
      else begin o_r<=sr; o_g<=sg; o_b<=sb; end
      sx<=x; sy<=y; s_de<=i_de; s_hs<=i_hs; s_vs<=i_vs; s_enable<=i_enable; sr<=i_r; sg<=i_g; sb<=i_b;
      vs_d<=i_vs;
      if(i_vs && !vs_d) begin x<=0; y<=0; end
      else if(i_de) begin
        if(x==FRAME_WIDTH-1) begin x<=0; if(y<FRAME_HEIGHT-1)y<=y+1'b1; end
        else x<=x+1'b1;
      end
    end
  end
endmodule
