`include "../defines.v"
// Bundled-data clock crossing. Source holds payload until destination ack.
// Both resets must be asserted together on a system reset.
module isp_cdc_mailbox #(parameter WIDTH=`CFG_ISP_ISP_CDC_MAILBOX_V_PARAMETER_WIDTH)(
  input s_clk, s_rst_n, s_valid,
  input [`CFG_ISP_ISP_CDC_MAILBOX_V_RANGE_1] s_data,
  output s_ready,
  input d_clk, d_rst_n,
  output reg d_valid,
  output reg [`CFG_ISP_ISP_CDC_MAILBOX_V_RANGE_2] d_data
);
  reg [`CFG_ISP_ISP_CDC_MAILBOX_V_RANGE_3] held;
  reg request, acknowledge;
  (* ASYNC_REG="TRUE" *) reg ack_meta, ack_sync;
  (* ASYNC_REG="TRUE" *) reg req_meta, req_sync;
  assign s_ready=(request==ack_sync);
  always @(posedge s_clk or negedge s_rst_n) begin
    if(!s_rst_n) begin held<=0; request<=0; ack_meta<=0; ack_sync<=0; end
    else begin
      ack_meta<=acknowledge; ack_sync<=ack_meta;
      if(s_valid && s_ready) begin held<=s_data; request<=~request; end
    end
  end
  always @(posedge d_clk or negedge d_rst_n) begin
    if(!d_rst_n) begin req_meta<=0; req_sync<=0; acknowledge<=0; d_valid<=0; d_data<=0; end
    else begin
      req_meta<=request; req_sync<=req_meta; d_valid<=0;
      if(req_sync!=acknowledge) begin
        d_data<=held; d_valid<=1; acknowledge<=req_sync;
      end
    end
  end
endmodule
