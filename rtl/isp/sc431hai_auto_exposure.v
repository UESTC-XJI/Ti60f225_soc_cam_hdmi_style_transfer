// Linear mode: exposure in half-lines, limit 4..(2*VTS-11).
// Read actual VTS/exposure first. Sensor analog/digital gains remain fixed.
// Every change uses Group Hold and starts at a sensor frame boundary.
module sc431hai_auto_exposure #(
  parameter WAIT_FRAMES=2, TIMEOUT_CYCLES=250000,
  parameter FILTER_SHIFT=2, CONFIRM_FRAMES=2, DEADBAND=12, SETTLE_BAND=6,
  parameter SMALL_STEP_SHIFT=6, LARGE_STEP_SHIFT=5, LARGE_ERROR=32,
  parameter RELEASE_FRAMES=8, PREDICTIVE_ENABLE=0, FIXED_STEP_ENABLE=1, RECOVERY_FRAMES=32, FAST_RECOVERY_FRAMES=4, EXPOSURE_PRIORITY_ENABLE=1
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
  output o_exposure_constrained,
  output reg o_highlight_limited
);
  localparam BOOT=0,READ_SEND=1,READ_WAIT=2,LIMITS=3,READY=4,
    WAIT_FRAME=5,WRITE_SEND=6,WRITE_WAIT=7,FAULT=8,
    PREDICT_DIVIDE=9,PREDICT_APPLY=10;
  reg [3:0] state;
  reg [2:0] index;
  reg [7:0] exp_hi,exp_mid,exp_lo,cooldown;
  reg [15:0] pending;
  reg group_failed;
  // Learn a safe ceiling after a highlight-driven reduction. Releasing the
  // latch must not immediately restore the large mean-driven exposure jump.
  reg ceiling_valid,pending_high;
  reg [15:0] highlight_ceiling,unsafe_exposure;
  reg [7:0] safe_scene_mean;
  reg safe_scene_valid;
  reg [7:0] scene_change_count;
  reg [7:0] recovery_count,ceiling_limit;
  reg recovery_was_fast,release_was_low;
  wire ceiling_active=(PREDICTIVE_ENABLE || FIXED_STEP_ENABLE) && i_high_protect && ceiling_valid &&
    ceiling_limit==(i_high_limit==0 ? 8'd1 : i_high_limit);
  reg [31:0] timer;
  wire [16:0] max_wide={o_vts,1'b0}-17'd11;
  wire [15:0] maximum=max_wide[15:0];
  wire [7:0] target=i_target<16 ? 8'd16 : (i_target>224 ? 8'd224 : i_target);
  // Q8.4 / Q10.4 EWMA: retain sub-code precision without pixel-path changes.
  reg filter_valid;
  reg [11:0] mean_filter;
  reg [13:0] high_filter;
  reg [7:0] previous_mean;
  reg [1:0] last_direction;
  reg [1:0] brightness_direction;
  reg [7:0] confirm_count,release_count;
  wire [19:0] mean_mix=mean_filter*((1<<FILTER_SHIFT)-1)+{i_mean,4'b0};
  wire [21:0] high_mix=high_filter*((1<<FILTER_SHIFT)-1)+{i_high_permille,4'b0};
  wire [19:0] mean_shifted=mean_mix>>FILTER_SHIFT;
  wire [21:0] high_shifted=high_mix>>FILTER_SHIFT;
  wire [8:0] mean_change=i_mean>previous_mean ? {1'b0,i_mean}-{1'b0,previous_mean} :
    {1'b0,previous_mean}-{1'b0,i_mean};
  // A late exposure response must not be mixed with an old exposure's mean.
  // Re-seed and confirm again when accepted measurements change substantially.
  wire mean_jump=(PREDICTIVE_ENABLE || FIXED_STEP_ENABLE) && filter_valid && mean_change>DEADBAND;
  wire [11:0] mean_next=(filter_valid && !mean_jump) ? mean_shifted[11:0] : {i_mean,4'b0};
  wire [13:0] high_next=filter_valid ? high_shifted[13:0] : {i_high_permille,4'b0};
  wire [7:0] mean_control=(mean_next+12'd8)>>4;
  wire [9:0] high_control=high_next[13:4];
  wire [8:0] mean_error=mean_control>target ? {1'b0,mean_control}-{1'b0,target} :
    {1'b0,target}-{1'b0,mean_control};
  function [15:0] fixed_step_lookup;
    input [8:0] error;
    begin
      if(error<=4) fixed_step_lookup=0;
      else if(error<=6) fixed_step_lookup=2;
      else if(error<=12) fixed_step_lookup=4;
      else if(error<=23) fixed_step_lookup=16;
      else if(error<=39) fixed_step_lookup=64;
      else if(error<=63) fixed_step_lookup=128;
      else if(error<=95) fixed_step_lookup=256;
      else fixed_step_lookup=512;
    end
  endfunction
  wire [15:0] brightness_step=fixed_step_lookup(mean_error);
  wire [15:0] small_step=(o_exposure>>SMALL_STEP_SHIFT)==0 ? 16'd1 : (o_exposure>>SMALL_STEP_SHIFT);
  wire [15:0] large_step=(o_exposure>>LARGE_STEP_SHIFT)==0 ? 16'd1 : (o_exposure>>LARGE_STEP_SHIFT);
  wire [7:0] high_limit=i_high_limit==0 ? 8'd1 : i_high_limit;
  wire [7:0] high_release=high_limit>>1;
  // Low highlight occupancy permits faster bounded recovery. Between half the
  // limit and the limit, keep probing rather than permanently freezing AE.
  wire recovery_headroom=high_control<{2'b0,high_limit} && i_high_permille<{2'b0,high_limit};
  wire recovery_fast=high_control<={2'b0,high_release} && i_high_permille<={2'b0,high_release};
  wire [15:0] recovery_raw=o_exposure>>(recovery_fast ? 4 : 5);
  wire [15:0] recovery_fixed=recovery_fast ?
    (brightness_step>128 ? 16'd128 : brightness_step) :
    (brightness_step>32 ? 16'd32 : brightness_step);
  wire [15:0] recovery_step=FIXED_STEP_ENABLE ? recovery_fixed :
    (recovery_raw<4 ? 16'd4 : recovery_raw);
  wire priority_active=EXPOSURE_PRIORITY_ENABLE && FIXED_STEP_ENABLE;
  wire [16:0] safe_gap=unsafe_exposure>o_exposure ? {1'b0,unsafe_exposure}-{1'b0,o_exposure} : 17'd0;
  wire [15:0] boundary_step=safe_gap<=4 ? 16'd0 :
    (safe_gap<=6 ? 16'd1 : ((safe_gap-17'd4)>>1));
  wire [15:0] guarded_recovery_step=priority_active && boundary_step<recovery_step ? boundary_step : recovery_step;
  wire [7:0] scene_high_limit=high_limit<4 ? 8'd0 : high_limit>>2;
  wire scene_became_dark=safe_scene_valid &&
    ({1'b0,mean_control}+9'd8)<{1'b0,safe_scene_mean} &&
    high_control<={2'b0,scene_high_limit} && i_high_permille<={2'b0,scene_high_limit};
  wire [16:0] recovery_candidate={1'b0,o_exposure}+{1'b0,guarded_recovery_step};
  wire high_over=i_high_protect && high_control>{2'b0,high_limit};
  wire high_hold=i_high_protect && o_highlight_limited &&
    (RELEASE_FRAMES!=1 || high_control>{2'b0,high_release});
  wire [9:0] severe_limit={2'b0,high_limit}+
    (high_limit<8 ? 10'd4 : {3'b0,high_limit[7:1]});
  wire [15:0] high_fixed=high_control>severe_limit ? 16'd32 : 16'd8;
  wire [15:0] step=FIXED_STEP_ENABLE ?
    (high_over ? high_fixed : brightness_step) :
    ((high_over ? high_control>severe_limit : mean_error>=LARGE_ERROR) ? large_step : small_step);
  wire [8:0] start_band=FIXED_STEP_ENABLE ? 9'd4 : DEADBAND;
  wire [8:0] settle_band=FIXED_STEP_ENABLE ? 9'd4 : SETTLE_BAND;
  reg [1:0] direction;
  reg [16:0] candidate;
  reg [15:0] next_exposure;
  // One 24-cycle divider per confirmed correction. No video-path division.
  reg [23:0] pred_dividend,pred_quotient,pred_estimate;
  reg [7:0] pred_divisor;
  reg [8:0] pred_remainder;
  reg [4:0] pred_bit;
  reg [15:0] pred_base;
  reg [1:0] pred_direction;
  reg pred_large;
  wire [8:0] pred_trial={pred_remainder[7:0],pred_dividend[23]};
  wire pred_subtract=pred_trial>={1'b0,pred_divisor};
  wire [23:0] pred_next_q={pred_quotient[22:0],pred_subtract};
  wire [15:0] pred_goal=pred_estimate>{8'b0,maximum} ? maximum :
    (pred_estimate<24'd4 ? 16'd4 : pred_estimate[15:0]);
  wire [15:0] pred_distance=pred_goal>pred_base ? pred_goal-pred_base : pred_base-pred_goal;
  wire [15:0] pred_half=pred_distance<2 ? 16'd1 : (pred_distance>>1);
  // Large changes: at most double exposure or reduce it by 25%. Near target:
  // at most 12.5%. Half-distance naturally shrinks further near convergence.
  wire [15:0] pred_cap_raw=pred_large ?
    (pred_direction==1 ? pred_base : (pred_base>>2)) : (pred_base>>3);
  wire [15:0] pred_cap=pred_cap_raw==0 ? 16'd1 : pred_cap_raw;
  wire [15:0] pred_step=pred_half>pred_cap ? pred_cap : pred_half;
  wire [16:0] pred_candidate=pred_direction==1 ? {1'b0,pred_base}+{1'b0,pred_step} :
    {1'b0,pred_base}-{1'b0,pred_step};
  wire [15:0] pred_unbounded=pred_candidate<4 ? 16'd4 :
    (pred_candidate>max_wide ? maximum : pred_candidate[15:0]);
  wire [15:0] pred_result=(pred_direction==1 && ceiling_active &&
    pred_unbounded>highlight_ceiling) ?
    (highlight_ceiling<o_exposure ? o_exposure : highlight_ceiling) : pred_unbounded;
  // A brightness-based reduction is also safe when highlights are excessive.
  // A dark mean must never turn highlight protection into an exposure increase.
  wire predict_correction=PREDICTIVE_ENABLE && !FIXED_STEP_ENABLE &&
    ((direction==1 && !high_over && !high_hold) ||
     (direction==2 && {1'b0,mean_control}>({1'b0,target}+settle_band)));
  assign o_exposure_constrained=i_enable && i_high_protect && o_ready &&
    (o_exposure>=maximum || (ceiling_active &&
      (!priority_active || safe_gap<=4 || o_highlight_limited)));
  assign o_ready=(state>=READY && state<=WRITE_WAIT) ||
    state==PREDICT_DIVIDE || state==PREDICT_APPLY;
  assign o_at_limit=o_ready && (o_exposure<=4 || o_exposure>=maximum);
  always @(*) begin
    candidate={1'b0,o_exposure};
    direction=0;
    // Full-frame highlights outrank mean brightness when protection is enabled.
    // Hysteresis holds exposure until the ratio falls below half the limit.
    if(high_over || {1'b0,mean_control}>({1'b0,target}+start_band) ||
       (brightness_direction==2 && {1'b0,mean_control}>({1'b0,target}+settle_band)) ||
       (!i_high_protect && i_highlights && mean_control>=target)) begin
      direction=2;
      candidate=o_exposure>step ? {1'b0,o_exposure}-{1'b0,step} : 17'd4;
    end else if(!high_hold && (({1'b0,mean_control}+start_band)<{1'b0,target} ||
       (brightness_direction==1 && ({1'b0,mean_control}+settle_band)<{1'b0,target}))) begin
      direction=1;
      candidate={1'b0,o_exposure}+{1'b0,step};
    end
    if(o_exposure<4 || candidate<4) next_exposure=16'd4;
    else if(o_exposure>maximum || candidate>max_wide) next_exposure=maximum;
    else next_exposure=candidate[15:0];
    if(direction==1 && ceiling_active && next_exposure>highlight_ceiling)
      next_exposure=highlight_ceiling<o_exposure ? o_exposure : highlight_ceiling;
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=BOOT;index<=0;exp_hi<=0;exp_mid<=0;exp_lo<=0;cooldown<=0;
      pending<=0;group_failed<=0;timer<=0;o_wr_en<=0;o_rd_en<=0;o_addr<=0;o_data<=0;
      o_exposure<=0;o_vts<=0;o_mean<=0;o_error<=0;
      o_highlight_limited<=0;ceiling_valid<=0;highlight_ceiling<=0;
      recovery_count<=0;ceiling_limit<=0;pending_high<=0;recovery_was_fast<=0;release_was_low<=0;
      unsafe_exposure<=0;safe_scene_mean<=0;safe_scene_valid<=0;scene_change_count<=0;
      filter_valid<=0;mean_filter<=0;high_filter<=0;previous_mean<=0;
      last_direction<=0;brightness_direction<=0;confirm_count<=0;release_count<=0;
      pred_dividend<=0;pred_quotient<=0;pred_estimate<=0;pred_divisor<=1;
      pred_remainder<=0;pred_bit<=0;pred_base<=0;pred_direction<=0;pred_large<=0;
    end else begin
      o_wr_en<=0;o_rd_en<=0;
      if(i_stats_valid) o_mean<=i_mean;
      if(!i_enable) begin
        o_highlight_limited<=0;filter_valid<=0;
        last_direction<=0;brightness_direction<=0;confirm_count<=0;release_count<=0;
      end
      if(!i_enable || !i_high_protect || ceiling_limit!=high_limit) begin
        ceiling_valid<=0;recovery_count<=0;safe_scene_valid<=0;scene_change_count<=0;
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
            else begin
              filter_valid<=1;mean_filter<=mean_next;high_filter<=high_next;
              previous_mean<=i_mean;
              // Remember settled safe-scene brightness, then invalidate a stale
              // highlight boundary only after a persistent dark-scene change.
              if(priority_active && ceiling_active) begin
                if(!safe_scene_valid && !high_hold && !high_over && !mean_jump) begin
                  safe_scene_mean<=mean_control;safe_scene_valid<=1;
                end
                if(scene_became_dark) begin
                  if(scene_change_count>=RELEASE_FRAMES-1) begin
                    ceiling_valid<=0;o_highlight_limited<=0;safe_scene_valid<=0;
                    scene_change_count<=0;
                  end else scene_change_count<=scene_change_count+1'b1;
                end else scene_change_count<=0;
              end else begin safe_scene_valid<=0;scene_change_count<=0;end
              // Learned limits are temporary: use 1/16 probes after eight
              // stable low-highlight samples, or 1/32 near the boundary; minimum 4.
              if(ceiling_active && !high_hold && direction==1 &&
                 o_exposure>=highlight_ceiling && recovery_headroom) begin
                recovery_was_fast<=recovery_fast;
                if(recovery_count!=0 && recovery_was_fast!=recovery_fast) recovery_count<=1;
                else if(recovery_count>=FAST_RECOVERY_FRAMES-1) begin
                  highlight_ceiling<=recovery_candidate>max_wide ? maximum : recovery_candidate[15:0];
                  recovery_count<=0;
                end else recovery_count<=recovery_count+1'b1;
              end else recovery_count<=0;
              if(mean_error<=settle_band) brightness_direction<=0;
              if(!i_high_protect) begin o_highlight_limited<=0;release_count<=0;end
              else if(high_control<={2'b0,high_release} || ((PREDICTIVE_ENABLE || FIXED_STEP_ENABLE) && recovery_headroom)) begin
                release_was_low<=high_control<={2'b0,high_release};
                if((PREDICTIVE_ENABLE || FIXED_STEP_ENABLE) && release_count!=0 && release_was_low!=(high_control<={2'b0,high_release}))
                  release_count<=1;
                else if(release_count>=((high_control<={2'b0,high_release}) ? RELEASE_FRAMES : RECOVERY_FRAMES)-1) begin
                  o_highlight_limited<=0;release_count<=0;
                end else release_count<=release_count+1'b1;
              end else release_count<=0;
              if(direction==0) begin last_direction<=0;confirm_count<=0;end
              else begin
                last_direction<=direction;
                if(direction!=last_direction || mean_jump) confirm_count<=1;
                else if(confirm_count<CONFIRM_FRAMES) confirm_count<=confirm_count+1'b1;
              end
              if(o_exposure<4 || o_exposure>maximum ||
                 (direction!=0 && (CONFIRM_FRAMES==1 ||
                  (!mean_jump && direction==last_direction && confirm_count>=CONFIRM_FRAMES-1)))) begin
                if(high_over) begin
                  o_highlight_limited<=1;
                  if(priority_active && (!ceiling_active || o_exposure<unsafe_exposure))
                    unsafe_exposure<=o_exposure;
                end
                if(next_exposure!=o_exposure) begin
                  pending_high<=high_over;
                  if(!high_over) brightness_direction<=direction;
                  if(predict_correction && o_exposure>=4 && o_exposure<=maximum) begin
                    pred_dividend<=o_exposure*target;
                    pred_divisor<=mean_control==0 ? 8'd1 : mean_control;
                    pred_quotient<=0;pred_remainder<=0;pred_bit<=0;
                    pred_base<=o_exposure;pred_direction<=direction;
                    pred_large<=mean_error>=LARGE_ERROR;
                    state<=PREDICT_DIVIDE;
                  end else begin pending<=next_exposure;state<=WAIT_FRAME;end
                  last_direction<=0;confirm_count<=0;
                end
              end
            end
          end
        end
        PREDICT_DIVIDE: begin
          if(!i_enable) state<=READY;
          else begin
            pred_remainder<=pred_subtract ? pred_trial-{1'b0,pred_divisor} : pred_trial;
            pred_dividend<={pred_dividend[22:0],1'b0};pred_quotient<=pred_next_q;
            if(pred_bit==23) begin pred_estimate<=pred_next_q;state<=PREDICT_APPLY;end
            else pred_bit<=pred_bit+1'b1;
          end
        end
        PREDICT_APPLY: begin
          if(!i_enable || (pred_direction==1 && (high_over || high_hold)) ||
             pred_goal==pred_base || pred_result==o_exposure) state<=READY;
          else begin pending<=pred_result;state<=WAIT_FRAME;end
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
            else begin
              o_exposure<=pending;cooldown<=WAIT_FRAMES;state<=READY;
              if((PREDICTIVE_ENABLE || FIXED_STEP_ENABLE) && pending_high && i_high_protect && i_enable) begin
                ceiling_valid<=1;highlight_ceiling<=pending;ceiling_limit<=high_limit;
                safe_scene_valid<=0;scene_change_count<=0;
              end
              recovery_count<=0;
              // Discard pre-change statistics; re-seed after DDR/sensor settling.
              filter_valid<=0;release_count<=0;last_direction<=0;confirm_count<=0;
            end
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
