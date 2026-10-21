"""Final held-out assessment: perceptual change and deployment arithmetic are separate."""
import argparse,hashlib,json,time
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
import torch
from torch.nn import functional as F
from model import Student,Teacher
from train import Features,gram,image_tensor
from integer import IntegerNetwork

def main():
    p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--fp',type=Path,required=True);p.add_argument('--qat',type=Path,required=True)
    p.add_argument('--teacher',type=Path,required=True);p.add_argument('--integer',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--count',type=int,default=64);a=p.parse_args()
    torch.set_num_threads(8);a.out.mkdir(parents=True,exist_ok=True);d=json.loads(a.manifest.read_text());root=Path(d['dataset'])
    paths=[r['path'] for r in d['records'] if r['domain']=='B' and r['split']=='test']
    paths=[paths[i*(len(paths)-1)//(a.count-1)] for i in range(a.count)]
    fp=Student().cuda().eval();fp.load_state_dict(torch.load(a.fp,weights_only=False)['model'])
    ck=torch.load(a.qat,weights_only=False);qat=Student().cuda().eval();qat.load_state_dict(ck['model']);qat.set_qat(True)
    if ck['config'].get('activation_scales'):qat.set_scales(ck['config']['activation_scales'])
    teacher=Teacher().cuda().eval();teacher.load_state_dict(torch.load(a.teacher,weights_only=False)['model'])
    net=IntegerNetwork(a.integer);features=Features().cuda()
    refs=json.loads((a.manifest.parent/'style_refs.json').read_text())
    with torch.no_grad():target=[gram(f).mean(0,keepdim=True) for f in features(torch.stack([image_tensor(root/r) for r in refs]).cuda())]
    sheet=Image.new('RGB',(5*256,8*280),'white');draw=ImageDraw.Draw(sheet);rows=[];start=time.monotonic()
    with torch.no_grad():
        for i,name in enumerate(paths):
            x=image_tensor(root/name)[None].cuda();yt=teacher(x);yf=fp(x);yq=qat(x)
            rgb=(x[0].permute(1,2,0).cpu().numpy()*255).round().astype('uint8');yi=net(rgb)
            yit=torch.from_numpy(yi.copy()).permute(2,0,1)[None].float().cuda()/255
            xf=features(x);itf=features(yit)
            baseline=sum(F.mse_loss(gram(f),g).item() for f,g in zip(xf,target))
            style=sum(F.mse_loss(gram(f),g).item() for f,g in zip(itf,target))
            mse=F.mse_loss(yit,yq).item();vsfp=F.mse_loss(yit,yf).item()
            rows.append(dict(path=name,original_style_mse=baseline,integer_style_mse=style,
                content_feature_mse=F.mse_loss(itf[2],xf[2]).item(),
                integer_vs_qat_psnr=-10*np.log10(max(mse,1e-12)),integer_vs_fp_psnr=-10*np.log10(max(vsfp,1e-12)),
                integer_vs_qat_mae_lsb=(yit-yq).abs().mean().item()*255,
                pixel_mae_from_input=(yit-x).abs().mean().item()))
            if i<8:
                for col,(label,y) in enumerate([('Input',x),('Teacher',yt),('FP student',yf),('QAT student',yq),('Integer',yit)]):
                    im=Image.fromarray((y[0].permute(1,2,0).cpu().numpy()*255).round().clip(0,255).astype('uint8'))
                    sheet.paste(im,(col*256,i*280+24));draw.text((col*256+4,i*280+4),label,fill='black')
            if (i+1)%8==0:print(f'EVALUATION {i+1}/{a.count} seconds={time.monotonic()-start:.1f}',flush=True)
    sheet.save(a.out/'heldout_comparison.png')
    metrics={k:float(np.mean([r[k] for r in rows])) for k in rows[0] if k!='path'}
    metrics['style_error_reduction']=1-metrics['integer_style_mse']/metrics['original_style_mse']
    # Independent synthetic translation check at a multiple of encoder stride.
    rgb=np.asarray(Image.open(root/paths[0]).convert('RGB').resize((640,480),Image.Resampling.BICUBIC))
    yi=net(rgb);Image.fromarray(np.concatenate([rgb,yi],axis=1)).save(a.out/'vga_demo.png')
    shifted=np.roll(rgb,4,axis=1);ys=net(shifted)
    metrics['synthetic_shift4_mae_lsb']=float(np.abs(ys[48:-48,52:-48].astype(float)-yi[48:-48,48:-52].astype(float)).mean())
    report=dict(count=a.count,split='test, reserved before any training; deterministic spread over filenames',
        metrics=metrics,items=rows,manifest_sha256=hashlib.sha256(a.manifest.read_bytes()).hexdigest(),
        qat_checkpoint_sha256=hashlib.sha256(a.qat.read_bytes()).hexdigest(),
        limitations=['single Monet style; style Gram distance is not subjective quality ground truth',
            'source photos 256x256; VGA images resized, not native camera validation',
            'dHash grouping is not exhaustive scene-leakage or provenance certification',
            'synthetic translation does not establish real video flicker performance'])
    (a.out/'metrics.json').write_text(json.dumps(report,indent=2));print(json.dumps(metrics,indent=2))
if __name__=='__main__':main()
