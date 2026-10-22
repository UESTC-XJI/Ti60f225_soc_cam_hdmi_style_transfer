// APB control at 100MHz; computation at 148.5MHz. Stable mailbox payloads
// are held until the completion toggle returns. Coefficient writes use a FIFO.
module style_accel #(parameter bit USE_ROW_PIPE = 1'b1)(
  input wire clk,cnn_clk,rst_n,
  input wire psel,penable,pwrite,input wire [7:0] paddr,input wire [31:0] pwdata,
  output reg [31:0] prdata,output wire pready,output wire pslverr,output wire irq,
  output reg stream_enable,
  input wire auto_start,input wire [31:0] auto_source,auto_result,
  output wire auto_ready,output wire job_done,output wire job_error,
  output wire [31:0] last_cycles,
  output wire [31:0] araddr,awaddr,output wire [7:0] arlen,awlen,
  output wire arvalid,awvalid,input wire arready,awready,
  output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
  input wire [127:0] rdata,input wire [1:0] rresp,bresp,input wire rlast,rvalid,bvalid,output wire rready,bready
);
  reg [31:0] source_cfg,result_cfg,geometry,mail_source,mail_result,mail_geometry;
  reg [15:0] coefficient_index,issued;
  reg pending,done_sticky,error_sticky,irq_enable,start_toggle;
  wire coef_ready,coef_valid;wire [44:0] coef_packet;
  wire coef_write=psel&&penable&&pwrite&&paddr==8'h2c&&!pending;
  wire [44:0] coef_input={coefficient_index[15:8],coefficient_index[4:0],pwdata};
  wire coeff_input_ready;
  // APB is backpressured when full; four entries cover CDC latency without
  // spending sixteen words of registers on the initialization-only queue.
  style_async_fifo #(.WIDTH(45),.LOG_DEPTH(2)) coeff_fifo(.reset_n(rst_n),.wclk(clk),.rclk(cnn_clk),
    .in_valid(coef_write),.in_ready(coeff_input_ready),.in_data(coef_input),
    .out_valid(coef_valid),.out_ready(coef_ready),.out_data(coef_packet));
  reg [15:0] committed,committed_gray;
  (* async_reg="true" *) reg [15:0] cg1,cg2;
  reg [15:0] acknowledged;integer bit_index;
  always @* begin
    acknowledged[15]=cg2[15];
    for(bit_index=14;bit_index>=0;bit_index=bit_index-1)acknowledged[bit_index]=acknowledged[bit_index+1]^cg2[bit_index];
  end
  wire coeff_idle=issued==acknowledged;
  assign auto_ready=!pending&&coeff_idle;
  wire [21:0] frame_bytes=geometry[9:0]*geometry[25:16]*4;
  wire config_ok=source_cfg[3:0]==0&&result_cfg[3:0]==0 &&
    source_cfg>=32'h05000000&&source_cfg<=32'h05800000-frame_bytes &&
    result_cfg>=32'h05800000&&result_cfg<=32'h06000000-frame_bytes &&
    geometry[9:0]>=32&&geometry[9:0]<=640&&geometry[4:0]==0&&
    geometry[25:16]>=24&&geometry[25:16]<=480&&geometry[17:16]==0;
  assign pready=!(coef_write&&!coeff_input_ready);
  wire is_config=paddr==8'h10||paddr==8'h14||paddr==8'h18||paddr==8'h28||paddr==8'h2c;
  assign pslverr=psel&&penable&&pwrite&&((pending&&is_config)||
    (paddr==4&&pwdata[0]&&(!auto_ready||!config_ok))||(paddr==8'h28&&pwdata[4:0]>23));
  assign irq=irq_enable&&(done_sticky||error_sticky);
  reg done_toggle,core_error_snapshot;reg [31:0] core_cycles_snapshot;
  reg [31:0] read_cycles_snapshot,compute_cycles_snapshot;
  reg [31:0] prefetch_starts_snapshot,prefetch_completions_snapshot,overlap_cycles_snapshot;
  wire [31:0] stat_read_cycles,stat_compute_cycles;
  wire [31:0] stat_prefetch_starts,stat_prefetch_completions,stat_overlap_cycles;
  (* async_reg="true" *) reg done1,done2;reg done_seen;
  assign job_done=done2!=done_seen;assign job_error=core_error_snapshot;
  assign last_cycles=core_cycles_snapshot;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      source_cfg<=32'h05000000;result_cfg<=32'h05800000;geometry<={16'd480,16'd640};
      mail_source<=0;mail_result<=0;mail_geometry<=0;coefficient_index<=0;issued<=0;
      pending<=0;done_sticky<=0;error_sticky<=0;irq_enable<=0;start_toggle<=0;stream_enable<=0;
      done1<=0;done2<=0;done_seen<=0;cg1<=0;cg2<=0;
    end else begin
      done1<=done_toggle;done2<=done1;done_seen<=done2;cg1<=committed_gray;cg2<=cg1;
      if(job_done)begin pending<=0;done_sticky<=1;if(job_error)error_sticky<=1;end
      if(coef_write&&coeff_input_ready)issued<=issued+1'b1;
      if(psel&&penable&&pready&&pwrite&&!pslverr)case(paddr)
        8'h04:begin
          stream_enable<=pwdata[4];
          if(pwdata[0])begin pending<=1;done_sticky<=0;mail_source<=source_cfg;mail_result<=result_cfg;mail_geometry<=geometry;start_toggle<=!start_toggle;end
        end
        8'h08:begin if(pwdata[1])done_sticky<=0;if(pwdata[2])error_sticky<=0;end
        8'h0c:irq_enable<=pwdata[0];
        8'h10:source_cfg<=pwdata;8'h14:result_cfg<=pwdata;8'h18:geometry<=pwdata;8'h28:coefficient_index<=pwdata[15:0];
      endcase
      if(auto_start&&auto_ready&&stream_enable)begin
        pending<=1;done_sticky<=0;mail_source<=auto_source;mail_result<=auto_result;mail_geometry<={16'd480,16'd640};start_toggle<=!start_toggle;
      end
    end
  end
  always @* begin
    prdata=0;
    case(paddr)
      8'h00:prdata=32'h3154534e;
      8'h04:prdata={27'b0,stream_enable,4'b0};
      8'h08:prdata={27'b0,coeff_idle,1'b0,error_sticky,done_sticky,pending};
      8'h0c:prdata={31'b0,irq_enable};8'h10:prdata=source_cfg;8'h14:prdata=result_cfg;8'h18:prdata=geometry;
      8'h1c:prdata=last_cycles;8'h28:prdata={16'b0,coefficient_index};8'h30:prdata={acknowledged,issued};
      8'h34:prdata=32'd148500000;
      8'ha8:prdata=read_cycles_snapshot;8'hac:prdata=compute_cycles_snapshot;
      8'hb0:prdata=prefetch_starts_snapshot;8'hb4:prdata=prefetch_completions_snapshot;8'hb8:prdata=overlap_cycles_snapshot;
    endcase
  end
  (* async_reg="true" *) reg [1:0] core_reset,start_sync;reg start_seen;
  always @(posedge cnn_clk or negedge rst_n)if(!rst_n)core_reset<=0;else core_reset<={core_reset[0],1'b1};
  wire core_start=start_sync[1]!=start_seen;
  wire core_busy,core_done,core_error;wire [4:0] core_layer;wire [31:0] core_cycles;
  assign coef_ready=core_reset[1]&&!core_busy;
  always @(posedge cnn_clk or negedge rst_n) begin
    if(!rst_n)begin start_sync<=0;start_seen<=0;committed<=0;committed_gray<=0;done_toggle<=0;core_error_snapshot<=0;core_cycles_snapshot<=0;read_cycles_snapshot<=0;compute_cycles_snapshot<=0;prefetch_starts_snapshot<=0;prefetch_completions_snapshot<=0;overlap_cycles_snapshot<=0;end
    else if(core_reset[1])begin
      start_sync<={start_sync[0],start_toggle};start_seen<=start_sync[1];
      if(coef_valid&&coef_ready)begin committed<=committed+1'b1;committed_gray<=((committed+1'b1)>>1)^(committed+1'b1);end
      if(core_done)begin done_toggle<=!done_toggle;core_error_snapshot<=core_error;core_cycles_snapshot<=core_cycles;read_cycles_snapshot<=stat_read_cycles;compute_cycles_snapshot<=stat_compute_cycles;prefetch_starts_snapshot<=stat_prefetch_starts;prefetch_completions_snapshot<=stat_prefetch_completions;overlap_cycles_snapshot<=stat_overlap_cycles;end
    end
  end
  wire [31:0] c_araddr,c_awaddr;wire [7:0] c_arlen,c_awlen;wire c_arvalid,c_arready,c_awvalid,c_awready;
  wire [127:0] c_wdata,c_rdata;wire [15:0] c_wstrb;wire c_wlast,c_wvalid,c_wready,c_rlast,c_rvalid,c_rready,c_bvalid,c_bready;wire [1:0] c_rresp,c_bresp;
  generate if (USE_ROW_PIPE) begin: g_row
  style_network_rowpipe network(.clk(cnn_clk),.rst_n(core_reset[1]),.start(core_start),.source_address(mail_source),.result_address(mail_result),
    .frame_width(mail_geometry[9:0]),.frame_height(mail_geometry[25:16]),
    .coef_we(coef_valid&&coef_ready),.coef_addr(coef_packet[44:37]),.coef_word(coef_packet[36:32]),.coef_data(coef_packet[31:0]),
    .busy(core_busy),.done(core_done),.error(core_error),.layer_index(core_layer),.cycles(core_cycles),
    .stat_read_cycles(stat_read_cycles),.stat_compute_cycles(stat_compute_cycles),
    .stat_prefetch_starts(stat_prefetch_starts),.stat_prefetch_completions(stat_prefetch_completions),.stat_overlap_cycles(stat_overlap_cycles),
    .araddr(c_araddr),.arlen(c_arlen),.arvalid(c_arvalid),.arready(c_arready),.rdata(c_rdata),.rresp(c_rresp),.rlast(c_rlast),.rvalid(c_rvalid),.rready(c_rready),
    .awaddr(c_awaddr),.awlen(c_awlen),.awvalid(c_awvalid),.awready(c_awready),.wdata(c_wdata),.wstrb(c_wstrb),.wlast(c_wlast),.wvalid(c_wvalid),.wready(c_wready),.bresp(c_bresp),.bvalid(c_bvalid),.bready(c_bready));
  end else begin: g_monet
  style_network network(.clk(cnn_clk),.rst_n(core_reset[1]),.start(core_start),.source_address(mail_source),.result_address(mail_result),
    .frame_width(mail_geometry[9:0]),.frame_height(mail_geometry[25:16]),
    .coef_we(coef_valid&&coef_ready),.coef_addr(coef_packet[44:37]),.coef_word(coef_packet[36:32]),.coef_data(coef_packet[31:0]),
    .busy(core_busy),.done(core_done),.error(core_error),.layer_index(core_layer),.cycles(core_cycles),
    .stat_read_cycles(stat_read_cycles),.stat_compute_cycles(stat_compute_cycles),
    .stat_prefetch_starts(stat_prefetch_starts),.stat_prefetch_completions(stat_prefetch_completions),.stat_overlap_cycles(stat_overlap_cycles),
    .araddr(c_araddr),.arlen(c_arlen),.arvalid(c_arvalid),.arready(c_arready),.rdata(c_rdata),.rresp(c_rresp),.rlast(c_rlast),.rvalid(c_rvalid),.rready(c_rready),
    .awaddr(c_awaddr),.awlen(c_awlen),.awvalid(c_awvalid),.awready(c_awready),.wdata(c_wdata),.wstrb(c_wstrb),.wlast(c_wlast),.wvalid(c_wvalid),.wready(c_wready),.bresp(c_bresp),.bvalid(c_bvalid),.bready(c_bready));
  end endgenerate
  style_axi_cdc cdc(.*,.reset_n(rst_n),.axi_clk(clk));
endmodule
