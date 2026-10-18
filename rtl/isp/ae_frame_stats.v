`include "../defines.v"
// Central 50% mean plus optional full-frame highlight fraction.
// Default dual-pixel mode meters before tone; single-pixel mean-only mode
// meters the actual post-lift display output.
// Two pixels sampled every eight pair-clocks and eight rows (32,400 at 1080p).
// One sequential divider computes both results; no pixel-path division.
module ae_frame_stats #(
  parameter FRAME_WIDTH=`CFG_ISP_AE_FRAME_STATS_V_PARAMETER_FRAME_WIDTH, FRAME_HEIGHT=`CFG_ISP_AE_FRAME_STATS_V_PARAMETER_FRAME_HEIGHT, MIN_SAMPLES=`CFG_ISP_AE_FRAME_STATS_V_PARAMETER_MIN_SAMPLES,
    PIXELS_PER_CLOCK=`CFG_ISP_AE_FRAME_STATS_V_PARAMETER_PIXELS_PER_CLOCK, MEAN_ONLY=`CFG_ISP_AE_FRAME_STATS_V_PARAMETER_MEAN_ONLY, FULL_FRAME_MEAN=`CFG_ISP_AE_FRAME_STATS_V_PARAMETER_FULL_FRAME_MEAN
)(
  input clk, rst_n, i_vs, i_de,
  input [`CFG_BITS_48-1:0] i_rgb,
  input [`CFG_BITS_8-1:0] i_high_threshold,
  output reg o_valid,
  output reg [`CFG_BITS_8-1:0] o_mean,
  output reg o_highlights,
  output reg [`CFG_BITS_10-1:0] o_high_permille
);
  reg vs_d,de_d;
  reg [`CFG_BITS_12-1:0] x,y;
  reg [`CFG_BITS_24-1:0] sum;
  reg [`CFG_BITS_16-1:0] samples,full_samples,full_hot;
  reg overflow,frame_started,frame_bad;
  reg [`CFG_BITS_8-1:0] threshold;
  wire [`CFG_BITS_10-1:0] luma0={2'b0,i_rgb[7:0]}+{1'b0,i_rgb[15:8],1'b0}+{2'b0,i_rgb[23:16]};
  wire [`CFG_BITS_10-1:0] luma1={2'b0,i_rgb[31:24]}+{1'b0,i_rgb[39:32],1'b0}+{2'b0,i_rgb[47:40]};
  wire hot0=i_rgb[7:0]>=threshold || i_rgb[15:8]>=threshold || i_rgb[23:16]>=threshold;
  wire hot1=i_rgb[31:24]>=threshold || i_rgb[39:32]>=threshold || i_rgb[47:40]>=threshold;
  wire [`CFG_BITS_2-1:0] hot_increment={1'b0,hot0}+{1'b0,hot1};
  wire line_end=de_d && !i_de;
  wire complete_frame=y==FRAME_HEIGHT || (line_end && y==FRAME_HEIGHT-1);
  wire take_full=frame_started && !i_vs && i_de && x<FRAME_WIDTH/PIXELS_PER_CLOCK &&
    y<FRAME_HEIGHT && (PIXELS_PER_CLOCK==2 ? x[2:0]==0 : x[3:0]==0) && y[2:0]==0;
  wire in_roi=x>=FRAME_WIDTH/(4*PIXELS_PER_CLOCK) && x<(FRAME_WIDTH*3)/(4*PIXELS_PER_CLOCK) &&
    y>=FRAME_HEIGHT/4 && y<(FRAME_HEIGHT*3)/4;
  reg dividing,div_ratio;
  reg [`CFG_BITS_5-1:0] bit_count;
  reg [`CFG_BITS_26-1:0] dividend,quotient,hot_scaled;
  reg [`CFG_BITS_16-1:0] divisor,full_divisor;
  reg [`CFG_BITS_17-1:0] remainder;
  wire [`CFG_BITS_17-1:0] trial={remainder[15:0],dividend[25]};
  wire subtract=trial>={1'b0,divisor};
  wire [`CFG_BITS_26-1:0] next_q={quotient[24:0],subtract};
  wire [`CFG_BITS_26-1:0] hot_times_1000={10'b0,full_hot}*26'd1000;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      vs_d<=0;de_d<=0;x<=0;y<=0;sum<=0;samples<=0;full_samples<=0;full_hot<=0;
      overflow<=0;frame_started<=0;frame_bad<=0;threshold<=8'd232;
      dividing<=0;div_ratio<=0;bit_count<=0;dividend<=0;quotient<=0;divisor<=0;
      full_divisor<=0;hot_scaled<=0;remainder<=0;
      o_valid<=0;o_mean<=0;o_highlights<=0;o_high_permille<=0;
    end else begin
      vs_d<=i_vs;de_d<=i_de;o_valid<=0;
      if(!i_de) x<=0; else x<=x+1'b1;
      if(vs_d && !i_vs) begin
        x<=0;y<=0;frame_started<=1;frame_bad<=0;
        threshold<=i_high_threshold<192 ? 8'd192 : (i_high_threshold>254 ? 8'd254 : i_high_threshold);
        sum<=0;samples<=0;full_samples<=0;full_hot<=0;overflow<=0;
      end else if(line_end) begin
        y<=y+1'b1;
        if(frame_started && x!=FRAME_WIDTH/PIXELS_PER_CLOCK) frame_bad<=1;
      end
      if(i_vs && !vs_d) begin
        if(frame_started && complete_frame && !frame_bad &&
           (!line_end || x==FRAME_WIDTH/PIXELS_PER_CLOCK) && !dividing && !overflow &&
           samples>=MIN_SAMPLES && full_samples!=0) begin
          dividing<=1;div_ratio<=0;dividend<={2'b0,sum};divisor<=samples;
          remainder<=0;quotient<=0;bit_count<=0;
          full_divisor<=full_samples;hot_scaled<=hot_times_1000;
          o_highlights<=({full_hot,6'b0}>{6'b0,full_samples});
        end
        sum<=0;samples<=0;full_samples<=0;full_hot<=0;overflow<=0;frame_started<=0;
      end else if(take_full) begin
        if(full_samples<=16'd65533) begin
          full_samples<=full_samples+PIXELS_PER_CLOCK;
          full_hot<=full_hot+(PIXELS_PER_CLOCK==2 ? {14'b0,hot_increment} : {15'b0,hot0});
          if(FULL_FRAME_MEAN || in_roi) begin
            sum<=sum+{16'b0,luma0[9:2]}+(PIXELS_PER_CLOCK==2 ? {16'b0,luma1[9:2]} : 24'd0);
            samples<=samples+PIXELS_PER_CLOCK;
          end
        end else overflow<=1;
      end
      if(dividing) begin
        remainder<=subtract ? trial-{1'b0,divisor} : trial;
        dividend<={dividend[24:0],1'b0};quotient<=next_q;
        if(bit_count==25) begin
          if(MEAN_ONLY) begin
            o_mean<=next_q[7:0];dividing<=0;o_valid<=1;
          end else if(!div_ratio) begin
            o_mean<=next_q[7:0];div_ratio<=1;
            dividend<=hot_scaled;divisor<=full_divisor;remainder<=0;quotient<=0;bit_count<=0;
          end else begin
            dividing<=0;o_high_permille<=next_q[9:0];o_valid<=1;
          end
        end else bit_count<=bit_count+1'b1;
      end
    end
  end
endmodule
