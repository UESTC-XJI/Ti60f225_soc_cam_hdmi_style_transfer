// Actual generated Sapphire SoC wrapper used by the simulation/integration top.
module soc_video_ddr_integration (
  input wire clk, rst_n, allow_access,
  input wire [7:0] vid_awid, input wire [31:0] vid_awaddr, input wire [7:0] vid_awlen, input wire [2:0] vid_awsize, input wire [1:0] vid_awburst, input wire vid_awvalid, output wire vid_awready,
  input wire [127:0] vid_wdata, input wire [15:0] vid_wstrb, input wire vid_wlast, input wire vid_wvalid, output wire vid_wready, output wire [7:0] vid_bid, output wire [1:0] vid_bresp, output wire vid_bvalid, input wire vid_bready,
  input wire [7:0] vid_arid, input wire [31:0] vid_araddr, input wire [7:0] vid_arlen, input wire [2:0] vid_arsize, input wire [1:0] vid_arburst, input wire vid_arvalid, output wire vid_arready, output wire [7:0] vid_rid, output wire [127:0] vid_rdata, output wire [1:0] vid_rresp, output wire vid_rlast, output wire vid_rvalid, input wire vid_rready,
  output wire [3:0] ddr_awid, output wire [31:0] ddr_awaddr, output wire [7:0] ddr_awlen, output wire [2:0] ddr_awsize, output wire [1:0] ddr_awburst, output wire ddr_awvalid, input wire ddr_awready, output wire [127:0] ddr_wdata, output wire [15:0] ddr_wstrb, output wire ddr_wlast, output wire ddr_wvalid, input wire ddr_wready, input wire [3:0] ddr_bid, input wire [1:0] ddr_bresp, input wire ddr_bvalid, output wire ddr_bready, output wire [3:0] ddr_arid, output wire [31:0] ddr_araddr, output wire [7:0] ddr_arlen, output wire [2:0] ddr_arsize, output wire [1:0] ddr_arburst, output wire ddr_arvalid, input wire ddr_arready, input wire [3:0] ddr_rid, input wire [127:0] ddr_rdata, input wire [1:0] ddr_rresp, input wire ddr_rlast, input wire ddr_rvalid, output wire ddr_rready,
  output wire [15:0] apb_paddr, output wire apb_psel, output wire apb_penable, input wire apb_pready, output wire apb_pwrite, output wire [31:0] apb_pwdata, input wire [31:0] apb_prdata, input wire apb_pslverr,
  input wire jtag_tck,jtag_tdi,jtag_capture,jtag_shift,jtag_update,jtag_reset,jtag_enable, output wire jtag_tdo,
  output wire uart_txd, input wire uart_rxd, input wire i2c_scl_in, output wire i2c_scl_out, input wire i2c_sda_in, output wire i2c_sda_out,
  output wire soc_system_reset,soc_memory_reset, output wire [31:0] axi_error_count
);
  wire  io_systemClk;
  wire [15:0] io_ddrA_w_payload_strb;
  wire [127:0] io_ddrA_w_payload_data;
  wire  axiA_awready;
  wire [7:0] axiA_awlen;
  wire [2:0] axiA_awsize;
  wire [1:0] axiA_arburst;
  wire  axiA_awlock;
  wire [3:0] axiA_arcache;
  wire [3:0] axiA_awqos;
  wire [2:0] axiA_awprot;
  wire [2:0] axiA_arsize;
  wire [3:0] axiA_arregion;
  wire  axiA_arready;
  wire [3:0] axiA_arqos;
  wire [2:0] axiA_arprot;
  wire  axiA_arlock;
  wire [7:0] axiA_arlen;
  wire [7:0] axiA_arid;
  wire [3:0] axiA_awcache;
  wire [1:0] axiA_awburst;
  wire [31:0] axiA_awaddr;
  wire  axiAInterrupt;
  wire  axiA_rlast;
  wire  jtagCtrl_enable;
  wire  jtagCtrl_tdi;
  wire  jtagCtrl_capture;
  wire  jtagCtrl_shift;
  wire  jtagCtrl_update;
  wire  jtagCtrl_reset;
  wire  jtagCtrl_tdo;
  wire  jtagCtrl_tck;
  wire [31:0] axiA_araddr;
  wire  axiA_wvalid;
  wire  axiA_wready;
  wire [31:0] axiA_wdata;
  wire [3:0] axiA_wstrb;
  wire  axiA_wlast;
  wire  axiA_bvalid;
  wire  axiA_bready;
  wire [7:0] axiA_bid;
  wire [1:0] axiA_bresp;
  wire  axiA_rvalid;
  wire  axiA_rready;
  wire [31:0] axiA_rdata;
  wire [7:0] axiA_rid;
  wire [1:0] axiA_rresp;
  wire  axiA_arvalid;
  wire [7:0] axiA_awid;
  wire [3:0] axiA_awregion;
  wire  axiA_awvalid;
  wire  io_ddrA_r_payload_last;
  wire [1:0] io_ddrA_r_payload_resp;
  wire [7:0] io_ddrA_r_payload_id;
  wire [127:0] io_ddrA_r_payload_data;
  wire  io_ddrA_r_ready;
  wire  io_ddrA_r_valid;
  wire [1:0] io_ddrA_b_payload_resp;
  wire [7:0] io_ddrA_b_payload_id;
  wire  io_ddrA_b_ready;
  wire  io_ddrA_b_valid;
  wire  io_ddrA_w_payload_last;
  wire  io_ddrA_w_ready;
  wire  io_ddrA_w_valid;
  wire [2:0] io_ddrA_aw_payload_prot;
  wire [3:0] io_ddrA_aw_payload_qos;
  wire [3:0] io_ddrA_aw_payload_cache;
  wire  io_ddrA_aw_payload_lock;
  wire [1:0] io_ddrA_aw_payload_burst;
  wire [2:0] io_ddrA_aw_payload_size;
  wire [7:0] io_ddrA_aw_payload_len;
  wire [3:0] io_ddrA_aw_payload_region;
  wire [7:0] io_ddrA_aw_payload_id;
  wire [31:0] io_ddrA_aw_payload_addr;
  wire  io_ddrA_aw_ready;
  wire  io_ddrA_aw_valid;
  wire [2:0] io_ddrA_ar_payload_prot;
  wire [3:0] io_ddrA_ar_payload_qos;
  wire [3:0] io_ddrA_ar_payload_cache;
  wire  io_ddrA_ar_payload_lock;
  wire [1:0] io_ddrA_ar_payload_burst;
  wire [2:0] io_ddrA_ar_payload_size;
  wire [7:0] io_ddrA_ar_payload_len;
  wire [3:0] io_ddrA_ar_payload_region;
  wire [7:0] io_ddrA_ar_payload_id;
  wire [31:0] io_ddrA_ar_payload_addr;
  wire  io_ddrA_ar_ready;
  wire  io_ddrA_ar_valid;
  wire  system_spi_0_io_data_0_read;
  wire  system_spi_0_io_data_0_write;
  wire  system_spi_0_io_data_0_writeEnable;
  wire  system_spi_0_io_data_1_read;
  wire  system_spi_0_io_data_1_write;
  wire  system_spi_0_io_data_1_writeEnable;
  wire  system_spi_0_io_data_2_read;
  wire  system_spi_0_io_data_2_write;
  wire  system_spi_0_io_data_2_writeEnable;
  wire  system_spi_0_io_data_3_read;
  wire  system_spi_0_io_data_3_write;
  wire  system_spi_0_io_data_3_writeEnable;
  wire  system_spi_0_io_sclk_write;
  wire  userInterruptA;
  wire [15:0] io_apbSlave_0_PADDR;
  wire  io_apbSlave_0_PENABLE;
  wire [31:0] io_apbSlave_0_PRDATA;
  wire  io_apbSlave_0_PREADY;
  wire  io_apbSlave_0_PSEL;
  wire  io_apbSlave_0_PSLVERROR;
  wire [31:0] io_apbSlave_0_PWDATA;
  wire  io_apbSlave_0_PWRITE;
  wire  io_asyncReset;
  wire  io_memoryClk;
  wire  io_systemReset;
  wire  system_uart_0_io_txd;
  wire  io_memoryReset;
  wire  system_uart_0_io_rxd;
  wire  system_i2c_0_io_scl_read;
  wire  system_i2c_0_io_scl_write;
  wire  system_i2c_0_io_sda_read;
  wire  system_i2c_0_io_sda_write;
  wire [3:0] system_gpio_0_io_writeEnable;
  wire  io_ddrMasters_0_reset;
  wire  io_ddrMasters_0_clk;
  wire  io_ddrMasters_0_r_payload_last;
  wire [1:0] io_ddrMasters_0_r_payload_resp;
  wire [3:0] io_ddrMasters_0_r_payload_id;
  wire [31:0] io_ddrMasters_0_r_payload_data;
  wire  io_ddrMasters_0_r_ready;
  wire  io_ddrMasters_0_r_valid;
  wire [2:0] io_ddrMasters_0_ar_payload_prot;
  wire [3:0] io_ddrMasters_0_ar_payload_qos;
  wire [3:0] io_ddrMasters_0_ar_payload_cache;
  wire  io_ddrMasters_0_ar_payload_lock;
  wire [1:0] io_ddrMasters_0_ar_payload_burst;
  wire [2:0] io_ddrMasters_0_ar_payload_size;
  wire [7:0] io_ddrMasters_0_ar_payload_len;
  wire [3:0] io_ddrMasters_0_ar_payload_region;
  wire [3:0] io_ddrMasters_0_ar_payload_id;
  wire [31:0] io_ddrMasters_0_ar_payload_addr;
  wire  io_ddrMasters_0_ar_ready;
  wire  io_ddrMasters_0_ar_valid;
  wire [1:0] io_ddrMasters_0_b_payload_resp;
  wire [3:0] io_ddrMasters_0_b_payload_id;
  wire  io_ddrMasters_0_b_ready;
  wire  io_ddrMasters_0_b_valid;
  wire  io_ddrMasters_0_w_payload_last;
  wire [3:0] io_ddrMasters_0_w_payload_strb;
  wire [31:0] io_ddrMasters_0_w_payload_data;
  wire  io_ddrMasters_0_w_ready;
  wire  io_ddrMasters_0_w_valid;
  wire [2:0] io_ddrMasters_0_aw_payload_prot;
  wire [3:0] io_ddrMasters_0_aw_payload_qos;
  wire [3:0] io_ddrMasters_0_aw_payload_cache;
  wire  io_ddrMasters_0_aw_payload_lock;
  wire [1:0] io_ddrMasters_0_aw_payload_burst;
  wire [2:0] io_ddrMasters_0_aw_payload_size;
  wire [7:0] io_ddrMasters_0_aw_payload_len;
  wire [3:0] io_ddrMasters_0_aw_payload_region;
  wire [3:0] io_ddrMasters_0_aw_payload_id;
  wire [31:0] io_ddrMasters_0_aw_payload_addr;
  wire  io_ddrMasters_0_aw_ready;
  wire  io_ddrMasters_0_aw_valid;
  wire [3:0] system_gpio_0_io_write;
  wire [3:0] system_gpio_0_io_read;
  wire [0:0] system_spi_0_io_ss;

  // Full CPU AXI4 (ID8/128-bit) is adapted to the frame-buffer master and
  // one DDR3 controller (ID4/128-bit). The bridge owns B/R responses.
  axi_shared_ddr_2m bridge(
    .clk(clk), .rst_n(rst_n), .allow_access(allow_access),
    .cpu_awid(io_ddrA_aw_payload_id), .cpu_awaddr(io_ddrA_aw_payload_addr), .cpu_awlen(io_ddrA_aw_payload_len), .cpu_awsize(io_ddrA_aw_payload_size), .cpu_awburst(io_ddrA_aw_payload_burst), .cpu_awvalid(io_ddrA_aw_valid), .cpu_awready(io_ddrA_aw_ready),
    .cpu_wdata(io_ddrA_w_payload_data), .cpu_wstrb(io_ddrA_w_payload_strb), .cpu_wlast(io_ddrA_w_payload_last), .cpu_wvalid(io_ddrA_w_valid), .cpu_wready(io_ddrA_w_ready), .cpu_bid(io_ddrA_b_payload_id), .cpu_bresp(io_ddrA_b_payload_resp), .cpu_bvalid(io_ddrA_b_valid), .cpu_bready(io_ddrA_b_ready),
    .cpu_arid(io_ddrA_ar_payload_id), .cpu_araddr(io_ddrA_ar_payload_addr), .cpu_arlen(io_ddrA_ar_payload_len), .cpu_arsize(io_ddrA_ar_payload_size), .cpu_arburst(io_ddrA_ar_payload_burst), .cpu_arvalid(io_ddrA_ar_valid), .cpu_arready(io_ddrA_ar_ready), .cpu_rid(io_ddrA_r_payload_id), .cpu_rdata(io_ddrA_r_payload_data), .cpu_rresp(io_ddrA_r_payload_resp), .cpu_rlast(io_ddrA_r_payload_last), .cpu_rvalid(io_ddrA_r_valid), .cpu_rready(io_ddrA_r_ready),
    .vid_awid(vid_awid),.vid_awaddr(vid_awaddr),.vid_awlen(vid_awlen),.vid_awsize(vid_awsize),.vid_awburst(vid_awburst),.vid_awvalid(vid_awvalid),.vid_awready(vid_awready),.vid_wdata(vid_wdata),.vid_wstrb(vid_wstrb),.vid_wlast(vid_wlast),.vid_wvalid(vid_wvalid),.vid_wready(vid_wready),.vid_bid(vid_bid),.vid_bresp(vid_bresp),.vid_bvalid(vid_bvalid),.vid_bready(vid_bready),
    .vid_arid(vid_arid),.vid_araddr(vid_araddr),.vid_arlen(vid_arlen),.vid_arsize(vid_arsize),.vid_arburst(vid_arburst),.vid_arvalid(vid_arvalid),.vid_arready(vid_arready),.vid_rid(vid_rid),.vid_rdata(vid_rdata),.vid_rresp(vid_rresp),.vid_rlast(vid_rlast),.vid_rvalid(vid_rvalid),.vid_rready(vid_rready),
    .ddr_awid(ddr_awid),.ddr_awaddr(ddr_awaddr),.ddr_awlen(ddr_awlen),.ddr_awsize(ddr_awsize),.ddr_awburst(ddr_awburst),.ddr_awvalid(ddr_awvalid),.ddr_awready(ddr_awready),.ddr_wdata(ddr_wdata),.ddr_wstrb(ddr_wstrb),.ddr_wlast(ddr_wlast),.ddr_wvalid(ddr_wvalid),.ddr_wready(ddr_wready),.ddr_bid(ddr_bid),.ddr_bresp(ddr_bresp),.ddr_bvalid(ddr_bvalid),.ddr_bready(ddr_bready),.ddr_arid(ddr_arid),.ddr_araddr(ddr_araddr),.ddr_arlen(ddr_arlen),.ddr_arsize(ddr_arsize),.ddr_arburst(ddr_arburst),.ddr_arvalid(ddr_arvalid),.ddr_arready(ddr_arready),.ddr_rid(ddr_rid),.ddr_rdata(ddr_rdata),.ddr_rresp(ddr_rresp),.ddr_rlast(ddr_rlast),.ddr_rvalid(ddr_rvalid),.ddr_rready(ddr_rready),.axi_error_count(axi_error_count));


  assign io_systemClk=clk; assign io_asyncReset=!rst_n; assign io_memoryClk=clk;
  assign jtagCtrl_tck=jtag_tck; assign jtagCtrl_tdi=jtag_tdi; assign jtagCtrl_capture=jtag_capture; assign jtagCtrl_shift=jtag_shift; assign jtagCtrl_update=jtag_update; assign jtagCtrl_reset=jtag_reset; assign jtagCtrl_enable=jtag_enable; assign jtag_tdo=jtagCtrl_tdo;
  assign system_uart_0_io_rxd=uart_rxd; assign uart_txd=system_uart_0_io_txd;
  assign system_i2c_0_io_scl_read=i2c_scl_in; assign system_i2c_0_io_sda_read=i2c_sda_in; assign i2c_scl_out=system_i2c_0_io_scl_write; assign i2c_sda_out=system_i2c_0_io_sda_write;
  assign apb_paddr=io_apbSlave_0_PADDR; assign apb_psel=io_apbSlave_0_PSEL; assign apb_penable=io_apbSlave_0_PENABLE; assign apb_pwrite=io_apbSlave_0_PWRITE; assign apb_pwdata=io_apbSlave_0_PWDATA; assign io_apbSlave_0_PREADY=apb_pready; assign io_apbSlave_0_PRDATA=apb_prdata; assign io_apbSlave_0_PSLVERROR=apb_pslverr;
  assign soc_system_reset=io_systemReset; assign soc_memory_reset=io_memoryReset;

  assign axiA_awready = '0;
  assign axiA_arready = '0;
  assign axiAInterrupt = '0;
  assign axiA_rlast = '0;
  assign axiA_wready = '0;
  assign axiA_bvalid = '0;
  assign axiA_bid = '0;
  assign axiA_bresp = '0;
  assign axiA_rvalid = '0;
  assign axiA_rdata = '0;
  assign axiA_rid = '0;
  assign axiA_rresp = '0;
  assign system_spi_0_io_data_0_read = '0;
  assign system_spi_0_io_data_1_read = '0;
  assign system_spi_0_io_data_2_read = '0;
  assign system_spi_0_io_data_3_read = '0;
  assign userInterruptA = '0;
  assign io_ddrMasters_0_clk = '0;
  assign io_ddrMasters_0_r_ready = '0;
  assign io_ddrMasters_0_ar_payload_prot = '0;
  assign io_ddrMasters_0_ar_payload_qos = '0;
  assign io_ddrMasters_0_ar_payload_cache = '0;
  assign io_ddrMasters_0_ar_payload_lock = '0;
  assign io_ddrMasters_0_ar_payload_burst = '0;
  assign io_ddrMasters_0_ar_payload_size = '0;
  assign io_ddrMasters_0_ar_payload_len = '0;
  assign io_ddrMasters_0_ar_payload_region = '0;
  assign io_ddrMasters_0_ar_payload_id = '0;
  assign io_ddrMasters_0_ar_payload_addr = '0;
  assign io_ddrMasters_0_ar_valid = '0;
  assign io_ddrMasters_0_b_ready = '0;
  assign io_ddrMasters_0_w_payload_last = '0;
  assign io_ddrMasters_0_w_payload_strb = '0;
  assign io_ddrMasters_0_w_payload_data = '0;
  assign io_ddrMasters_0_w_valid = '0;
  assign io_ddrMasters_0_aw_payload_prot = '0;
  assign io_ddrMasters_0_aw_payload_qos = '0;
  assign io_ddrMasters_0_aw_payload_cache = '0;
  assign io_ddrMasters_0_aw_payload_lock = '0;
  assign io_ddrMasters_0_aw_payload_burst = '0;
  assign io_ddrMasters_0_aw_payload_size = '0;
  assign io_ddrMasters_0_aw_payload_len = '0;
  assign io_ddrMasters_0_aw_payload_region = '0;
  assign io_ddrMasters_0_aw_payload_id = '0;
  assign io_ddrMasters_0_aw_payload_addr = '0;
  assign io_ddrMasters_0_aw_valid = '0;
  assign system_gpio_0_io_read = '0;
  // The generated IP exposes an auxiliary 32-bit AXI master and a second
  // DDR master port. They are intentionally tied off; only io_ddrA is CPU DDR.
  soc u_soc (
    .io_systemClk(io_systemClk),
    .io_ddrA_w_payload_strb(io_ddrA_w_payload_strb),
    .io_ddrA_w_payload_data(io_ddrA_w_payload_data),
    .axiA_awready(axiA_awready),
    .axiA_awlen(axiA_awlen),
    .axiA_awsize(axiA_awsize),
    .axiA_arburst(axiA_arburst),
    .axiA_awlock(axiA_awlock),
    .axiA_arcache(axiA_arcache),
    .axiA_awqos(axiA_awqos),
    .axiA_awprot(axiA_awprot),
    .axiA_arsize(axiA_arsize),
    .axiA_arregion(axiA_arregion),
    .axiA_arready(axiA_arready),
    .axiA_arqos(axiA_arqos),
    .axiA_arprot(axiA_arprot),
    .axiA_arlock(axiA_arlock),
    .axiA_arlen(axiA_arlen),
    .axiA_arid(axiA_arid),
    .axiA_awcache(axiA_awcache),
    .axiA_awburst(axiA_awburst),
    .axiA_awaddr(axiA_awaddr),
    .axiAInterrupt(axiAInterrupt),
    .axiA_rlast(axiA_rlast),
    .jtagCtrl_enable(jtagCtrl_enable),
    .jtagCtrl_tdi(jtagCtrl_tdi),
    .jtagCtrl_capture(jtagCtrl_capture),
    .jtagCtrl_shift(jtagCtrl_shift),
    .jtagCtrl_update(jtagCtrl_update),
    .jtagCtrl_reset(jtagCtrl_reset),
    .jtagCtrl_tdo(jtagCtrl_tdo),
    .jtagCtrl_tck(jtagCtrl_tck),
    .axiA_araddr(axiA_araddr),
    .axiA_wvalid(axiA_wvalid),
    .axiA_wready(axiA_wready),
    .axiA_wdata(axiA_wdata),
    .axiA_wstrb(axiA_wstrb),
    .axiA_wlast(axiA_wlast),
    .axiA_bvalid(axiA_bvalid),
    .axiA_bready(axiA_bready),
    .axiA_bid(axiA_bid),
    .axiA_bresp(axiA_bresp),
    .axiA_rvalid(axiA_rvalid),
    .axiA_rready(axiA_rready),
    .axiA_rdata(axiA_rdata),
    .axiA_rid(axiA_rid),
    .axiA_rresp(axiA_rresp),
    .axiA_arvalid(axiA_arvalid),
    .axiA_awid(axiA_awid),
    .axiA_awregion(axiA_awregion),
    .axiA_awvalid(axiA_awvalid),
    .io_ddrA_r_payload_last(io_ddrA_r_payload_last),
    .io_ddrA_r_payload_resp(io_ddrA_r_payload_resp),
    .io_ddrA_r_payload_id(io_ddrA_r_payload_id),
    .io_ddrA_r_payload_data(io_ddrA_r_payload_data),
    .io_ddrA_r_ready(io_ddrA_r_ready),
    .io_ddrA_r_valid(io_ddrA_r_valid),
    .io_ddrA_b_payload_resp(io_ddrA_b_payload_resp),
    .io_ddrA_b_payload_id(io_ddrA_b_payload_id),
    .io_ddrA_b_ready(io_ddrA_b_ready),
    .io_ddrA_b_valid(io_ddrA_b_valid),
    .io_ddrA_w_payload_last(io_ddrA_w_payload_last),
    .io_ddrA_w_ready(io_ddrA_w_ready),
    .io_ddrA_w_valid(io_ddrA_w_valid),
    .io_ddrA_aw_payload_prot(io_ddrA_aw_payload_prot),
    .io_ddrA_aw_payload_qos(io_ddrA_aw_payload_qos),
    .io_ddrA_aw_payload_cache(io_ddrA_aw_payload_cache),
    .io_ddrA_aw_payload_lock(io_ddrA_aw_payload_lock),
    .io_ddrA_aw_payload_burst(io_ddrA_aw_payload_burst),
    .io_ddrA_aw_payload_size(io_ddrA_aw_payload_size),
    .io_ddrA_aw_payload_len(io_ddrA_aw_payload_len),
    .io_ddrA_aw_payload_region(io_ddrA_aw_payload_region),
    .io_ddrA_aw_payload_id(io_ddrA_aw_payload_id),
    .io_ddrA_aw_payload_addr(io_ddrA_aw_payload_addr),
    .io_ddrA_aw_ready(io_ddrA_aw_ready),
    .io_ddrA_aw_valid(io_ddrA_aw_valid),
    .io_ddrA_ar_payload_prot(io_ddrA_ar_payload_prot),
    .io_ddrA_ar_payload_qos(io_ddrA_ar_payload_qos),
    .io_ddrA_ar_payload_cache(io_ddrA_ar_payload_cache),
    .io_ddrA_ar_payload_lock(io_ddrA_ar_payload_lock),
    .io_ddrA_ar_payload_burst(io_ddrA_ar_payload_burst),
    .io_ddrA_ar_payload_size(io_ddrA_ar_payload_size),
    .io_ddrA_ar_payload_len(io_ddrA_ar_payload_len),
    .io_ddrA_ar_payload_region(io_ddrA_ar_payload_region),
    .io_ddrA_ar_payload_id(io_ddrA_ar_payload_id),
    .io_ddrA_ar_payload_addr(io_ddrA_ar_payload_addr),
    .io_ddrA_ar_ready(io_ddrA_ar_ready),
    .io_ddrA_ar_valid(io_ddrA_ar_valid),
    .system_spi_0_io_data_0_read(system_spi_0_io_data_0_read),
    .system_spi_0_io_data_0_write(system_spi_0_io_data_0_write),
    .system_spi_0_io_data_0_writeEnable(system_spi_0_io_data_0_writeEnable),
    .system_spi_0_io_data_1_read(system_spi_0_io_data_1_read),
    .system_spi_0_io_data_1_write(system_spi_0_io_data_1_write),
    .system_spi_0_io_data_1_writeEnable(system_spi_0_io_data_1_writeEnable),
    .system_spi_0_io_data_2_read(system_spi_0_io_data_2_read),
    .system_spi_0_io_data_2_write(system_spi_0_io_data_2_write),
    .system_spi_0_io_data_2_writeEnable(system_spi_0_io_data_2_writeEnable),
    .system_spi_0_io_data_3_read(system_spi_0_io_data_3_read),
    .system_spi_0_io_data_3_write(system_spi_0_io_data_3_write),
    .system_spi_0_io_data_3_writeEnable(system_spi_0_io_data_3_writeEnable),
    .system_spi_0_io_sclk_write(system_spi_0_io_sclk_write),
    .userInterruptA(userInterruptA),
    .io_apbSlave_0_PADDR(io_apbSlave_0_PADDR),
    .io_apbSlave_0_PENABLE(io_apbSlave_0_PENABLE),
    .io_apbSlave_0_PRDATA(io_apbSlave_0_PRDATA),
    .io_apbSlave_0_PREADY(io_apbSlave_0_PREADY),
    .io_apbSlave_0_PSEL(io_apbSlave_0_PSEL),
    .io_apbSlave_0_PSLVERROR(io_apbSlave_0_PSLVERROR),
    .io_apbSlave_0_PWDATA(io_apbSlave_0_PWDATA),
    .io_apbSlave_0_PWRITE(io_apbSlave_0_PWRITE),
    .io_asyncReset(io_asyncReset),
    .io_memoryClk(io_memoryClk),
    .io_systemReset(io_systemReset),
    .system_uart_0_io_txd(system_uart_0_io_txd),
    .io_memoryReset(io_memoryReset),
    .system_uart_0_io_rxd(system_uart_0_io_rxd),
    .system_i2c_0_io_scl_read(system_i2c_0_io_scl_read),
    .system_i2c_0_io_scl_write(system_i2c_0_io_scl_write),
    .system_i2c_0_io_sda_read(system_i2c_0_io_sda_read),
    .system_i2c_0_io_sda_write(system_i2c_0_io_sda_write),
    .system_gpio_0_io_writeEnable(system_gpio_0_io_writeEnable),
    .io_ddrMasters_0_reset(io_ddrMasters_0_reset),
    .io_ddrMasters_0_clk(io_ddrMasters_0_clk),
    .io_ddrMasters_0_r_payload_last(io_ddrMasters_0_r_payload_last),
    .io_ddrMasters_0_r_payload_resp(io_ddrMasters_0_r_payload_resp),
    .io_ddrMasters_0_r_payload_id(io_ddrMasters_0_r_payload_id),
    .io_ddrMasters_0_r_payload_data(io_ddrMasters_0_r_payload_data),
    .io_ddrMasters_0_r_ready(io_ddrMasters_0_r_ready),
    .io_ddrMasters_0_r_valid(io_ddrMasters_0_r_valid),
    .io_ddrMasters_0_ar_payload_prot(io_ddrMasters_0_ar_payload_prot),
    .io_ddrMasters_0_ar_payload_qos(io_ddrMasters_0_ar_payload_qos),
    .io_ddrMasters_0_ar_payload_cache(io_ddrMasters_0_ar_payload_cache),
    .io_ddrMasters_0_ar_payload_lock(io_ddrMasters_0_ar_payload_lock),
    .io_ddrMasters_0_ar_payload_burst(io_ddrMasters_0_ar_payload_burst),
    .io_ddrMasters_0_ar_payload_size(io_ddrMasters_0_ar_payload_size),
    .io_ddrMasters_0_ar_payload_len(io_ddrMasters_0_ar_payload_len),
    .io_ddrMasters_0_ar_payload_region(io_ddrMasters_0_ar_payload_region),
    .io_ddrMasters_0_ar_payload_id(io_ddrMasters_0_ar_payload_id),
    .io_ddrMasters_0_ar_payload_addr(io_ddrMasters_0_ar_payload_addr),
    .io_ddrMasters_0_ar_ready(io_ddrMasters_0_ar_ready),
    .io_ddrMasters_0_ar_valid(io_ddrMasters_0_ar_valid),
    .io_ddrMasters_0_b_payload_resp(io_ddrMasters_0_b_payload_resp),
    .io_ddrMasters_0_b_payload_id(io_ddrMasters_0_b_payload_id),
    .io_ddrMasters_0_b_ready(io_ddrMasters_0_b_ready),
    .io_ddrMasters_0_b_valid(io_ddrMasters_0_b_valid),
    .io_ddrMasters_0_w_payload_last(io_ddrMasters_0_w_payload_last),
    .io_ddrMasters_0_w_payload_strb(io_ddrMasters_0_w_payload_strb),
    .io_ddrMasters_0_w_payload_data(io_ddrMasters_0_w_payload_data),
    .io_ddrMasters_0_w_ready(io_ddrMasters_0_w_ready),
    .io_ddrMasters_0_w_valid(io_ddrMasters_0_w_valid),
    .io_ddrMasters_0_aw_payload_prot(io_ddrMasters_0_aw_payload_prot),
    .io_ddrMasters_0_aw_payload_qos(io_ddrMasters_0_aw_payload_qos),
    .io_ddrMasters_0_aw_payload_cache(io_ddrMasters_0_aw_payload_cache),
    .io_ddrMasters_0_aw_payload_lock(io_ddrMasters_0_aw_payload_lock),
    .io_ddrMasters_0_aw_payload_burst(io_ddrMasters_0_aw_payload_burst),
    .io_ddrMasters_0_aw_payload_size(io_ddrMasters_0_aw_payload_size),
    .io_ddrMasters_0_aw_payload_len(io_ddrMasters_0_aw_payload_len),
    .io_ddrMasters_0_aw_payload_region(io_ddrMasters_0_aw_payload_region),
    .io_ddrMasters_0_aw_payload_id(io_ddrMasters_0_aw_payload_id),
    .io_ddrMasters_0_aw_payload_addr(io_ddrMasters_0_aw_payload_addr),
    .io_ddrMasters_0_aw_ready(io_ddrMasters_0_aw_ready),
    .io_ddrMasters_0_aw_valid(io_ddrMasters_0_aw_valid),
    .system_gpio_0_io_write(system_gpio_0_io_write),
    .system_gpio_0_io_read(system_gpio_0_io_read),
    .system_spi_0_io_ss(system_spi_0_io_ss)
  );
endmodule
