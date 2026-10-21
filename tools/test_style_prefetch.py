"""Exact full-network oracle, prefetch safety and serial/prefetch comparison."""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
p=argparse.ArgumentParser();p.add_argument('--width',type=int,default=32);p.add_argument('--height',type=int,default=24);p.add_argument('--require-overlap',action='store_true');p.add_argument('--baseline',action='store_true');p.add_argument('--seed',type=int,default=741);p.add_argument('--fault',choices=['none','prefetch_read','prefetch_write','reset'],default='none');a=p.parse_args()
assert a.width%4==0 and a.height%4==0
out=ROOT/f'reports/prefetch/{"baseline" if a.baseline else "candidate"}_{a.width}x{a.height}_{a.seed}{"" if a.fault=="none" else "_"+a.fault}';out.mkdir(parents=True,exist_ok=True)
rgb=np.random.default_rng(a.seed).integers(0,256,(a.height,a.width,3),dtype=np.uint8)
y=IntegerNetwork(ROOT/'ml/style_transfer/artifacts_quality/integer')(rgb)
for name,x in [('input',rgb),('expected',y)]:
 z=np.zeros((*x.shape[:2],4),np.uint8);z[:,:,:3]=x;raw=z.tobytes();(out/f'{name}.hex').write_text(''.join(f'{int.from_bytes(raw[i:i+16],"little"):032x}\n' for i in range(0,len(raw),16)))
text=(ROOT/'tests/style_network_tb.sv').read_text()
text=text.replace('frame_width=32,frame_height=24',f'frame_width={a.width},frame_height={a.height}')
beats=a.width*a.height//4
text=text.replace('mem[0:24575],golden[0:191]',f'mem[0:524287],golden[0:{beats-1}]')
s=text.index('      if(address>=');e=text.index('\n    end\n  endfunction',s)
text=text[:s]+'''      if(address>=32'h05000000 && address<32'h05200000) address_index=(address-32'h05000000)>>4;
      else if(address>=32'h05800000 && address<32'h05a00000) address_index=131072+((address-32'h05800000)>>4);
      else if(address>=32'h06000000 && address<32'h06400000) address_index=262144+((address-32'h06000000)>>4);
      else begin address_index=0;$fatal(1,"illegal address");end'''+text[e:]
text=text.replace('0,191',f'0,{beats-1}').replace('i<192',f'i<{beats}').replace('mem[4096+i]','mem[131072+i]').replace('n>2000000','n>60000000')
text=text.replace('integer n=0,','integer overlap_count=0;\n  integer n=0,')
text=text.replace('      n=n+1;','''      n=n+1;
      if(dut.rd_valid && dut.core_busy)begin
        overlap_count=overlap_count+1;
        if(dut.kernel3 || dut.residual || dut.load_skip)$fatal(1,"unsupported prefetch layer");
        if(dut.load_bank==dut.row_select[3:2])$fatal(1,"live row overwrite");
      end''')
text=text.replace('    $display("PASS',('    if(overlap_count==0)$fatal(1,"missing read-compute overlap");\n' if a.require_overlap else '')+'    $display("OVERLAP %0d",overlap_count);\n    $display("PASS')
if a.fault.startswith('prefetch_'):
 text=text.replace('wire [1:0] rresp=0,bresp=0;', 'reg inject=0;wire [1:0] rresp='+('inject ? 2 : 0' if a.fault=='prefetch_read' else '0')+',bresp='+('inject ? 2 : 0' if a.fault=='prefetch_write' else '0')+';\n  initial begin wait(rst_n);wait(dut.prefetch_active);inject=1;end')
 text=text.replace('if(error)$fatal(1,"accelerator error");','if(!error)$fatal(1,"missing prefetch error");\n    if(read_active||write_active||dut.rd_busy||dut.wr_busy||dut.core_busy)$fatal(1,"error returned with active operation");')
 text=re.sub(r'    for\(i=0;i<\d+;i=i\+1\) if\(mem\[131072\+i\].*?;','',text)
 text=text.replace('full graph exact RGB','prefetch fault drained')
elif a.fault=='reset':
 text=text.replace('    wait(done);', '''    wait(dut.prefetch_active && dut.core_busy);
    @(negedge clk);rst_n=0;repeat(7)@(negedge clk);
    if(arvalid||awvalid||wvalid||busy)$fatal(1,"reset failed to quiesce");
    rst_n=1;start=1;@(negedge clk);start=0;
    wait(done);''')
(out/'tb.sv').write_text(text)
network=ROOT/'rtl/style/style_network.sv'
if a.baseline:network=ROOT/'reports/baseline/style_network.sv'
cmd=[os.environ.get('IVERILOG','iverilog'),'-g2012','-grelative-include','-s','style_network_tb','-o',str(out/'test.vvp'),str(out/'tb.sv'),str(network),*[str(ROOT/f'rtl/style/{n}.sv') for n in ['style_axi_rows','style_row_core','style_mac8x12']]]
c=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True);assert c.returncode==0,c.stderr
t=time.monotonic();r=subprocess.run([os.environ.get('VVP','vvp'),str(out/'test.vvp'),'+input='+str(out/'input.hex'),'+expected='+str(out/'expected.hex')],cwd=ROOT,capture_output=True,text=True,timeout=3600)
(out/'simulation.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout,flush=True);assert r.returncode==0,r.stderr
cycles=int(re.search(r'cycles=(\d+)',r.stdout)[1]);overlap=int(re.search(r'OVERLAP (\d+)',r.stdout)[1]);(out/'metrics.json').write_text(json.dumps({'width':a.width,'height':a.height,'seed':a.seed,'cycles':cycles,'overlap_pixels':overlap,'ms_at_148_5mhz':cycles/148500,'behavioral_task_fps':148500000/cycles,'wall_seconds':time.monotonic()-t,'physical_ddr':False},indent=2))
