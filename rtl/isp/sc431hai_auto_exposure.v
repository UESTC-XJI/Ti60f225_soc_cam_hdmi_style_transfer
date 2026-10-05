// Linear mode: exposure in half-lines, limit 4..(2*VTS-11).
// Read actual VTS/exposure first. Sensor analog/digital gains remain fixed.
// Every change uses Group Hold and starts at a sensor frame boundary.
module sc431hai_auto_exposure #(
  parameter WAIT_FRAMES=8, TIMEOUT_CYCLES=250000
)(
  input clk,rst_n,i_config_done,i_enable,i_sensor_frame_start,
  input i_stats_valid,i_highlights,
  input [7:0] i_mean,i_target,
  output reg o_wr_en,o_rd_en,
  output reg [15:0] o_addr,
  output reg [7:0] o_data,
  input i_wr_done,i_rd_done,i_wr_error,i_rd_error,
  input [7:0] i_read_data,
  output reg [15:0] o_exposure,o_vts,
  output reg [7:0] o_mean,
  output o_ready,o_at_limit,
  output reg o_error,
  input i_high_protect,
  input [9:0] i_high_permille,
  input [7:0] i_high_limit,
  output reg o_highlight_limited
);
  localparam BOOT=0,READ_SEND=1,READ_WAIT=2,LIMITS=3,READY=4,
    WAIT_FRAME=5,WRITE_SEND=6,WRITE_WAIT=7,FAULT=8;
  reg [3:0] state;
  reg [2:0] index;
  reg [7:0] exp_hi,exp_mid,exp_lo,cooldown;
  reg [15:0] pending;
  reg group_failed;
  reg [31:0] timer;
  wire [16:0] max_wide={o_vts,1'b0}-17'd11;
  wire [15:0] maximum=max_wide[15:0];
  wire [7:0] target=i_target<16 ? 8'd16 : (i_target>224 ? 8'd224 : i_target);
  wire [15:0] step=(o_exposure>>3)==0 ? 16'd1 : (o_exposure>>3);
  wire [7:0] high_limit=i_high_limit==0 ? 8'd1 : i_high_limit;
  wire [7:0] high_release=high_limit>>1;
  wire high_over=i_high_protect && i_high_permille>{2'b0,high_limit};
  wire high_hold=i_high_protect && o_highlight_limited && i_high_permille>{2'b0,high_release};
  reg [16:0] candidate;
  reg [15:0] next_exposure;
  assign o_ready=state>=READY && state<=WRITE_WAIT;
  assign o_at_limit=o_ready && (o_exposure<=4 || o_exposure>=maximum);
  always @(*) begin
    candidate={1'b0,o_exposure};
    // Full-frame highlights outrank mean brightness when protection is enabled.
    // Hysteresis holds exposure until the ratio falls below half the limit.
    if(high_over || {1'b0,i_mean}>({1'b0,target}+9'd8) ||
       (!i_high_protect && i_highlights && i_mean>=target))
      candidate=o_exposure>step ? {1'b0,o_exposure}-{1'b0,step} : 17'd4;
    else if(!high_hold && ({1'b0,i_mean}+9'd8)<{1'b0,target})
      candidate={1'b0,o_exposure}+{1'b0,step};
    if(o_exposure<4 || candidate<4) next_exposure=16'd4;
    else if(o_exposure>maximum || candidate>max_wide) next_exposure=maximum;
    else next_exposure=candidate[15:0];
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=BOOT;index<=0;exp_hi<=0;exp_mid<=0;exp_lo<=0;cooldown<=0;
      pending<=0;group_failed<=0;timer<=0;o_wr_en<=0;o_rd_en<=0;o_addr<=0;o_data<=0;
      o_exposure<=0;o_vts<=0;o_mean<=0;o_error<=0;
      o_highlight_limited<=0;
    end else begin
      o_wr_en<=0;o_rd_en<=0;
      if(i_stats_valid) o_mean<=i_mean;
      if(!i_enable) o_highlight_limited<=0;
      else if(i_stats_valid) begin
        if(!i_high_protect || i_high_permille<={2'b0,high_release}) o_highlight_limited<=0;
        else if(high_over) o_highlight_limited<=1;
      end
      if(state==READ_WAIT || state==WRITE_WAIT || state==WAIT_FRAME) timer<=timer+1'b1;
      else timer<=0;
      if((state==READ_WAIT || state==WRITE_WAIT || state==WAIT_FRAME) && timer>=TIMEOUT_CYCLES-1) begin
        state<=FAULT;o_error<=1;
      end else case(state)
        BOOT: if(i_config_done) begin index<=0;state<=READ_SEND; end
        READ_SEND: begin
          case(index)
            0:o_addr<=16'h320e;
            1:o_addr<=16'h320f;
            2:o_addr<=16'h3e00;
            3:o_addr<=16'h3e01;
            4:o_addr<=16'h3e02;
            default:o_addr<=16'h320e;
          endcase
          o_rd_en<=1;state<=READ_WAIT;
        end
        READ_WAIT: if(i_rd_done) begin
          if(i_rd_error) begin state<=FAULT;o_error<=1; end
          else begin
            case(index)
              0:o_vts[15:8]<={1'b0,i_read_data[6:0]}; // 320e[7] is not part of VTS.
              1:o_vts[7:0]<=i_read_data;
              2:exp_hi<=i_read_data;
              3:exp_mid<=i_read_data;
              4:exp_lo<=i_read_data;
            endcase
            if(index==4) state<=LIMITS;
            else begin index<=index+1'b1;state<=READ_SEND; end
          end
        end
        LIMITS: begin
          if(o_vts<8) begin state<=FAULT;o_error<=1; end
          else begin
            o_exposure<={exp_hi[3:0],exp_mid,exp_lo[7:4]};
            cooldown<=WAIT_FRAMES;state<=READY;
          end
        end
        READY: begin
          if(!i_enable) cooldown<=0;
          else if(i_stats_valid) begin
            if(cooldown!=0) cooldown<=cooldown-1'b1;
            else if(next_exposure!=o_exposure) begin
              pending<=next_exposure;state<=WAIT_FRAME;
            end
          end
        end
        WAIT_FRAME: begin
          if(!i_enable) state<=READY;
          else if(i_sensor_frame_start) begin index<=0;group_failed<=0;state<=WRITE_SEND; end
        end
        WRITE_SEND: begin
          case(index)
            0:begin o_addr<=16'h3812;o_data<=8'h00;end
            1:begin o_addr<=16'h3e00;o_data<={exp_hi[7:4],pending[15:12]};end
            2:begin o_addr<=16'h3e01;o_data<=pending[11:4];end
            3:begin o_addr<=16'h3e02;o_data<={pending[3:0],exp_lo[3:0]};end
            4:begin o_addr<=16'h3812;o_data<=8'h30;end
          endcase
          o_wr_en<=1;state<=WRITE_WAIT;
        end
        WRITE_WAIT: if(i_wr_done) begin
          if(i_wr_error) group_failed<=1;
          // Even on NACK, attempt release before reporting failure.
          if(index==4) begin
            if(group_failed || i_wr_error) begin state<=FAULT;o_error<=1; end
            else begin o_exposure<=pending;cooldown<=WAIT_FRAMES;state<=READY; end
          end else begin
            index<=i_wr_error ? 3'd4 : index+1'b1;
            state<=WRITE_SEND;
          end
        end
        FAULT: begin o_wr_en<=0;o_rd_en<=0; end
        default: begin state<=FAULT;o_error<=1; end
      endcase
    end
  end
endmodule
