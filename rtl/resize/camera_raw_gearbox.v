`include "../defines.v"
// Four RAW8 samples/CSI beat -> two samples/processing beat.
// Queue an entire line before replay so the legacy Debayer sees contiguous DE.
module camera_raw_gearbox #(
  parameter SOURCE_WIDTH=`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_PARAMETER_SOURCE_WIDTH, SOURCE_HEIGHT=`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_PARAMETER_SOURCE_HEIGHT, FIFO_AW=`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_PARAMETER_FIFO_AW
)(
  input s_clk,s_rst_n,s_vs,s_valid,
  input [`CFG_BITS_32-1:0] s_data,
  input d_clk,d_rst_n,
  output reg d_vs,d_de,
  output reg [`CFG_BITS_16-1:0] d_data,
  output wire fault
);
  localparam GROUPS=`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_LOCALPARAM_GROUPS;
  reg vs_d,pending_sof,started;
  reg [`CFG_BITS_12-1:0] sx,sy;
  reg input_fault;
  wire fs=vs_d && !s_vs;
  wire first=pending_sof || fs;
  wire [`CFG_BITS_12-1:0] current_sx=fs ? 12'd0 : sx;
  wire [`CFG_BITS_12-1:0] current_sy=fs ? 12'd0 : sy;
  wire [`CFG_BITS_34-1:0] packet={first,current_sx==GROUPS-1,s_data};
  wire full;
  wire accept=s_valid && (started || fs) && !input_fault;
  always @(posedge s_clk or negedge s_rst_n) begin
    if(!s_rst_n) begin vs_d<=0;pending_sof<=0;started<=0;sx<=0;sy<=0;input_fault<=0;end
    else begin
      vs_d<=s_vs;
      if(fs) begin
        pending_sof<=1;started<=1;sx<=0;sy<=0;
        if(started && (sx!=0 || sy!=SOURCE_HEIGHT)) input_fault<=1;
      end
      if(accept) begin
        pending_sof<=0;
        if(full || current_sy>=SOURCE_HEIGHT) input_fault<=1;
        if(current_sx==GROUPS-1) begin sx<=0;sy<=current_sy+1'b1;end
        else sx<=current_sx+1'b1;
      end
    end
  end
  wire [`CFG_BITS_34-1:0] q;
  wire valid;
  wire [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_1] available;
  reg active,half;
  reg [`CFG_BITS_3-1:0] preamble;
  reg output_fault;
  wire take=active && preamble==0 && half && valid;
  resize_async_fifo #(.WIDTH(`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_INST_QUEUE_WIDTH),.AW(`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_INST_QUEUE_AW)) queue(
    .s_clk(s_clk),.s_rst_n(s_rst_n),.s_valid(accept),.s_data(packet),.s_full(full),
    .d_clk(d_clk),.d_rst_n(d_rst_n),.d_ready(take),.d_valid(valid),.d_data(q),.d_available(available)
  );
  (* async_reg="true" *) reg fault_meta,fault_sync;
  assign fault=fault_sync || output_fault;
  always @(posedge d_clk or negedge d_rst_n) begin
    if(!d_rst_n) begin
      active<=0;half<=0;preamble<=0;d_vs<=0;d_de<=0;d_data<=0;output_fault<=0;fault_meta<=0;fault_sync<=0;
    end else begin
      fault_meta<=input_fault;fault_sync<=fault_meta;
      d_vs<=0;d_de<=0;
      if(!active && valid && available>=GROUPS && !fault) begin
        active<=1;half<=0;d_vs<=q[33];
        preamble<=q[33] ? 6 : 0;
      end else if(active) begin
        if(preamble!=0) preamble<=preamble-1'b1;
        else if(!valid || fault) begin active<=0;output_fault<=1;end
        else begin
          d_de<=1;
          d_data<=half ? q[31:16] : q[15:0];
          half<=!half;
          if(half && q[32]) active<=0;
        end
      end
    end
  end
endmodule

// Gray pointers; synchronous BRAM read with a registered first-word buffer.
module resize_async_fifo #(parameter WIDTH=`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_PARAMETER_WIDTH,AW=`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_PARAMETER_AW)(
 input s_clk,s_rst_n,s_valid,
 input [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_2] s_data,
 output wire s_full,
 input d_clk,d_rst_n,d_ready,
 output reg d_valid,
 output reg [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_3] d_data,
 output wire [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_4] d_available
);
 (* syn_ramstyle="block_ram" *) reg [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_5] mem[`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_6];
 reg [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_7] wp,wg,rp,rg;
 (* async_reg="true" *) reg [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_8] rg_m,rg_s,wg_m,wg_s;
 function [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_9] ungray;
   input [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_10] g;integer k;
   begin ungray[AW]=g[AW];for(k=AW-1;k>=0;k=k-1) ungray[k]=ungray[k+1]^g[k];end
 endfunction
 wire [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_11] wn=wp+1'b1;
 wire [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_12] wn_gray=(wn>>1)^wn;
 assign s_full=wg=={~rg_s[AW:AW-1],rg_s[AW-2:0]};
 assign d_available=ungray(wg_s)-rp+d_valid;
 always @(posedge s_clk or negedge s_rst_n) begin
   if(!s_rst_n) begin wp<=0;wg<=0;rg_m<=0;rg_s<=0;end
   else begin
     rg_m<=rg;rg_s<=rg_m;
     if(s_valid && !s_full) begin wp<=wn;wg<=wn_gray;end
   end
 end
 always @(posedge s_clk) if(s_valid && !s_full) mem[wp[AW-1:0]]<=s_data;
 wire load=(!d_valid || d_ready) && rg!=wg_s;
 wire [`CFG_RESIZE_CAMERA_RAW_GEARBOX_V_RANGE_13] rn=rp+1'b1;
 always @(posedge d_clk) if(load) d_data<=mem[rp[AW-1:0]];
 always @(posedge d_clk or negedge d_rst_n) begin
   if(!d_rst_n) begin rp<=0;rg<=0;wg_m<=0;wg_s<=0;d_valid<=0;end
   else begin
     wg_m<=wg;wg_s<=wg_m;
     if(load) begin rp<=rn;rg<=(rn>>1)^rn;d_valid<=1;end
     else if(d_ready) d_valid<=0;
   end
 end
endmodule
