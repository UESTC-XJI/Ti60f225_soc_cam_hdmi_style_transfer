// Fixed 720p60 timing. Missing pixels become black without stopping sync.
// 2026-10-31：对比模式 = 左右两幅完整画面；单画面 = 裁黑边 4× 全屏。
//   采集自 2026-10-30 起输出「640×360 活动画面 + 上下各 60 行黑边」（风格槽
//   320×240 = 320×180 + 上下各 30 行）。显示端只取活动行：
//   · 对比模式（single_panel=0）：左半屏（h=260..899）放**完整原画** 640×360
//     (1:1)，右半屏（h=900..1539）放**完整风格画** 320×180 → 2× 最近邻 = 640×360。
//     两幅垂直居中（DE 行 180..539），上下各留 180 行黑边；等比、不裁切、不变形。
//   · 单画面（single_panel=1）：风格 320×180 4× 铺满 1280×720（裁掉采集黑边，
//     整屏无黑边）。
//   模式仍在帧首锁存。
//
// 2026-10-28（A-4）：风格结果帧改为 **320×240 原生分辨率**（L11 半分辨率直写，
//   rowpipe 的写通道不再做 2×2 复制）。放大搬到这里做**最近邻 2×2**：
//     · 读：风格行只读 **320 像素**，行跨距 **1280 B**（320×4B），
//           源行号 = `row_number>>1`（480 个显示行只用 240 个源行，每个源行读 2 次）
//     · 横：每个源像素写**两遍**进像素 FIFO（x 自增 2），使 pix_clk 侧看到的
//           tag 流与改动前**逐拍相同**（仍是每行 1280 条、x=640..1279 / 单面板 0..639）
//   ⇒ pix_clk 域的 match/obsolete/几何/时序**一行都不用改**（这是本改动的主要安全性来源）。
//   原画（左半）仍是 640 像素 / 跨距 2560 B，完全不变。
module style_display #(parameter bit BUFFERED=1'b1)(
  input wire clk,pix_clk,rst_n,
  input wire [2:0] display_slot,input wire display_valid,
  output wire display_frame_event,display_safe,
  output reg [31:0] pixel,output reg hs,vs,de,underflow,
  output reg [31:0] dma_errors,
  output wire read_urgent,
  // single_panel=1 shows only the stylised result, 4x nearest-neighbour, filling
  // the whole 1280x720 raster (the 320x240 result is cropped to its middle
  // 320x180, i.e. the capture letterbox rows are dropped, then stretched 4x).
  // single_panel=0 shows the two complete images side by side: the full
  // original (640x360, 1:1) on the left and the full stylised result
  // (320x180, 2x) on the right, centred vertically with 180-line black bars
  // above and below.  No cropping and no aspect distortion in either mode.
  // The mode is latched at the frame start (sp_lat) so switching it can never
  // desynchronise the row-tagged pixel FIFO.
  // Two versions of it are resynchronised below: one for the pix_clk pixel path
  // and one for the clk row-fetch state machine.
  input wire single_panel,
  output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
  input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready
);
  (* async_reg="true" *)reg sp_meta,sp_sync;
  always @(posedge pix_clk or negedge rst_n)begin
    if(!rst_n)begin sp_meta<=1'b0;sp_sync<=1'b0;end
    else begin sp_meta<=single_panel;sp_sync<=sp_meta;end
  end
  //   ①a：显示模式**只在帧首生效**。单画面与对比模式的行映射/复制倍数不同（>>2 vs >>1），
  //   若在帧中间切换，FIFO 里旧几何的包会和新 expect_row 错位：实测过渡帧 60% 像素黑/错
  //   （tb_disp_toggle：uf=554900）。帧首锁存后，切模式与 epoch 翻转同拍，旧包统一按
  //   「epoch 不符」清掉（不依赖行号比较，不会卡队头），切模式那一帧起就是干净画面。
  reg sp_lat;
  wire single_panel_pix=sp_lat;
  // The row-fetch state machine below runs in the clk domain, so it needs its
  // own synchroniser.  Feeding it the pix_clk-domain copy would be a CDC
  // violation and left the reader addressing the wrong DDR row.
  //   （同步的是帧首锁存后的 sp_lat，而不是引脚：单比特、只在一帧一次变化，比同步原始引脚更稳。）
  (* async_reg = "true" *) reg spc_meta,spc_sync;
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin spc_meta<=1'b0;spc_sync<=1'b0;end
    else begin spc_meta<=sp_lat;spc_sync<=spc_meta;end
  end
  wire single_panel_clk=spc_sync;
  reg [10:0] h;reg [9:0] v;reg [7:0] epoch,epoch_gray;
  (* async_reg="true" *)reg [2:0] slot1,slot2;reg dv1,dv2;
  // ---- 2026-10-31：对比两幅完整画面 / 单画面无黑边 -------------------------
  //   显示列 x = h-260 ∈ [0,1280)，DE 行 d = v-25 ∈ [0,720)。
  //   源画面在 DDR 槽里带上下黑边（原画 60 行、风格 30 行），只取活动行。
  //   对比模式（两幅完整画面，垂直居中）：
  //     图片区 v=205..564（DE 行 180..539），上下各 180 行黑边。
  //     左半屏 x<640：原画完整 640×360，1:1；源行 = 60+(v-205)，源 x = x
  //     右半屏 x≥640：风格完整 320×180，2×：源行 = 30+((v-205)>>1)，
  //                   源 x = (x-640)>>1（= (h-900)>>1）
  //   单画面：整屏 1280×720，风格 320×180 4×：源行 = 30+(d>>2)，源 x = x>>2。
  //   两种模式每显示行都重取源行（行内无垂直缓冲），DDR 读：
  //     对比 640+320 px/行（360 行），单画面 320 px/行（720 行）。
  wire [10:0] img_x0=11'd260;
  wire [10:0] img_x1=11'd1540;
  wire [9:0]  img_y0=single_panel_pix ? 10'd25  : 10'd205;
  wire [9:0]  img_y1=single_panel_pix ? 10'd745 : 10'd565;
  wire image=v>=img_y0&&v<img_y1&&h>=img_x0&&h<img_x1;
  wire active=v>=25&&v<745&&h>=260&&h<1540;
  wire [9:0] row_d=v>=img_y0 ? (v-img_y0) : 10'd0;
  //   对比：原画槽行号 60..419（1:1）；单画面：风格槽行号 30..209（4 行）。
  wire [8:0] expect_row=single_panel_pix
        ? (9'd30+(row_d>>2))
        : (9'd60+row_d);
  // Column index within the picture, 0..1279.  Tags on the FIFO are display-
  // relative x; comparison writes the original as tags 0..639 and the stylised
  // as 640..1279 (2x), single panel writes 0..1279 (4x).  Clamped below img_x0
  // so the value cannot wrap negative in the left blanking band.
  wire [10:0] expect_x=(h>=img_x0) ? (h-img_x0) : 11'd0;
  //   每个显示行都发一次请求；请求行对应**下一个显示行**：
  //   对比 v=204..563 预取图片行 0..359；单画面 v=24..743 预取 0..719。
  wire request=h==0&&dv2&&(single_panel_pix ? (v>=10'd24&&v<10'd744)
                                            : (v>=10'd204&&v<10'd564));
  wire request_ready,req_valid,req_ready;wire [19:0] req;
  wire [8:0] request_row=single_panel_pix
        ? (9'd30+((v>=10'd24 ? (v-10'd24) : 10'd0)>>2))
        : (9'd60+(v>=10'd204 ? (v-10'd204) : 10'd0));
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
  reg [1:0] dup_cnt;         // ①a：还要写几条（单画面 3 ⇒ 共 4 条；对比风格侧 1 ⇒ 共 2 条）
  reg [31:0] dup_rgb;        // 第 1 条的内容（后续几条复用它）
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
  // ---- 帧几何：原画 640 px/行，风格 320 px/行 ----
  localparam [9:0]  PIX_W_FULL   = 10'd640;    // 对比首段：原画完整行
  localparam [9:0]  PIX_W_HALF   = 10'd320;    // 风格完整行（单画面首段 / 对比第二段）
  localparam [31:0] STRIDE_FULL  = 32'd2560;   // 640 px × 4 B
  localparam [31:0] STRIDE_HALF  = 32'd1280;   // 320 px × 4 B
  localparam [31:0] STYLE_OFFSET = 32'h0080_0000;
  assign req_ready=state==IDLE&&dup_cnt==2'd0;
  assign display_safe=state==IDLE&&!rd_busy;
  wire pixel_valid,pixel_ready;wire [59:0] packet;
  // The stylised buffer stores INT8 with a +0x80 bias (0 = mid grey), so only
  // the right-hand read needs the bias removed. The original frame is already
  // plain 8-bit RGB. right_side is low for the original fetch and high for the
  // stylised one (see the fetch FSM below), so it selects the conversion.
  wire [31:0] rgb={8'b0, right_side ? (rd_pixel[23:0]^24'h808080) : rd_pixel[23:0]};
  // ---- 水平最近邻复制（对比：原画 1×/风格 2×；单画面：风格 4×）----
  //   读侧每接受一个源像素，就往像素 FIFO 写 dup_max+1 条（x 连续递增），
  //   所以 pix_clk 侧收到的仍是「每行 1280 条、x=0..1279」的流。
  //   后续几条必须用**锁存的** dup_rgb（那时 rd_pixel 已经前进了一拍）。
  wire pixel_in_ready;
  //   2026-10-31：对比模式原画完整行 1×（dup_max=0）、风格 2×（dup_max=1）；
  //   单画面风格 4×（dup_max=3）。right_side 在每段读开始时定好，不会半路变形。
  wire [1:0] dup_max=right_side?(single_panel_clk?2'd3:2'd1):2'd0;
  wire pix_we=(dup_cnt!=2'd0)?1'b1:rd_valid;
  wire [31:0] pix_rgb=(dup_cnt!=2'd0)?dup_rgb:rgb;
  assign rd_ready=pixel_in_ready&&(dup_cnt==2'd0);
  style_async_fifo #(.WIDTH(60),.LOG_DEPTH(BUFFERED ? 9:10)) pixels(.reset_n(rst_n),.wclk(clk),.rclk(pix_clk),
    .in_valid(pix_we),.in_ready(pixel_in_ready),.in_data({row_epoch,row_number,x,pix_rgb}),
    .out_valid(pixel_valid),.out_ready(pixel_ready),.out_data(packet),.write_level(pixel_level));
  wire match=pixel_valid&&packet[59:52]==epoch&&packet[51:43]==expect_row&&packet[42:32]==expect_x;
  //   两种模式现在都是「每显示行重取一行」：同一源行会排队多份拷贝。水平消隐期
  //   h>=img_x1 时 expect_x 仍在按 h-img_x0 增长（可到 1389），若此时按 x<expect_x
  //   判过期，会把下一份拷贝的头部 110 个像素（消隐长度 1649-1539）当过期弹掉，
  //   队列错位到 x=110、该行前 110 像素全黑（实测 540 行 × 110 = 59,400 uf）。
  //   ⇒ x 过期判据只在可见窗口内生效；满图垂直裁剪/跨帧清理仍无条件执行。
  wire x_passed=h>=img_x0&&h<img_x1&&v>=img_y0&&packet[42:32]<expect_x;
  wire obsolete=pixel_valid&&(packet[59:52]!=epoch || v>=img_y1 ||
    (v>=img_y0 && (packet[51:43]<expect_row || (packet[51:43]==expect_row && x_passed))));
  assign pixel_ready=obsolete||(image&&match);
  always @(posedge pix_clk or negedge rst_n)begin
    if(!rst_n)begin h<=0;v<=0;epoch<=0;epoch_gray<=0;slot1<=0;slot2<=0;dv1<=0;dv2<=0;pixel<=0;hs<=0;vs<=0;de<=0;underflow<=0;sp_lat<=0;end
    else begin
      slot1<=display_slot;slot2<=slot1;dv1<=display_valid;dv2<=dv1;
      if(h==1649)begin h<=0;if(v==749)v<=0;else v<=v+1'b1;end else h<=h+1'b1;
      if(h==0&&v==0)begin epoch<=epoch+1'b1;epoch_gray<=((epoch+1'b1)>>1)^(epoch+1'b1);sp_lat<=sp_sync;end
      hs<=h<40;vs<=v<5;de<=active;pixel<=image&&match ? packet[31:0]:0;
      underflow<=(image&&dv2&&!match)||(request&&!request_ready);
    end
  end
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin state<=IDLE;rd_start<=0;rd_address<=0;row_epoch<=0;row_slot<=0;row_number<=0;x<=0;right_side<=0;dma_errors<=0;row_age<=0;rd_pixels_sel<=PIX_W_HALF;dup_cnt<=0;dup_rgb<=0;end
    else begin
      rd_start<=0;
      if(state==IDLE)row_age<=0;
      else if(row_age!=4095)row_age<=row_age+1'b1;
      // x 是「像素 FIFO 写第几条」，每条 +1；对比原画 1 条、风格 2 条/像素；单画面 4 条。
      if(pix_we&&pixel_in_ready)begin
        x<=x+1'b1;
        if(dup_cnt!=2'd0) dup_cnt<=dup_cnt-2'd1;
        else if(dup_max!=2'd0)begin dup_rgb<=rgb;dup_cnt<=dup_max;end
      end
      case(state)
        IDLE:if(req_valid&&req_ready&&req[19:12]==current_epoch)begin
          row_epoch<=req[19:12];row_slot<=req[11:9];row_number<=req[8:0];x<=0;
          // Single panel fetches the stylised buffer straight away and skips
          // the second fetch, so a display row costs one DDR read instead of
          // two.  Two-panel mode keeps its original order: original frame first,
          // stylised frame second.
          right_side<=single_panel_clk;
          //   单画面：req 已是风格源行（30..209），读完整 320 px；
          //   对比：req 是原画源行（60..419），读完整 640 px。
          rd_pixels_sel<=single_panel_clk ? PIX_W_HALF : PIX_W_FULL;
          rd_address<=single_panel_clk ? (raw_base(req[11:9])+STYLE_OFFSET+req[8:0]*STRIDE_HALF)
                                       : (raw_base(req[11:9])+req[8:0]*STRIDE_FULL);
          state<=START;
        end
        START:begin rd_start<=1;state<=WAIT;end
        WAIT:if(rd_done)begin
          if(rd_error)dma_errors<=dma_errors+1'b1;
          //   对比模式第二段：风格源行 = 30+((原画源行-60)>>1)（风格每源行显示 2 行），
          //   读完整 320 px，每个源像素写 2 条。
          if(!right_side)begin right_side<=1;rd_pixels_sel<=PIX_W_HALF;
            rd_address<=raw_base(row_slot)+STYLE_OFFSET
              +(9'd30+((row_number>=9'd60)?((row_number-9'd60)>>1):9'd0))*STRIDE_HALF;
            state<=START;end
          else state<=IDLE;
        end
      endcase
    end
  end
endmodule
