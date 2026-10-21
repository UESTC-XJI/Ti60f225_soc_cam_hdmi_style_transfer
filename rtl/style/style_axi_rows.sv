// Compact NHWC row DMA, 128-bit INCR bursts, maximum 32 beats, no 4KiB crossing.
// RGB is XBGR8888 little-endian in DDR; features are compact signed INT8.
module style_axi_rows #(parameter integer BURST_MAX=32)(
  input wire clk,rst_n,
  input wire rd_start,input wire [31:0] rd_address,input wire [9:0] rd_pixels,input wire [4:0] rd_channels,
  output reg rd_busy,rd_done,rd_error,output wire rd_valid,input wire rd_ready,output reg [191:0] rd_pixel,
  input wire wr_start,input wire [31:0] wr_address,input wire [9:0] wr_pixels,input wire [4:0] wr_channels,
  output reg wr_busy,wr_done,wr_error,input wire wr_valid,output wire wr_ready,input wire [191:0] wr_pixel,
  output reg [31:0] araddr,output reg [7:0] arlen,output wire arvalid,input wire arready,
  input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
  output reg [31:0] awaddr,output reg [7:0] awlen,output wire awvalid,input wire awready,
  output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
  input wire [1:0] bresp,input wire bvalid,output wire bready
);
  localparam R_IDLE=0,R_ADDR=1,R_DATA=2,R_DRAIN=3;
  localparam W_IDLE=0,W_ADDR=1,W_DATA=2,W_RESP=3;
  reg [1:0] rs,ws;reg [319:0] rb,wb;reg [5:0] rc,wc;
  reg [4:0] rbpp,wbpp;reg [9:0] rn,wn;reg [15:0] rleft,wleft;
  reg [7:0] rbeat,wbeat;reg [31:0] ra,wa;
  function [7:0] burst_len;
    input [15:0] remaining;input [31:0] address;
    reg [8:0] boundary;reg [15:0] n;
    begin
      boundary=(13'd4096-{1'b0,address[11:0]})>>4;
      n=remaining>BURST_MAX ? BURST_MAX:remaining;
      if(n>boundary) n=boundary;
      burst_len=n-1;
    end
  endfunction
  assign arvalid=rs==R_ADDR;assign awvalid=ws==W_ADDR;
  assign rd_valid=rd_busy && rc>=rbpp && rn!=0;
  wire rpop=rd_valid&&rd_ready;
  // Consume and append concurrently; the 40-byte reservoir stays bounded.
  assign rready=rs==R_DATA && (rc-(rpop ? rbpp:0))<=24;
  assign wdata=wb[127:0];assign wstrb=16'hffff;
  assign wvalid=ws==W_DATA && wc>=16;
  assign wlast=wbeat==awlen;assign bready=ws==W_RESP;
  wire wpop=wvalid&&wready;
  assign wr_ready=wr_busy && wn!=0 && (wc+wbpp <= (wpop ? 56:40));
  reg [191:0] pack_pixel;
  reg [319:0] rb_next;reg [6:0] rc_next;
  reg [319:0] wb_next;reg [6:0] wc_next;
  always @* begin
    rd_pixel=0;
    if(rbpp==4) rd_pixel[23:0]=rb[23:0]^24'h808080;
    else rd_pixel=rb[191:0];
    rb_next=rpop ? rb>>(rbpp*8):rb;rc_next=rpop ? rc-rbpp:rc;
    if(rvalid&&rready)begin
      rb_next=rb_next | ({{192{1'b0}},rdata}<<(rc_next[4:2]*32));rc_next=rc_next+16;
    end
    pack_pixel=wr_pixel;
    if(wbpp==4) pack_pixel={160'b0,8'b0,(wr_pixel[23:0]^24'h808080)};
    wb_next=wpop ? wb>>128:wb;wc_next=wpop ? wc-16:wc;
    if(wr_valid&&wr_ready) begin
      // Explicit masks prevent stale padding channels entering the next pixel.
      case(wbpp) 4:pack_pixel[191:32]=0;8:pack_pixel[191:64]=0;default:begin end endcase
      wb_next=wb_next | ({{128{1'b0}},pack_pixel} << (wc_next[5:2]*32));
      wc_next=wc_next+wbpp;
    end
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rd_busy<=0;rd_done<=0;rd_error<=0;wr_busy<=0;wr_done<=0;wr_error<=0;
      rs<=R_IDLE;ws<=W_IDLE;rb<=0;wb<=0;rc<=0;wc<=0;rbpp<=0;wbpp<=0;
      rn<=0;wn<=0;rleft<=0;wleft<=0;rbeat<=0;wbeat<=0;ra<=0;wa<=0;araddr<=0;awaddr<=0;arlen<=0;awlen<=0;
    end else begin
      rd_done<=0;wr_done<=0;
      if(rd_start&&!rd_busy) begin
        rd_busy<=1;rd_error<=0;rb<=0;rc<=0;rn<=rd_pixels;rbpp<=rd_channels==3 ? 4:rd_channels;
        rleft<=(rd_pixels*(rd_channels==3 ? 4:rd_channels))>>4;ra<=rd_address;
        araddr<=rd_address;arlen<=burst_len((rd_pixels*(rd_channels==3 ? 4:rd_channels))>>4,rd_address);rs<=R_ADDR;
      end
      else begin rb<=rb_next;rc<=rc_next[5:0];if(rpop)rn<=rn-1'b1;end
      if(arvalid&&arready) begin rs<=R_DATA;rbeat<=0;end
      if(rvalid&&rready) begin
        if(rresp!=0 || rlast!=(rbeat==arlen)) rd_error<=1;
        rbeat<=rbeat+1'b1;
        if(rlast) begin
          rleft<=rleft-({8'b0,arlen}+1);ra<=ra+(({24'b0,arlen}+1)<<4);
          if(rleft==({8'b0,arlen}+1)) rs<=R_DRAIN;
          else begin
            araddr<=ra+(({24'b0,arlen}+1)<<4);
            arlen<=burst_len(rleft-({8'b0,arlen}+1),ra+(({24'b0,arlen}+1)<<4));rs<=R_ADDR;
          end
        end
      end
      if(rs==R_DRAIN && rn==0) begin rd_busy<=0;rd_done<=1;rs<=R_IDLE;end
      if(wr_start&&!wr_busy) begin
        wr_busy<=1;wr_error<=0;wb<=0;wc<=0;wn<=wr_pixels;wbpp<=wr_channels==3 ? 4:wr_channels;
        wleft<=(wr_pixels*(wr_channels==3 ? 4:wr_channels))>>4;wa<=wr_address;
        awaddr<=wr_address;awlen<=burst_len((wr_pixels*(wr_channels==3 ? 4:wr_channels))>>4,wr_address);ws<=W_ADDR;
      end else begin
        wb<=wb_next;wc<=wc_next[5:0];
        if(wr_valid&&wr_ready) wn<=wn-1'b1;
      end
      if(awvalid&&awready) begin ws<=W_DATA;wbeat<=0;end
      if(wpop) begin
        wbeat<=wbeat+1'b1;
        if(wlast) ws<=W_RESP;
      end
      if(bvalid&&bready) begin
        if(bresp!=0) wr_error<=1;
        wleft<=wleft-({8'b0,awlen}+1);wa<=wa+(({24'b0,awlen}+1)<<4);
        if(wleft==({8'b0,awlen}+1)) begin ws<=W_IDLE;wr_busy<=0;wr_done<=1;end
        else begin
          awaddr<=wa+(({24'b0,awlen}+1)<<4);
          awlen<=burst_len(wleft-({8'b0,awlen}+1),wa+(({24'b0,awlen}+1)<<4));ws<=W_ADDR;
        end
      end
    end
  end
endmodule
