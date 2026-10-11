// One capture sampler: post-gain RGB AE/Y histogram and pre-gain BGGR RAW8
// AWB. Pair column 0,8,...; AE rows 0,8,...; AWB cells rows (0,1),(8,9),...
// Native RAW is 8 bits here: the CSI gearbox already discarded RAW10 bits 1:0.
// No divider. Max 1080p: 32400 AE pixels, 16200 AWB cells; sums fit 32 bits.
module capture_frame_stats #(
  parameter integer FRAME_WIDTH=1920, FRAME_HEIGHT=1080, MIN_SAMPLES=16
)(
  input wire clk,rst_n,raw_vs,raw_de,
  input wire [15:0] raw_data,
  input wire rgb_vs,rgb_de,input wire [47:0] rgb_data,
  input wire [31:0] raw_cfg_seq,rgb_cfg_seq,
  input wire [15:0] gain_r,gain_g,gain_b,
  input wire [7:0] high_threshold,
  input wire [31:0] awb_filter,input wire [15:0] neutral_ratio,
  input wire capture_fault,resize_fault,
  output reg stats_valid,output reg [383:0] stats_data,input wire stats_ready,
  input wire hist_request,
  output wire hist_valid,output wire [38:0] hist_data,input wire hist_ready,
  output reg overrun
);
  localparam integer COLS=(FRAME_WIDTH/2+7)/8;
  reg rvs,rde,cvs,cde,rstarted,cstarted,rbad,cbad,raw_done;
  reg [11:0] rx,ry,cx,cy;
  reg [31:0] rid,cid,rtag,ctag,raw_done_id,raw_done_tag;
  reg [31:0] rs,gs,bs,cells,total;
  reg [31:0] done_rs,done_gs,done_bs,done_cells,done_total;
  reg done_bad;
  reg [31:0] ys,samples,hot;
  // A counter bank remains frozen until the complete stream is accepted.
  // Valid bits provide logical zero without resetting or clearing the RAM.
  reg [15:0] hist_mem[0:127];
  reg active_bank,frozen_bank;
  reg [63:0] bin_valid,frozen_valid;
  reg [2:0] hist_state;
  reg [15:0] hist_q,freeze_q;
  reg stream_loaded;
  wire hist_we=(hist_state==3)||(hist_state==4);
  wire [5:0] hist_addr=rgb_take ? bin0 : hist_state==1 || hist_state==4 ? pending_bin1 : pending_bin0;
  wire [15:0] hist_wdata=hist_state==4 ? bin_value1+16'd1 :
    bin_value0+(pending_bin0==pending_bin1 ? 16'd2 : 16'd1);
  always @(posedge clk) begin
    if(rst_n&&hist_we&&!rgb_start) hist_mem[{active_bank,hist_addr}]<=hist_wdata;
    hist_q<=hist_mem[{active_bank,hist_addr}];
    freeze_q<=hist_mem[{frozen_bank,stream_index[5:0]-6'd14}];
  end
  reg [31:0] frozen_meta[0:13];
  // Sparse previous row only; never read before written in this frame.
  reg [15:0] previous_row[0:COLS-1];
  reg [7:0] threshold,dark_min,sat_max;
  reg neutral_enable;reg [15:0] ratio,gr,gg,gb;
  (* ASYNC_REG="TRUE" *) reg hist_req_meta,hist_req_sync;
  reg hist_seen,hist_pending,streaming;
  reg [6:0] stream_index;
  reg [5:0] pending_bin0,pending_bin1;
  reg [15:0] bin_value0,bin_value1;
  integer k;
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
  // Sparse AWB sample spacing is eight clocks. Pipeline RAW fetch, gain
  // products, min/max, ratio products and comparison instead of putting
  // the entire neutral filter in a 148.5 MHz combinational path.
  reg [3:0] awb_pipe_valid;
  reg [7:0] pr[0:3],pb[0:3];reg [8:0] pg[0:3];
  reg [3:0] range_ok;
  reg [25:0] corr_r,corr_g,corr_b,color_max,color_min;
  reg [41:0] neutral_lhs,neutral_rhs;
  wire candidate=range_ok[3]&&(!neutral_enable||neutral_lhs<=neutral_rhs);
  wire [9:0] y0={2'd0,rgb_data[7:0]}+{1'b0,rgb_data[15:8],1'b0}+{2'd0,rgb_data[23:16]};
  wire [9:0] y1={2'd0,rgb_data[31:24]}+{1'b0,rgb_data[39:32],1'b0}+{2'd0,rgb_data[47:40]};
  wire [5:0] bin0=y0[9:4],bin1=y1[9:4];
  wire hot0=rgb_data[7:0]>=threshold||rgb_data[15:8]>=threshold||rgb_data[23:16]>=threshold;
  wire hot1=rgb_data[31:24]>=threshold||rgb_data[39:32]>=threshold||rgb_data[47:40]>=threshold;
  wire good=cstarted&&rgb_complete&&!cbad&&(!rgb_line||cx==FRAME_WIDTH/2)&&
    raw_done&&raw_done_id==cid&&raw_done_tag==ctag&&!done_bad&&
    samples>=MIN_SAMPLES&&!capture_fault&&!resize_fault;
  wire [31:0] flags={27'd0,(done_cells!=0),overrun,resize_fault,capture_fault,1'b1};
  // word0 Y,1 count,2 hot,3 R,4 G(two samples),5 B,6 N,7 total,
  // 8 flags,9 frame,10 config,11 source (1).
  wire [383:0] packet={32'd1,ctag,cid,flags,done_total,done_cells,done_bs,done_gs,done_rs,hot,samples,ys};
  assign hist_valid=streaming&&stream_loaded;
  assign hist_data={stream_index,stream_index<14 ? frozen_meta[stream_index] : {16'd0,(frozen_valid[stream_index[5:0]-6'd14] ? freeze_q : 16'd0)}};
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      awb_pipe_valid<=0;range_ok<=0;corr_r<=0;corr_g<=0;corr_b<=0;color_max<=0;color_min<=0;neutral_lhs<=0;neutral_rhs<=0;
      hist_state<=0;active_bank<=0;frozen_bank<=1;bin_valid<=0;frozen_valid<=0;stream_loaded<=0;awb_fetch<=0;raw_pair_q<=0;pending_bin0<=0;pending_bin1<=0;bin_value0<=0;bin_value1<=0;
      for(k=0;k<4;k=k+1)begin pr[k]<=0;pg[k]<=0;pb[k]<=0;end
      rvs<=0;rde<=0;cvs<=0;cde<=0;rx<=0;ry<=0;cx<=0;cy<=0;
      rstarted<=0;cstarted<=0;rbad<=0;cbad<=0;raw_done<=0;done_bad<=0;
      rid<=0;cid<=0;rtag<=0;ctag<=0;raw_done_id<=0;raw_done_tag<=0;
      rs<=0;gs<=0;bs<=0;cells<=0;total<=0;ys<=0;samples<=0;hot<=0;
      done_rs<=0;done_gs<=0;done_bs<=0;done_cells<=0;done_total<=0;
      threshold<=232;dark_min<=8;sat_max<=248;neutral_enable<=0;ratio<=512;
      gr<=16'h168;gg<=256;gb<=16'h1a9;stats_valid<=0;stats_data<=0;overrun<=0;
      hist_req_meta<=0;hist_req_sync<=0;hist_seen<=0;hist_pending<=0;streaming<=0;stream_index<=0;
      for(k=0;k<14;k=k+1) frozen_meta[k]<=0;
    end else begin
      rvs<=raw_vs;rde<=raw_de;cvs<=rgb_vs;cde<=rgb_de;
      hist_req_meta<=hist_request;hist_req_sync<=hist_req_meta;
      if(hist_req_sync!=hist_seen) begin hist_seen<=hist_req_sync;hist_pending<=1;end
      if(stats_valid&&stats_ready) stats_valid<=0;
      if(streaming&&!stream_loaded) stream_loaded<=1;
      if(hist_valid&&hist_ready) begin
        stream_loaded<=0;
        if(stream_index==77) begin streaming<=0;stream_index<=0;end
        else stream_index<=stream_index+1'b1;
      end
      if(!raw_de) rx<=0;else if(rx<4095) rx<=rx+1'b1;
      if(!rgb_de) cx<=0;else if(cx<4095) cx<=cx+1'b1;
      if(raw_start) begin
        rx<=0;ry<=0;rid<=rid+1'b1;rtag<=raw_cfg_seq;rstarted<=1;rbad<=0;
        rs<=0;gs<=0;bs<=0;cells<=0;total<=0;

      end else if(raw_line) begin
        if(ry<4095) ry<=ry+1'b1;
        if(rstarted&&rx!=FRAME_WIDTH/2) rbad<=1;
      end
      if(raw_de && rx==0 && ry==0) begin
        dark_min<=awb_filter[15:8];sat_max<=awb_filter[23:16];neutral_enable<=awb_filter[0];
        ratio<=neutral_ratio;gr<=gain_r;gg<=gain_g;gb<=gain_b;
      end
      awb_fetch<=raw_take&&ry[2:0]==1;
      if(raw_take) raw_pair_q<=raw_data;
      awb_pipe_valid<={awb_pipe_valid[2:0],awb_fetch};
      if(awb_fetch)begin
        pr[0]<=r;pg[0]<=greens;pb[0]<=b;
        range_ok[0]<=b>=dark_min&&b<sat_max&&g0>=dark_min&&g0<sat_max&&
          g1>=dark_min&&g1<sat_max&&r>=dark_min&&r<sat_max;
      end
      for(k=1;k<4;k=k+1)begin pr[k]<=pr[k-1];pg[k]<=pg[k-1];pb[k]<=pb[k-1];range_ok[k]<=range_ok[k-1];end
      corr_r<=({18'd0,pr[0]}*gr)<<1;
      corr_g<={17'd0,pg[0]}*gg;
      corr_b<=({18'd0,pb[0]}*gb)<<1;
      color_max<=corr_r>corr_g?(corr_r>corr_b?corr_r:corr_b):(corr_g>corr_b?corr_g:corr_b);
      color_min<=corr_r<corr_g?(corr_r<corr_b?corr_r:corr_b):(corr_g<corr_b?corr_g:corr_b);
      neutral_lhs<={16'd0,color_max}<<8;neutral_rhs<=color_min*ratio;
      if(awb_pipe_valid[3]&&candidate)begin
        rs<=rs+pr[3];gs<=gs+pg[3];bs<=bs+pb[3];cells<=cells+1'b1;
      end
      if(raw_take) begin
        if(ry[2:0]==1) begin
          total<=total+1'b1;

        end
      end
      if(raw_end) begin
        rstarted<=0;raw_done<=rstarted;raw_done_id<=rid;raw_done_tag<=rtag;
        done_bad<=rbad||!raw_complete||(raw_line&&rx!=FRAME_WIDTH/2);
        done_rs<=rs;done_gs<=gs;done_bs<=bs;done_cells<=cells;done_total<=total;
      end
      if(rgb_start) begin
        cx<=0;cy<=0;cid<=cid+1'b1;ctag<=rgb_cfg_seq;cstarted<=1;cbad<=0;
        threshold<=high_threshold;ys<=0;samples<=0;hot<=0;
        bin_valid<=0;hist_state<=0;
      end else if(rgb_line) begin
        if(cy<4095) cy<=cy+1'b1;
        if(cstarted&&cx!=FRAME_WIDTH/2) cbad<=1;
      end
      // Two synchronous reads followed by at most two writes fit between
      // samples. Check both counts before either write (atomic overflow).
      if(!rgb_start) case(hist_state)
        1: begin
          bin_value0<=bin_valid[pending_bin0] ? hist_q : 16'd0;
          hist_state<=2;
        end
        2: begin
          bin_value1<=bin_valid[pending_bin1] ? hist_q : 16'd0;
          if((pending_bin0==pending_bin1 && bin_value0>65533)||
             (pending_bin0!=pending_bin1 && (bin_value0==65535||
              (bin_valid[pending_bin1]&&hist_q==65535)))) begin cbad<=1;hist_state<=0;end
          else hist_state<=3;
        end
        3: begin
          bin_valid[pending_bin0]<=1;
          hist_state<=pending_bin0==pending_bin1 ? 0 : 4;
        end
        4: begin bin_valid[pending_bin1]<=1;hist_state<=0;end
        default: begin end
      endcase
      if(rgb_take) begin
        ys<=ys+{24'd0,y0[9:2]}+{24'd0,y1[9:2]};samples<=samples+2;
        hot<=hot+{31'd0,hot0}+{31'd0,hot1};
        pending_bin0<=bin0;pending_bin1<=bin1;
        if(hist_state!=0) cbad<=1;
        else hist_state<=1;
      end
      if(rgb_end) begin
        cstarted<=0;
        if(good&&hist_state==0) begin
          if(!stats_valid||stats_ready) begin stats_data<=packet;stats_valid<=1;end
          else overrun<=1;
          if(hist_pending&&!streaming) begin
            hist_pending<=0;streaming<=1;stream_index<=0;stream_loaded<=0;
            frozen_bank<=active_bank;active_bank<=~active_bank;frozen_valid<=bin_valid;
            for(k=0;k<11;k=k+1) frozen_meta[k]<=packet[k*32+:32];
            frozen_meta[11]<=0;frozen_meta[12]<=0;frozen_meta[13]<=1;
          end
        end
      end
    end
  end
endmodule
