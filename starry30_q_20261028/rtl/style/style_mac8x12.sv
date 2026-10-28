// Eight output channels, twelve signed INT8 reduction terms per cycle.
// BN stays explicit: acc32 * M16 + B32, exact ties-away rounding and saturation.
// Global clock enable makes every pipeline stage stable under output backpressure.
module style_mac8x12 # (parameter ACC_WIDTH=32,AFFINE_WIDTH=48)(
  input wire clk, rst_n,
  input wire in_valid, output wire in_ready,
  input wire first, last,
  input wire [767:0] activations, weights,
  input wire [127:0] multipliers,
  input wire [255:0] biases,
  input wire [63:0] shifts,
  input wire relu,
  input wire [15:0] in_tag,
  input wire [63:0] in_skip,
  output reg out_valid, input wire out_ready,
  output reg [63:0] result,out_skip, output reg [15:0] out_tag
);
  wire ce=!out_valid || out_ready;
  assign in_ready=ce;
  reg [4:0] valid_pipe,first_pipe,last_pipe,relu_pipe;
  reg [15:0] tags[0:4];
  reg [63:0] skips[0:4];
  reg [127:0] mul_pipe[0:4]; reg [255:0] bias_pipe[0:4]; reg [63:0] shift_pipe[0:4];
  reg signed [15:0] product[0:95];
  reg signed [17:0] sum4[0:23];
  reg signed [19:0] dot[0:7];
  reg signed [ACC_WIDTH-1:0] accumulator[0:7], total[0:7];
  reg signed [AFFINE_WIDTH-1:0] affine[0:7];
  integer i,j;
  function [7:0] quantize;
    input signed [AFFINE_WIDTH-1:0] value; input [7:0] shift; input do_relu;
    reg [AFFINE_WIDTH:0] magnitude,rounded; reg signed [AFFINE_WIDTH+1:0] q;
    begin
      magnitude=value[AFFINE_WIDTH-1] ? -$signed({value[AFFINE_WIDTH-1],value}) : {1'b0,value};
      rounded=shift>AFFINE_WIDTH ? 0 :
        (magnitude+(shift==0 ? 0 : ({{AFFINE_WIDTH{1'b0}},1'b1}<<(shift[5:0]-1'b1))))>>shift[5:0];
      q=value[AFFINE_WIDTH-1] ? -$signed({1'b0,rounded}) : $signed({1'b0,rounded});
      if(do_relu && q<0) quantize=0;
      else if(q>127) quantize=8'h7f;
      else if(q < -128) quantize=8'h80;
      else quantize=q[7:0];
    end
  endfunction
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      valid_pipe<=0; first_pipe<=0; last_pipe<=0; relu_pipe<=0;
      out_valid<=0; result<=0; out_tag<=0;out_skip<=0;
      for(i=0;i<8;i=i+1) accumulator[i]<=0;
    end else if(ce) begin
      valid_pipe<={valid_pipe[3:0],in_valid};
      first_pipe<={first_pipe[3:0],first};last_pipe<={last_pipe[3:0],last};
      relu_pipe<={relu_pipe[3:0],relu};
      tags[0]<=in_tag;skips[0]<=in_skip;mul_pipe[0]<=multipliers;bias_pipe[0]<=biases;shift_pipe[0]<=shifts;
      for(i=1;i<5;i=i+1) begin
        tags[i]<=tags[i-1];skips[i]<=skips[i-1];mul_pipe[i]<=mul_pipe[i-1];bias_pipe[i]<=bias_pipe[i-1];shift_pipe[i]<=shift_pipe[i-1];
      end
      if(in_valid) for(i=0;i<96;i=i+1)
        product[i]<=$signed(activations[i*8+:8])*$signed(weights[i*8+:8]);
      if(valid_pipe[0]) for(i=0;i<24;i=i+1)
        sum4[i]<= {{2{product[i*4][15]}},product[i*4]} +
                  {{2{product[i*4+1][15]}},product[i*4+1]} +
                  {{2{product[i*4+2][15]}},product[i*4+2]} +
                  {{2{product[i*4+3][15]}},product[i*4+3]};
      if(valid_pipe[1]) for(i=0;i<8;i=i+1)
        dot[i]<= {{2{sum4[i*3][17]}},sum4[i*3]}+
                 {{2{sum4[i*3+1][17]}},sum4[i*3+1]}+
                 {{2{sum4[i*3+2][17]}},sum4[i*3+2]};
      if(valid_pipe[2]) for(i=0;i<8;i=i+1) begin
        accumulator[i]<=first_pipe[2] ? $signed(dot[i]) : accumulator[i]+$signed(dot[i]);
        total[i]<=first_pipe[2] ? $signed(dot[i]) : accumulator[i]+$signed(dot[i]);
      end
      if(valid_pipe[3] && last_pipe[3]) for(i=0;i<8;i=i+1)
        affine[i]<= $signed(total[i])*$signed(mul_pipe[3][i*16+:16])+
                    $signed(bias_pipe[3][i*32+:32]);
      out_valid<=valid_pipe[4] && last_pipe[4];
      if(valid_pipe[4] && last_pipe[4]) begin
        out_tag<=tags[4];out_skip<=skips[4];
        for(i=0;i<8;i=i+1) result[i*8+:8]<=quantize(affine[i],shift_pipe[4][i*8+:8],relu_pipe[4]);
      end
    end
  end
endmodule
