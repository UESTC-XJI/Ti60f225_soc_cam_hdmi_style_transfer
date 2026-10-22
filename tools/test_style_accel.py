"""APB, unrelated clocks, coefficient handshake, completion IRQ and exact DDR RGB."""
import subprocess,sys,os
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
OUT=ROOT/'reports/style_demo/accel';OUT.mkdir(parents=True,exist_ok=True)
rgb=np.random.default_rng(741).integers(0,256,(24,32,3),dtype=np.uint8);net=IntegerNetwork(ROOT/'ml/style_transfer/artifacts_quality/integer');y=net(rgb)
def beats(x):
    z=np.zeros((*x.shape[:2],4),np.uint8);z[:,:,:3]=x;raw=z.tobytes()
    return ''.join(f'{int.from_bytes(raw[i:i+16],"little"):032x}\n' for i in range(0,len(raw),16))
(OUT/'input.hex').write_text(beats(rgb));(OUT/'expected.hex').write_text(beats(y))
text=(ROOT/'tests/style_network_tb.sv').read_text().replace('module style_network_tb;','module style_accel_tb;')
text=text.replace('style_network dut(.*);','''reg cnn_clk=0;always #3.367 cnn_clk=~cnn_clk;
  reg psel=0,penable=0,pwrite=0;reg [7:0] paddr=0;reg [31:0] pwdata=0;
  wire [31:0] prdata,last_cycles;wire pready,pslverr,irq,stream_enable,auto_ready,job_done,job_error;
  reg auto_start=0;reg [31:0] auto_source=0,auto_result=0;
  assign busy=dut.pending;assign done=job_done;assign error=job_error;
  assign cycles=last_cycles;assign layer_index=dut.network.layer_index;
  assign stat_prefetch_starts=dut.prefetch_starts_snapshot;
  assign stat_prefetch_completions=dut.prefetch_completions_snapshot;
  assign stat_overlap_cycles=dut.overlap_cycles_snapshot;
  style_accel dut(.*);
  task write_apb(input [7:0] address,input [31:0] value,input reject);
    begin
      @(negedge clk);psel=1;penable=0;pwrite=1;paddr=address;pwdata=value;
      @(negedge clk);penable=1;
      while(!pready)@(negedge clk);
      @(posedge clk);if(pslverr!==reject)$fatal(1,"APB reject addr=%h got=%b",address,pslverr);
      @(negedge clk);psel=0;penable=0;pwrite=0;
    end
  endtask''')
blob=(ROOT/'rtl/style/model/coeff.bin').read_bytes()
(OUT/'zero_coeff.hex').write_text(('0'*192+'\n')*256)
(OUT/'coeff32.hex').write_text(''.join(f'{int.from_bytes(blob[i:i+4],"little"):08x}\n' for i in range(0,len(blob),4)))
text=text.replace('integer n=0,', '''reg [31:0] cpu_coeff[0:6143];integer cr,cw;
  initial $readmemh("reports/style_demo/accel/coeff32.hex",cpu_coeff);
  defparam dut.network.COEFF_FILE="reports/style_demo/accel/zero_coeff.hex";
  integer n=0,''')
text=text.replace('rst_n=1;start=1;@(negedge clk);start=0;', '''rst_n=1;
    for(cr=0;cr<256;cr=cr+1)for(cw=0;cw<24;cw=cw+1)begin
      write_apb(8'h28,(cr<<8)|cw,0);write_apb(8'h2c,cpu_coeff[cr*24+cw],0);
    end
    repeat(12)@(negedge clk);
    if(!dut.coeff_idle||dut.issued!=6144)$fatal(1,"coefficient CDC acknowledgement");
    write_apb(8'h28,24,1);
    write_apb(8'h10,32'hfffffff0,0);write_apb(8'h04,1,1);
    write_apb(8'h10,32'h05000000,0);
    write_apb(8'h18,32'h00170020,0);write_apb(8'h04,1,1);
    write_apb(8'h18,32'h00180021,0);write_apb(8'h04,1,1);
    write_apb(8'h18,32'h00180020,0);write_apb(8'h0c,1,0);write_apb(8'h04,1,0);
    write_apb(8'h10,32'h05140000,1);''')
text=text.replace('if(error)$fatal(1,"accelerator error");','''if(error)$fatal(1,"accelerator error");
    @(posedge clk);@(negedge clk);
    if(!irq||dut.source_cfg!=32'h05000000)$fatal(1,"IRQ or rejected write changed config");
    if(dut.read_cycles_snapshot>cycles||dut.compute_cycles_snapshot>cycles)$fatal(1,"phase snapshot outside job");
    if(!error&&(dut.read_cycles_snapshot==0||dut.compute_cycles_snapshot==0))$fatal(1,"missing phase snapshot");
    @(negedge clk);psel=1;penable=1;pwrite=0;paddr=8'ha8;
    @(posedge clk);#1;if(prdata!==dut.read_cycles_snapshot)$fatal(1,"APB read phase decode");
    @(negedge clk);paddr=8'hac;
    @(posedge clk);#1;if(prdata!==dut.compute_cycles_snapshot)$fatal(1,"APB compute phase decode");
    @(negedge clk);paddr=8'hb0;
    @(posedge clk);#1;if(prdata!==stat_prefetch_starts || prdata==0)$fatal(1,"APB prefetch starts");
    @(negedge clk);paddr=8'hb4;
    @(posedge clk);#1;if(prdata!==stat_prefetch_completions || prdata!==stat_prefetch_starts)$fatal(1,"APB prefetch completions");
    @(negedge clk);paddr=8'hb8;
    @(posedge clk);#1;if(prdata!==stat_overlap_cycles || prdata==0)$fatal(1,"APB overlap pixels");
    @(negedge clk);psel=0;penable=0;
    write_apb(8'h08,2,0);if(irq)$fatal(1,"IRQ W1C");''')
text=text.replace('dut.state,dut.dma.rs,dut.dma.ws','dut.network.state,dut.network.dma.rs,dut.network.dma.ws')
text=text.replace('PASS style_network','PASS style_accel all 6144 APB coefficients+CDC+IRQ')
tb=OUT/'tb.sv';tb.write_text(text);sim=OUT/'test.vvp'
rtl=['style_accel','style_async_fifo','style_axi_cdc','style_network','style_axi_rows','style_row_core','style_mac8x12']
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-grelative-include','-s','style_accel_tb','-o',str(sim),str(tb),*[f'rtl/style/{m}.sv' for m in rtl]],cwd=ROOT,capture_output=True,text=True)
assert c.returncode==0,c.stderr
r=subprocess.run([os.environ.get('VVP','vvp'),str(sim),'+input='+str(OUT/'input.hex'),'+expected='+str(OUT/'expected.hex')],cwd=ROOT,capture_output=True,text=True,timeout=180)
(OUT/'simulation.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout);assert r.returncode==0,r.stderr
