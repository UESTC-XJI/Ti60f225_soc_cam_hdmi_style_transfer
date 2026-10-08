// APB3 OSD register bank.  The local Sapphire APB address is 16 bits and the
// block occupies offsets 0x0000..0x0030. Every write is qualified by the APB
// ACCESS handshake; invalid and read-only writes have no side effects.
module osd_apb_regs #(
  parameter integer CHAR_ADDR_W=7,
  parameter logic [31:0] CORE_ID=32'h4f534431
)(
  input logic pclk,preset_n,psel,penable,pwrite,
  input logic [15:0] paddr,input logic [31:0] pwdata,
  output logic [31:0] prdata, output logic pready,pslverr,
  output logic o_enable, output logic [11:0] o_x,o_y, output logic [23:0] o_color,
  output logic o_char_we, output logic [CHAR_ADDR_W-1:0] o_char_addr, output logic o_char_page, output logic [7:0] o_char_data,
  output logic o_commit_toggle, output logic o_commit_page, output logic o_video_ready,
  input logic i_ack_toggle, input logic i_active_page, input logic i_busy,
  input logic [15:0] i_frame_count, input logic [15:0] i_capture_fps,
  input logic [15:0] i_display_fps, input logic [15:0] i_drop_count, input logic [15:0] i_error_count,
  input logic [15:0] i_raw_fps
);
  wire access=psel&&penable;
  wire hit_id=(paddr==16'h0000), hit_ctrl=(paddr==16'h0004), hit_x=(paddr==16'h0008), hit_y=(paddr==16'h000c), hit_color=(paddr==16'h0010), hit_addr=(paddr==16'h0014), hit_data=(paddr==16'h0018), hit_commit=(paddr==16'h001c), hit_status=(paddr==16'h0020), hit_status2=(paddr==16'h0024), hit_video=(paddr==16'h0028);
  wire hit_raw=(paddr==16'h002c),hit_resize=(paddr==16'h0030);
  wire legal=hit_id||hit_ctrl||hit_x||hit_y||hit_color||hit_addr||hit_data||hit_commit||hit_status||hit_status2||hit_video||hit_raw||hit_resize;
  wire read_only_write=pwrite&&(hit_id||hit_status||hit_status2||hit_raw||hit_resize);
  logic [CHAR_ADDR_W-1:0] char_addr_reg; logic char_page_reg;
  logic ack_sync1,ack_sync2,active_sync1,active_sync2,busy_sync1,busy_sync2;
  always_ff @(posedge pclk or negedge preset_n) begin
    if(!preset_n) begin
      ack_sync1<=1'b0; ack_sync2<=1'b0; active_sync1<=1'b0; active_sync2<=1'b0;
      busy_sync1<=1'b0; busy_sync2<=1'b0;
    end else begin
      ack_sync1<=i_ack_toggle; ack_sync2<=ack_sync1;
      active_sync1<=i_active_page; active_sync2<=active_sync1;
      busy_sync1<=i_busy; busy_sync2<=busy_sync1;
    end
  end
  assign pready=1'b1; assign pslverr=access&&(!legal||read_only_write);
  always_comb begin
    prdata=32'd0;
    case(paddr)
      16'h0000:prdata=CORE_ID;
      16'h0004:prdata={31'd0,o_enable};
      16'h0008:prdata={20'd0,o_x};
      16'h000c:prdata={20'd0,o_y};
      16'h0010:prdata={8'd0,o_color};
      16'h0014:prdata={{(31-CHAR_ADDR_W){1'b0}},char_page_reg,char_addr_reg};
      16'h0020:prdata={5'd0,i_error_count[7:0],i_drop_count[7:0],i_frame_count[7:0],busy_sync2,active_sync2,ack_sync2};
      16'h0024:prdata={i_display_fps,i_capture_fps};
      16'h0028:prdata={31'd0,o_video_ready};
      16'h002c:prdata={16'd0,i_raw_fps};
      16'h0030:prdata={16'd0,i_capture_fps};
      default:prdata=32'd0;
    endcase
  end
  always_ff @(posedge pclk or negedge preset_n) begin
    if(!preset_n) begin
      o_enable<=1'b1; o_x<=12'd16; o_y<=12'd16; o_color<=24'h20ff40; o_video_ready<=1'b0; char_addr_reg<='0; char_page_reg<=1'b1;
      o_char_we<=0;o_char_addr<='0;o_char_page<=1;o_char_data<=0;o_commit_toggle<=0;o_commit_page<=1;
    end else begin
      o_char_we<=0;
      if(access&&pwrite&&!pslverr) begin
        case(paddr)
          16'h0004:o_enable<=pwdata[0];
          16'h0008:o_x<=pwdata[11:0];
          16'h000c:o_y<=pwdata[11:0];
          16'h0010:o_color<=pwdata[23:0];
          16'h0014:begin char_addr_reg<=pwdata[CHAR_ADDR_W-1:0]; char_page_reg<=pwdata[CHAR_ADDR_W]; end
          16'h0018:begin o_char_we<=1; o_char_addr<=char_addr_reg; o_char_page<=char_page_reg; o_char_data<=pwdata[7:0]; end
          16'h001c:if(!busy_sync2 && (char_page_reg!=active_sync2)) begin o_commit_toggle<=~o_commit_toggle; o_commit_page<=char_page_reg; end
          16'h0028:o_video_ready<=pwdata[0];
          default:;
        endcase
      end
    end
  end
endmodule
