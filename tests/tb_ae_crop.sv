// AE full-frame test: since 2026-10-30 the style path compresses the whole
// 1920x1080 frame (3x3 -> 640x360, letterboxed) instead of cropping, so AE
// must meter all 2,073,600 samples.  The centre is bright and the border dim,
// so a still-cropped meter would under-count.
`timescale 1ns/1ps
module tb_ae_crop;
  reg capture_clk=0, pclk=0;
  always #3.367 capture_clk=~capture_clk;
  always #5.0   pclk=~pclk;
  reg preset_n=0;
  reg psel=0,penable=0,pwrite=0; reg [15:0] paddr=0; reg [31:0] pwdata=0;
  wire [31:0] prdata; wire pready,pslverr;
  wire o_enable,o_char_we,o_char_page,o_commit_toggle,o_commit_page,o_video_ready;
  wire [11:0] o_x,o_y; wire [23:0] o_color; wire [6:0] o_char_addr; wire [7:0] o_char_data;
  wire [15:0] gain_r,gain_g,gain_b; wire [31:0] display_tone,display_lift; wire [2:0] display_hist;
  reg raw_vs=0,raw_de=0,rgb_vs=0,rgb_de=0,display_vs=0; reg [15:0] raw_data=0; reg [47:0] rgb_data=0;
  reg capture_fault=0,resize_fault=0,raw_event=0;
  reg [31:0] drop_count32=0,axi_errors32=0,underflows32=0,resize_frames32=0,display_frames32=0;
  reg display_stats_valid=0; reg [7:0] display_mean=0,display_strength=0; reg display_at_max=0;
  reg [6:0] csi_errors=0; reg [4:0] reset_status=5'h1f;
  video_apb_ctrl dut(
    .pclk(pclk),.preset_n(preset_n),.psel(psel),.penable(penable),.pwrite(pwrite),
    .paddr(paddr),.pwdata(pwdata),.prdata(prdata),.pready(pready),.pslverr(pslverr),
    .o_enable(o_enable),.o_x(o_x),.o_y(o_y),.o_color(o_color),.o_char_we(o_char_we),
    .o_char_addr(o_char_addr),.o_char_page(o_char_page),.o_char_data(o_char_data),
    .o_commit_toggle(o_commit_toggle),.o_commit_page(o_commit_page),.o_video_ready(o_video_ready),
    .i_ack_toggle(1'b0),.i_active_page(1'b0),.i_busy(1'b0),
    .i_frame_count(16'd0),.i_capture_fps(16'd0),.i_display_fps(16'd0),.i_drop_count(16'd0),
    .i_error_count(16'd0),.i_raw_fps(16'd0),
    .capture_clk(capture_clk),.display_clk(pclk),.raw_vs(raw_vs),.raw_de(raw_de),
    .rgb_vs(rgb_vs),.rgb_de(rgb_de),.display_vs(display_vs),
    .raw_data(raw_data),.rgb_data(rgb_data),
    .capture_fault(capture_fault),.resize_fault(resize_fault),.raw_event(raw_event),
    .drop_count32(drop_count32),.axi_errors32(axi_errors32),.underflows32(underflows32),
    .resize_frames32(resize_frames32),.display_frames32(display_frames32),
    .display_stats_valid(display_stats_valid),.display_mean(display_mean),
    .display_strength(display_strength),.display_at_max(display_at_max),
    .csi_errors(csi_errors),.reset_status(reset_status),
    .gain_r(gain_r),.gain_g(gain_g),.gain_b(gain_b),
    .display_tone(display_tone),.display_lift(display_lift),.display_hist(display_hist));
  task apb_read(input [15:0] a, output [31:0] d); begin
    @(posedge pclk); psel=1;penable=1;pwrite=0;paddr=a;pwdata=0;
    @(posedge pclk); d=prdata; psel=0;penable=0;
  end endtask
  integer f,row,pair; reg [31:0] seq,y_sum,samples,hot,flags,cfg,source,cap_seq;
  localparam [47:0] WHITE48={24'hC8C8C8,24'hC8C8C8}; // B=G=R=200 -> luma 200
  localparam [47:0] DIM48  ={24'h646464,24'h646464}; // luma 100
  initial begin
    repeat(5) @(posedge capture_clk); preset_n=1; repeat(5) @(posedge capture_clk);
    for(f=0;f<2;f=f+1) begin
      for(row=0;row<1080;row=row+1) begin
        for(pair=0;pair<960;pair=pair+1) begin
          @(negedge capture_clk);
          rgb_de=1;
          rgb_data=((pair>=160&&pair<800)&&(row>=60&&row<1020))?WHITE48:DIM48;
        end
        @(negedge capture_clk); rgb_de=0;
      end
      @(negedge capture_clk); rgb_vs=1;
      @(negedge capture_clk); rgb_vs=0; rgb_de=0;
      repeat(20) @(posedge capture_clk);
    end
    repeat(50) @(posedge pclk);
    apb_read(16'h0c0,seq); apb_read(16'h0c4,y_sum); apb_read(16'h0e4,samples);
    apb_read(16'h0e8,hot); apb_read(16'h0d0,flags); apb_read(16'h0dc,cfg);
    apb_read(16'h0ec,source); apb_read(16'h058,cap_seq);
    $display("seq=%0d y=%0d n=%0d hot=%0d fl=0x%0h cfg=%0d src=%0d capseq=%0d",
             seq,y_sum,samples,hot,flags,cfg,source,cap_seq);
    if(seq!==32'd2) $display("FAIL seq expect 2");
    if(samples!==32'd2073600) $display("FAIL samples expect 2073600");
    if(y_sum!==32'd330240000) $display("FAIL y_sum expect 330240000");
    if(hot!==32'd0) $display("FAIL hot expect 0");
    if(!(flags&1)) $display("FAIL flags bit0");
    if(cfg!==cap_seq) $display("FAIL cfg != capseq");
    if(source!==32'd1) $display("FAIL source");
    if(seq==32'd2&&samples==32'd2073600&&y_sum==32'd330240000&&(flags&1)&&cfg==cap_seq&&source==1)
      $display("PASS AE full-frame metering: 2,073,600 samples, centre+border both metered");
    $finish;
  end
endmodule
