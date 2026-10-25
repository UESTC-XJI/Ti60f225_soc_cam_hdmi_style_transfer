// One capture sampler: post-gain RGB AE Y sum and pre-gain BGGR RAW8 AWB.
// Pair column 0,8,...; AE rows 0,8,...; AWB cells rows (0,1),(8,9),...
// Native RAW is 8 bits here: the CSI gearbox already discarded RAW10 bits 1:0.
// No divider. Max 1080p: 32400 AE pixels, 16200 AWB cells; sums fit 32 bits.
// AWB keeps only the dark/saturation range check; neutral-colour rejection is firmware's.
module capture_frame_stats #(
  parameter integer FRAME_WIDTH=1920, FRAME_HEIGHT=1080, MIN_SAMPLES=16
)(
  input wire clk,rst_n,raw_vs,raw_de,
  input wire [15:0] raw_data,
  input wire rgb_vs,rgb_de,input wire [47:0] rgb_data,
  input wire [31:0] raw_cfg_seq,rgb_cfg_seq,
  input wire [7:0] high_threshold,
  input wire [31:0] awb_filter,
  input wire capture_fault,resize_fault,
  output reg stats_valid,output reg [383:0] stats_data,input wire stats_ready,
  output reg overrun
);
  localparam integer COLS=(FRAME_WIDTH/2+7)/8;
  // Bounds count every possible sparse position, including rejected/bad frames.
  localparam integer AE_MAX=2*COLS*((FRAME_HEIGHT+7)/8);
  localparam integer AWB_MAX=COLS*((FRAME_HEIGHT+6)/8);
  localparam integer AE_COUNT_W=$clog2(AE_MAX+1)>0 ? $clog2(AE_MAX+1):1;
  localparam integer AWB_COUNT_W=$clog2(AWB_MAX+1)>0 ? $clog2(AWB_MAX+1):1;
  localparam integer RB_W=$clog2(255*AWB_MAX+1)>0 ? $clog2(255*AWB_MAX+1):1;
  localparam integer G_W=$clog2(510*AWB_MAX+1)>0 ? $clog2(510*AWB_MAX+1):1;
  localparam integer Y_W=$clog2(255*AE_MAX+1)>0 ? $clog2(255*AE_MAX+1):1;
  reg rvs,rde,cvs,cde,rstarted,cstarted,rbad,cbad,raw_done;
  reg [11:0] rx,ry,cx,cy;
  reg [31:0] rid,cid,rtag,ctag,raw_done_id,raw_done_tag;
  reg [RB_W-1:0] rs,bs,done_rs,done_bs;
  reg [G_W-1:0] gs,done_gs;
  reg [AWB_COUNT_W-1:0] cells,total,done_cells,done_total;
  reg done_bad;
  reg [Y_W-1:0] ys;
  reg [AE_COUNT_W-1:0] samples,hot;
  // Sparse previous row only; never read before written in this frame.
  reg [15:0] previous_row[0:COLS-1];
  reg [7:0] threshold,dark_min,sat_max;
  wire raw_start=rvs&&!raw_vs,rgb_start=cvs&&!rgb_vs;
  wire raw_end=!rvs&&raw_vs,rgb_end=!cvs&&rgb_vs;
  wire raw_line=rde&&!raw_de,rgb_line=cde&&!rgb_de;
  wire raw_complete=(ry==FRAME_HEIGHT)||(raw_line&&ry==FRAME_HEIGHT-1);
  wire rgb_complete=(cy==FRAME_HEIGHT)||(rgb_line&&cy==FRAME_HEIGHT-1);
  wire raw_take=rstarted&&!raw_vs&&raw_de&&rx<FRAME_WIDTH/2&&ry<FRAME_HEIGHT&&rx[2:0]==0;
  wire rgb_take=cstarted&&!rgb_vs&&rgb_de&&cx<FRAME_WIDTH/2&&cy<FRAME_HEIGHT&&cx[2:0]==0&&cy[2:0]==0;
  reg [15:0] prev,raw_pair_q;
  reg awb_fetch;
  always @(posedge clk) begin
    if(rst_n&&raw_take&&ry[2:0]==0) previous_row[rx>>3]<=raw_data;
    prev<=previous_row[rx>>3];
  end
  wire [7:0] b=prev[7:0],g0=prev[15:8],g1=raw_pair_q[7:0],r=raw_pair_q[15:8];
  wire [8:0] greens={1'b0,g0}+{1'b0,g1};
  // One register stage between the RAM read and the accumulators.
  reg awb_valid,range_ok;
  reg [7:0] pr,pb;reg [8:0] pg;
  wire [9:0] y0={2'd0,rgb_data[7:0]}+{1'b0,rgb_data[15:8],1'b0}+{2'd0,rgb_data[23:16]};
  wire [9:0] y1={2'd0,rgb_data[31:24]}+{1'b0,rgb_data[39:32],1'b0}+{2'd0,rgb_data[47:40]};
  wire hot0=rgb_data[7:0]>=threshold||rgb_data[15:8]>=threshold||rgb_data[23:16]>=threshold;
  wire hot1=rgb_data[31:24]>=threshold||rgb_data[39:32]>=threshold||rgb_data[47:40]>=threshold;
  wire good=cstarted&&rgb_complete&&!cbad&&(!rgb_line||cx==FRAME_WIDTH/2)&&
    raw_done&&raw_done_id==cid&&raw_done_tag==ctag&&!done_bad&&
    samples>=MIN_SAMPLES&&!capture_fault&&!resize_fault;
  wire [31:0] flags={27'd0,(done_cells!=0),overrun,resize_fault,capture_fault,1'b1};
  // word0 Y,1 count,2 hot,3 R,4 G(two samples),5 B,6 N,7 total,
  // 8 flags,9 frame,10 config,11 source (1).
  wire [383:0] packet={32'd1,ctag,cid,flags,
    {{(32-AWB_COUNT_W){1'b0}},done_total},{{(32-AWB_COUNT_W){1'b0}},done_cells},
    {{(32-RB_W){1'b0}},done_bs},{{(32-G_W){1'b0}},done_gs},{{(32-RB_W){1'b0}},done_rs},
    {{(32-AE_COUNT_W){1'b0}},hot},{{(32-AE_COUNT_W){1'b0}},samples},{{(32-Y_W){1'b0}},ys}};
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      awb_valid<=0;range_ok<=0;pr<=0;pg<=0;pb<=0;awb_fetch<=0;raw_pair_q<=0;
      rvs<=0;rde<=0;cvs<=0;cde<=0;rx<=0;ry<=0;cx<=0;cy<=0;
      rstarted<=0;cstarted<=0;rbad<=0;cbad<=0;raw_done<=0;done_bad<=0;
      rid<=0;cid<=0;rtag<=0;ctag<=0;raw_done_id<=0;raw_done_tag<=0;
      rs<=0;gs<=0;bs<=0;cells<=0;total<=0;ys<=0;samples<=0;hot<=0;
      done_rs<=0;done_gs<=0;done_bs<=0;done_cells<=0;done_total<=0;
      threshold<=232;dark_min<=8;sat_max<=248;stats_valid<=0;stats_data<=0;overrun<=0;
    end else begin
      rvs<=raw_vs;rde<=raw_de;cvs<=rgb_vs;cde<=rgb_de;
      if(stats_valid&&stats_ready) stats_valid<=0;
      if(!raw_de) rx<=0;else if(rx<4095) rx<=rx+1'b1;
      if(!rgb_de) cx<=0;else if(cx<4095) cx<=cx+1'b1;
      if(raw_start) begin
        rx<=0;ry<=0;rid<=rid+1'b1;rtag<=raw_cfg_seq;rstarted<=1;rbad<=0;
        rs<=0;gs<=0;bs<=0;cells<=0;total<=0;
      end else if(raw_line) begin
        if(ry<4095) ry<=ry+1'b1;
        if(rstarted&&rx!=FRAME_WIDTH/2) rbad<=1;
      end
      if(raw_de && rx==0 && ry==0) begin dark_min<=awb_filter[15:8];sat_max<=awb_filter[23:16];end
      awb_fetch<=raw_take&&ry[2:0]==1;
      if(raw_take) raw_pair_q<=raw_data;
      awb_valid<=awb_fetch;
      if(awb_fetch)begin
        pr<=r;pg<=greens;pb<=b;
        range_ok<=b>=dark_min&&b<sat_max&&g0>=dark_min&&g0<sat_max&&
          g1>=dark_min&&g1<sat_max&&r>=dark_min&&r<sat_max;
      end
      if(awb_valid&&range_ok)begin
        rs<=rs+pr;gs<=gs+pg;bs<=bs+pb;cells<=cells+1'b1;
      end
      if(raw_take&&ry[2:0]==1) total<=total+1'b1;
      if(raw_end) begin
        rstarted<=0;raw_done<=rstarted;raw_done_id<=rid;raw_done_tag<=rtag;
        done_bad<=rbad||!raw_complete||(raw_line&&rx!=FRAME_WIDTH/2);
        done_rs<=rs;done_gs<=gs;done_bs<=bs;done_cells<=cells;done_total<=total;
      end
      if(rgb_start) begin
        cx<=0;cy<=0;cid<=cid+1'b1;ctag<=rgb_cfg_seq;cstarted<=1;cbad<=0;
        threshold<=high_threshold;ys<=0;samples<=0;hot<=0;
      end else if(rgb_line) begin
        if(cy<4095) cy<=cy+1'b1;
        if(cstarted&&cx!=FRAME_WIDTH/2) cbad<=1;
      end
      if(rgb_take) begin
        ys<=ys+{24'd0,y0[9:2]}+{24'd0,y1[9:2]};samples<=samples+2;
        hot<=hot+{31'd0,hot0}+{31'd0,hot1};
      end
      if(rgb_end) begin
        cstarted<=0;
        if(good) begin
          if(!stats_valid||stats_ready) begin stats_data<=packet;stats_valid<=1;end
          else overrun<=1;
        end
      end
    end
  end
endmodule
