// Preserve sparse frame events across independent clocks. Event spacing must
// exceed three destination cycles (video frames are many milliseconds apart).
module video_frame_event_cdc(
  input wire s_clk,s_rst_n,s_event,d_clk,d_rst_n,
  output wire d_event
);
  reg toggle;
  (* async_reg="true" *) reg sync1,sync2;
  reg seen;
  always @(posedge s_clk or negedge s_rst_n)
    if(!s_rst_n) toggle<=0;
    else if(s_event) toggle<=~toggle;
  always @(posedge d_clk or negedge d_rst_n)
    if(!d_rst_n) begin sync1<=0;sync2<=0;seen<=0;end
    else begin sync1<=toggle;sync2<=sync1;seen<=sync2;end
  assign d_event=sync2 ^ seen;
endmodule

// Observe the original CSI frame boundary, complete resized frames and CVO VS.
// All three events are generated in their source domains before CDC.
module video_frame_diagnostics(
  input wire raw_clk,resize_clk,display_clk,core_clk,rst_n,
  input wire raw_vs,display_vs,
  input wire [31:0] resize_completed_frames,
  output wire raw_event,resize_event,display_event
);
  reg raw_vs_d,display_vs_d;
  reg resize_parity_d;
  // Reset release is synchronized independently into every source domain.
  (* async_reg="true" *) reg [1:0] raw_reset,resize_reset,display_reset,core_reset;
  always @(posedge raw_clk or negedge rst_n)
    if(!rst_n) raw_reset<=0; else raw_reset<={raw_reset[0],1'b1};
  always @(posedge resize_clk or negedge rst_n)
    if(!rst_n) resize_reset<=0; else resize_reset<={resize_reset[0],1'b1};
  always @(posedge display_clk or negedge rst_n)
    if(!rst_n) display_reset<=0; else display_reset<={display_reset[0],1'b1};
  always @(posedge core_clk or negedge rst_n)
    if(!rst_n) core_reset<=0; else core_reset<={core_reset[0],1'b1};
  always @(posedge raw_clk or negedge rst_n)
    if(!rst_n) raw_vs_d<=0; else raw_vs_d<=raw_vs;
  always @(posedge resize_clk or negedge rst_n)
    if(!rst_n) resize_parity_d<=0; else resize_parity_d<=resize_completed_frames[0];
  always @(posedge display_clk or negedge rst_n)
    if(!rst_n) display_vs_d<=0; else display_vs_d<=display_vs;
  video_frame_event_cdc raw_cdc(.s_clk(raw_clk),.s_rst_n(raw_reset[1]),
    .s_event(raw_vs_d && !raw_vs),.d_clk(core_clk),.d_rst_n(core_reset[1]),.d_event(raw_event));
  video_frame_event_cdc resize_cdc(.s_clk(resize_clk),.s_rst_n(resize_reset[1]),
    .s_event(resize_completed_frames[0] ^ resize_parity_d),
    .d_clk(core_clk),.d_rst_n(core_reset[1]),.d_event(resize_event));
  video_frame_event_cdc display_cdc(.s_clk(display_clk),.s_rst_n(display_reset[1]),
    .s_event(display_vs && !display_vs_d),.d_clk(core_clk),.d_rst_n(core_reset[1]),.d_event(display_event));
endmodule
