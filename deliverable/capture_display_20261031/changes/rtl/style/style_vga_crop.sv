// Full-frame compression 1920x1080 -> 640x480 (replaces the central 1280x960
// crop).  Exact 3x3 area average -> 640x360, letterboxed with 60 blank lines
// at top and bottom, so the sensor's whole field of view is kept and the 16:9
// geometry is not squeezed.
//
// The 120 blank lines are emitted in the sensor's vertical blanking at
// 1 pixel per BAR_DIV clocks (148.5/3 = 49.5 Mpx/s < the 100 MHz frame-store
// reader), so the output contract stays exactly as before: 640x480 pixels per
// frame at 1 px/clk, sof on the first top bar, eof on the last bottom bar.
// Downstream (frame store 307,200 px/frame, 640x480 engine input, display row
// mapping) is untouched.
//
// Pipeline: the two input pixels of a clock are the earlier one in i_rgb[23:0]
// and the later one in i_rgb[47:24]; three pixels make one 10-bit horizontal
// sum (640 sums per 960-clock line).  Line y%3==0 fills lineA, y%3==1 fills
// lineB, y%3==2 reads both and adds its own sum -> 12-bit total -> rounded /9
// (no DSP, 4-stage divide-by-9).
module style_vga_crop #(
  parameter SOURCE_WIDTH=1920,SOURCE_HEIGHT=1080,WIDTH=640,HEIGHT=480,
  parameter SY=3,BAR_DIV=3
)(
  input wire clk,rst_n,i_vs,i_de,input wire [47:0] i_rgb,
  output reg valid,sof,eof,output reg [31:0] pixel,
  output reg fault,output reg [31:0] completed_frames
);
  localparam integer PAIRS=SOURCE_WIDTH/2;      // DE clocks per line
  localparam integer IMG_H=SOURCE_HEIGHT/SY;    // 360 image rows
  localparam integer BAR_R=(HEIGHT-IMG_H)/2;    // 60 top + 60 bottom
  localparam [1:0] B_IDLE=2'd0,B_BOT=2'd1,B_TOP=2'd2;

  // ---- input pixels: earlier pixel [23:0], later pixel [47:24] ----
  wire [9:0] c0r={2'b0,i_rgb[7:0]},  c0g={2'b0,i_rgb[15:8]},  c0b={2'b0,i_rgb[23:16]};
  wire [9:0] c1r={2'b0,i_rgb[31:24]},c1g={2'b0,i_rgb[39:32]}, c1b={2'b0,i_rgb[47:40]};

  reg vs_d,started,frame_open;
  reg [9:0] pair_x,hx;      // hx is the write index AND the emitted-sum count
  reg [10:0] y;
  reg [1:0] ph;             // y % SY
  reg [9:0] ar,ag,ab;       // partial horizontal sum (max 2*255)
  reg [1:0] hcnt;

  wire h0=(hcnt==2'd2);     // sum completes on the earlier pixel
  wire h1=(hcnt==2'd1);     // sum completes on the later pixel
  wire [9:0] hr=h0?ar+c0r:h1?ar+c0r+c1r:10'd0;
  wire [9:0] hg=h0?ag+c0g:h1?ag+c0g+c1g:10'd0;
  wire [9:0] hb=h0?ab+c0b:h1?ab+c0b+c1b:10'd0;
  wire hwr=i_de&&started&&(h0||h1);
  wire line_end=i_de&&started&&(pair_x==PAIRS-1);

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      vs_d<=0;started<=0;pair_x<=0;y<=0;ph<=0;ar<=0;ag<=0;ab<=0;hcnt<=0;hx<=0;
    end else begin
      vs_d<=i_vs;
      if(vs_d&&!i_vs) begin pair_x<=0;y<=0;ph<=0;started<=1;hcnt<=0;ar<=0;ag<=0;ab<=0;hx<=0; end
      else if(i_de&&started) begin
        if(line_end) begin
          pair_x<=0;hx<=0;
          if(y==SOURCE_HEIGHT-1) begin y<=0;ph<=0; end
          else begin y<=y+1'b1;ph<=(ph==SY-1)?2'd0:ph+2'd1;end
        end else begin
          pair_x<=pair_x+1'b1;
          if(hwr)hx<=hx+1'b1;
        end
        case(hcnt)
          2'd0:begin ar<=c0r+c1r;ag<=c0g+c1g;ab<=c0b+c1b;hcnt<=2'd2;end
          2'd1:begin ar<=0;ag<=0;ab<=0;hcnt<=0;end
          default:begin ar<=c1r;ag<=c1g;ab<=c1b;hcnt<=2'd1;end
        endcase
      end
    end
  end

  // ---- vertical accumulation (10-bit channel sums, 12-bit total) ----
  (* syn_ramstyle="block_ram" *) reg [29:0] lineA[0:WIDTH-1];
  (* syn_ramstyle="block_ram" *) reg [29:0] lineB[0:WIDTH-1];
  reg [29:0] aq,bq,hs_q;
  reg v1q,vt;
  reg [11:0] totR,totG,totB;
  reg [3:0] dv;
  always @(posedge clk) begin
    if(hwr) begin
      if(ph==2'd0)lineA[hx]<={hr,hg,hb};
      else if(ph==2'd1)lineB[hx]<={hr,hg,hb};
      else begin aq<=lineA[hx];bq<=lineB[hx];end
    end
    hs_q<={hr,hg,hb};
    v1q<=hwr&&(ph==2'd2);
    vt<=v1q;
    // Widen before adding: 10-bit part-selects summed in 10 bits would wrap
    // at 1023 (max total is 9*255 = 2295).
    totR<={2'b0,aq[29:20]}+{2'b0,bq[29:20]}+{2'b0,hs_q[29:20]};
    totG<={2'b0,aq[19:10]}+{2'b0,bq[19:10]}+{2'b0,hs_q[19:10]};
    totB<={2'b0,aq[9:0]}+{2'b0,bq[9:0]}+{2'b0,hs_q[9:0]};
    dv<={dv[2:0],vt};
  end
  wire [7:0] qr,qg,qb;
  wire img_valid=dv[3];
  style_div9 dR(.clk(clk),.n(totR),.q(qr));
  style_div9 dG(.clk(clk),.n(totG),.q(qg));
  style_div9 dB(.clk(clk),.n(totB),.q(qb));

  // ---- letterbox bars, emitted in the vertical blanking ----
  reg [1:0] bst;reg [6:0] brow;reg [9:0] bx;reg [1:0] bsub;reg [5:0] bwait;
  wire bar_on=(bst!=B_IDLE);
  wire bar_tick=bar_on&&(bsub==2'd0);
  wire bar_sof=bar_tick&&(bst==B_TOP)&&(bx==0)&&(brow==BAR_R);
  wire bar_eof=bar_tick&&(bst==B_BOT)&&(bx==WIDTH-1)&&(brow==1);
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin bst<=B_IDLE;brow<=0;bx<=0;bsub<=0;bwait<=0; end
    else begin
      // 48 clocks let the last image pixels leave the /9 pipeline first.
      if(line_end&&(y==SOURCE_HEIGHT-1)) bwait<=6'd48;
      else if(bwait!=0) bwait<=bwait-1'b1;
      if(bar_on) begin
        if(bar_tick) begin
          bsub<=BAR_DIV-1;
          if(bx==WIDTH-1) begin
            bx<=0;
            if(brow==1) begin
              if(bst==B_BOT)begin bst<=B_TOP;brow<=BAR_R;end
              else bst<=B_IDLE;
            end else brow<=brow-1'b1;
          end else bx<=bx+1'b1;
        end else bsub<=bsub-1'b1;
      end else if(bwait==6'd1) begin bst<=B_BOT;brow<=BAR_R;bx<=0;bsub<=BAR_DIV-1; end
    end
  end

  // ---- output stream ----
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin valid<=0;sof<=0;eof<=0;pixel<=0;fault<=0;completed_frames<=0;frame_open<=0; end
    else begin
      if(bar_on) begin
        valid<=bar_tick;pixel<=32'd0;sof<=bar_sof;eof<=bar_eof;
        if(bar_sof)frame_open<=1;
        if(bar_eof)begin frame_open<=0;if(frame_open)completed_frames<=completed_frames+1'b1;end
      end else begin
        valid<=img_valid;
        pixel<=img_valid?{8'd0,qb,qg,qr}:32'd0;
        sof<=1'b0;eof<=1'b0;
      end
      // Bars still running when active video returns => the blanking was too
      // short for this mode; never let it silently truncate the frame.
      if(i_de&&started&&(bar_on||bwait!=0))fault<=1'b1;
      // Every line must yield exactly WIDTH horizontal sums.
      if(line_end&&(hx+(hwr?1'b1:1'b0))!=WIDTH)fault<=1'b1;
    end
  end
endmodule

// Rounded divide-by-9 for n <= 9*255, four compare/subtract stages, no DSP.
module style_div9(input wire clk,input wire [11:0] n,output wire [7:0] q);
  reg [19:0] s0,s1,s2,s3;
  function [19:0] step;
    input [19:0] value;input integer high_bit;
    reg [11:0] remn,threshold;reg [7:0] quotient;integer k;
    begin
      remn=value[11:0];quotient=value[19:12];
      for(k=high_bit;k>high_bit-2;k=k-1) begin
        threshold=12'd9<<k;
        if(remn>=threshold) begin remn=remn-threshold;quotient[k]=1;end
      end
      step={quotient,remn};
    end
  endfunction
  always @(posedge clk) begin
    s0<=step({8'b0,n+12'd4},7);
    s1<=step(s0,5);
    s2<=step(s1,3);
    s3<=step(s2,1);
  end
  assign q=s3[19:12];
endmodule
