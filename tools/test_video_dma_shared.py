"""Run the real video DMA through the shared bridge with concurrent CPU bursts."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
text = (root / 'tests/tb_video_dma.sv').read_text()
text = text.replace('module tb_video_dma;', 'module tb_video_dma_shared;')
start = text.index('frame_buffer #')
end = text.index('reg [127:0] mem', start)
dut = text[start:end]
names = ['awaddr','awlen','awvalid','awready','wdata','wstrb','wlast','wvalid','wready',
         'bvalid','bready','araddr','arlen','arvalid','arready','rdata','rlast','rvalid','rready']
for name in names:
    dut = dut.replace('('+name+')', '(v_'+name+')')
bridge = '''
wire [31:0] v_awaddr,v_araddr; wire [7:0] v_awlen,v_arlen;
wire v_awvalid,v_awready,v_wvalid,v_wready,v_wlast,v_bvalid,v_bready;
wire v_arvalid,v_arready,v_rvalid,v_rready,v_rlast;
wire [127:0] v_wdata,v_rdata; wire [15:0] v_wstrb;
wire [3:0] awid,arid; reg [3:0] bid=0,rid=0;
wire [31:0] errors;
reg c_awvalid=0,c_wvalid=0,c_wlast=0,c_arvalid=0;
wire c_awready,c_wready,c_bvalid,c_arready,c_rvalid,c_rlast;
wire [127:0] c_rdata; reg [127:0] c_wdata=0;
integer cpu_writes=0,cpu_reads=0;
axi_shared_ddr_2m shared(
 .clk(ac),.rst_n(rst),.allow_access(rst),
 .cpu_awid(8'ha5),.cpu_awaddr(32'h18000),.cpu_awlen(8'd3),.cpu_awsize(3'd4),.cpu_awburst(2'd1),
 .cpu_awvalid(c_awvalid),.cpu_awready(c_awready),.cpu_wdata(c_wdata),.cpu_wstrb(16'hffff),
 .cpu_wvalid(c_wvalid),.cpu_wlast(c_wlast),.cpu_wready(c_wready),.cpu_bvalid(c_bvalid),.cpu_bready(1'b1),
 .cpu_arid(8'hc3),.cpu_araddr(32'h18000),.cpu_arlen(8'd3),.cpu_arsize(3'd4),.cpu_arburst(2'd1),
 .cpu_arvalid(c_arvalid),.cpu_arready(c_arready),.cpu_rdata(c_rdata),.cpu_rvalid(c_rvalid),
 .cpu_rready(1'b1),.cpu_rlast(c_rlast),
 .vid_awid(8'd0),.vid_awaddr(v_awaddr),.vid_awlen(v_awlen),.vid_awsize(3'd4),.vid_awburst(2'd1),
 .vid_awvalid(v_awvalid),.vid_awready(v_awready),.vid_wdata(v_wdata),.vid_wstrb(v_wstrb),
 .vid_wlast(v_wlast),.vid_wvalid(v_wvalid),.vid_wready(v_wready),.vid_bvalid(v_bvalid),.vid_bready(v_bready),
 .vid_arid(8'd0),.vid_araddr(v_araddr),.vid_arlen(v_arlen),.vid_arsize(3'd4),.vid_arburst(2'd1),
 .vid_arvalid(v_arvalid),.vid_arready(v_arready),.vid_rdata(v_rdata),.vid_rvalid(v_rvalid),
 .vid_rready(v_rready),.vid_rlast(v_rlast),
 .ddr_awid(awid),.ddr_awaddr(awaddr),.ddr_awlen(awlen),.ddr_awvalid(awvalid),.ddr_awready(awready),
 .ddr_wdata(wdata),.ddr_wstrb(wstrb),.ddr_wlast(wlast),.ddr_wvalid(wvalid),.ddr_wready(wready),
 .ddr_bid(bid),.ddr_bresp(2'b00),.ddr_bvalid(bvalid),.ddr_bready(bready),
 .ddr_arid(arid),.ddr_araddr(araddr),.ddr_arlen(arlen),.ddr_arvalid(arvalid),.ddr_arready(arready),
 .ddr_rid(rid),.ddr_rdata(rdata),.ddr_rresp(2'b00),.ddr_rlast(rlast),.ddr_rvalid(rvalid),.ddr_rready(rready),
 .axi_error_count(errors));
initial begin : cpu_traffic
 integer transaction,k;
 wait(rst);
 for(transaction=0;transaction<200;transaction=transaction+1) begin
   @(negedge ac); c_awvalid=1;
   do @(posedge ac); while(!c_awready);
   @(negedge ac); c_awvalid=0;
   for(k=0;k<4;k=k+1) begin
     c_wvalid=1; c_wlast=(k==3); c_wdata=128'hcafe0000+transaction*4+k;
     do @(posedge ac); while(!c_wready);
     @(negedge ac); c_wvalid=0;
   end
   wait(c_bvalid); @(negedge ac); cpu_writes=cpu_writes+1;
   c_arvalid=1;
   do @(posedge ac); while(!c_arready);
   @(negedge ac); c_arvalid=0;
   for(k=0;k<4;k=k+1) begin
     do @(posedge ac); while(!c_rvalid);
     if(c_rdata !== 128'hcafe0000+transaction*4+k || c_rlast !== (k==3))
       $fatal(1,"CPU readback transaction=%0d beat=%0d got=%h",transaction,k,c_rdata);
   end
   @(negedge ac); cpu_reads=cpu_reads+1;
 end
end
'''
text = text[:start] + bridge + dut + text[end:]
text = text.replace('mem[0:3*SLOT-1]', 'mem[0:3*SLOT+1023]')
text = text.replace('i<3*SLOT;', 'i<3*SLOT+1024;')
text = text.replace('awaddr>=3*SLOT*16', "(awaddr>=3*SLOT*16 && awaddr!=32'h18000)")
text = text.replace('araddr>=3*SLOT*16', "(araddr>=3*SLOT*16 && araddr!=32'h18000)")
text = text.replace('integer cycle=0', 'reg [3:0] readids[0:1023];\ninteger cycle=0')
text = text.replace('addrs[wp]=awaddr/16;', 'bid<=awid; addrs[wp]=awaddr/16;')
text = text.replace('raddrs[rwp]=araddr/16;', 'readids[rwp]=arid; raddrs[rwp]=araddr/16;')
text = text.replace('rdata<=mem[raddrs[rrp]+rbeat];', 'rid<=readids[rrp]; rdata<=mem[raddrs[rrp]+rbeat];')
text = text.replace('if(output_frames!=3', 'if(errors!=0 || cpu_reads!=200 || cpu_writes!=200) $fatal(1,"shared DDR errors or CPU progress");\n if(output_frames!=3')
text = text.replace('PASS XRGB DMA:', 'PASS shared DDR + real XRGB DMA + 200 concurrent CPU write/read bursts:')
work = root / 'work'
work.mkdir(exist_ok=True)
tb = work / 'tb_video_dma_shared.sv'
tb.write_text(text)
sim = work / 'video_dma_shared.vvp'
files = [p.relative_to(root).as_posix() for p in (root / 'rtl/frame_buffer_V4').glob('*.v')]
commands = [
    ['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-I',str(root/'rtl'),
     '-s','tb_video_dma_shared','-o',str(sim),tb.relative_to(root).as_posix(),'rtl/soc_integration/axi_shared_ddr_2m.sv',*files],
    ['C:/iverilog/bin/vvp.exe',str(sim)]
]
log = ''
for command in commands:
    result = subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=60)
    log += result.stdout + result.stderr
    print(result.stdout + result.stderr, end='', flush=True)
    (root / 'reports/color_regression/dma_shared_test.log').write_text(log)
    if result.returncode:
        raise SystemExit(result.returncode)
