`include "../defines.v"
// Previous-frame display histogram. RAM contents are never asynchronously reset.
module hdmi_frame_histogram #(
  parameter FRAME_WIDTH=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_FRAME_WIDTH,
    FRAME_HEIGHT=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_FRAME_HEIGHT,
    PLOT_HEIGHT=`CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_PLOT_HEIGHT
)(
  input clk,rst_n,i_vs,i_de,input [7:0] i_r,i_g,i_b,
  input [1:0] i_mode,input [5:0] i_read_bin,
  output [7:0] o_height,output reg o_valid,output reg [15:0] o_samples
);
  reg [15:0] counts[0:63];reg [7:0] heights[0:63];
  reg [15:0] count_q;reg [7:0] height_q;
  reg [63:0] count_valid;
  reg [11:0] x,y;reg vs_d,de_d,started,bad,processing_bad;
  reg [15:0] samples,peak;reg [1:0] frame_mode,last_mode;
  localparam IDLE=0,SCAN_PRIME=1,SCAN=2,LOAD_PRIME=3,LOAD=4,DIVIDE=5;
  reg [2:0] state;reg [5:0] index;reg [4:0] bit_index;
  reg sample_pending;reg [5:0] sample_bin;
  reg [23:0] dividend,quotient;reg [16:0] remainder;
  wire [9:0] luma={2'b0,i_r}+{1'b0,i_g,1'b0}+{2'b0,i_b};
  wire [7:0] value=frame_mode==1 ? i_r : frame_mode==2 ? i_g : frame_mode==3 ? i_b : luma[9:2];
  wire line_end=de_d&&!i_de;
  wire frame_start=vs_d&&!i_vs,frame_end=i_vs&&!vs_d;
  wire complete=y==FRAME_HEIGHT||(line_end&&y==FRAME_HEIGHT-1);
  wire sample_pixel=started&&!i_vs&&i_de&&state==IDLE&&
    x<FRAME_WIDTH&&y<FRAME_HEIGHT&&x[3:0]==0&&y[2:0]==0;
  wire [5:0] read_addr=sample_pixel ? value[7:2] : state==SCAN ? index+6'd1 : index;
  wire [15:0] scan_count=count_valid[index] ? count_q : 16'd0;
  wire [16:0] trial={remainder[15:0],dividend[23]};
  wire subtract=trial>={1'b0,peak};
  wire [23:0] next_q={quotient[22:0],subtract};
  wire [7:0] scaled=peak==0 ? 8'd0 : next_q>PLOT_HEIGHT ? PLOT_HEIGHT : next_q[7:0];
  always @(posedge clk) begin
    if(rst_n&&sample_pending&&state==IDLE&&!frame_start)
      counts[sample_bin]<=(count_valid[sample_bin] ? count_q : 16'd0)+16'd1;
    count_q<=counts[read_addr];
    if(rst_n&&state==DIVIDE&&bit_index==23) heights[index]<=scaled;
    height_q<=heights[i_read_bin];
  end
  assign o_height=o_valid ? height_q : 8'd0;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      count_valid<=0;x<=0;y<=0;vs_d<=0;de_d<=0;started<=0;bad<=0;processing_bad<=0;
      samples<=0;peak<=0;state<=IDLE;index<=0;bit_index<=0;
      dividend<=0;quotient<=0;remainder<=0;frame_mode<=0;last_mode<=0;
      sample_pending<=0;sample_bin<=0;o_valid<=0;o_samples<=0;
    end else begin
      vs_d<=i_vs;de_d<=i_de;
      sample_pending<=sample_pixel&&samples!=16'hffff;
      if(sample_pixel) sample_bin<=value[7:2];
      if(sample_pending&&state==IDLE&&!frame_start) count_valid[sample_bin]<=1;
      if(!i_de) x<=0;else x<=x+1'b1;
      if(frame_start) begin
        x<=0;y<=0;started<=1;bad<=state!=IDLE;samples<=0;frame_mode<=i_mode;
        if(state==IDLE) count_valid<=0;
        else processing_bad<=1;
        if(i_mode!=last_mode||state!=IDLE) o_valid<=0;
        last_mode<=i_mode;
      end else if(line_end) begin
        y<=y+1'b1;if(started&&x!=FRAME_WIDTH) bad<=1;
      end
      if(frame_end) begin
        started<=0;
        if(state==IDLE) begin
          state<=SCAN_PRIME;index<=0;peak<=0;processing_bad<=0;
          if(started&&complete&&!bad&&(!line_end||x==FRAME_WIDTH)&&samples!=0&&!sample_pending)
            o_samples<=samples;
          else o_samples<=0;
        end else begin bad<=1;o_valid<=0;processing_bad<=1;end
      end else if(sample_pixel) begin
        if(samples!=16'hffff) samples<=samples+1'b1;else bad<=1;
      end
      case(state)
        SCAN_PRIME: state<=SCAN;
        SCAN: begin
          if(scan_count>peak) peak<=scan_count;
          if(index==63) begin index<=0;state<=LOAD_PRIME;end
          else index<=index+1'b1;
        end
        LOAD_PRIME: state<=LOAD;
        LOAD: begin
          dividend<=scan_count*PLOT_HEIGHT;count_valid[index]<=0;
          quotient<=0;remainder<=0;bit_index<=0;state<=DIVIDE;
        end
        DIVIDE: begin
          remainder<=subtract ? trial-{1'b0,peak} : trial;
          dividend<={dividend[22:0],1'b0};quotient<=next_q;
          if(bit_index==23) begin
            if(index==63) begin state<=IDLE;o_valid<=o_samples!=0&&!started&&!processing_bad&&!frame_start;end
            else begin index<=index+1'b1;state<=LOAD_PRIME;end
          end else bit_index<=bit_index+1'b1;
        end
        default: begin end
      endcase
    end
  end
endmodule
