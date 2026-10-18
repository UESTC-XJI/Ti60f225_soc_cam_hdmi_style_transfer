// Bundled payload stays locked in core until a FRAME-APPLIED acknowledgement.
// rst_n is common to both domains. No-frame requests remain pending.
module video_cfg_cdc #(
  parameter integer WIDTH=32, parameter [WIDTH-1:0] DEFAULT_VALUE=0,
  parameter integer FALLING_EDGE=1
)(
  input wire clk,rst_n,vs,request,
  input wire [WIDTH-1:0] payload,
  output reg acknowledge,
  output reg [WIDTH-1:0] active,
  output reg [31:0] sequence_id,
  output wire [31:0] frame_sequence
);
  (* ASYNC_REG="TRUE" *) reg req_meta,req_sync;
  reg vs_d;
  wire boundary=FALLING_EDGE ? (vs_d && !vs) : (!vs_d && vs);
  wire apply_now=boundary && req_sync!=acknowledge;
  // Tag generated at the same source edge as the parameter update.
  assign frame_sequence=sequence_id+(apply_now ? 32'd1 : 32'd0);
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      req_meta<=0;req_sync<=0;vs_d<=0;acknowledge<=0;
      active<=DEFAULT_VALUE;sequence_id<=0;
    end else begin
      req_meta<=request;req_sync<=req_meta;vs_d<=vs;
      if(apply_now) begin
        active<=payload;sequence_id<=sequence_id+1'b1;acknowledge<=req_sync;
      end
    end
  end
endmodule
