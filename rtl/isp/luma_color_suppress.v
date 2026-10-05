// Three pixel-clock stages, with sync/DE delayed exactly like RGB.
// Strength 0..128 removes up to approximately 50% of the selected channel.
// Highlight ramp: Y=192..255. Shadow ramp: Y=64..0.
module luma_color_suppress(
  input clk,rst_n,i_enable,
  input [7:0] i_high_green,i_dark_red,
  input i_vs,i_hs,i_de,
  input [7:0] i_r,i_g,i_b,
  output reg o_vs,o_hs,o_de,
  output reg [7:0] o_r,o_g,o_b
);
  reg vs_d,enabled;
  reg [7:0] high_strength,dark_strength;
  wire [9:0] weighted_y={2'b0,i_r}+{1'b0,i_g,1'b0}+{2'b0,i_b};
  wire [7:0] luminance=weighted_y[9:2];
  wire [8:0] high_delta=luminance>192 ? {1'b0,luminance}-9'd192 : 9'd0;
  wire [8:0] dark_delta=luminance<64 ? 9'd64-{1'b0,luminance} : 9'd0;
  wire [8:0] shadow_weight=dark_delta<<2;
  reg [7:0] high_weight,dark_weight,r1,g1,b1,r2,g2,b2;
  reg [15:0] red_cut,green_cut;
  reg [2:0] sync1,sync2;
  wire [8:0] red_factor=9'd256-{1'b0,red_cut[15:8]};
  wire [8:0] green_factor=9'd256-{1'b0,green_cut[15:8]};
  wire [16:0] red_product=r2*red_factor;
  wire [16:0] green_product=g2*green_factor;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      vs_d<=0;enabled<=0;high_strength<=0;dark_strength<=0;
      high_weight<=0;dark_weight<=0;r1<=0;g1<=0;b1<=0;r2<=0;g2<=0;b2<=0;
      red_cut<=0;green_cut<=0;sync1<=0;sync2<=0;
      o_vs<=0;o_hs<=0;o_de<=0;o_r<=0;o_g<=0;o_b<=0;
    end else begin
      vs_d<=i_vs;
      // VIO adjustments take effect in vertical blanking, never mid-frame.
      if(i_vs && !vs_d) begin
        enabled<=i_enable;
        high_strength<=i_high_green>128 ? 8'd128 : i_high_green;
        dark_strength<=i_dark_red>128 ? 8'd128 : i_dark_red;
      end
      r1<=i_r;g1<=i_g;b1<=i_b;sync1<={i_vs,i_hs,i_de};
      high_weight<={high_delta[5:0],2'b00};
      dark_weight<=shadow_weight>255 ? 8'd255 : shadow_weight[7:0];
      r2<=r1;g2<=g1;b2<=b1;sync2<=sync1;
      green_cut<=enabled ? high_weight*high_strength : 16'd0;
      red_cut<=enabled ? dark_weight*dark_strength : 16'd0;
      o_r<=red_product[15:8];o_g<=green_product[15:8];o_b<=b2;
      {o_vs,o_hs,o_de}<=sync2;
    end
  end
endmodule
