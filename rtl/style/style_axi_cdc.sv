// Network at 148.5MHz, shared DDR at 100MHz. Each AXI channel owns one FIFO.
module style_axi_cdc(
  input wire reset_n,cnn_clk,axi_clk,
  input wire [31:0] c_araddr,c_awaddr,input wire [7:0] c_arlen,c_awlen,
  input wire c_arvalid,c_awvalid,output wire c_arready,c_awready,
  input wire [127:0] c_wdata,input wire [15:0] c_wstrb,input wire c_wlast,c_wvalid,output wire c_wready,
  output wire [127:0] c_rdata,output wire [1:0] c_rresp,c_bresp,output wire c_rlast,c_rvalid,c_bvalid,input wire c_rready,c_bready,
  output wire [31:0] araddr,awaddr,output wire [7:0] arlen,awlen,
  output wire arvalid,awvalid,input wire arready,awready,
  output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
  input wire [127:0] rdata,input wire [1:0] rresp,bresp,input wire rlast,rvalid,bvalid,output wire rready,bready
);
  style_async_fifo #(.WIDTH(40)) ar(.reset_n(reset_n),.wclk(cnn_clk),.rclk(axi_clk),
    .in_valid(c_arvalid),.in_ready(c_arready),.in_data({c_arlen,c_araddr}),.out_valid(arvalid),.out_ready(arready),.out_data({arlen,araddr}));
  style_async_fifo #(.WIDTH(40)) aw(.reset_n(reset_n),.wclk(cnn_clk),.rclk(axi_clk),
    .in_valid(c_awvalid),.in_ready(c_awready),.in_data({c_awlen,c_awaddr}),.out_valid(awvalid),.out_ready(awready),.out_data({awlen,awaddr}));
  style_async_fifo #(.WIDTH(145)) w(.reset_n(reset_n),.wclk(cnn_clk),.rclk(axi_clk),
    .in_valid(c_wvalid),.in_ready(c_wready),.in_data({c_wlast,c_wstrb,c_wdata}),.out_valid(wvalid),.out_ready(wready),.out_data({wlast,wstrb,wdata}));
  style_async_fifo #(.WIDTH(131)) r(.reset_n(reset_n),.wclk(axi_clk),.rclk(cnn_clk),
    .in_valid(rvalid),.in_ready(rready),.in_data({rlast,rresp,rdata}),.out_valid(c_rvalid),.out_ready(c_rready),.out_data({c_rlast,c_rresp,c_rdata}));
  style_async_fifo #(.WIDTH(2)) b(.reset_n(reset_n),.wclk(axi_clk),.rclk(cnn_clk),
    .in_valid(bvalid),.in_ready(bready),.in_data(bresp),.out_valid(c_bvalid),.out_ready(c_bready),.out_data(c_bresp));
endmodule
