// Sole Sapphire video APB entry. Full 16-bit decode prevents high-address aliases.
module video_apb_ctrl #(parameter integer CHAR_ADDR_W=7,parameter [31:0] CORE_ID=32'h4f534431,
  parameter integer FRAME_WIDTH=1920,FRAME_HEIGHT=1080,MIN_SAMPLES=16)(
  input logic pclk,preset_n,psel,penable,pwrite,
  input logic [15:0] paddr,input logic [31:0] pwdata,
  output logic [31:0] prdata, output logic pready,pslverr,
  output logic o_enable, output logic [11:0] o_x,o_y, output logic [23:0] o_color,
  output logic o_char_we, output logic [CHAR_ADDR_W-1:0] o_char_addr, output logic o_char_page, output logic [7:0] o_char_data,
  output logic o_commit_toggle, output logic o_commit_page, output logic o_video_ready,
  input logic i_ack_toggle, input logic i_active_page, input logic i_busy,
  input logic [15:0] i_frame_count, input logic [15:0] i_capture_fps,
  input logic [15:0] i_display_fps, input logic [15:0] i_drop_count, input logic [15:0] i_error_count,
  input logic [15:0] i_raw_fps,
  input wire capture_clk,display_clk,raw_vs,raw_de,rgb_vs,rgb_de,display_vs,
  input wire [15:0] raw_data,input wire [47:0] rgb_data,
  input wire capture_fault,resize_fault,raw_event,
  input wire [31:0] drop_count32,axi_errors32,underflows32,resize_frames32,display_frames32,
  input wire display_stats_valid,input wire [7:0] display_mean,display_strength,input wire display_at_max,
  input wire [6:0] csi_errors,input wire [4:0] reset_status,
  output wire [15:0] gain_r,gain_g,gain_b,
  output wire [31:0] display_tone,display_lift,
  output wire [2:0] display_hist
);
  wire legacy_hit=paddr<=16'h0030;
  wire [31:0] legacy_data;wire legacy_ready,legacy_error;
  osd_apb_regs #(.CHAR_ADDR_W(CHAR_ADDR_W),.CORE_ID(CORE_ID)) legacy(
.pclk(pclk),.preset_n(preset_n),.penable(penable),.pwrite(pwrite),.paddr(paddr),.pwdata(pwdata),.o_enable(o_enable),.o_x(o_x),.o_y(o_y),.o_color(o_color),.o_char_we(o_char_we),.o_char_addr(o_char_addr),.o_char_page(o_char_page),.o_char_data(o_char_data),.o_commit_toggle(o_commit_toggle),.o_commit_page(o_commit_page),.o_video_ready(o_video_ready),.i_ack_toggle(i_ack_toggle),.i_active_page(i_active_page),.i_busy(i_busy),.i_frame_count(i_frame_count),.i_capture_fps(i_capture_fps),.i_display_fps(i_display_fps),.i_drop_count(i_drop_count),.i_error_count(i_error_count),.i_raw_fps(i_raw_fps),.psel(psel&&legacy_hit),.prdata(legacy_data),.pready(legacy_ready),.pslverr(legacy_error));

  localparam [127:0] CAP_DEFAULT={24'd0,16'h0200,32'h00f80800,8'd232,16'h01a9,16'h0100,16'h0168};
  localparam [127:0] DISP_DEFAULT={45'd0,3'd0,16'd0,32'h00002001,32'h00202001};
  reg [127:0] cap_shadow,disp_shadow,cap_pending,disp_pending,cap_mirror,disp_mirror;
  reg cap_req,disp_req;wire cap_ack,disp_ack;
  (* ASYNC_REG="TRUE" *) reg [1:0] cap_ack_sync,disp_ack_sync;
  wire cap_busy=cap_req!=cap_seen,disp_busy=disp_req!=disp_seen;
  reg cap_seen,disp_seen;reg [31:0] cap_seq,disp_seq;
  wire [127:0] cap_active,disp_active;wire [31:0] cap_source_seq,cap_frame_seq;
  wire [31:0] unused_disp_seq,unused_disp_frame;
  video_cfg_cdc #(.WIDTH(128),.DEFAULT_VALUE(CAP_DEFAULT)) capture_config(
    .clk(capture_clk),.rst_n(preset_n),.vs(raw_vs),.request(cap_req),.payload(cap_pending),
    .acknowledge(cap_ack),.active(cap_active),.sequence_id(cap_source_seq),.frame_sequence(cap_frame_seq));
  video_cfg_cdc #(.WIDTH(128),.DEFAULT_VALUE(DISP_DEFAULT),.FALLING_EDGE(0)) display_config(
    .clk(display_clk),.rst_n(preset_n),.vs(display_vs),.request(disp_req),.payload(disp_pending),
    .acknowledge(disp_ack),.active(disp_active),.sequence_id(unused_disp_seq),.frame_sequence(unused_disp_frame));
  assign gain_r=cap_active[15:0];assign gain_g=cap_active[31:16];assign gain_b=cap_active[47:32];
  assign display_tone=disp_active[31:0];assign display_lift=disp_active[63:32];assign display_hist=disp_active[82:80];
  // Gain (1) + line_buffer (2) + raw_to_rgb VS pipeline (2) = five clocks.
  // Shift the effective source-edge version with that exact VS latency.
  reg [31:0] tag_pipe[0:4];integer t;
  always @(posedge capture_clk or negedge preset_n) begin
    if(!preset_n) for(t=0;t<5;t=t+1) tag_pipe[t]<=0;
    else begin tag_pipe[0]<=cap_frame_seq;for(t=1;t<5;t=t+1) tag_pipe[t]<=tag_pipe[t-1];end
  end
  wire stats_valid,stats_ready,stats_arrived;wire [383:0] stats_payload,stats_received;
  wire stream_valid,stream_ready,stream_arrived;wire [38:0] stream_payload,stream_received;
  wire source_overrun;reg hist_req;
  capture_frame_stats #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),.MIN_SAMPLES(MIN_SAMPLES)) capture_statistics(
    .clk(capture_clk),.rst_n(preset_n),.raw_vs(raw_vs),.raw_de(raw_de),.raw_data(raw_data),
    .rgb_vs(rgb_vs),.rgb_de(rgb_de),.rgb_data(rgb_data),.raw_cfg_seq(cap_frame_seq),.rgb_cfg_seq(tag_pipe[4]),
    .gain_r(gain_r),.gain_g(gain_g),.gain_b(gain_b),.high_threshold(cap_active[55:48]),
    .awb_filter(cap_active[87:56]),.neutral_ratio(cap_active[103:88]),
    .capture_fault(capture_fault),.resize_fault(resize_fault),.stats_valid(stats_valid),.stats_data(stats_payload),
    .stats_ready(stats_ready),.hist_request(hist_req),.hist_valid(stream_valid),.hist_data(stream_payload),
    .hist_ready(stream_ready),.overrun(source_overrun));
  isp_cdc_mailbox #(.WIDTH(384)) scalar_mailbox(
    .s_clk(capture_clk),.s_rst_n(preset_n),.s_valid(stats_valid),.s_ready(stats_ready),.s_data(stats_payload),
    .d_clk(pclk),.d_rst_n(preset_n),.d_valid(stats_arrived),.d_data(stats_received));
  isp_cdc_mailbox #(.WIDTH(39)) histogram_mailbox(
    .s_clk(capture_clk),.s_rst_n(preset_n),.s_valid(stream_valid),.s_ready(stream_ready),.s_data(stream_payload),
    .d_clk(pclk),.d_rst_n(preset_n),.d_valid(stream_arrived),.d_data(stream_received));
  wire display_stats_arrived;wire [31:0] display_stats_received;
  reg [31:0] display_stats_seq,display_stats_value;
  isp_cdc_mailbox #(.WIDTH(32)) display_stats_mailbox(
    .s_clk(display_clk),.s_rst_n(preset_n),.s_valid(display_stats_valid),.s_ready(),
    .s_data({14'd0,1'b1,display_at_max,display_strength,display_mean}),
    .d_clk(pclk),.d_rst_n(preset_n),.d_valid(display_stats_arrived),.d_data(display_stats_received));
  reg [383:0] scalar;reg [31:0] stats_seq,raw_frames;reg [63:0] ticks,stats_time;
  reg [31:0] hist_cache[0:63],hist_meta[0:13];
  reg [5:0] bin_index;reg [3:0] meta_index;
  reg hist_busy,hist_locked,hist_fault;reg [31:0] hist_seq;
  reg [6:0] expected_word;wire [6:0] incoming_word=stream_received[38:32];
  (* ASYNC_REG="TRUE" *) reg [2:0] faults_meta,faults_sync;
  (* ASYNC_REG="TRUE" *) reg [6:0] csi_meta,csi_sync;
  (* ASYNC_REG="TRUE" *) reg [4:0] reset_meta,reset_sync;
  reg [31:0] fault_sticky;
  wire access=psel&&penable;
  reg ext_legal,ext_writable,value_error;
  wire filter_valid=cap_shadow[71:64]>0&&cap_shadow[71:64]<cap_shadow[79:72]&&cap_shadow[103:88]>=256;
  assign pready=1'b1;
  assign pslverr=legacy_hit?legacy_error:(access&&(!ext_legal||(pwrite&&!ext_writable)||value_error));
  always @* begin
    ext_legal=1;ext_writable=0;value_error=0;prdata=0;
    if(legacy_hit) prdata=legacy_data;
    else case(paddr)
      16'h034:prdata=32'h00010000;
      16'h038:prdata=32'h000001ff;
      16'h03c:prdata={27'd0,reset_sync};
      16'h040:begin ext_writable=1;prdata={16'd0,cap_shadow[15:0]};end
      16'h044:begin ext_writable=1;prdata={16'd0,cap_shadow[31:16]};end
      16'h048:begin ext_writable=1;prdata={16'd0,cap_shadow[47:32]};end
      16'h04c:begin ext_writable=1;prdata=disp_shadow[31:0];end
      16'h050:begin
        ext_writable=1;
        if(pwrite) value_error=pwdata==0||pwdata[31:2]!=0||(pwdata[0]&&(cap_busy||!filter_valid||
          cap_shadow[15:0]==0||cap_shadow[31:16]==0||cap_shadow[47:32]==0))||(pwdata[1]&&disp_busy);
      end
      16'h054:prdata={30'd0,disp_busy,cap_busy};
      16'h058:prdata=cap_seq;
      16'h05c:prdata=disp_seq;
      16'h060:prdata={16'd0,cap_mirror[15:0]};
      16'h064:prdata={16'd0,cap_mirror[31:16]};
      16'h068:prdata={16'd0,cap_mirror[47:32]};
      16'h06c:prdata=disp_mirror[31:0];
      16'h080:begin ext_writable=1;prdata=disp_shadow[63:32];if(pwrite&&pwdata[1]) value_error=1;end
      16'h084:begin ext_writable=1;prdata={16'd0,disp_shadow[79:64]};end
      16'h088:prdata=disp_mirror[63:32];
      16'h08c:prdata={16'd0,disp_mirror[79:64]};
      16'h090:prdata=display_stats_seq;
      16'h094:prdata=display_stats_value;
      16'h0c0:prdata=stats_seq;
      16'h0c4:prdata=scalar[0*32+:32];
      16'h0c8:prdata=stats_time[31:0];
      16'h0cc:prdata=stats_time[63:32];
      16'h0d0:prdata=scalar[8*32+:32]|{28'd0,faults_sync[2],faults_sync[1:0],1'b0};
      16'h0d4:begin ext_writable=1;prdata={24'd0,cap_shadow[55:48]};end
      16'h0d8:prdata=scalar[9*32+:32];
      16'h0dc:prdata=scalar[10*32+:32];
      16'h0e0:prdata=raw_frames;
      16'h0e4:prdata=scalar[1*32+:32];
      16'h0e8:prdata=scalar[2*32+:32];
      16'h0ec:prdata=1;
      16'h100:begin ext_writable=1;prdata={29'd0,disp_shadow[82:80]};end
      16'h104:prdata={29'd0,disp_mirror[82:80]};
      16'h108:begin
        ext_writable=1;
        if(pwrite) value_error=(pwdata!=1&&pwdata!=2)||(pwdata==1&&(hist_busy||hist_locked))||(pwdata==2&&hist_busy);
      end
      16'h10c:prdata={22'd0,2'd1,5'd0,hist_fault,hist_locked,hist_busy};
      16'h110:prdata=hist_meta[9];
      16'h114:prdata=hist_meta[1];
      16'h118:begin ext_writable=1;prdata={26'd0,bin_index};if(pwrite&&pwdata>63)value_error=1;end
      16'h11c:begin prdata=hist_cache[bin_index];if(!pwrite&&!hist_locked)value_error=1;end
      16'h120:prdata=hist_meta[10];
      16'h124:prdata=hist_seq;
      16'h128:begin ext_writable=1;prdata={28'd0,meta_index};if(pwrite&&pwdata>13)value_error=1;end
      16'h12c:begin prdata=hist_meta[meta_index];if(!pwrite&&!hist_locked)value_error=1;end
      16'h140:prdata=fault_sticky;
      16'h144:prdata=drop_count32;
      16'h148:prdata=axi_errors32;
      16'h14c:prdata=underflows32;
      16'h150:prdata=raw_frames;
      16'h154:prdata=resize_frames32;
      16'h158:prdata=display_frames32;
      16'h15c:prdata={25'd0,csi_sync};
      16'h160:prdata={27'd0,reset_sync};
      16'h180:prdata=scalar[3*32+:32];
      16'h184:prdata=scalar[4*32+:32];
      16'h188:prdata=scalar[5*32+:32];
      16'h18c:prdata=scalar[6*32+:32];
      16'h190:begin ext_writable=1;prdata=cap_shadow[87:56];end
      16'h194:begin ext_writable=1;prdata={16'd0,cap_shadow[103:88]};end
      16'h198:prdata=cap_mirror[87:56];
      16'h19c:prdata={16'd0,cap_mirror[103:88]};
      16'h1a0:prdata=scalar[7*32+:32];
      default:ext_legal=0;
    endcase
  end
  integer i;
  always @(posedge pclk or negedge preset_n) begin
    if(!preset_n) begin
      cap_shadow<=CAP_DEFAULT;cap_pending<=CAP_DEFAULT;cap_mirror<=CAP_DEFAULT;
      disp_shadow<=DISP_DEFAULT;disp_pending<=DISP_DEFAULT;disp_mirror<=DISP_DEFAULT;
      cap_req<=0;disp_req<=0;cap_seen<=0;disp_seen<=0;cap_ack_sync<=0;disp_ack_sync<=0;cap_seq<=0;disp_seq<=0;
      display_stats_seq<=0;display_stats_value<=0;scalar<=0;stats_seq<=0;raw_frames<=0;ticks<=0;stats_time<=0;
      hist_req<=0;hist_busy<=0;hist_locked<=0;hist_fault<=0;hist_seq<=0;expected_word<=0;bin_index<=0;meta_index<=0;
      faults_meta<=0;faults_sync<=0;csi_meta<=0;csi_sync<=0;reset_meta<=0;reset_sync<=0;fault_sticky<=0;
      for(i=0;i<64;i=i+1) hist_cache[i]<=0;
      for(i=0;i<14;i=i+1) hist_meta[i]<=0;
    end else begin
      ticks<=ticks+1'b1;if(raw_event)raw_frames<=raw_frames+1'b1;
      cap_ack_sync<={cap_ack_sync[0],cap_ack};disp_ack_sync<={disp_ack_sync[0],disp_ack};
      faults_meta<={source_overrun,resize_fault,capture_fault};faults_sync<=faults_meta;
      csi_meta<=csi_errors;csi_sync<=csi_meta;reset_meta<=reset_status;reset_sync<=reset_meta;
      fault_sticky<=fault_sticky|{24'd0,hist_fault,faults_sync[2],1'b0,(|csi_sync),(|axi_errors32),(|underflows32),faults_sync[1:0]};
      if(cap_seen!=cap_ack_sync[1]) begin cap_seen<=cap_ack_sync[1];cap_mirror<=cap_pending;cap_seq<=cap_seq+1'b1;end
      if(disp_seen!=disp_ack_sync[1]) begin disp_seen<=disp_ack_sync[1];disp_mirror<=disp_pending;disp_seq<=disp_seq+1'b1;end
      if(access&&pwrite&&pslverr&&paddr==16'h050)fault_sticky[5]<=1;
      if(display_stats_arrived)begin display_stats_value<=display_stats_received;display_stats_seq<=display_stats_seq+1'b1;end
      if(stats_arrived) begin scalar<=stats_received;stats_seq<=stats_seq+1'b1;stats_time<=ticks;end
      if(stream_arrived) begin
        if(!hist_busy||incoming_word!=expected_word) begin hist_fault<=1;hist_busy<=0;end
        else begin
          if(incoming_word<14) hist_meta[incoming_word]<=stream_received[31:0];
          else hist_cache[incoming_word-14]<=stream_received[31:0];
          expected_word<=expected_word+1'b1;
          if(incoming_word==77) begin
            hist_busy<=0;hist_locked<=1;hist_seq<=hist_seq+1'b1;
            hist_meta[11]<=ticks[31:0];hist_meta[12]<=ticks[63:32];
          end
        end
      end
      if(access&&pwrite&&!legacy_hit&&!pslverr) case(paddr)
        16'h040:cap_shadow[15:0]<=pwdata[15:0];
        16'h044:cap_shadow[31:16]<=pwdata[15:0];
        16'h048:cap_shadow[47:32]<=pwdata[15:0];
        16'h04c:disp_shadow[31:0]<=pwdata&32'h00ffff01;
        16'h050:begin
          if(pwdata[0])begin cap_pending<=cap_shadow;cap_req<=~cap_req;end
          if(pwdata[1])begin disp_pending<=disp_shadow;disp_req<=~disp_req;end
        end
        16'h080:disp_shadow[63:32]<=pwdata&32'h0000ff01;
        16'h084:disp_shadow[79:64]<=pwdata[15:0];
        16'h0d4:cap_shadow[55:48]<=pwdata[7:0];
        16'h100:disp_shadow[82:80]<=pwdata[2:0];
        16'h108:if(pwdata==1)begin hist_req<=~hist_req;hist_busy<=1;hist_locked<=0;hist_fault<=0;expected_word<=0;end
                   else hist_locked<=0;
        16'h118:bin_index<=pwdata[5:0];
        16'h128:meta_index<=pwdata[3:0];
        16'h190:cap_shadow[87:56]<=pwdata&32'h00ffff01;
        16'h194:cap_shadow[103:88]<=pwdata[15:0];
        default:;
      endcase
    end
  end
endmodule
