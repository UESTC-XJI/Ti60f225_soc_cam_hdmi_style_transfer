// Display-luma loop only: never changes sensor exposure or the RAW mean.
// Post-lift samples include the real curve and RGB headroom limiting.
module auto_tone_lift #(
  parameter WAIT_FRAMES=2, CONFIRM_FRAMES=2, DEADBAND=3
)(
  input clk,rst_n,i_enable,i_valid,i_can_lift,
  input [7:0] i_mean,i_target,i_max_strength,i_manual_strength,
  output [7:0] o_strength,
  output o_at_max
);
  reg [7:0] automatic_strength,cooldown,confirm_count;
  reg [1:0] previous_direction;
  wire [7:0] maximum=i_max_strength>128 ? 8'd128 : i_max_strength;
  wire [7:0] target=i_target<16 ? 8'd16 : (i_target>224 ? 8'd224 : i_target);
  wire [8:0] error=i_mean>target ? {1'b0,i_mean}-{1'b0,target} : {1'b0,target}-{1'b0,i_mean};
  wire [7:0] step=!i_can_lift ? 8'd16 : error>=24 ? 8'd16 : (error>=12 ? 8'd8 : (error>=6 ? 8'd4 : 8'd1));
  wire [1:0] direction=!i_can_lift ? (automatic_strength!=0 ? 2'd2 : 2'd0) : error<=DEADBAND ? 2'd0 : (i_mean<target ? 2'd1 : 2'd2);
  wire [8:0] increase={1'b0,automatic_strength}+{1'b0,step};
  wire [7:0] next_strength=direction==1 ? (increase>{1'b0,maximum} ? maximum : increase[7:0]) :
    (automatic_strength>step ? automatic_strength-step : 8'd0);
  assign o_strength=i_enable ? (automatic_strength>maximum ? maximum : automatic_strength) :
    (i_manual_strength>128 ? 8'd128 : i_manual_strength);
  assign o_at_max=i_enable && automatic_strength>=maximum;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin automatic_strength<=0;cooldown<=WAIT_FRAMES;confirm_count<=0;previous_direction<=0;end
    else if(!i_enable) begin automatic_strength<=0;cooldown<=WAIT_FRAMES;confirm_count<=0;previous_direction<=0;end
    else if(automatic_strength>maximum) begin
      automatic_strength<=maximum;cooldown<=WAIT_FRAMES;confirm_count<=0;previous_direction<=0;
    end else if(i_valid) begin
      if(cooldown!=0) cooldown<=cooldown-1'b1;
      else begin
        previous_direction<=direction;
        if(direction==0) confirm_count<=0;
        else if(direction!=previous_direction) confirm_count<=1;
        else if(confirm_count<CONFIRM_FRAMES) confirm_count<=confirm_count+1'b1;
        if(direction!=0 && (CONFIRM_FRAMES==1 ||
           (direction==previous_direction && confirm_count>=CONFIRM_FRAMES-1)) && next_strength!=automatic_strength) begin
          automatic_strength<=next_strength;cooldown<=WAIT_FRAMES;confirm_count<=0;previous_direction<=0;
        end
      end
    end
  end
endmodule
