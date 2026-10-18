"""Export explicit BN to M16/B32/shift8, with proven arithmetic bounds."""
import argparse, hashlib, json, struct
from pathlib import Path
import numpy as np
import torch
from model import Student


def away(x): return np.sign(x)*np.floor(np.abs(x)+.5)


def main():
    p=argparse.ArgumentParser();p.add_argument('--checkpoint',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    ck=torch.load(a.checkpoint,map_location='cpu',weights_only=False)
    cfg=ck.get('config',{})
    model=Student(channels=cfg.get('channels',24),blocks=cfg.get('blocks',4),
                  head=cfg.get('head',0),head_channels=cfg.get('head_channels',8))
    model.load_state_dict(ck['model']);model.eval()
    scales=cfg.get('activation_scales')
    if scales:model.set_scales(scales)
    layers=[]; params={}; packed=bytearray(); max_bound=0
    coeff=[0]*256;weight_cursor=0;norm_cursor=128
    # full-resolution head layers run before the encoder; all are stride 1
    jobs=[(f'head.{i}',m,1,-1) for i,m in enumerate(model.pre)]
    base=len(jobs)
    jobs.extend((f'enc.{i}',m,1,-1) for i,m in enumerate(model.enc))
    for block in range(model.blocks):
        skip=len(jobs)
        jobs.extend((f'res.{block}.{j}',m,1,skip if j==3 else -1) for j,m in enumerate(model.res[block]))
    jobs.extend((f'dec.{j}',m,2 if j in (0,2) else 1,-1) for j,m in enumerate(model.dec))
    for i,(name,m,up,res) in enumerate(jobs):
        wf=m.conv.weight.detach().numpy().astype(np.float64);ws=np.maximum(np.abs(wf).reshape(len(wf),-1).max(1)/127,1e-8/127)
        w=away(wf/ws[:,None,None,None]).clip(-127,127).astype(np.int8)
        bn=isinstance(m.bn,torch.nn.BatchNorm2d)
        if bn:
            gain=m.bn.weight.detach().numpy().astype(np.float64)/np.sqrt(m.bn.running_var.detach().numpy().astype(np.float64)+m.bn.eps)
            bias=m.bn.bias.detach().numpy().astype(np.float64)-m.bn.running_mean.detach().numpy()*gain
        else:
            gain=np.ones(len(w));bias=m.conv.bias.detach().numpy().astype(np.float64)
        factor=gain*ws*m.in_scale/m.out_scale;offset=bias/m.out_scale
        mult=[];shift=[];bint=[]
        for f,b in zip(factor,offset):
            for r in range(31,-1,-1):
                mi=int(away(f*(1<<r))); bi=int(away(b*(1<<r)))
                if abs(mi)<=32767 and -(1<<31)<=bi<(1<<31): break
            else: raise ValueError('Affine cannot be represented')
            bound=128*127*np.prod(w.shape[1:])*abs(mi)+abs(bi)
            assert bound<(1<<63);max_bound=max(max_bound,int(bound))
            mult.append(mi);shift.append(r);bint.append(bi)
        params[f'w{i}']=w;params[f'm{i}']=np.asarray(mult,dtype=np.int16)
        params[f'b{i}']=np.asarray(bint,dtype=np.int32);params[f'r{i}']=np.asarray(shift,dtype=np.uint8)
        start=len(packed);packed.extend(w.tobytes())
        for mi,bi,r in zip(mult,bint,shift): packed.extend(struct.pack('<hBBi',mi,r,int(m.relu)|(2 if bn else 0),bi))
        groups=(len(w)+7)//8;reduction=w.shape[1]*w.shape[2]*w.shape[3];rg=(reduction+11)//12
        flat=w.reshape(len(w),-1)
        for cg in range(groups):
            for g in range(rg):
                word=0
                for lane in range(8):
                    for t in range(12):
                        co=cg*8+lane;ri=g*12+t
                        value=int(flat[co,ri]) if co<len(w) and ri<reduction else 0
                        word|=(value&255)<<((lane*12+t)*8)
                coeff[weight_cursor+cg*rg+g]=word
            normal=0
            for lane in range(8):
                co=cg*8+lane
                if co<len(w): normal|=int.from_bytes(struct.pack('<hBBi',mult[co],shift[co],int(m.relu)|(2 if bn else 0),bint[co]),'little')<<(lane*64)
            coeff[norm_cursor+cg]=normal
        layers.append(dict(index=i,name=name,ci=m.conv.in_channels,co=m.conv.out_channels,
            kernel=m.conv.kernel_size[0],stride=m.conv.stride[0],dw=m.conv.groups>1,bn=bn,
            relu=m.relu,upsample=up,residual=res,input_scale=m.in_scale,output_scale=m.out_scale,
            payload_offset=start,payload_bytes=len(packed)-start,weight_base=weight_cursor,norm_base=norm_cursor))
        weight_cursor+=groups*rg;norm_cursor+=groups
    # The hardware ceiling is 256 words per bank, shared by weights and norms.
    # The historical norm_cursor=128 split is only a convention: raising it is
    # safe as long as neither region overruns 256.  See STEP3_HEAD_FEASIBILITY.md.
    assert weight_cursor<=256, f'weight region overflows 256 (used {weight_cursor})'
    assert norm_cursor<=256, f'norm region overflows 256 (used {norm_cursor})'
    if weight_cursor>128:
        raise ValueError(f'weights reached {weight_cursor} > 128; the norm region '
                         'starts at 128 and would collide. Re-run with a higher '
                         'norm_cursor or compact the weight layout.')
    (a.out/'coeff.hex').write_text(''.join(f'{v:0192x}\n' for v in coeff))
    (a.out/'coeff.bin').write_bytes(b''.join(v.to_bytes(96,'little') for v in coeff))
    np.savez(a.out/'parameters.npz',**params);(a.out/'model.bin').write_bytes(packed)
    graph=dict(format_version=1,rounding='nearest_ties_away_from_zero',input='RGB uint8, q=u8-128',
        output='RGB uint8, u8=q+128',padding='zero',activation='signed INT8; ReLU [0,127]',
        accumulator='signed INT32',affine='signed64(acc*M16+B32) then round shift',
        checkpoint_sha256=hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),
        payload_sha256=hashlib.sha256(packed).hexdigest(),payload_bytes=len(packed),
        maximum_affine_abs_bound=max_bound,qat_checkpoint=ck.get('qat',False),layers=layers)
    (a.out/'graph.json').write_text(json.dumps(graph,indent=2));print(json.dumps({k:v for k,v in graph.items() if k!='layers'},indent=2))

if __name__=='__main__': main()
