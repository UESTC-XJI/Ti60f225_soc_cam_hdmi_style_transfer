import re
from pathlib import Path

src=Path('soc/efx_sapphire_soc/soc/soc.v').read_text(encoding='utf-8')
head=src[src.index('module soc'):src.index(');',src.index('module soc'))]
ports=[]
for d,w,n in re.findall(r'\b(input|output)\s*(\[[^]]+\])?\s*([A-Za-z_][A-Za-z0-9_]*)\s*,?',head):
    ports.append((d,w or '',n))
decl=[]
for d,w,n in ports:
    decl.append(f'  wire {w} {n};')
bridge='''
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
'''
body=['// Actual generated Sapphire SoC wrapper used by the simulation/integration top.', 'module soc_video_ddr_integration (',
'''  input wire clk, rst_n, allow_access,
  input wire [7:0] vid_awid, input wire [31:0] vid_awaddr, input wire [7:0] vid_awlen, input wire [2:0] vid_awsize, input wire [1:0] vid_awburst, input wire vid_awvalid, output wire vid_awready,
  input wire [127:0] vid_wdata, input wire [15:0] vid_wstrb, input wire vid_wlast, input wire vid_wvalid, output wire vid_wready, output wire [7:0] vid_bid, output wire [1:0] vid_bresp, output wire vid_bvalid, input wire vid_bready,
  input wire [7:0] vid_arid, input wire [31:0] vid_araddr, input wire [7:0] vid_arlen, input wire [2:0] vid_arsize, input wire [1:0] vid_arburst, input wire vid_arvalid, output wire vid_arready, output wire [7:0] vid_rid, output wire [127:0] vid_rdata, output wire [1:0] vid_rresp, output wire vid_rlast, output wire vid_rvalid, input wire vid_rready,
  output wire [3:0] ddr_awid, output wire [31:0] ddr_awaddr, output wire [7:0] ddr_awlen, output wire [2:0] ddr_awsize, output wire [1:0] ddr_awburst, output wire ddr_awvalid, input wire ddr_awready, output wire [127:0] ddr_wdata, output wire [15:0] ddr_wstrb, output wire ddr_wlast, output wire ddr_wvalid, input wire ddr_wready, input wire [3:0] ddr_bid, input wire [1:0] ddr_bresp, input wire ddr_bvalid, output wire ddr_bready, output wire [3:0] ddr_arid, output wire [31:0] ddr_araddr, output wire [7:0] ddr_arlen, output wire [2:0] ddr_arsize, output wire [1:0] ddr_arburst, output wire ddr_arvalid, input wire ddr_arready, input wire [3:0] ddr_rid, input wire [127:0] ddr_rdata, input wire [1:0] ddr_rresp, input wire ddr_rlast, input wire ddr_rvalid, output wire ddr_rready,
  output wire [15:0] apb_paddr, output wire apb_psel, output wire apb_penable, input wire apb_pready, output wire apb_pwrite, output wire [31:0] apb_pwdata, input wire [31:0] apb_prdata, input wire apb_pslverr,
  input wire jtag_tck,jtag_tdi,jtag_capture,jtag_shift,jtag_update,jtag_reset,jtag_enable, output wire jtag_tdo,
  output wire uart_txd, input wire uart_rxd, input wire i2c_scl_in, output wire i2c_scl_out, input wire i2c_sda_in, output wire i2c_sda_out,
  output wire soc_system_reset,soc_memory_reset, output wire [31:0] axi_error_count
);'''.replace('  input wire','  input wire')]
body += decl
body += [bridge]
body += ['''
  assign io_systemClk=clk; assign io_asyncReset=!rst_n; assign io_memoryClk=clk;
  assign jtagCtrl_tck=jtag_tck; assign jtagCtrl_tdi=jtag_tdi; assign jtagCtrl_capture=jtag_capture; assign jtagCtrl_shift=jtag_shift; assign jtagCtrl_update=jtag_update; assign jtagCtrl_reset=jtag_reset; assign jtagCtrl_enable=jtag_enable; assign jtag_tdo=jtagCtrl_tdo;
  assign system_uart_0_io_rxd=uart_rxd; assign uart_txd=system_uart_0_io_txd;
  assign system_i2c_0_io_scl_read=i2c_scl_in; assign system_i2c_0_io_sda_read=i2c_sda_in; assign i2c_scl_out=system_i2c_0_io_scl_write; assign i2c_sda_out=system_i2c_0_io_sda_write;
  assign apb_paddr=io_apbSlave_0_PADDR; assign apb_psel=io_apbSlave_0_PSEL; assign apb_penable=io_apbSlave_0_PENABLE; assign apb_pwrite=io_apbSlave_0_PWRITE; assign apb_pwdata=io_apbSlave_0_PWDATA; assign io_apbSlave_0_PREADY=apb_pready; assign io_apbSlave_0_PRDATA=apb_prdata; assign io_apbSlave_0_PSLVERROR=apb_pslverr;
  assign soc_system_reset=io_systemReset; assign soc_memory_reset=io_memoryReset;
''']
# Tie every unused SoC input to a safe value. Outputs not used by the wrapper
# are left as wires and are optimized away by Efinity.
used={'io_systemClk','io_asyncReset','io_memoryClk','io_ddrA_w_payload_strb','io_ddrA_w_payload_data','io_ddrA_aw_payload_id','io_ddrA_aw_payload_addr','io_ddrA_aw_payload_len','io_ddrA_aw_payload_size','io_ddrA_aw_payload_burst','io_ddrA_aw_valid','io_ddrA_aw_ready','io_ddrA_w_payload_last','io_ddrA_w_ready','io_ddrA_w_valid','io_ddrA_b_payload_id','io_ddrA_b_payload_resp','io_ddrA_b_ready','io_ddrA_b_valid','io_ddrA_ar_payload_id','io_ddrA_ar_payload_addr','io_ddrA_ar_payload_len','io_ddrA_ar_payload_size','io_ddrA_ar_payload_burst','io_ddrA_ar_valid','io_ddrA_ar_ready','io_ddrA_r_payload_id','io_ddrA_r_payload_data','io_ddrA_r_payload_resp','io_ddrA_r_payload_last','io_ddrA_r_valid','io_ddrA_r_ready','io_apbSlave_0_PADDR','io_apbSlave_0_PSEL','io_apbSlave_0_PENABLE','io_apbSlave_0_PWRITE','io_apbSlave_0_PWDATA','io_apbSlave_0_PREADY','io_apbSlave_0_PRDATA','io_apbSlave_0_PSLVERROR','jtagCtrl_tck','jtagCtrl_tdi','jtagCtrl_capture','jtagCtrl_shift','jtagCtrl_update','jtagCtrl_reset','jtagCtrl_enable','jtagCtrl_tdo','system_uart_0_io_rxd','system_uart_0_io_txd','system_i2c_0_io_scl_read','system_i2c_0_io_scl_write','system_i2c_0_io_sda_read','system_i2c_0_io_sda_write','io_systemReset','io_memoryReset'}
for d,w,n in ports:
    if n not in used and d=='input': body.append(f'  assign {n} = \'0;')
body += ['  // The generated IP exposes an auxiliary 32-bit AXI master and a second', '  // DDR master port. They are intentionally tied off; only io_ddrA is CPU DDR.', '  soc u_soc (']
for i,(d,w,n) in enumerate(ports): body.append(f'    .{n}({n})'+(',' if i<len(ports)-1 else ''))
body += ['  );','endmodule','']
Path('rtl/soc_integration/soc_video_ddr_integration.sv').write_text('\n'.join(body),encoding='utf-8')
print('generated wrapper with',len(ports),'SoC ports')
