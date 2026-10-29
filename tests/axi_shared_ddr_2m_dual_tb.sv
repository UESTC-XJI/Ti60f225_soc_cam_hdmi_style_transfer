`timescale 1ns/1ps
// DUAL_READ test: both masters issue reads while the DDR model delays all
// responses; both ARs must be outstanding. Responses are returned
// out-of-order to prove owner-bit routing.
module axi_shared_ddr_2m_dual_tb;
  logic clk=0,rst_n=0,allow_access=0; always #5 clk=~clk;
  logic video_read_urgent=1'b0;
  logic [7:0] cpu_awid=8'hA5,vid_awid=8'h5A,cpu_arid=8'hC3,vid_arid=8'h3C;
  logic [31:0] cpu_awaddr=32'h01000000,vid_awaddr=32'h10000000,cpu_araddr=32'h01000000,vid_araddr=32'h10000000;
  logic [7:0] cpu_awlen=3,vid_awlen=3,cpu_arlen=3,vid_arlen=3;
  logic [2:0] cpu_awsize=4,vid_awsize=4,cpu_arsize=4,vid_arsize=4;
  logic [1:0] cpu_awburst=1,vid_awburst=1,cpu_arburst=1,vid_arburst=1;
  logic cpu_awvalid=0,vid_awvalid=0,cpu_wlast=0,vid_wlast=0,cpu_wvalid=0,vid_wvalid=0,cpu_bready=1,vid_bready=1;
  logic cpu_arvalid=0,vid_arvalid=0,cpu_rready=1,vid_rready=1;
  logic [127:0] cpu_wdata=0,vid_wdata=0; logic [15:0] cpu_wstrb='1,vid_wstrb='1;
  logic [7:0] cpu_bid,vid_bid,cpu_rid,vid_rid; logic [1:0] cpu_bresp,vid_bresp,cpu_rresp,vid_rresp;
  logic [127:0] cpu_rdata,vid_rdata;
  logic cpu_awready,vid_awready,cpu_wready,vid_wready,cpu_bvalid,vid_bvalid,cpu_arready,vid_arready,cpu_rvalid,vid_rvalid,cpu_rlast,vid_rlast;
  logic [3:0] ddr_awid,ddr_bid,ddr_arid,ddr_rid;
  logic [31:0] ddr_awaddr,ddr_araddr; logic [7:0] ddr_awlen,ddr_arlen; logic [2:0] ddr_awsize,ddr_arsize;
  logic [1:0] ddr_awburst,ddr_arburst; logic [127:0] ddr_wdata,ddr_rdata; logic [15:0] ddr_wstrb;
  logic ddr_awvalid,ddr_awready,ddr_wlast,ddr_wvalid,ddr_wready,ddr_bvalid,ddr_bready,ddr_arvalid,ddr_arready,ddr_rvalid,ddr_rready,ddr_rlast;
  logic [1:0] ddr_bresp=0,ddr_rresp=0; logic [31:0] axi_error_count;

  axi_shared_ddr_2m #(.DUAL_READ(1'b1)) dut(.*);

  // ---- two-entry DDR read queue, responds LIFO (out of order) ----
  logic [3:0] q_id[0:1]; logic [31:0] q_addr[0:1]; logic [7:0] q_len[0:1];
  integer q_count=0, ar_count=0;
  logic responding=0; integer beat=0, latency=0;
  logic [3:0] cur_id; logic [31:0] cur_addr; logic [7:0] cur_len;
  integer cyc=0; always @(posedge clk) cyc<=cyc+1;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      ddr_arready<=0; ddr_rvalid<=0; ddr_rlast<=0; ddr_rid<=0; ddr_rdata<=0;
      responding<=0; q_count<=0; ar_count<=0; beat<=0; latency<=0;
    end else begin
      ddr_arready <= (q_count<2);
      if(ddr_arvalid&&ddr_arready) begin
        q_id[q_count]<=ddr_arid; q_addr[q_count]<=ddr_araddr; q_len[q_count]<=ddr_arlen;
        q_count<=q_count+1; ar_count<=ar_count+1;
      end
      if(!responding && q_count>0 && latency<8) latency<=latency+1;
      else if(!responding && q_count>0 && latency==8) begin
        responding<=1; beat<=0; latency<=0;
        cur_id<=q_id[q_count-1]; cur_addr<=q_addr[q_count-1]; cur_len<=q_len[q_count-1];
        ddr_rid<=q_id[q_count-1];
        ddr_rdata<={104'd0,q_id[q_count-1],8'd0};
        ddr_rvalid<=1; ddr_rlast<=(q_len[q_count-1]==0);
      end
      if(ddr_rvalid&&ddr_rready) begin
        if(ddr_rlast) begin
          ddr_rvalid<=0; ddr_rlast<=0; responding<=0;
          // remove the entry we responded with (LIFO: last)
          q_count<=q_count-1;
        end else begin
          beat<=beat+1;
          ddr_rdata<={104'd0,cur_id,beat[7:0]+8'd1};
          ddr_rlast<=(beat+1==cur_len);
        end
      end
    end
  end

  task automatic issue_read(input bit video); begin
    if(video) vid_arvalid=1; else cpu_arvalid=1;
    do @(posedge clk); while(!(video?vid_arready:cpu_arready));
    if(video) vid_arvalid=0; else cpu_arvalid=0;
  end endtask

  integer cpu_beats=0, vid_beats=0, cpu_last=0, vid_last=0;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin cpu_beats<=0;vid_beats<=0;cpu_last<=0;vid_last<=0; end
    else begin
      if(cpu_rvalid&&cpu_rready) begin cpu_beats<=cpu_beats+1; if(cpu_rlast)cpu_last<=1; end
      if(vid_rvalid&&vid_rready) begin vid_beats<=vid_beats+1; if(vid_rlast)vid_last<=1; end
    end
  end

  initial begin
    repeat(3) @(posedge clk); rst_n=1; allow_access=1;
    fork
      issue_read(0);
      issue_read(1);
    join
    // Both ARs must be accepted before any response arrives (DDR latency 8).
    repeat(3) @(posedge clk);
    if(ar_count!==2) $fatal(1,"both ARs were not outstanding: ar_count=%0d",ar_count);
    if(cpu_beats!=0 || vid_beats!=0) $fatal(1,"response arrived before both ARs were accepted");
    // Wait for both 4-beat bursts to complete.
    while(!(cpu_last&&vid_last)) @(posedge clk);
    repeat(3) @(posedge clk);
    if(cpu_beats!==4||vid_beats!==4) $fatal(1,"beat counts cpu=%0d vid=%0d",cpu_beats,vid_beats);
    if(cpu_rid!==8'hC3||vid_rid!==8'h3C) $fatal(1,"rid cpu=%h vid=%h",cpu_rid,vid_rid);
    if(axi_error_count!==0) $fatal(1,"AXI errors: %0d",axi_error_count);
    $display("PASS dual-read: 2 outstanding ARs, out-of-order responses routed by owner bit");
    $finish;
  end
endmodule
