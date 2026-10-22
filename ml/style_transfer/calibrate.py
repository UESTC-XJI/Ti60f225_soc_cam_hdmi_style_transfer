"""Use held-out validation only to diagnose range and select activation scales."""
import argparse,json,math
from pathlib import Path
import numpy as np
import torch
from PIL import Image,ImageDraw
from model import Student,Layer
from train import image_tensor

def main():
    p=argparse.ArgumentParser();p.add_argument('--checkpoint',type=Path,required=True)
    p.add_argument('--manifest',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True);torch.set_num_threads(8)
    ck=torch.load(a.checkpoint,weights_only=False);model=Student().cuda().eval();model.load_state_dict(ck['model'])
    data=json.loads(a.manifest.read_text());root=Path(data['dataset']);v=[r['path'] for r in data['records'] if r['domain']=='B' and r['split']=='validation']
    v=[v[i*(len(v)-1)//31] for i in range(32)]
    layers=[m for m in model.modules() if isinstance(m,Layer)];maxima=np.zeros(len(layers));outputs={}
    handles=[]
    for i,m in enumerate(layers):
        def hook(module,input,output,i=i):
            maxima[i]=max(maxima[i],output.abs().max().item());outputs[i]=output
        handles.append(m.register_forward_hook(hook))
    residual_max=0
    with torch.no_grad():
        for name in v:
            model(image_tensor(root/name)[None].cuda())
            for i in range(4):
                prev=outputs[2] if i==0 else previous
                previous=(outputs[6+i*4]+prev).relu()
                residual_max=max(residual_max,previous.max().item())
    for h in handles:h.remove()
    scales=[2**math.ceil(math.log2(max(m,1e-5)/127)) for m in maxima]
    common=2**math.ceil(math.log2(max(residual_max,maxima[[2,6,10,14,18]].max())/127))
    for i in (2,6,10,14,18):scales[i]=common
    scales[-1]=1/128
    report={'maxima':maxima.tolist(),'residual_max':residual_max,'scales':scales,'candidates':[]}
    sheet=Image.new('RGB',(6*256,4*280),'white');draw=ImageDraw.Draw(sheet)
    candidates=[('FP32',None),('global_1_32',[1/32]*22+[1/128]),('global_1_16',[1/16]*22+[1/128]),
                ('global_1_8',[1/8]*22+[1/128]),('global_1_4',[1/4]*22+[1/128]),('calibrated',scales)]
    for col,(label,s) in enumerate(candidates):
        model.set_qat(False)
        errs=[]
        with torch.no_grad():
            for row,name in enumerate(v):
                x=image_tensor(root/name)[None].cuda();model.set_qat(False);ref=model(x)
                if s:model.set_scales(s);model.set_qat(True)
                y=model(x);errs.append((y-ref).square().mean().item())
                if row<4:
                    im=Image.fromarray((y[0].permute(1,2,0).cpu().numpy()*255).round().clip(0,255).astype('uint8'))
                    sheet.paste(im,(col*256,row*280+24));draw.text((col*256+4,row*280+4),label,fill='black')
        mse=float(np.mean(errs));report['candidates'].append({'label':label,'mse':mse,'psnr':float(-10*np.log10(max(mse,1e-12)))})
    sheet.save(a.out/'scale_comparison.png');(a.out/'scales.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if __name__=='__main__':main()
