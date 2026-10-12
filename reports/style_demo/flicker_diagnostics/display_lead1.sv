// Fixed 720p60 timing. Missing pixels become black without stopping sync.
// DDR only supplies the two VGA rectangles; the 120-line bars are generated.
module style_display #(parameter bit BUFFERED=1'b1)(
  input wire clk,pix_clk,rst_n,
  input wire [2:0] display_slot,input wire display_valid,
  output wire display_frame_event,display_safe,
  output reg [31:0] pixel,output reg hs,vs,de,underflow,
  output reg [31:0] dma_errors,
  output wire read_urgent,
  output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
  input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready
);
  reg [10:0] h;reg [9:0] v;reg [7:0] epoch,epoch_gray;
  (* async_reg="true" *)reg [2:0] slot1,slot2;reg dv1,dv2;
  wire image=v>=145&&v<625&&h>=260&&h<1540;
  wire active=v>=25&&v<745&&h>=260&&h<1540;
  wire [8:0] expect_row=v-145;wire [10:0] expect_x=h-260;
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
  reg [11:0] row_age;
  localparam integer PIXEL_LOG=BUFFERED ? 9:10;
  wire [PIXEL_LOG:0] pixel_level;
  // Request leads the visible row by ~25.7 us. Give a delayed row priority
  // before that deadline, or whenever less than 256 pixels are buffered.
  assign read_urgent=display_valid&&(pixel_level<256||row_age>=1600||req_valid);
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
  style_axi_rows reader(.clk(clk),.rst_n(rst_n),.rd_start(rd_start),.rd_address(rd_address),.rd_pixels(10'd640),.rd_channels(5'd3),
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
  assign req_ready=state==IDLE;
  assign display_safe=state==IDLE&&!rd_busy;
  wire pixel_valid,pixel_ready;wire [59:0] packet;
  wire [31:0] rgb={8'b0,(rd_pixel[23:0]^24'h808080)};
  style_async_fifo #(.WIDTH(60),.LOG_DEPTH(BUFFERED ? 9:10)) pixels(.reset_n(rst_n),.wclk(clk),.rclk(pix_clk),
    .in_valid(rd_valid),.in_ready(rd_ready),.in_data({row_epoch,row_number,x,rgb}),
    .out_valid(pixel_valid),.out_ready(pixel_ready),.out_data(packet),.write_level(pixel_level));
  wire match=pixel_valid&&packet[59:52]==epoch&&packet[51:43]==expect_row&&packet[42:32]==expect_x;
  wire obsolete=pixel_valid&&(packet[59:52]!=epoch || v>=625 ||
    (v>=145 && (packet[51:43]<expect_row || (packet[51:43]==expect_row && h>=260 && packet[42:32]<expect_x))));
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
    if(!rst_n)begin state<=IDLE;rd_start<=0;rd_address<=0;row_epoch<=0;row_slot<=0;row_number<=0;x<=0;right_side<=0;dma_errors<=0;row_age<=0;end
    else begin
      rd_start<=0;
      if(state==IDLE)row_age<=0;
      else if(row_age!=4095)row_age<=row_age+1'b1;
      if(rd_valid&&rd_ready)x<=x+1'b1;
      case(state)
        IDLE:if(req_valid&&req_ready&&req[19:12]==current_epoch)begin
          row_epoch<=req[19:12];row_slot<=req[11:9];row_number<=req[8:0];x<=0;right_side<=0;
          rd_address<=raw_base(req[11:9])+req[8:0]*2560;state<=START;
        end
        START:begin rd_start<=1;state<=WAIT;end
        WAIT:if(rd_done)begin
          if(rd_error)dma_errors<=dma_errors+1'b1;
          if(!right_side)begin right_side<=1;rd_address<=raw_base(row_slot)+32'h00800000+row_number*2560;state<=START;end
          else state<=IDLE;
        end
      endcase
    end
  end
endmodule
