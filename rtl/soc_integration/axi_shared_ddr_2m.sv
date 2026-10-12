// AXI4 shared DDR bridge for one Sapphire CPU master and one video master.
// One write and one read burst may be outstanding. Address skid registers
// hold payloads stable during DDR backpressure; owner and full source ID are
// retained through B/R. DDR_ID_W-1 is the owner bit.
module axi_shared_ddr_2m #(
  parameter integer ADDR_W=32, DATA_W=128, STRB_W=DATA_W/8,
  parameter integer ID_W=8, DDR_ID_W=4,
  // A display reader has a hard per-line deadline.  The isolated style
  // bridge enables this only for its inner CNN/display arbitration; the
  // outer CPU/video bridge keeps the fair round-robin default.
  parameter bit VIDEO_READ_PRIORITY=1'b0,
  parameter bit DYNAMIC_VIDEO_READ=1'b0,
  // A hard display deadline may override the best-effort bypass limit.
  // When urgency clears, the existing round-robin policy resumes.
  parameter bit URGENT_OVERRIDES_FAIRNESS=1'b0,
  // Preserve the gap between display bursts while its FIFO needs data.
  // An already outstanding transaction is never cancelled or preempted.
  parameter bit RESERVE_URGENT_READ=1'b0,
  parameter integer MAX_VIDEO_BURSTS=3
)(
  input logic clk, rst_n, allow_access,
  input logic video_read_urgent,
  input logic [ID_W-1:0] cpu_awid, input logic [ADDR_W-1:0] cpu_awaddr, input logic [7:0] cpu_awlen, input logic [2:0] cpu_awsize, input logic [1:0] cpu_awburst, input logic cpu_awvalid, output logic cpu_awready,
  input logic [DATA_W-1:0] cpu_wdata, input logic [STRB_W-1:0] cpu_wstrb, input logic cpu_wlast, input logic cpu_wvalid, output logic cpu_wready,
  output logic [ID_W-1:0] cpu_bid, output logic [1:0] cpu_bresp, output logic cpu_bvalid, input logic cpu_bready,
  input logic [ID_W-1:0] cpu_arid, input logic [ADDR_W-1:0] cpu_araddr, input logic [7:0] cpu_arlen, input logic [2:0] cpu_arsize, input logic [1:0] cpu_arburst, input logic cpu_arvalid, output logic cpu_arready,
  output logic [ID_W-1:0] cpu_rid, output logic [DATA_W-1:0] cpu_rdata, output logic [1:0] cpu_rresp, output logic cpu_rlast, output logic cpu_rvalid, input logic cpu_rready,
  input logic [ID_W-1:0] vid_awid, input logic [ADDR_W-1:0] vid_awaddr, input logic [7:0] vid_awlen, input logic [2:0] vid_awsize, input logic [1:0] vid_awburst, input logic vid_awvalid, output logic vid_awready,
  input logic [DATA_W-1:0] vid_wdata, input logic [STRB_W-1:0] vid_wstrb, input logic vid_wlast, input logic vid_wvalid, output logic vid_wready,
  output logic [ID_W-1:0] vid_bid, output logic [1:0] vid_bresp, output logic vid_bvalid, input logic vid_bready,
  input logic [ID_W-1:0] vid_arid, input logic [ADDR_W-1:0] vid_araddr, input logic [7:0] vid_arlen, input logic [2:0] vid_arsize, input logic [1:0] vid_arburst, input logic vid_arvalid, output logic vid_arready,
  output logic [ID_W-1:0] vid_rid, output logic [DATA_W-1:0] vid_rdata, output logic [1:0] vid_rresp, output logic vid_rlast, output logic vid_rvalid, input logic vid_rready,
  output logic [DDR_ID_W-1:0] ddr_awid, output logic [ADDR_W-1:0] ddr_awaddr, output logic [7:0] ddr_awlen, output logic [2:0] ddr_awsize, output logic [1:0] ddr_awburst, output logic ddr_awvalid, input logic ddr_awready,
  output logic [DATA_W-1:0] ddr_wdata, output logic [STRB_W-1:0] ddr_wstrb, output logic ddr_wlast, output logic ddr_wvalid, input logic ddr_wready,
  input logic [DDR_ID_W-1:0] ddr_bid, input logic [1:0] ddr_bresp, input logic ddr_bvalid, output logic ddr_bready,
  output logic [DDR_ID_W-1:0] ddr_arid, output logic [ADDR_W-1:0] ddr_araddr, output logic [7:0] ddr_arlen, output logic [2:0] ddr_arsize, output logic [1:0] ddr_arburst, output logic ddr_arvalid, input logic ddr_arready,
  input logic [DDR_ID_W-1:0] ddr_rid, input logic [DATA_W-1:0] ddr_rdata, input logic [1:0] ddr_rresp, input logic ddr_rlast, input logic ddr_rvalid, output logic ddr_rready,
  output logic [31:0] axi_error_count
);
  localparam integer SRC_ID_W = DDR_ID_W-1;
  logic wr_busy, wr_aw_sent, wr_owner, wr_w_seen;
  logic [ID_W-1:0] wr_id; logic [ADDR_W-1:0] wr_addr; logic [7:0] wr_len; logic [2:0] wr_size; logic [1:0] wr_burst;
  logic rd_busy, rd_ar_sent, rd_owner;
  logic [ID_W-1:0] rd_id; logic [ADDR_W-1:0] rd_addr; logic [7:0] rd_len; logic [2:0] rd_size; logic [1:0] rd_burst;
  logic rd_turn; logic [3:0] video_write_streak;
  localparam integer STREAK_W=$clog2(MAX_VIDEO_BURSTS+1);
  logic [STREAK_W-1:0] video_read_streak;
  wire choose_vid_w = cpu_awvalid && vid_awvalid ? (video_write_streak < 4'd8) : vid_awvalid;
  wire choose_vid_r = cpu_arvalid && vid_arvalid ?
    (VIDEO_READ_PRIORITY ? 1'b1 :
      DYNAMIC_VIDEO_READ && video_read_urgent && (URGENT_OVERRIDES_FAIRNESS || video_read_streak<MAX_VIDEO_BURSTS) ? 1'b1:
      DYNAMIC_VIDEO_READ && video_read_streak>=MAX_VIDEO_BURSTS ? 1'b0:rd_turn) : vid_arvalid;
  // Count B/R protocol or ownership errors once per response beat.  These
  // are wires so simultaneous B and R errors are accumulated together rather
  // than losing one increment to two nonblocking assignments.
  wire [DDR_ID_W-1:0] expected_bid={wr_owner,wr_id[SRC_ID_W-1:0]};
  wire [DDR_ID_W-1:0] expected_rid={rd_owner,rd_id[SRC_ID_W-1:0]};
  wire b_error = ddr_bvalid && ddr_bready &&
                 (ddr_bresp != 2'b00 || ddr_bid !== expected_bid);
  wire r_error = ddr_rvalid && ddr_rready &&
                 (ddr_rresp != 2'b00 || ddr_rid !== expected_rid);

  always_comb begin
    cpu_awready=allow_access&&!wr_busy&&cpu_awvalid&&!choose_vid_w;
    vid_awready=allow_access&&!wr_busy&&vid_awvalid&&choose_vid_w;
    ddr_awvalid=wr_busy&&!wr_aw_sent; ddr_awid={wr_owner,wr_id[SRC_ID_W-1:0]}; ddr_awaddr=wr_addr; ddr_awlen=wr_len; ddr_awsize=wr_size; ddr_awburst=wr_burst;
    ddr_wvalid=wr_busy&&wr_aw_sent&&!wr_w_seen&&(wr_owner?vid_wvalid:cpu_wvalid);
    ddr_wdata=wr_owner?vid_wdata:cpu_wdata; ddr_wstrb=wr_owner?vid_wstrb:cpu_wstrb; ddr_wlast=wr_owner?vid_wlast:cpu_wlast;
    cpu_wready=wr_busy&&wr_aw_sent&&!wr_w_seen&&!wr_owner&&ddr_wready; vid_wready=wr_busy&&wr_aw_sent&&!wr_w_seen&&wr_owner&&ddr_wready;
    cpu_bvalid=wr_busy&&wr_w_seen&&!wr_owner&&ddr_bvalid; vid_bvalid=wr_busy&&wr_w_seen&&wr_owner&&ddr_bvalid;
    cpu_bid=wr_id; vid_bid=wr_id; cpu_bresp=ddr_bresp; vid_bresp=ddr_bresp; ddr_bready=wr_busy&&wr_w_seen&&(wr_owner?vid_bready:cpu_bready);
    cpu_arready=allow_access&&!rd_busy&&cpu_arvalid&&!choose_vid_r&&!(RESERVE_URGENT_READ&&video_read_urgent); vid_arready=allow_access&&!rd_busy&&vid_arvalid&&choose_vid_r;
    ddr_arvalid=rd_busy&&!rd_ar_sent; ddr_arid={rd_owner,rd_id[SRC_ID_W-1:0]}; ddr_araddr=rd_addr; ddr_arlen=rd_len; ddr_arsize=rd_size; ddr_arburst=rd_burst;
    cpu_rvalid=rd_busy&&!rd_owner&&ddr_rvalid; vid_rvalid=rd_busy&&rd_owner&&ddr_rvalid; cpu_rid=rd_id; vid_rid=rd_id; cpu_rdata=ddr_rdata; vid_rdata=ddr_rdata; cpu_rresp=ddr_rresp; vid_rresp=ddr_rresp; cpu_rlast=ddr_rlast; vid_rlast=ddr_rlast;
    ddr_rready=rd_busy&&(rd_owner?vid_rready:cpu_rready);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      wr_busy<=0; wr_aw_sent<=0; wr_owner<=0; wr_w_seen<=0; wr_id<='0; wr_addr<='0; wr_len<='0; wr_size<='0; wr_burst<='0;
      rd_busy<=0; rd_ar_sent<=0; rd_owner<=0; rd_id<='0; rd_addr<='0; rd_len<='0; rd_size<='0; rd_burst<='0; rd_turn<=0; video_write_streak<=0;video_read_streak<=0; axi_error_count<=0;
    end else begin
      if(cpu_awready||vid_awready) begin
        wr_busy<=1; wr_aw_sent<=0; wr_w_seen<=0; wr_owner<=choose_vid_w; wr_id<=choose_vid_w?vid_awid:cpu_awid; wr_addr<=choose_vid_w?vid_awaddr:cpu_awaddr; wr_len<=choose_vid_w?vid_awlen:cpu_awlen; wr_size<=choose_vid_w?vid_awsize:cpu_awsize; wr_burst<=choose_vid_w?vid_awburst:cpu_awburst;
        if(choose_vid_w) video_write_streak <= (video_write_streak==4'hf)?4'hf:video_write_streak+1'b1; else video_write_streak<=0;
      end
      if(ddr_awvalid&&ddr_awready) wr_aw_sent<=1;
      if(ddr_wvalid&&ddr_wready&&ddr_wlast) wr_w_seen<=1;
      if(ddr_bvalid&&ddr_bready) begin wr_busy<=0; wr_aw_sent<=0; wr_w_seen<=0; end
      if(cpu_arready||vid_arready) begin
        rd_busy<=1; rd_ar_sent<=0; rd_owner<=choose_vid_r; rd_id<=choose_vid_r?vid_arid:cpu_arid; rd_addr<=choose_vid_r?vid_araddr:cpu_araddr; rd_len<=choose_vid_r?vid_arlen:cpu_arlen; rd_size<=choose_vid_r?vid_arsize:cpu_arsize; rd_burst<=choose_vid_r?vid_arburst:cpu_arburst; rd_turn<=~choose_vid_r;
      end
      if(DYNAMIC_VIDEO_READ)begin
        if(!cpu_arvalid||cpu_arready)video_read_streak<=0;
        else if(vid_arready&&video_read_streak<MAX_VIDEO_BURSTS)video_read_streak<=video_read_streak+1'b1;
      end
      if(ddr_arvalid&&ddr_arready) rd_ar_sent<=1;
      if(ddr_rvalid&&ddr_rready) begin
        if(ddr_rlast) begin rd_busy<=0; rd_ar_sent<=0; end
      end
      if (b_error || r_error)
        axi_error_count <= axi_error_count + b_error + r_error;
    end
  end
endmodule
