"""Independent integer oracle -> full network DDR/AXI simulation."""
import subprocess,sys
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
OUT=ROOT/'reports/style_demo/network';OUT.mkdir(parents=True,exist_ok=True)
rgb=np.random.default_rng(741).integers(0,256,(24,32,3),dtype=np.uint8)
net=IntegerNetwork(ROOT/'ml/style_transfer/artifacts/integer');y=net(rgb)
def beats(x):
    packed=np.zeros((*x.shape[:2],4),np.uint8);packed[:,:,:3]=x;raw=packed.tobytes()
    return ''.join(f'{int.from_bytes(raw[i:i+16],"little"):032x}\n' for i in range(0,len(raw),16))
(OUT/'input.hex').write_text(beats(rgb));(OUT/'expected.hex').write_text(beats(y))
sim=OUT/'test.vvp';c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-s','style_network_tb','-o',str(sim),
    'tests/style_network_tb.sv','rtl/style/style_network.sv','rtl/style/style_axi_rows.sv','rtl/style/style_row_core.sv','rtl/style/style_mac8x12.sv'],cwd=ROOT,capture_output=True,text=True)
assert c.returncode==0,c.stderr
r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim),'+input='+str(OUT/'input.hex'),'+expected='+str(OUT/'expected.hex')],cwd=ROOT,capture_output=True,text=True,timeout=180)
(OUT/'simulation.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout);assert r.returncode==0,r.stderr
