// Optional APB3 register bank for the future CPU integration.
// Status inputs must already be synchronized into pclk; control outputs go
// through a coherent mailbox to the pixel clock, as in the current top level.
module hdmi_info_overlay_apb(
  input pclk,preset_n,psel,penable,pwrite,
  input [11:0] paddr,
  input [31:0] pwdata,
  output reg [31:0] prdata,
  output pready,pslverr,
  output o_hist_enable,o_text_enable,
  output [1:0] o_hist_mode,
  input i_hist_valid,
  input [15:0] i_hist_samples
);
  reg [3:0] control;
  wire control_address=paddr==12'h000;
  wire valid_address=control_address || paddr==12'h004 || paddr==12'h008;
  assign pready=1'b1;
  assign pslverr=psel && penable && (!valid_address || (pwrite && !control_address));
  assign {o_text_enable,o_hist_mode,o_hist_enable}=control;
  always @(*) begin
    case(paddr)
      12'h000: prdata={28'd0,control};
      12'h004: prdata={31'd0,i_hist_valid};
      12'h008: prdata={16'd0,i_hist_samples};
      default: prdata=32'd0;
    endcase
  end
  always @(posedge pclk or negedge preset_n) begin
    if(!preset_n) control<=4'b0001;
    else if(psel && penable && pwrite && control_address) control<=pwdata[3:0];
  end
endmodule
