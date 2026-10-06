`include "../defines.v"
// Display-source histogram, never includes the overlay itself.
// Single-pixel samples every 16 columns / 8 rows. VS is active high.
// Blank-time shared divider scales each bin to the tallest bin, not probability.
module hdmi_frame_histogram #(
  parameter FRAME_WIDTH=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_FRAME_WIDTH, FRAME_HEIGHT=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_FRAME_HEIGHT, PLOT_HEIGHT=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_PLOT_HEIGHT
)(
  input clk,rst_n,i_vs,i_de,
  input [`CFG_BITS_8-1:0] i_r,i_g,i_b,
  input [`CFG_BITS_2-1:0] i_mode, // 0=Y, 1=R, 2=G, 3=B; already frame-latched
  input [`CFG_BITS_6-1:0] i_read_bin,
  output [`CFG_BITS_8-1:0] o_height,
  output reg o_valid,
  output reg [`CFG_BITS_16-1:0] o_samples
);
  reg [`CFG_BITS_16-1:0] counts[`CFG_RANGE_0_63];
  reg [`CFG_BITS_8-1:0] heights[`CFG_RANGE_0_63];
  reg [`CFG_BITS_12-1:0] x,y;
  reg vs_d,de_d,started,bad;
  reg [`CFG_BITS_16-1:0] samples,peak;
  reg [`CFG_BITS_2-1:0] frame_mode,last_mode,state;
  localparam IDLE=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_LOCALPARAM_IDLE,SCAN=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_LOCALPARAM_SCAN,LOAD=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_LOCALPARAM_LOAD,DIVIDE=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_LOCALPARAM_DIVIDE;
  reg [`CFG_BITS_6-1:0] index;
  reg [`CFG_BITS_5-1:0] bit_index;
  reg sample_pending;
  reg [`CFG_BITS_6-1:0] sample_bin;
  reg [`CFG_BITS_24-1:0] dividend,quotient;
  reg [`CFG_BITS_17-1:0] remainder;
  wire [`CFG_BITS_10-1:0] luma={2'b0,i_r}+{1'b0,i_g,1'b0}+{2'b0,i_b};
  wire [`CFG_BITS_8-1:0] value=frame_mode==1 ? i_r : frame_mode==2 ? i_g : frame_mode==3 ? i_b : luma[9:2];
  wire line_end=de_d && !i_de;
  wire complete=y==FRAME_HEIGHT || (line_end && y==FRAME_HEIGHT-1);
  wire sample_pixel=started && !i_vs && i_de && state==IDLE &&
    x<FRAME_WIDTH && y<FRAME_HEIGHT && x[3:0]==0 && y[2:0]==0;
  wire [`CFG_BITS_17-1:0] trial={remainder[15:0],dividend[23]};
  wire subtract=trial>={1'b0,peak};
  wire [`CFG_BITS_24-1:0] next_q={quotient[22:0],subtract};
  assign o_height=o_valid ? heights[i_read_bin] : 8'd0;
  integer n;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      x<=0;y<=0;vs_d<=0;de_d<=0;started<=0;bad<=0;
      samples<=0;peak<=0;state<=IDLE;index<=0;bit_index<=0;
      dividend<=0;quotient<=0;remainder<=0;frame_mode<=0;last_mode<=0;
      sample_pending<=0;sample_bin<=0;
      o_valid<=0;o_samples<=0;
      for(n=0;n<64;n=n+1) begin counts[n]<=0;heights[n]<=0;end
    end else begin
      vs_d<=i_vs;de_d<=i_de;
      // Separate RGB-to-bin arithmetic from the counter read/modify/write.
      // Samples are 16 clocks apart, so consecutive equal bins have no hazard.
      sample_pending<=sample_pixel && samples!=16'hffff;
      if(sample_pixel) sample_bin<=value[7:2];
      if(sample_pending) counts[sample_bin]<=counts[sample_bin]+1'b1;
      if(!i_de) x<=0;else x<=x+1'b1;
      if(vs_d && !i_vs) begin
        x<=0;y<=0;started<=1;bad<=state!=IDLE;
        samples<=0;frame_mode<=i_mode;
        if(i_mode!=last_mode || state!=IDLE) o_valid<=0;
        last_mode<=i_mode;
      end else if(line_end) begin
        y<=y+1'b1;
        if(started && x!=FRAME_WIDTH) bad<=1;
      end
      if(i_vs && !vs_d) begin
        started<=0;
        if(state==IDLE) begin
          state<=SCAN;index<=0;peak<=0;
          if(started && complete && !bad && (!line_end || x==FRAME_WIDTH) && samples!=0) begin
            o_samples<=samples;
          end else begin o_samples<=0;end
        end else begin bad<=1;o_valid<=0;end
      end else if(sample_pixel) begin
        if(samples!=16'hffff) begin
          samples<=samples+1'b1;
        end else bad<=1;
      end
      case(state)
        SCAN: begin
          if(counts[index]>peak) peak<=counts[index];
          if(index==63) begin index<=0;state<=LOAD;end
          else index<=index+1'b1;
        end
        LOAD: begin
          dividend<=counts[index]*PLOT_HEIGHT;counts[index]<=0;
          quotient<=0;remainder<=0;bit_index<=0;state<=DIVIDE;
        end
        DIVIDE: begin
          remainder<=subtract ? trial-{1'b0,peak} : trial;
          dividend<={dividend[22:0],1'b0};quotient<=next_q;
          if(bit_index==23) begin
            heights[index]<=peak==0 ? 8'd0 : next_q>PLOT_HEIGHT ? PLOT_HEIGHT : next_q[7:0];
            if(index==63) begin
              state<=IDLE;
              // Drop snapshots if processing overlapped the next active frame.
              o_valid<=o_samples!=0 && !started;
            end else begin index<=index+1'b1;state<=LOAD;end
          end else bit_index<=bit_index+1'b1;
        end
        default: begin end
      endcase
    end
  end
endmodule
