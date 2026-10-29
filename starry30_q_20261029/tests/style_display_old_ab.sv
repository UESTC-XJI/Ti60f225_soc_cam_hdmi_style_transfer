// Fixed 720p60 timing. Missing pixels become black without stopping sync.
// DDR only supplies the two VGA rectangles; the 120-line bars are generated.
//
// 2026-10-28（A-4）：风格结果帧改为 **320×240 原生分辨率**（L11 半分辨率直写，
//   rowpipe 的写通道不再做 2×2 复制）。放大搬到这里做**最近邻 2×2**：
//     · 读：风格行只读 **320 像素**，行跨距 **1280 B**（320×4B），
//           源行号 = `row_number>>1`（480 个显示行只用 240 个源行，每个源行读 2 次）
//     · 横：每个源像素写**两遍**进像素 FIFO（x 自增 2），使 pix_clk 侧看到的
//           tag 流与改动前**逐拍相同**（仍是每行 1280 条、x=640..1279 / 单面板 0..639）
//   ⇒ pix_clk 域的 match/obsolete/几何/时序**一行都不用改**（这是本改动的主要安全性来源）。
//   原画（左半）仍是 640 像素 / 跨距 2560 B，完全不变。
module style_display_old #(parameter bit BUFFERED=1'b1)(
  input wire clk,pix_clk,rst_n,
  input wire [2:0] display_slot,input wire display_valid,
  output wire display_frame_event,display_safe,
  output reg [31:0] pixel,output reg hs,vs,de,underflow,
  output reg [31:0] dma_errors,
  output wire read_urgent,
  // single_panel=1 shows only the stylised result, at its native 640-pixel
  // width, centred between black side bands, instead of the side-by-side
  // original/stylised pair.  Two versions of it are resynchronised below: one
  // for the pix_clk pixel path and one for the clk row-fetch state machine.
  input wire single_panel,
  output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
  input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready
);
  (* async_reg="true" *)reg sp_meta,sp_sync;
  always @(posedge pix_clk or negedge rst_n)begin
    if(!rst_n)begin sp_meta<=1'b0;sp_sync<=1'b0;end
    else begin sp_meta<=single_panel;sp_sync<=sp_meta;end
  end
  wire single_panel_pix=sp_sync;
  // The row-fetch state machine below runs in the clk domain, so it needs its
  // own synchroniser.  Feeding it the pix_clk-domain copy would be a CDC
  // violation and left the reader addressing the wrong DDR row.
  (* async_reg = "true" *) reg spc_meta,spc_sync;
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin spc_meta<=1'b0;spc_sync<=1'b0;end
    else begin spc_meta<=single_panel;spc_sync<=spc_meta;end
  end
  wire single_panel_clk=spc_sync;
  reg [10:0] h;reg [9:0] v;reg [7:0] epoch,epoch_gray;
  (* async_reg="true" *)reg [2:0] slot1,slot2;reg dv1,dv2;
  // Horizontal extent of the picture content.  Two-panel mode draws the
  // original and the result side by side across the full 1280 columns; single
  // panel keeps the 640-wide result at its native size, centred, with black to
  // either side (no stretching).  `active` is the DE window and stays full width
  // in both modes, so the side bands are driven black rather than blanked.
  wire [10:0] img_x0=single_panel_pix ? 11'd580 : 11'd260;
  wire [10:0] img_x1=single_panel_pix ? 11'd1220 : 11'd1540;
  wire image=v>=145&&v<625&&h>=img_x0&&h<img_x1;
  wire active=v>=25&&v<745&&h>=260&&h<1540;
  wire [8:0] expect_row=v-145;
  // Column index within the picture.  Both modes map one column to one source
  // pixel, they only differ in where the picture starts, so the FIFO is
  // consumed at the same rate in both.  Clamped below img_x0 so the value
  // cannot wrap negative while the beam is still in the left blanking band.
  wire [10:0] expect_x=(h>=img_x0) ? (h-img_x0) : 11'd0;
  wire request=h==0&&v>=144&&v<624&&dv2;
  wire request_ready,req_valid,req_ready;wire [19:0] req;
  wire [8:0] request_row=v-144;
  style_async_fifo #(.WIDTH(20)) requests(.reset_n(rst_n),.wclk(pix_clk),.rclk(clk),
    .in_valid(request),.in_ready(request_ready),.in_data({epoch,slot2,request_row}),
    .out_valid(req_valid),.out_ready(req_ready),.out_data(req));
  (* async_reg="true" *)reg [7:0] eg1,eg2;reg [7:0] current_epoch,seen_epoch;integer bit_index;
  always @*begin
    current_epoch[7]=eg2[7];
    for(bit_index=6;bit_index>=0;bit_index=bit_index-1)current_epoch[bit_index]=current_epoch[bit_index+1]^eg2[bit_index];
  end
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin eg1<=0;eg2<=0;seen_epoch<=0;end
    else begin eg1<=epoch_gray;eg2<=eg1;seen_epoch<=current_epoch;end
  end
  assign display_frame_event=current_epoch!=seen_epoch;
  reg [1:0] state;localparam IDLE=0,START=1,WAIT=2;
  reg [7:0] row_epoch;reg [2:0] row_slot;reg [8:0] row_number;reg [10:0] x;reg right_side;
  reg rd_start;reg [31:0] rd_address;
  reg [9:0] rd_pixels_sel;   // A-4：本次读的像素数（原画 640 / 风格 320）
  reg dup_pend;              // A-4：风格侧第 2 条待写（见下方水平 2× 复制）
  reg [31:0] dup_rgb;        // A-4：第 1 条的内容（第 2 条复用它）
  reg [11:0] row_age;
  localparam integer PIXEL_LOG=BUFFERED ? 9:10;
  wire [PIXEL_LOG:0] pixel_level;
  // Reserve inter-burst gaps only while a display row is pending. Otherwise
  // the empty FIFO in vertical blanking would permanently block CNN reads.
  // 384 buffered pixels give ~5.2 us at the 74.25 MHz pixel clock.
  assign read_urgent=display_valid&&(state!=IDLE||req_valid)&&(pixel_level<384||row_age>=1600||req_valid);
  wire rd_busy,rd_done,rd_error,rd_valid,rd_ready;wire [191:0] rd_pixel;
  wire unused_busy,unused_done,unused_error,unused_ready;wire [31:0] unused_addr;wire [7:0] unused_len;
  wire unused_awvalid,unused_wlast,unused_wvalid,unused_bready;wire [127:0] unused_wdata;wire [15:0] unused_strb;
  wire [127:0] reader_rdata;wire [1:0] reader_rresp;wire reader_rlast,reader_rvalid,reader_rready;
  generate if(BUFFERED)begin:burst_buffer
    style_display_beats beats(.clk(clk),.rst_n(rst_n),.in_valid(rvalid),.in_ready(rready),
      .in_data(rdata),.in_resp(rresp),.in_last(rlast),.out_valid(reader_rvalid),.out_ready(reader_rready),
      .out_data(reader_rdata),.out_resp(reader_rresp),.out_last(reader_rlast));
  end else begin:direct_reader
    assign reader_rdata=rdata;assign reader_rresp=rresp;assign reader_rlast=rlast;
    assign reader_rvalid=rvalid;assign rready=reader_rready;
  end endgenerate
  style_axi_rows reader(.clk(clk),.rst_n(rst_n),.rd_start(rd_start),.rd_address(rd_address),.rd_pixels(rd_pixels_sel),.rd_channels(5'd3),
    .rd_busy(rd_busy),.rd_done(rd_done),.rd_error(rd_error),.rd_valid(rd_valid),.rd_ready(rd_ready),.rd_pixel(rd_pixel),
    .wr_start(1'b0),.wr_address(32'b0),.wr_pixels(10'b0),.wr_channels(5'b0),.wr_busy(unused_busy),.wr_done(unused_done),.wr_error(unused_error),.wr_valid(1'b0),.wr_ready(unused_ready),.wr_pixel(192'b0),
    .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),.rdata(reader_rdata),.rresp(reader_rresp),.rlast(reader_rlast),.rvalid(reader_rvalid),.rready(reader_rready),
    .awaddr(unused_addr),.awlen(unused_len),.awvalid(unused_awvalid),.awready(1'b0),.wdata(unused_wdata),.wstrb(unused_strb),.wlast(unused_wlast),.wvalid(unused_wvalid),.wready(1'b0),.bresp(2'b0),.bvalid(1'b0),.bready(unused_bready));
  function [31:0] raw_base;
    input [2:0] slot;
    begin case(slot)
      0:raw_base=32'h05000000;1:raw_base=32'h05140000;2:raw_base=32'h05280000;
      3:raw_base=32'h053c0000;4:raw_base=32'h05500000;default:raw_base=32'h05640000;
    endcase end
  endfunction
  // ---- A-4：风格结果帧几何（320×240 原生 → 显示端最近邻 2×2）----
  localparam [9:0]  PIX_W_FULL   = 10'd640;    // 原画行：640 像素
  localparam [9:0]  PIX_W_HALF   = 10'd320;    // 风格行：320 像素（L11 半分辨率）
  localparam [31:0] STRIDE_FULL  = 32'd2560;   // 640 px × 4 B
  localparam [31:0] STRIDE_HALF  = 32'd1280;   // 320 px × 4 B
  assign req_ready=state==IDLE&&!dup_pend;
  assign display_safe=state==IDLE&&!rd_busy;
  wire pixel_valid,pixel_ready;wire [59:0] packet;
  // The stylised buffer stores INT8 with a +0x80 bias (0 = mid grey), so only
  // the right-hand read needs the bias removed. The original frame is already
  // plain 8-bit RGB. right_side is low for the original fetch and high for the
  // stylised one (see the fetch FSM below), so it selects the conversion.
  wire [31:0] rgb={8'b0, right_side ? (rd_pixel[23:0]^24'h808080) : rd_pixel[23:0]};
  // ---- A-4：水平 2× 最近邻复制（只在风格侧）----
  //   读侧每接受一个源像素，就往像素 FIFO 写两条（x 与 x+1），所以 pix_clk 侧收到的
  //   仍是「每行 1280 条、x 连续」的流，与改动前完全同构。dup_pend 表示第 2 条待写；
  //   第 2 条必须用**锁存的** dup_rgb（那时 rd_pixel 已经前进了一拍）。
  //   （dup_pend / dup_rgb 的声明在 FSM 寄存器那一行，因为 req_ready 要先用到它。）
  wire pixel_in_ready;
  wire style_dup=right_side;
  wire pix_we=(style_dup&&dup_pend)?1'b1:rd_valid;
  wire [31:0] pix_rgb=(style_dup&&dup_pend)?dup_rgb:rgb;
  assign rd_ready=pixel_in_ready&&!(style_dup&&dup_pend);
  style_async_fifo #(.WIDTH(60),.LOG_DEPTH(BUFFERED ? 9:10)) pixels(.reset_n(rst_n),.wclk(clk),.rclk(pix_clk),
    .in_valid(pix_we),.in_ready(pixel_in_ready),.in_data({row_epoch,row_number,x,pix_rgb}),
    .out_valid(pixel_valid),.out_ready(pixel_ready),.out_data(packet),.write_level(pixel_level));
  wire match=pixel_valid&&packet[59:52]==epoch&&packet[51:43]==expect_row&&packet[42:32]==expect_x;
  wire obsolete=pixel_valid&&(packet[59:52]!=epoch || v>=625 ||
    (v>=145 && (packet[51:43]<expect_row || (packet[51:43]==expect_row && h>=img_x0 && packet[42:32]<expect_x))));
  assign pixel_ready=obsolete||(image&&match);
  always @(posedge pix_clk or negedge rst_n)begin
    if(!rst_n)begin h<=0;v<=0;epoch<=0;epoch_gray<=0;slot1<=0;slot2<=0;dv1<=0;dv2<=0;pixel<=0;hs<=0;vs<=0;de<=0;underflow<=0;end
    else begin
      slot1<=display_slot;slot2<=slot1;dv1<=display_valid;dv2<=dv1;
      if(h==1649)begin h<=0;if(v==749)v<=0;else v<=v+1'b1;end else h<=h+1'b1;
      if(h==0&&v==0)begin epoch<=epoch+1'b1;epoch_gray<=((epoch+1'b1)>>1)^(epoch+1'b1);end
      hs<=h<40;vs<=v<5;de<=active;pixel<=image&&match ? packet[31:0]:0;
      underflow<=(image&&dv2&&!match)||(request&&!request_ready);
    end
  end
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin state<=IDLE;rd_start<=0;rd_address<=0;row_epoch<=0;row_slot<=0;row_number<=0;x<=0;right_side<=0;dma_errors<=0;row_age<=0;rd_pixels_sel<=PIX_W_FULL;dup_pend<=0;dup_rgb<=0;end
    else begin
      rd_start<=0;
      if(state==IDLE)row_age<=0;
      else if(row_age!=4095)row_age<=row_age+1'b1;
      // A-4：x 是「像素 FIFO 写第几条」，每条 +1；风格侧一个源像素写两条 ⇒ x += 2/像素
      if(pix_we&&pixel_in_ready)begin
        x<=x+1'b1;
        if(style_dup)begin dup_pend<=!dup_pend;if(!dup_pend)dup_rgb<=rgb;end
      end
      case(state)
        IDLE:if(req_valid&&req_ready&&req[19:12]==current_epoch)begin
          row_epoch<=req[19:12];row_slot<=req[11:9];row_number<=req[8:0];x<=0;
          // Single panel fetches the stylised buffer straight away and skips
          // the second fetch, so a display row costs one DDR read instead of
          // two.  Two-panel mode keeps its original order: original frame first,
          // stylised frame second.
          right_side<=single_panel_clk;
          // A-4：风格帧 = 320×240 / 跨距 1280，源行 = 显示行>>1（垂直 2× 最近邻）
          rd_pixels_sel<=single_panel_clk ? PIX_W_HALF : PIX_W_FULL;
          rd_address<=single_panel_clk ? (raw_base(req[11:9])+32'h00800000+(req[8:0]>>1)*STRIDE_HALF)
                                       : (raw_base(req[11:9])+req[8:0]*STRIDE_FULL);
          state<=START;
        end
        START:begin rd_start<=1;state<=WAIT;end
        WAIT:if(rd_done)begin
          if(rd_error)dma_errors<=dma_errors+1'b1;
          if(!right_side)begin right_side<=1;rd_pixels_sel<=PIX_W_HALF;
            rd_address<=raw_base(row_slot)+32'h00800000+(row_number>>1)*STRIDE_HALF;state<=START;end
          else state<=IDLE;
        end
      endcase
    end
  end
endmodule
