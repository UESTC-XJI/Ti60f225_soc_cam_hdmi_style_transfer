// All cumulative counters use the 100 MHz AXI clock and wrap modulo 2^32.
// Freeze permits coherent software reads; clear does not reset AXI tracking.
// Events overlap: they describe interfaces, not an additive time partition.
module style_ddr_profiler(
  input wire clk,rst_n,enable,freeze,clear,network_idle,
  input wire c_arvalid,c_arready,c_rvalid,c_rready,c_rlast,
  input wire c_awvalid,c_awready,c_wvalid,c_wready,c_wlast,c_bvalid,c_bready,
  input wire arvalid,arready,v_rvalid,v_rready,
  input wire [3:0] index,output wire [31:0] value
);
  reg read_active,write_response;
  reg [31:0] counters[0:11];
  wire [11:0] events={v_rvalid&&v_rready,c_rvalid&&c_rready,network_idle,
    write_response&&!c_bvalid,c_wvalid&&!c_wready,c_awvalid&&!c_awready,
    v_rvalid&&!v_rready,c_rvalid&&!c_rready,
    read_active&&c_rready&&!c_rvalid,arvalid&&!arready,
    c_arvalid&&!c_arready,1'b1};
  integer i;
  assign value=index<12 ? counters[index]:32'b0;
  always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin read_active<=0;write_response<=0;for(i=0;i<12;i=i+1)counters[i]<=0;end
    else begin
      if(c_arvalid&&c_arready)read_active<=1;
      if(c_rvalid&&c_rready&&c_rlast)read_active<=0;
      if(c_wvalid&&c_wready&&c_wlast)write_response<=1;
      if(c_bvalid&&c_bready)write_response<=0;
      for(i=0;i<12;i=i+1)begin
        if(clear)counters[i]<=0;
        else if(enable&&!freeze&&events[i])counters[i]<=counters[i]+1'b1;
      end
    end
  end
endmodule
