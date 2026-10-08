// Two-page text RAM and pixel-domain commit handshake.  CPU writes the page
// opposite active_page; a commit toggle is accepted once and applied at VS
// rising edge. The ACK toggle changes at that same edge.
module osd_text_double_buffer #(
  parameter integer FRAME_WIDTH=1280, FRAME_HEIGHT=720, PAGE_SIZE=80,
  parameter integer BASE_X=16, BASE_Y=16
)(
  input logic wr_clk,pix_clk,rst_n,
  input logic wr_en,input logic wr_page,input logic [6:0] wr_addr,input logic [7:0] wr_data,
  input logic wr_commit,input logic wr_commit_page,input logic wr_enable,
  input logic [11:0] wr_x,wr_y,input logic [23:0] wr_color,
  input logic i_vs,i_hs,i_de,input logic [7:0] i_r,i_g,i_b,
  output logic o_vs,o_hs,o_de,output logic [7:0] o_r,o_g,o_b,output logic o_char_pixel,
  output logic ack_toggle,active_page,output logic busy
);
  logic [7:0] page_mem[0:1][0:PAGE_SIZE-1]; integer k;
  initial begin
    for(k=0;k<PAGE_SIZE;k=k+1) begin page_mem[0][k]=8'h20; page_mem[1][k]=8'h20; end
    page_mem[0][0]="H";page_mem[0][1]="E";page_mem[0][2]="L";page_mem[0][3]="L";page_mem[0][4]="O";page_mem[0][5]=" ";page_mem[0][6]="S";page_mem[0][7]="O";page_mem[0][8]="C";
  end
  logic active_wr1,active_wr2;
  always_ff @(posedge wr_clk or negedge rst_n) begin
    if(!rst_n) begin active_wr1<=0; active_wr2<=0; end else begin active_wr1<=active_page; active_wr2<=active_wr1; end
  end
  always_ff @(posedge wr_clk) if(wr_en && wr_addr<PAGE_SIZE && (wr_page!=active_wr2)) page_mem[wr_page][wr_addr]<=wr_data;

  logic cmt1,cmt2,cmt_seen,page1,page2;
  (* ASYNC_REG="TRUE" *) logic en1,en2;
  logic active_enable;
  logic [11:0] x1,x2,y1,y2; logic [23:0] col1,col2;
  logic [11:0] x,y,sx,sy; logic vs_d; logic s_de,s_hs,s_vs,s_en; logic [7:0] sr,sg,sb;
  logic [23:0] active_color; logic [11:0] active_x,active_y; logic [7:0] font_bits,active_ch; logic [3:0] font_row; logic in_text,s_bit; logic [6:0] char_idx; logic [2:0] glyph_col;
  always_comb begin
    in_text=(sx>=active_x && sx<active_x+8*PAGE_SIZE && sy>=active_y && sy<active_y+16);
    char_idx=(sx-active_x)>>3; active_ch=8'h20; font_row=0;
    if(in_text && char_idx<PAGE_SIZE) begin active_ch=page_mem[active_page][char_idx]; font_row=sy-active_y; end
    glyph_col=(sx-active_x)&12'h007;
    s_bit=s_en&&s_de&&in_text&&font_bits[7-glyph_col];
  end
  osd_font8x16 font(.clk(pix_clk),.ch(active_ch),.row(font_row),.bits(font_bits));
  // Export the pixel-domain pending state through a two-flop synchronizer so
  // APB/core logic never samples a changing pixel-domain bit directly.
  logic busy_pix,busy_wr1,busy_wr2;
  assign busy_pix=(cmt2!=cmt_seen);
  always_ff @(posedge wr_clk or negedge rst_n) begin
    if(!rst_n) begin busy_wr1<=1'b0; busy_wr2<=1'b0; end
    else begin busy_wr1<=busy_pix; busy_wr2<=busy_wr1; end
  end
  assign busy=busy_wr2;
  always_ff @(posedge pix_clk or negedge rst_n) begin
    if(!rst_n) begin
      cmt1<=0;cmt2<=0;cmt_seen<=0;page1<=1;page2<=1;en1<=1;en2<=1;x1<=16;x2<=16;y1<=16;y2<=16;col1<=24'h20ff40;col2<=24'h20ff40;
      active_page<=0;ack_toggle<=0;active_enable<=1;active_color<=24'h20ff40;active_x<=16;active_y<=16;x<=0;y<=0;sx<=0;sy<=0;vs_d<=0;s_de<=0;s_hs<=0;s_vs<=0;s_en<=0;sr<=0;sg<=0;sb<=0;o_vs<=0;o_hs<=0;o_de<=0;o_r<=0;o_g<=0;o_b<=0;o_char_pixel<=0;
    end else begin
      cmt1<=wr_commit;cmt2<=cmt1;page1<=wr_commit_page;page2<=page1;en1<=wr_enable;en2<=en1;x1<=wr_x;x2<=x1;y1<=wr_y;y2<=y1;col1<=wr_color;col2<=col1;
      o_vs<=s_vs;o_hs<=s_hs;o_de<=s_de;o_char_pixel<=s_bit;
      if(s_bit) begin o_r<=active_color[23:16];o_g<=active_color[15:8];o_b<=active_color[7:0]; end else begin o_r<=sr;o_g<=sg;o_b<=sb; end
      sx<=x;sy<=y;s_de<=i_de;s_hs<=i_hs;s_vs<=i_vs;s_en<=active_enable;sr<=i_r;sg<=i_g;sb<=i_b;vs_d<=i_vs;
      if(i_vs&&!vs_d) begin
        x<=0;y<=0;
        // Enable changes do not require a text COMMIT, but apply only at VS
        // after two-flop synchronization to avoid cutting a glyph mid-frame.
        active_enable<=en2;
        if(cmt2!=cmt_seen) begin active_page<=page2;active_x<=x2;active_y<=y2;active_color<=col2;cmt_seen<=cmt2;ack_toggle<=cmt2; end
      end else if(i_de) begin if(x==FRAME_WIDTH-1) begin x<=0;if(y<FRAME_HEIGHT-1)y<=y+1'b1;end else x<=x+1'b1; end
    end
  end
endmodule
