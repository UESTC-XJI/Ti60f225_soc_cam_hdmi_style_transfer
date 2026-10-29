"""Seeded integer MAC/BN vectors, including rounding, saturation and negative gain."""
import subprocess
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/style_demo/mac';OUT.mkdir(parents=True,exist_ok=True)
rng=np.random.default_rng(20261012);packets=[];expected=[]
for tag in range(2000):
    acc=np.zeros(8,dtype=np.int64);groups=int(rng.integers(1,5))
    m=rng.integers(-32768,32768,8);b=rng.integers(-(1<<31),(1<<31),8)
    r=rng.integers(0,32,8);relu=int(rng.integers(2))
    for group in range(groups):
        a=rng.integers(-128,128,(8,12));w=rng.integers(-128,128,(8,12));acc+=(a*w).sum(1)
        fields=[(a.ravel(),8),(w.ravel(),8),(m,16),(b,32),(r,8),([int(group==0),int(group==groups-1),relu],1),([tag],16)]
        value=0;offset=0
        for arr,bits in fields:
            for v in arr: value|=(int(v)&((1<<bits)-1))<<offset;offset+=bits
        packets.append(f'{value:0501x}\n')
    v=acc*m+b;mag=(np.abs(v)+np.where(r>0,1<<np.maximum(r-1,0),0))>>r
    q=(np.sign(v)*mag).clip(0 if relu else -128,127)
    value=sum((int(v)&255)<<(8*i) for i,v in enumerate(q));expected.append(f'{value:016x}\n')
# Hand-selected exact +/-.5 and adjacent values are covered separately.
for nums in ([1,-1,3,-3,255,-257,254,-256], [0,0,0,0,0,0,0,0]):
    tag=len(expected);a=np.zeros((8,12),int);w=np.zeros((8,12),int)
    m=np.ones(8,int);b=np.array(nums);r=np.ones(8,int)
    fields=[(a.ravel(),8),(w.ravel(),8),(m,16),(b,32),(r,8),([1,1,0],1),([tag],16)];value=offset=0
    for arr,bits in fields:
        for v in arr:value|=(int(v)&((1<<bits)-1))<<offset;offset+=bits
    packets.append(f'{value:0501x}\n');q=np.sign(nums)*((np.abs(nums)+1)//2);q=q.clip(-128,127)
    expected.append(f'{sum((int(v)&255)<<(8*i) for i,v in enumerate(q)):016x}\n')
(OUT/'packets.hex').write_text(''.join(packets));(OUT/'expected.hex').write_text(''.join(expected))
sim=OUT/'test.vvp'
c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s','style_mac_tb','-o',str(sim),
                  'tests/style_mac_tb.sv','rtl/style/style_mac8x12.sv'],cwd=ROOT,capture_output=True,text=True)
assert c.returncode==0,c.stderr
r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim),'+packets='+str(OUT/'packets.hex'),
    '+expected='+str(OUT/'expected.hex'),f'+count={len(packets)}',f'+outputs={len(expected)}'],cwd=ROOT,capture_output=True,text=True,timeout=60)
(OUT/'simulation.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout);assert r.returncode==0,r.stderr
