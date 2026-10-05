// Central 50% ROI, two adjacent RGB pixels every eight pair-clocks/eight rows.
// Statistics precede color suppression and gamma. Division is sequential.
module ae_frame_stats #(
  parameter FRAME_WIDTH=1920, FRAME_HEIGHT=1080, MIN_SAMPLES=64
)(
  input clk, rst_n, i_vs, i_de,
  input [47:0] i_rgb,
  output reg o_valid,
  output reg [7:0] o_mean,
  output reg o_highlights
);
  reg vs_d,de_d;
  reg [11:0] x,y;
  reg [23:0] sum;
  reg [15:0] samples,hot;
  reg overflow,frame_started,frame_bad;
  wire [9:0] luma0={2'b0,i_rgb[7:0]}+{1'b0,i_rgb[15:8],1'b0}+{2'b0,i_rgb[23:16]};
  wire [9:0] luma1={2'b0,i_rgb[31:24]}+{1'b0,i_rgb[39:32],1'b0}+{2'b0,i_rgb[47:40]};
  wire hot0=i_rgb[7:0]>=240 || i_rgb[15:8]>=240 || i_rgb[23:16]>=240;
  wire hot1=i_rgb[31:24]>=240 || i_rgb[39:32]>=240 || i_rgb[47:40]>=240;
  wire [1:0] hot_increment={1'b0,hot0}+{1'b0,hot1};
  wire line_end=de_d && !i_de;
  wire complete_frame=y==FRAME_HEIGHT || (line_end && y==FRAME_HEIGHT-1);
  wire take=frame_started && !i_vs && i_de && x>=FRAME_WIDTH/8 && x<(FRAME_WIDTH*3)/8 &&
    y>=FRAME_HEIGHT/4 && y<(FRAME_HEIGHT*3)/4 && x[2:0]==0 && y[2:0]==0;
  reg dividing,div_hot;
  reg [4:0] bit_count;
  reg [23:0] dividend,quotient;
  reg [15:0] divisor;
  reg [16:0] remainder;
  wire [16:0] trial={remainder[15:0],dividend[23]};
  wire subtract=trial>={1'b0,divisor};
  wire [23:0] next_q={quotient[22:0],subtract};
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      vs_d<=0;de_d<=0;x<=0;y<=0;sum<=0;samples<=0;hot<=0;overflow<=0;
      frame_started<=0;frame_bad<=0;
      dividing<=0;div_hot<=0;bit_count<=0;dividend<=0;quotient<=0;divisor<=0;remainder<=0;
      o_valid<=0;o_mean<=0;o_highlights<=0;
    end else begin
      vs_d<=i_vs;de_d<=i_de;o_valid<=0;
      if(!i_de) x<=0; else x<=x+1'b1;
      if(vs_d && !i_vs) begin
        x<=0;y<=0;frame_started<=1;frame_bad<=0;
        sum<=0;samples<=0;hot<=0;overflow<=0;
      end else if(line_end) begin
        y<=y+1'b1;
        if(frame_started && x!=FRAME_WIDTH/2) frame_bad<=1;
      end
      if(i_vs && !vs_d) begin
        if(frame_started && complete_frame && !frame_bad &&
           (!line_end || x==FRAME_WIDTH/2) && !dividing && !overflow && samples>=MIN_SAMPLES) begin
          dividing<=1;dividend<=sum;divisor<=samples;remainder<=0;quotient<=0;bit_count<=0;
          div_hot<=({hot,6'b0}>{6'b0,samples});
        end
        sum<=0;samples<=0;hot<=0;overflow<=0;
        frame_started<=0;
      end else if(take) begin
        if(samples<=16'd65533) begin
          sum<=sum+{16'b0,luma0[9:2]}+{16'b0,luma1[9:2]};
          samples<=samples+2;
          hot<=hot+{14'b0,hot_increment};
        end else overflow<=1;
      end
      if(dividing) begin
        remainder<=subtract ? trial-{1'b0,divisor} : trial;
        dividend<={dividend[22:0],1'b0};quotient<=next_q;
        if(bit_count==23) begin
          dividing<=0;o_mean<=next_q[7:0];o_highlights<=div_hot;o_valid<=1;
        end else bit_count<=bit_count+1'b1;
      end
    end
  end
endmodule
