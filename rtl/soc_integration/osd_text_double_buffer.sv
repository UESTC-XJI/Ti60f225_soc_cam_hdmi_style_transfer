// Two pages in a synchronous dual-clock character RAM, followed by font ROM.
// RGB and all qualifiers have the same three-clock input-to-output latency.
module osd_text_double_buffer #(
  parameter integer FRAME_WIDTH=1280,FRAME_HEIGHT=720,PAGE_SIZE=80,
  parameter integer BASE_X=16,BASE_Y=16
)(
  input logic wr_clk,pix_clk,rst_n,
  input logic wr_en,wr_page,input logic [6:0] wr_addr,input logic [7:0] wr_data,
  input logic wr_commit,wr_commit_page,wr_enable,
  input logic [11:0] wr_x,wr_y,input logic [23:0] wr_color,
  input logic i_vs,i_hs,i_de,input logic [7:0] i_r,i_g,i_b,
  output logic o_vs,o_hs,o_de,output logic [7:0] o_r,o_g,o_b,output logic o_char_pixel,
  output logic ack_toggle,active_page,output logic busy
);
  logic [7:0] page_mem[0:255];integer k;
  initial begin
    for(k=0;k<256;k=k+1) page_mem[k]=8'h20;
    page_mem[0]="H";page_mem[1]="E";page_mem[2]="L";page_mem[3]="L";page_mem[4]="O";
    page_mem[5]=" ";page_mem[6]="S";page_mem[7]="O";page_mem[8]="C";
  end
  logic active_wr1,active_wr2;
  always_ff @(posedge wr_clk or negedge rst_n) begin
    if(!rst_n) begin active_wr1<=0;active_wr2<=0;end
    else begin active_wr1<=active_page;active_wr2<=active_wr1;end
  end
  always_ff @(posedge wr_clk)
    if(rst_n&&wr_en&&wr_addr<PAGE_SIZE&&wr_page!=active_wr2) page_mem[{wr_page,wr_addr}]<=wr_data;
  logic cmt1,cmt2,cmt_seen,page1,page2;
  (* ASYNC_REG="TRUE" *) logic en1,en2;
  logic active_enable;logic [11:0] x1,x2,y1,y2,active_x,active_y,x,y;
  logic [23:0] col1,col2,active_color;
  logic vs_d;
  wire in_text=x>=active_x&&x<active_x+8*PAGE_SIZE&&y>=active_y&&y<active_y+16;
  wire [11:0] relative_x=x-active_x;
  wire [6:0] char_idx=relative_x[9:3];
  logic [7:0] active_ch,font_bits;
  logic [3:0] row1;logic [2:0] glyph_col1,glyph_col2;
  logic v1,h1,d1,e1,v2,h2,d2,e2;
  logic [23:0] rgb1,rgb2,color1,color2;
  // No read reset: e1/e2 mask RAM/ROM contents during reset and outside text.
  always_ff @(posedge pix_clk) active_ch<=page_mem[{active_page,char_idx}];
  osd_font8x16 font(.clk(pix_clk),.ch(active_ch),.row(row1),.bits(font_bits));
  wire glyph=e2&&d2&&font_bits[7-glyph_col2];
  logic busy_pix,busy_wr1,busy_wr2;
  assign busy_pix=cmt2!=cmt_seen;
  always_ff @(posedge wr_clk or negedge rst_n) begin
    if(!rst_n) begin busy_wr1<=0;busy_wr2<=0;end
    else begin busy_wr1<=busy_pix;busy_wr2<=busy_wr1;end
  end
  assign busy=busy_wr2;
  always_ff @(posedge pix_clk or negedge rst_n) begin
    if(!rst_n) begin
      cmt1<=0;cmt2<=0;cmt_seen<=0;page1<=1;page2<=1;en1<=1;en2<=1;
      x1<=BASE_X;x2<=BASE_X;y1<=BASE_Y;y2<=BASE_Y;col1<=24'h20ff40;col2<=24'h20ff40;
      active_page<=0;ack_toggle<=0;active_enable<=1;active_color<=24'h20ff40;
      active_x<=BASE_X;active_y<=BASE_Y;x<=0;y<=0;vs_d<=0;
      v1<=0;h1<=0;d1<=0;e1<=0;v2<=0;h2<=0;d2<=0;e2<=0;
      rgb1<=0;rgb2<=0;color1<=0;color2<=0;row1<=0;glyph_col1<=0;glyph_col2<=0;
      o_vs<=0;o_hs<=0;o_de<=0;o_r<=0;o_g<=0;o_b<=0;o_char_pixel<=0;
    end else begin
      cmt1<=wr_commit;cmt2<=cmt1;page1<=wr_commit_page;page2<=page1;en1<=wr_enable;en2<=en1;
      x1<=wr_x;x2<=x1;y1<=wr_y;y2<=y1;col1<=wr_color;col2<=col1;
      v1<=i_vs;h1<=i_hs;d1<=i_de;e1<=active_enable&&in_text;
      rgb1<={i_r,i_g,i_b};color1<=active_color;row1<=y-active_y;glyph_col1<=relative_x[2:0];
      v2<=v1;h2<=h1;d2<=d1;e2<=e1;rgb2<=rgb1;color2<=color1;glyph_col2<=glyph_col1;
      o_vs<=v2;o_hs<=h2;o_de<=d2;o_char_pixel<=glyph;
      {o_r,o_g,o_b}<=glyph ? color2 : rgb2;
      vs_d<=i_vs;
      if(i_vs&&!vs_d) begin
        x<=0;y<=0;active_enable<=en2;
        if(cmt2!=cmt_seen) begin
          active_page<=page2;active_x<=x2;active_y<=y2;active_color<=col2;cmt_seen<=cmt2;ack_toggle<=cmt2;
        end
      end else if(i_de) begin
        if(x==FRAME_WIDTH-1) begin x<=0;if(y<FRAME_HEIGHT-1) y<=y+1'b1;end
        else x<=x+1'b1;
      end
    end
  end
endmodule
