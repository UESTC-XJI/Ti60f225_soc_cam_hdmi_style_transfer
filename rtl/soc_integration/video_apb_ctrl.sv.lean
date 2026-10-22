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
  wire [31:0] legacy_data=(paddr==16'h0000)?CORE_ID:32'd0;
  wire legacy_ready=1'b1,legacy_error=1'b0;
  // 2026-10-21: OSD text page removed; FPS overlay is LUT-based (fps_overlay).
  assign o_enable=1'b0; assign o_x=12'd0; assign o_y=12'd0; assign o_color=24'd0;
  assign o_char_we=1'b0; assign o_char_addr={CHAR_ADDR_W{1'b0}}; assign o_char_page=1'b0; assign o_char_data=8'd0;
  assign o_commit_toggle=1'b0; assign o_commit_page=1'b0; assign o_video_ready=1'b1;

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
  reg [31:0] raw_frames;
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
      16'h090:prdata=32'd0;
      16'h094:prdata=32'd0;
      16'h0c0:prdata=32'd0;
      16'h0c4:prdata=32'd0;
      16'h0c8:prdata=32'd0;
      16'h0cc:prdata=32'd0;
      16'h0d0:prdata={28'd0,faults_sync[2],faults_sync[1:0],1'b0};
      16'h0d4:begin ext_writable=1;prdata={24'd0,cap_shadow[55:48]};end
      16'h0d8:prdata=32'd0;
      16'h0dc:prdata=32'd0;
      16'h0e0:prdata=raw_frames;
      16'h0e4:prdata=32'd0;
      16'h0e8:prdata=32'd0;
      16'h0ec:prdata=1;
      16'h100:begin ext_writable=1;prdata={29'd0,disp_shadow[82:80]};end
      16'h104:prdata={29'd0,disp_mirror[82:80]};
      16'h140:prdata=fault_sticky;
      16'h144:prdata=drop_count32;
      16'h148:prdata=axi_errors32;
      16'h14c:prdata=underflows32;
      16'h150:prdata=raw_frames;
      16'h154:prdata=resize_frames32;
      16'h158:prdata=display_frames32;
      16'h15c:prdata={25'd0,csi_sync};
      16'h160:prdata={27'd0,reset_sync};
      16'h180:prdata=32'd0;
      16'h184:prdata=32'd0;
      16'h188:prdata=32'd0;
      16'h18c:prdata=32'd0;
      16'h190:begin ext_writable=1;prdata=cap_shadow[87:56];end
      16'h194:begin ext_writable=1;prdata={16'd0,cap_shadow[103:88]};end
      16'h198:prdata=cap_mirror[87:56];
      16'h19c:prdata={16'd0,cap_mirror[103:88]};
      16'h1a0:prdata=32'd0;
      default:ext_legal=0;
    endcase
  end
  integer i;
  always @(posedge pclk or negedge preset_n) begin
    if(!preset_n) begin
      cap_shadow<=CAP_DEFAULT;cap_pending<=CAP_DEFAULT;cap_mirror<=CAP_DEFAULT;
      disp_shadow<=DISP_DEFAULT;disp_pending<=DISP_DEFAULT;disp_mirror<=DISP_DEFAULT;
      cap_req<=0;disp_req<=0;cap_seen<=0;disp_seen<=0;cap_ack_sync<=0;disp_ack_sync<=0;cap_seq<=0;disp_seq<=0;
      raw_frames<=0;
      faults_meta<=0;faults_sync<=0;csi_meta<=0;csi_sync<=0;reset_meta<=0;reset_sync<=0;fault_sticky<=0;
    end else begin
      if(raw_event)raw_frames<=raw_frames+1'b1;
      cap_ack_sync<={cap_ack_sync[0],cap_ack};disp_ack_sync<={disp_ack_sync[0],disp_ack};
      faults_meta<={1'b0,resize_fault,capture_fault};faults_sync<=faults_meta;
      csi_meta<=csi_errors;csi_sync<=csi_meta;reset_meta<=reset_status;reset_sync<=reset_meta;
      fault_sticky<=fault_sticky|{25'd0,faults_sync[2],1'b0,(|csi_sync),(|axi_errors32),(|underflows32),faults_sync[1:0]};
      if(cap_seen!=cap_ack_sync[1]) begin cap_seen<=cap_ack_sync[1];cap_mirror<=cap_pending;cap_seq<=cap_seq+1'b1;end
      if(disp_seen!=disp_ack_sync[1]) begin disp_seen<=disp_ack_sync[1];disp_mirror<=disp_pending;disp_seq<=disp_seq+1'b1;end
      if(access&&pwrite&&pslverr&&paddr==16'h050)fault_sticky[5]<=1;
      
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
        16'h190:cap_shadow[87:56]<=pwdata&32'h00ffff01;
        16'h194:cap_shadow[103:88]<=pwdata[15:0];
        default:;
      endcase
    end
  end
endmodule
