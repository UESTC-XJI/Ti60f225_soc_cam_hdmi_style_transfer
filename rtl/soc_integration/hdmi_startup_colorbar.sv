// Stable 1280x720 RGB bars used until the CPU has initialized the camera.
// The timing matches the integrated CVO: 74.25 MHz, positive HS/VS.
module hdmi_startup_colorbar #(
  parameter integer HACT=1280, HFP=110, HSP=40, HBP=220,
  parameter integer VACT=720, VFP=5, VSP=5, VBP=20
)(
  input  wire clk,
  input  wire rst_n,
  output reg hs, output reg vs, output reg de,
  output reg [7:0] r, output reg [7:0] g, output reg [7:0] b
);
  localparam integer HTOTAL=HSP+HBP+HACT+HFP;
  localparam integer VTOTAL=VSP+VBP+VACT+VFP;
  reg [11:0] x;
  reg [10:0] y;
  wire active_x=(x>=HSP+HBP) && (x<HSP+HBP+HACT);
  wire active_y=(y>=VSP+VBP) && (y<VSP+VBP+VACT);
  wire [11:0] bar_x=x-(HSP+HBP);
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin x<=0; y<=0; hs<=0; vs<=0; de<=0; r<=0; g<=0; b<=0; end
    else begin
      hs<=(x<HSP); vs<=(y<VSP); de<=active_x && active_y;
      if(x==HTOTAL-1) begin x<=0; if(y==VTOTAL-1) y<=0; else y<=y+1'b1; end
      else x<=x+1'b1;
      if(active_x && active_y) begin
        if     (bar_x<HACT/8)   {r,g,b}<=24'hffffff;
        else if(bar_x<HACT*2/8) {r,g,b}<=24'hffff00;
        else if(bar_x<HACT*3/8) {r,g,b}<=24'h00ffff;
        else if(bar_x<HACT*4/8) {r,g,b}<=24'h00ff00;
        else if(bar_x<HACT*5/8) {r,g,b}<=24'hff00ff;
        else if(bar_x<HACT*6/8) {r,g,b}<=24'hff0000;
        else if(bar_x<HACT*7/8) {r,g,b}<=24'h0000ff;
        else                   {r,g,b}<=24'h000000;
      end else begin r<=0; g<=0; b<=0; end
    end
  end
endmodule

// Finish the outgoing bar frame, blank while waiting, and enter camera video
// at its next vertical sync. Independent sources may cause one display relock
// at handover; no camera active pixels are exposed before CPU readiness.
module hdmi_startup_select(
  input wire clk,rst_n,ready_async,
  input wire bar_vs,bar_hs,bar_de,
  input wire [7:0] bar_r,bar_g,bar_b,
  input wire cam_vs,cam_hs,cam_de,
  input wire [7:0] cam_r,cam_g,cam_b,
  output wire out_vs,out_hs,out_de,
  output wire [7:0] out_r,out_g,out_b
);
  localparam [1:0] BARS=0,WAIT_CAMERA=1,CAMERA=2,WAIT_BARS=3;
  (* async_reg="true" *) reg ready_meta,ready_sync;
  reg bar_vs_d,cam_vs_d,cam_seen;
  reg [1:0] state;
  wire bar_start=bar_vs && !bar_vs_d && !bar_de;
  wire cam_start=cam_vs && !cam_vs_d && !cam_de;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      ready_meta<=0; ready_sync<=0; bar_vs_d<=0; cam_vs_d<=0;
      cam_seen<=0; state<=BARS;
    end else begin
      ready_meta<=ready_async; ready_sync<=ready_meta;
      bar_vs_d<=bar_vs; cam_vs_d<=cam_vs;
      if(!ready_sync) cam_seen<=0;
      else if(cam_start) cam_seen<=1;
      case(state)
        BARS: if(ready_sync && cam_seen && bar_start) state<=WAIT_CAMERA;
        WAIT_CAMERA: if(!ready_sync) state<=WAIT_BARS;
                     else if(cam_start) state<=CAMERA;
        CAMERA: if(!ready_sync) state<=WAIT_BARS;
        WAIT_BARS: if(bar_start) state<=BARS;
        default: state<=BARS;
      endcase
    end
  end
  wire camera_selected=(state==CAMERA);
  wire bars_selected=(state==BARS);
  assign out_vs=camera_selected ? cam_vs : bar_vs;
  assign out_hs=camera_selected ? cam_hs : bar_hs;
  assign out_de=camera_selected ? cam_de : bars_selected && bar_de;
  assign out_r=camera_selected ? cam_r : bars_selected ? bar_r : 8'd0;
  assign out_g=camera_selected ? cam_g : bars_selected ? bar_g : 8'd0;
  assign out_b=camera_selected ? cam_b : bars_selected ? bar_b : 8'd0;
endmodule
