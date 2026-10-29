"""All 23 trained layers including nearest, borders, BN and residual, integer oracle."""
import json,sys,subprocess
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
OUT=ROOT/'reports/style_demo/rows';OUT.mkdir(parents=True,exist_ok=True)
net=IntegerNetwork(ROOT/'ml/style_transfer/artifacts/integer');rng=np.random.default_rng(90213)
rgb=rng.integers(0,256,(24,32,3),dtype=np.uint8);net(rgb,trace=True)
inputs=[];expected=[];commands=[];values=[rgb.astype(np.int16)-128]+[t['output'] for t in net.last_trace]
def word(x): return sum((int(v)&255)<<(8*i) for i,v in enumerate(x))
for i,t in enumerate(net.last_trace):
    l=t['layer'];original=t['input'][::2,::2] if l['upsample']==2 else t['input'];h,w,ci=original.shape
    oh,ow,co=t['output'].shape
    for y in range(oh):
        present=0
        for ky in range(3):
            yy=y*l['stride']+ky-1 if l['kernel']==3 else y
            if l['kernel']==1 and ky!=1:yy=-1
            if 0<=yy<t['input'].shape[0]:
                present|=1<<ky;row=original[yy//l['upsample']]
            else:row=np.zeros((w,ci),dtype=np.int16)
            inputs.extend(f'{word(pixel):048x}\n' for pixel in row)
        residual=values[l['residual']][y] if l['residual']>=0 else np.zeros((ow,co),np.int16)
        inputs.extend(f'{word(pixel):048x}\n' for pixel in residual)
        expected.extend(f'{word(pixel):048x}\n' for pixel in t['output'][y])
        fields=[(w,10),(ow,10),(ci,5),(co,5),(l['kernel']==3,1),(l['dw'],1),(l['stride']==2,1),
            (l['upsample']==2,1),(l['residual']>=0,1),(l['relu'],1),(present,3),(l['weight_base'],8),(l['norm_base'],8)]
        cmd=shift=0
        for v,bits in fields:cmd|=int(v)<<shift;shift+=bits
        commands.append(f'{cmd:016x}\n')
(OUT/'inputs.hex').write_text(''.join(inputs));(OUT/'expected.hex').write_text(''.join(expected));(OUT/'commands.hex').write_text(''.join(commands))
sim=OUT/'test.vvp';c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-s','style_row_tb','-o',str(sim),
    'tests/style_row_tb.sv','rtl/style/style_row_core.sv','rtl/style/style_mac8x12.sv'],cwd=ROOT,capture_output=True,text=True)
assert c.returncode==0,c.stderr
r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim),'+input='+str(OUT/'inputs.hex'),'+expected='+str(OUT/'expected.hex'),
    '+commands='+str(OUT/'commands.hex'),f'+jobs={len(commands)}'],cwd=ROOT,capture_output=True,text=True,timeout=180)
(OUT/'simulation.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout);assert r.returncode==0,r.stderr
