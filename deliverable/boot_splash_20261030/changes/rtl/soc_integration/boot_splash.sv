// Initialized BRAM image and precomputed fade palette: no RGB multipliers.
// 256x144 indexed image, nearest-neighbour 5x to the fixed 1280x720 raster.
module boot_splash #(
  parameter integer FRAME_STEP=3,HOLD_FRAMES=60,
  parameter IMAGE_FILE="assets/boot/pixels.hex",
  parameter PALETTE_FILE="assets/boot/fade_palette.hex"
)(
  input wire clk,rst_n,start_toggle,live_arm,live_valid,
  input wire live_hs,live_vs,live_de,input wire [7:0] live_r,live_g,live_b,
  output wire out_hs,out_vs,out_de,output wire [7:0] out_r,out_g,out_b,
  output wire busy,done,selected
);
  localparam integer FADE_FRAMES=16*FRAME_STEP;
  localparam integer TOTAL_FRAMES=2*FADE_FRAMES+HOLD_FRAMES;
  (* ram_style="block" *) reg [7:0] image_rom [0:36863];
  (* ram_style="block" *) reg [23:0] fade_rom [0:4095];
  initial begin $readmemh(IMAGE_FILE,image_rom);$readmemh(PALETTE_FILE,fade_rom);end
  (* async_reg="true" *)reg [1:0] start_sync,arm_sync,valid_sync;
  reg start_seen,playing,finished,live_selected,wait_live,live_vs_d;
  reg [7:0] frame_no;
  reg [3:0] level;
  reg [10:0] h;reg [9:0] v;
  // Divide-by-five coordinates use small counters, not arithmetic dividers.
  reg [2:0] x_repeat,y_repeat;reg [7:0] sx,sy;
  wire active=h>=260&&h<1540&&v>=25&&v<745;
  wire frame_start=h==0&&v==0;
  wire frame_end=h==1649&&v==749;
  wire live_edge=live_vs&&!live_vs_d;
  assign busy=playing;assign done=finished;assign selected=live_selected;
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
      start_sync<=0;arm_sync<=0;valid_sync<=0;start_seen<=0;
      playing<=0;finished<=0;live_selected<=0;wait_live<=0;live_vs_d<=0;
      frame_no<=0;level<=0;h<=0;v<=0;x_repeat<=0;y_repeat<=0;sx<=0;sy<=0;
    end else begin
      start_sync<={start_sync[0],start_toggle};arm_sync<={arm_sync[0],live_arm};
      valid_sync<={valid_sync[0],live_valid};live_vs_d<=live_vs;
      if(h==1649)begin h<=0;if(v==749)v<=0;else v<=v+1'b1;end else h<=h+1'b1;
      if(h==259)begin x_repeat<=0;sx<=0;end
      else if(h>=260&&h<1540)begin
        if(x_repeat==4)begin x_repeat<=0;sx<=sx+1'b1;end else x_repeat<=x_repeat+1'b1;
      end
      if(h==0)begin
        if(v==25)begin y_repeat<=0;sy<=0;end
        else if(v>25&&v<745)begin
          if(y_repeat==4)begin y_repeat<=0;sy<=sy+1'b1;end else y_repeat<=y_repeat+1'b1;
        end
      end
      if(start_sync[1]!=start_seen)begin
        start_seen<=start_sync[1];playing<=1;finished<=0;live_selected<=0;wait_live<=0;
        frame_no<=0;level<=0;
      end else begin
        if(playing&&frame_end)begin
          if(frame_no==TOTAL_FRAMES-1)begin playing<=0;finished<=1;level<=0;end
          else begin
            frame_no<=frame_no+1'b1;
            if(frame_no<FADE_FRAMES-1)begin
              if((frame_no+1)%FRAME_STEP==0)level<=level+1'b1;
            end else if(frame_no>=FADE_FRAMES+HOLD_FRAMES-1)begin
              if((frame_no-(FADE_FRAMES+HOLD_FRAMES-1))%FRAME_STEP==0&&level!=0)level<=level-1'b1;
            end
          end
        end
        // Complete a black boot frame before switching at a live VS edge.
        if(finished&&arm_sync[1]&&valid_sync[1]&&frame_end)wait_live<=1;
        if(wait_live&&live_edge&&arm_sync[1]&&valid_sync[1])live_selected<=1;
      end
    end
  end
  reg [7:0] index_q;reg [23:0] color_q;
  reg [3:0] level_q;
  reg [1:0] hs_q,vs_q,de_q,show_q;
  // Both memory reads are synchronous for BRAM inference. Delay timing equally.
  always @(posedge clk)begin
    index_q<=image_rom[active ? {sy,sx}:16'd0];
    level_q<=level;
    color_q<=fade_rom[{level_q,index_q}];
  end
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin hs_q<=0;vs_q<=0;de_q<=0;show_q<=0;end
    else begin
      hs_q<={hs_q[0],h<40};vs_q<={vs_q[0],v<5};de_q<={de_q[0],active};
      show_q<={show_q[0],playing&&active};
    end
  end
  assign out_hs=live_selected?live_hs:hs_q[1];
  assign out_vs=live_selected?live_vs:vs_q[1];
  assign out_de=live_selected?live_de:de_q[1];
  assign {out_r,out_g,out_b}=live_selected?{live_r,live_g,live_b}:(show_q[1]?color_q:24'd0);
endmodule
