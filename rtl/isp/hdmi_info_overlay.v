// Two-cycle RGB/VS/HS/DE latency in both enabled and bypass modes.
// Controls must be coherent in clk domain (use mailbox from future APB clock).
// Text renderer is external and reserved for a later implementation.
module hdmi_info_overlay #(
  parameter FRAME_WIDTH=1920, FRAME_HEIGHT=1080,
    MARGIN=16, PLOT_HEIGHT=128, BIN_WIDTH=4,
    TEXT_WIDTH=320, TEXT_HEIGHT=64
)(
  input clk,rst_n,i_vs,i_hs,i_de,
  input [7:0] i_r,i_g,i_b,
  input i_hist_enable,i_text_enable,
  input [1:0] i_hist_mode,
  input i_text_valid,
  input [23:0] i_text_rgb,
  output [11:0] o_x,o_y,
  output o_hist_valid,
  output [15:0] o_hist_samples,
  output reg o_vs,o_hs,o_de,
  output reg [7:0] o_r,o_g,o_b
);
  localparam PLOT_WIDTH=64*BIN_WIDTH;
  localparam TOP=FRAME_HEIGHT-MARGIN-PLOT_HEIGHT-2;
  reg [11:0] x,y;
  reg vs_d,de_d,hist_enable,text_enable;
  reg [1:0] mode;
  // At falling VS the histogram also sees the newly latched controls.
  wire frame_start=vs_d && !i_vs;
  wire [1:0] selected_mode=frame_start ? i_hist_mode : mode;
  wire [11:0] local_x=x-MARGIN-1;
  wire [5:0] bin_index=local_x/BIN_WIDTH;
  wire [7:0] height;
  hdmi_frame_histogram #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),.PLOT_HEIGHT(PLOT_HEIGHT)) histogram(
    .clk(clk),.rst_n(rst_n),.i_vs(i_vs),.i_de(i_de),.i_r(i_r),.i_g(i_g),.i_b(i_b),
    .i_mode(selected_mode),.i_read_bin(bin_index),.o_height(height),.o_valid(o_hist_valid),.o_samples(o_hist_samples)
  );
  assign o_x=x;assign o_y=y;
  reg s_vs,s_hs,s_de,s_box,s_border,s_bar,s_text;
  reg [7:0] s_r,s_g,s_b;
  reg [23:0] s_text_rgb,s_bar_rgb;
  wire in_box=x>=MARGIN && x<MARGIN+PLOT_WIDTH+2 && y>=TOP && y<TOP+PLOT_HEIGHT+2;
  wire border=x==MARGIN || x==MARGIN+PLOT_WIDTH+1 || y==TOP || y==TOP+PLOT_HEIGHT+1;
  wire [11:0] from_bottom=TOP+PLOT_HEIGHT-y;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      x<=0;y<=0;vs_d<=0;de_d<=0;hist_enable<=0;text_enable<=0;mode<=0;
      s_vs<=0;s_hs<=0;s_de<=0;s_box<=0;s_border<=0;s_bar<=0;s_text<=0;
      s_r<=0;s_g<=0;s_b<=0;s_text_rgb<=0;s_bar_rgb<=0;
      o_vs<=0;o_hs<=0;o_de<=0;o_r<=0;o_g<=0;o_b<=0;
    end else begin
      vs_d<=i_vs;de_d<=i_de;
      if(!i_de) x<=0;else x<=x+1'b1;
      if(frame_start) begin
        x<=0;y<=0;hist_enable<=i_hist_enable;text_enable<=i_text_enable;mode<=i_hist_mode;
      end else if(de_d && !i_de) y<=y+1'b1;
      s_vs<=i_vs;s_hs<=i_hs;s_de<=i_de;s_r<=i_r;s_g<=i_g;s_b<=i_b;
      s_box<=hist_enable && in_box && i_de && !i_vs;
      s_border<=border;
      s_bar<=o_hist_valid && !border && from_bottom<height;
      s_bar_rgb<=mode==1 ? 24'hff4040 : mode==2 ? 24'h40ff40 : mode==3 ? 24'h6080ff : 24'h40e0e0;
      s_text<=text_enable && i_text_valid && i_de && !i_vs && x<MARGIN+TEXT_WIDTH && x>=MARGIN && y>=MARGIN && y<MARGIN+TEXT_HEIGHT;
      s_text_rgb<=i_text_rgb;
      o_vs<=s_vs;o_hs<=s_hs;o_de<=s_de;
      if(s_text) begin {o_r,o_g,o_b}<=s_text_rgb;end
      else if(s_box && s_border) begin {o_r,o_g,o_b}<=24'hc0c0c0;end
      else if(s_box && s_bar) begin {o_r,o_g,o_b}<=s_bar_rgb;end
      else if(s_box) begin o_r<={1'b0,s_r[7:1]};o_g<={1'b0,s_g[7:1]};o_b<={1'b0,s_b[7:1]};end
      else begin o_r<=s_r;o_g<=s_g;o_b<=s_b;end
    end
  end
endmodule
