`include "../defines.v"
// Four stages, one common RGB scale: lift shadows/midtones without channel clipping.
// LUT curve leaves codes <=16 unchanged. Strength 0..128 blends to the full curve.
// Gain is limited by the brightest channel's headroom, preserving RGB ratios.
module luma_tone_map #(parameter HIGHLIGHT_SAFE=`CFG_ISP_LUMA_TONE_MAP_V_PARAMETER_HIGHLIGHT_SAFE)(
  input clk,rst_n,i_enable,
  input [`CFG_BITS_8-1:0] i_strength,
  input i_vs,i_hs,i_de,
  input [`CFG_BITS_8-1:0] i_r,i_g,i_b,
  output reg o_vs,o_hs,o_de,
  output reg [`CFG_BITS_8-1:0] o_r,o_g,o_b
);
  `include "lift_tables.vh"
  reg vs_d,enabled;
  reg [`CFG_BITS_8-1:0] strength;
  wire [`CFG_BITS_10-1:0] weighted_y={2'b0,i_r}+{1'b0,i_g,1'b0}+{2'b0,i_b};
  wire [`CFG_BITS_8-1:0] luminance=weighted_y[9:2];
  wire [`CFG_BITS_8-1:0] max_rg=i_r>i_g ? i_r : i_g;
  wire [`CFG_BITS_8-1:0] maximum=max_rg>i_b ? max_rg : i_b;
  reg [`CFG_BITS_8-1:0] r1,g1,b1,r2,g2,b2,r3,g3,b3;
  reg [`CFG_BITS_3-1:0] sync1,sync2,sync3;
  reg [`CFG_BITS_9-1:0] extra1;
  reg [`CFG_BITS_10-1:0] cap1,cap2,factor3;
  reg [`CFG_BITS_17-1:0] lift2;
  wire [`CFG_BITS_10-1:0] requested=10'd256+{1'b0,lift2[15:7]};
  wire [`CFG_BITS_18-1:0] red_product=r3*factor3;
  wire [`CFG_BITS_18-1:0] green_product=g3*factor3;
  wire [`CFG_BITS_18-1:0] blue_product=b3*factor3;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      vs_d<=0;enabled<=0;strength<=0;
      r1<=0;g1<=0;b1<=0;r2<=0;g2<=0;b2<=0;r3<=0;g3<=0;b3<=0;
      sync1<=0;sync2<=0;sync3<=0;extra1<=0;cap1<=256;cap2<=256;lift2<=0;factor3<=256;
      o_vs<=0;o_hs<=0;o_de<=0;o_r<=0;o_g<=0;o_b<=0;
    end else begin
      vs_d<=i_vs;
      if(i_vs && !vs_d) begin enabled<=i_enable;strength<=i_strength>128 ? 8'd128 : i_strength;end
      r1<=i_r;g1<=i_g;b1<=i_b;sync1<={i_vs,i_hs,i_de};
      extra1<=lift_extra_lookup(luminance);cap1<=HIGHLIGHT_SAFE ? lift_safe_cap_lookup(maximum) : lift_cap_lookup(maximum);
      r2<=r1;g2<=g1;b2<=b1;sync2<=sync1;cap2<=cap1;
      lift2<=enabled ? extra1*strength : 17'd0;
      r3<=r2;g3<=g2;b3<=b2;sync3<=sync2;
      factor3<=requested>cap2 ? cap2 : requested;
      o_r<=red_product[15:8];o_g<=green_product[15:8];o_b<=blue_product[15:8];
      {o_vs,o_hs,o_de}<=sync3;
    end
  end
endmodule
