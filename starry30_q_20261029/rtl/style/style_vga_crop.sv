// Central 1280x960 crop from 1920x1080, followed by rounded 2x2 averaging.
// One RGB pair per input clock produces one VGA pixel on alternate lines.
module style_vga_crop #(
  parameter SOURCE_WIDTH=1920,SOURCE_HEIGHT=1080,WIDTH=640,HEIGHT=480
)(
  input wire clk,rst_n,i_vs,i_de,input wire [47:0] i_rgb,
  output reg valid,sof,eof,output reg [31:0] pixel,
  output reg fault,output reg [31:0] completed_frames
);
  localparam X0=(SOURCE_WIDTH-WIDTH*2)/4,Y0=(SOURCE_HEIGHT-HEIGHT*2)/2;
  (* syn_ramstyle="block_ram" *) reg [26:0] line[0:WIDTH-1];
  reg vs_d,started,v1,s1,e1;reg [10:0] pair_x,y;
  reg [26:0] previous,current;reg [26:0] pair_sum;
  reg [9:0] total;integer c;
  always @* begin
    pair_sum=0;
    for(c=0;c<3;c=c+1)pair_sum[c*9+:9]={1'b0,i_rgb[c*8+:8]}+{1'b0,i_rgb[24+c*8+:8]};
  end
  wire inside_crop=started&&i_de&&pair_x>=X0&&pair_x<X0+WIDTH&&y>=Y0&&y<Y0+HEIGHT*2;
  wire odd_row=(y-Y0)&1;
  always @(posedge clk) if(inside_crop&&!fault)begin
    if(!odd_row)line[pair_x-X0]<=pair_sum;
    else begin previous<=line[pair_x-X0];current<=pair_sum;end
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      vs_d<=0;started<=0;pair_x<=0;y<=0;valid<=0;sof<=0;eof<=0;pixel<=0;fault<=0;completed_frames<=0;
      v1<=0;s1<=0;e1<=0;
    end else begin
      vs_d<=i_vs;v1<=inside_crop&&odd_row&&!fault;
      s1<=pair_x==X0&&y==Y0+1;e1<=pair_x==X0+WIDTH-1&&y==Y0+HEIGHT*2-1;
      valid<=v1;sof<=s1&&v1;eof<=e1&&v1;
      if(v1)begin
        pixel<=0;
        for(c=0;c<3;c=c+1)begin
          total={1'b0,previous[c*9+:9]}+{1'b0,current[c*9+:9]}+10'd2;
          pixel[c*8+:8]<=total[9:2];
        end
        if(e1)completed_frames<=completed_frames+1'b1;
      end
      if(vs_d&&!i_vs)begin pair_x<=0;y<=0;started<=1;end
      else if(i_de&&started)begin
        if(pair_x==SOURCE_WIDTH/2-1)begin pair_x<=0;if(y==SOURCE_HEIGHT-1)y<=0;else y<=y+1'b1;end
        else pair_x<=pair_x+1'b1;
      end
    end
  end
endmodule
