// Replaces the baseline resize/framebuffer/CVO path in the isolated demo branch.
// The nested bridge saves full local IDs before the outer CPU/video bridge.
module style_video_system #(parameter bit DISPLAY_BUFFER=1'b1,ADAPTIVE_READ=1'b1,UI_ENABLE=1'b0)(
  input wire clk,cnn_clk,pix_clk,rst_n,
  input wire compare_enable,
  input wire rgb_vs,rgb_de,input wire [47:0] rgb_data,
  input wire psel,penable,pwrite,input wire [7:0] paddr,input wire [31:0] pwdata,
  output wire [31:0] prdata,output wire pready,pslverr,irq,
  output wire [31:0] pixel,output wire hs,vs,de,underflow,capture_fault,
  output wire [31:0] resized_frames,
  output wire [5:0] awid,arid,output wire [31:0] awaddr,araddr,output wire [7:0] awlen,arlen,
  output wire [2:0] awsize,arsize,output wire [1:0] awburst,arburst,
  output wire awvalid,arvalid,input wire awready,arready,
  output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
  input wire [5:0] bid,rid,input wire [1:0] bresp,rresp,input wire bvalid,rvalid,rlast,output wire bready,rready,input wire [127:0] rdata
);
  wire crop_valid,crop_sof,crop_eof,crop_fault;wire [31:0] crop_pixel;
  style_vga_crop crop(.clk(cnn_clk),.rst_n(rst_n),.i_vs(rgb_vs),.i_de(rgb_de),.i_rgb(rgb_data),
    .valid(crop_valid),.sof(crop_sof),.eof(crop_eof),.pixel(crop_pixel),.fault(crop_fault),.completed_frames(resized_frames));
  wire stream_enable;
  (* async_reg="true" *)reg [1:0] enable_sync;reg cap_gate,cap_overflow;
  wire cap_input_ready,cap_valid,cap_ready;wire [33:0] cap_packet;
  wire cap_input_valid=crop_valid&&(crop_sof ? enable_sync[1]:cap_gate);
  always @(posedge cnn_clk or negedge rst_n)begin
    if(!rst_n)begin enable_sync<=0;cap_gate<=0;cap_overflow<=0;end
    else begin
      enable_sync<={enable_sync[0],stream_enable};
      if(crop_sof&&crop_valid)cap_gate<=enable_sync[1];
      if(crop_eof&&crop_valid)cap_gate<=0;
      if(cap_input_valid&&!cap_input_ready)cap_overflow<=1;
    end
  end
  assign capture_fault=crop_fault||cap_overflow;
  style_async_fifo #(.WIDTH(34),.LOG_DEPTH(11)) capture_fifo(.reset_n(rst_n),.wclk(cnn_clk),.rclk(clk),
    .in_valid(cap_input_valid),.in_ready(cap_input_ready),.in_data({crop_sof,crop_eof,crop_pixel}),
    .out_valid(cap_valid),.out_ready(cap_ready),.out_data(cap_packet));
  wire nn_start,nn_ready,nn_done,nn_error;wire [31:0] nn_source,nn_result,nn_cycles;
  wire [2:0] display_slot;wire display_valid,display_frame_event,display_safe;
  wire display_read_urgent;
  wire [31:0] captured,dropped,inferred,infer_errors,display_frame_id,display_dma_errors;
  wire [31:0] v_awaddr,v_araddr;wire [7:0] v_awlen,v_arlen;
  wire v_awvalid,v_awready,v_wlast,v_wvalid,v_wready,v_bvalid,v_bready,v_arvalid,v_arready,v_rvalid,v_rready,v_rlast;
  wire [127:0] v_wdata,v_rdata;wire [15:0] v_wstrb;wire [1:0] v_bresp,v_rresp;
  wire [7:0] unused_bid,unused_rid;
  style_frame_store store(.clk(clk),.rst_n(rst_n),.cap_valid(cap_valid),.cap_ready(cap_ready),.cap_packet(cap_packet),
    .stream_enable(stream_enable),.nn_ready(nn_ready),.nn_done(nn_done),.nn_error(nn_error),.nn_start(nn_start),.nn_source(nn_source),.nn_result(nn_result),
    .display_frame_event(display_frame_event),.display_safe(display_safe),.display_slot(display_slot),.display_valid(display_valid),
    .captured(captured),.dropped(dropped),.inferred(inferred),.infer_errors(infer_errors),.display_frame_id(display_frame_id),
    .awaddr(v_awaddr),.awlen(v_awlen),.awvalid(v_awvalid),.awready(v_awready),.wdata(v_wdata),.wstrb(v_wstrb),.wlast(v_wlast),.wvalid(v_wvalid),.wready(v_wready),.bresp(v_bresp),.bvalid(v_bvalid),.bready(v_bready));
  style_display #(.BUFFERED(DISPLAY_BUFFER),.UI_ENABLE(UI_ENABLE)) display(.clk(clk),.pix_clk(pix_clk),.rst_n(rst_n),.display_slot(display_slot),.display_valid(display_valid),.compare_enable(compare_enable),
    .display_frame_event(display_frame_event),.display_safe(display_safe),.pixel(pixel),.hs(hs),.vs(vs),.de(de),.underflow(underflow),.dma_errors(display_dma_errors),
    .read_urgent(display_read_urgent),
    .araddr(v_araddr),.arlen(v_arlen),.arvalid(v_arvalid),.arready(v_arready),.rdata(v_rdata),.rresp(v_rresp),.rlast(v_rlast),.rvalid(v_rvalid),.rready(v_rready));
  wire [31:0] c_awaddr,c_araddr;wire [7:0] c_awlen,c_arlen;
  wire c_awvalid,c_awready,c_wlast,c_wvalid,c_wready,c_bvalid,c_bready,c_arvalid,c_arready,c_rvalid,c_rready,c_rlast;
  wire [127:0] c_wdata,c_rdata;wire [15:0] c_wstrb;wire [1:0] c_bresp,c_rresp;
  wire [7:0] c_bid,c_rid;wire [31:0] accel_prdata;
  style_accel accelerator(.clk(clk),.cnn_clk(cnn_clk),.rst_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),.paddr(paddr),.pwdata(pwdata),
    .prdata(accel_prdata),.pready(pready),.pslverr(pslverr),.irq(irq),.stream_enable(stream_enable),
    .auto_start(nn_start),.auto_source(nn_source),.auto_result(nn_result),.auto_ready(nn_ready),.job_done(nn_done),.job_error(nn_error),.last_cycles(nn_cycles),
    .araddr(c_araddr),.arlen(c_arlen),.arvalid(c_arvalid),.arready(c_arready),.rdata(c_rdata),.rresp(c_rresp),.rlast(c_rlast),.rvalid(c_rvalid),.rready(c_rready),
    .awaddr(c_awaddr),.awlen(c_awlen),.awvalid(c_awvalid),.awready(c_awready),.wdata(c_wdata),.wstrb(c_wstrb),.wlast(c_wlast),.wvalid(c_wvalid),.wready(c_wready),.bresp(c_bresp),.bvalid(c_bvalid),.bready(c_bready));
  wire [31:0] bridge_errors;
  reg profile_freeze;
  wire profile_write=psel&&penable&&pwrite&&pready&&!pslverr&&paddr==8'h54;
  wire [31:0] profile_value;
  wire [3:0] profile_index=(paddr-8'h58)>>2;
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)profile_freeze<=0;
    else if(profile_write)profile_freeze<=pwdata[0];
  end
  style_ddr_profiler profiler(.clk(clk),.rst_n(rst_n),.enable(stream_enable),.freeze(profile_freeze),
    .clear(profile_write&&pwdata[1]),.network_idle(nn_ready),.index(profile_index),.value(profile_value),
    .c_arvalid(c_arvalid),.c_arready(c_arready),.c_rvalid(c_rvalid),.c_rready(c_rready),.c_rlast(c_rlast),
    .c_awvalid(c_awvalid),.c_awready(c_awready),.c_wvalid(c_wvalid),.c_wready(c_wready),.c_wlast(c_wlast),.c_bvalid(c_bvalid),.c_bready(c_bready),
    .arvalid(arvalid),.arready(arready),.v_rvalid(v_rvalid),.v_rready(v_rready));
  // Hard display deadlines override the CNN bypass limit. CNN reads remain
  // fair when display urgency clears; the outer CPU/video policy is unchanged.
  axi_shared_ddr_2m #(.DDR_ID_W(6),.VIDEO_READ_PRIORITY(!ADAPTIVE_READ),.DYNAMIC_VIDEO_READ(ADAPTIVE_READ),.URGENT_OVERRIDES_FAIRNESS(1'b1),.RESERVE_URGENT_READ(ADAPTIVE_READ)) bridge(.clk(clk),.rst_n(rst_n),.allow_access(1'b1),.video_read_urgent(display_read_urgent),
    .cpu_awid(8'h03),.cpu_awaddr(c_awaddr),.cpu_awlen(c_awlen),.cpu_awsize(3'd4),.cpu_awburst(2'b01),.cpu_awvalid(c_awvalid),.cpu_awready(c_awready),
    .cpu_wdata(c_wdata),.cpu_wstrb(c_wstrb),.cpu_wlast(c_wlast),.cpu_wvalid(c_wvalid),.cpu_wready(c_wready),.cpu_bid(c_bid),.cpu_bresp(c_bresp),.cpu_bvalid(c_bvalid),.cpu_bready(c_bready),
    .cpu_arid(8'h03),.cpu_araddr(c_araddr),.cpu_arlen(c_arlen),.cpu_arsize(3'd4),.cpu_arburst(2'b01),.cpu_arvalid(c_arvalid),.cpu_arready(c_arready),.cpu_rid(c_rid),.cpu_rdata(c_rdata),.cpu_rresp(c_rresp),.cpu_rlast(c_rlast),.cpu_rvalid(c_rvalid),.cpu_rready(c_rready),
    .vid_awid(8'h01),.vid_awaddr(v_awaddr),.vid_awlen(v_awlen),.vid_awsize(3'd4),.vid_awburst(2'b01),.vid_awvalid(v_awvalid),.vid_awready(v_awready),
    .vid_wdata(v_wdata),.vid_wstrb(v_wstrb),.vid_wlast(v_wlast),.vid_wvalid(v_wvalid),.vid_wready(v_wready),.vid_bid(unused_bid),.vid_bresp(v_bresp),.vid_bvalid(v_bvalid),.vid_bready(v_bready),
    .vid_arid(8'h02),.vid_araddr(v_araddr),.vid_arlen(v_arlen),.vid_arsize(3'd4),.vid_arburst(2'b01),.vid_arvalid(v_arvalid),.vid_arready(v_arready),.vid_rid(unused_rid),.vid_rdata(v_rdata),.vid_rresp(v_rresp),.vid_rlast(v_rlast),.vid_rvalid(v_rvalid),.vid_rready(v_rready),
    .ddr_awid(awid),.ddr_awaddr(awaddr),.ddr_awlen(awlen),.ddr_awsize(awsize),.ddr_awburst(awburst),.ddr_awvalid(awvalid),.ddr_awready(awready),
    .ddr_wdata(wdata),.ddr_wstrb(wstrb),.ddr_wlast(wlast),.ddr_wvalid(wvalid),.ddr_wready(wready),.ddr_bid(bid),.ddr_bresp(bresp),.ddr_bvalid(bvalid),.ddr_bready(bready),
    .ddr_arid(arid),.ddr_araddr(araddr),.ddr_arlen(arlen),.ddr_arsize(arsize),.ddr_arburst(arburst),.ddr_arvalid(arvalid),.ddr_arready(arready),.ddr_rid(rid),.ddr_rdata(rdata),.ddr_rresp(rresp),.ddr_rlast(rlast),.ddr_rvalid(rvalid),.ddr_rready(rready),.axi_error_count(bridge_errors));
  assign prdata=paddr==8'h38 ? captured:paddr==8'h3c ? dropped:paddr==8'h40 ? inferred:
    paddr==8'h44 ? infer_errors:paddr==8'h48 ? display_frame_id:paddr==8'h4c ? display_dma_errors:
    paddr==8'h50 ? bridge_errors:paddr==8'h54 ? {31'b0,profile_freeze}:
    (paddr>=8'h58&&paddr<=8'h84) ? profile_value:accel_prdata;
endmodule
