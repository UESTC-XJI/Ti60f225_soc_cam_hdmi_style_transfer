"""Full VGA integer oracle vs real APB/CDC/DDR RTL, with layer cycle counts.

AXI randomized behavioral memory is not a cycle model of the board DDR PHY.
"""
import argparse, subprocess, sys, json, time
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
p=argparse.ArgumentParser();p.add_argument('--height',type=int,default=480)
p.add_argument('--fixtures-only',action='store_true',help='Generate integer input/oracle without running RTL')
a=p.parse_args();width=640;height=a.height;assert height%4==0
out=ROOT/f'reports/style_demo/vga_{height}';out.mkdir(parents=True,exist_ok=True)
rgb=np.random.default_rng(742).integers(0,256,(height,width,3),dtype=np.uint8)
t=time.monotonic();y=IntegerNetwork(ROOT/'ml/style_transfer/artifacts/integer')(rgb)
def beats(x):
    z=np.zeros((*x.shape[:2],4),np.uint8);z[:,:,:3]=x;raw=z.tobytes()
    return ''.join(f'{int.from_bytes(raw[i:i+16],"little"):032x}\n' for i in range(0,len(raw),16))
(out/'input.hex').write_text(beats(rgb));(out/'expected.hex').write_text(beats(y))
if a.fixtures_only:
    print(f'PASS integer fixtures {width}x{height}')
    sys.exit(0)
# Use the APB/CDC test's real accelerator instantiation and task setup.
if not (ROOT/'reports/style_demo/accel/tb.sv').exists():
    subprocess.run([sys.executable,'tools/test_style_accel.py'],cwd=ROOT,check=True)
text=(ROOT/'reports/style_demo/accel/tb.sv').read_text()
text=text.replace('module style_accel_tb;','module style_vga_tb;')
text=text.replace('frame_width=32,frame_height=24',f'frame_width=640,frame_height={height}')
text=text.replace('mem[0:24575],golden[0:191]',f'mem[0:524287],golden[0:{width*height//4-1}]')
start=text.index('      if(address>=');end=text.index('\n    end\n  endfunction',start)
text=text[:start]+'''      if(address>=32'h05000000 && address<32'h05200000) address_index=(address-32'h05000000)>>4;
      else if(address>=32'h05800000 && address<32'h05a00000) address_index=131072+((address-32'h05800000)>>4);
      else if(address>=32'h06000000 && address<32'h06400000) address_index=262144+((address-32'h06000000)>>4);
      else begin address_index=0;$fatal(1,"illegal DDR address %h",address);end'''+text[end:]
text=text.replace('0,191',f'0,{width*height//4-1}').replace('i<192',f'i<{width*height//4}')
text=text.replace('mem[4096+i]','mem[131072+i]')
text=text.replace("32'h00180020",f"32'h{height:04x}0280")
text=text.replace('n>2000000','n>60000000').replace('32x24',f'640x{height}')
text=text.replace('integer n=0,','reg [4:0] previous_layer=31;reg [31:0] layer_start=0;\n  integer n=0,')
text=text.replace('      n=n+1;', '''      n=n+1;
      if(dut.network.layer_index!=previous_layer)begin
        if(previous_layer!=31)$display("LAYER %0d cycles %0d",previous_layer,dut.network.cycles-layer_start);
        $fflush();
        previous_layer<=dut.network.layer_index;layer_start<=dut.network.cycles;
      end''')
text=text.replace('    $display("PASS', '    $display("LAYER %0d cycles %0d",previous_layer,cycles-layer_start);\n    $display("PASS')
tb=out/'tb.sv';tb.write_text(text);sim=out/'test.vvp'
rtl=['style_accel','style_async_fifo','style_axi_cdc','style_network','style_axi_rows','style_row_core','style_mac8x12']
c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-s','style_vga_tb','-o',str(sim),str(tb),*[f'rtl/style/{m}.sv' for m in rtl]],cwd=ROOT,capture_output=True,text=True)
assert c.returncode==0,c.stderr
print(f'Oracle ready for {width}x{height} after {time.monotonic()-t:.1f}s; running RTL',flush=True)
with (out/'simulation.log').open('w') as log:
    log.write(c.stderr);log.flush()
    r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim),'+input='+str(out/'input.hex'),'+expected='+str(out/'expected.hex')],cwd=ROOT,stdout=log,stderr=log,timeout=3600)
result=(out/'simulation.log').read_text();print(result[-3500:]);assert r.returncode==0
import re
cycles=int(re.search(r'cycles=(\d+)',result)[1])
(out/'metrics.json').write_text(json.dumps({'width':width,'height':height,'cycles':cycles,'cnn_mhz':148.5,'milliseconds':cycles/148500,'fps':148500000/cycles,'axi':'random-stall behavioral memory, no competing video/CPU','wall_seconds':time.monotonic()-t},indent=2))
