"""Perceptual teacher / deployment student training. Test data never enter training."""
import argparse, hashlib, json, random, time
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
import torch
from torch import nn
from torch.nn import functional as F
from torchvision.models import vgg16, VGG16_Weights
from model import Teacher, Student


class Features(nn.Module):
    def __init__(self):
        super().__init__(); self.net=vgg16(weights=VGG16_Weights.IMAGENET1K_V1).features[:23].eval()
        self.net.requires_grad_(False)
        self.register_buffer('mean',torch.tensor([.485,.456,.406])[None,:,None,None])
        self.register_buffer('std',torch.tensor([.229,.224,.225])[None,:,None,None])
    def forward(self,x):
        x=(x-self.mean)/self.std; out=[]
        for i,m in enumerate(self.net):
            x=m(x)
            if i in (3,8,15,22): out.append(x)
        return out


def gram(x):
    with torch.autocast('cuda',enabled=False):
        n,c,h,w=x.shape; z=x.flatten(2).float(); return (z@z.transpose(1,2))/(c*h*w)


def image_tensor(path,size=256):
    im=Image.open(path).convert('RGB').resize((size,size),Image.Resampling.BICUBIC)
    return torch.from_numpy(np.asarray(im).copy()).permute(2,0,1).float()/255


class Photos(torch.utils.data.Dataset):
    def __init__(self,root,paths): self.root,self.paths=root,paths
    def __len__(self): return len(self.paths)
    def __getitem__(self,i):
        x=image_tensor(self.root/self.paths[i]); return x.flip(2) if random.random()<.5 else x


@torch.no_grad()
def evaluate(model,features,target,root,paths,out,step,teacher=None):
    model.eval(); items=[]; images=[]
    for name in paths:
        x=image_tensor(root/name)[None].cuda(); y=model(x); xf=features(x); yf=features(y)
        content=F.mse_loss(yf[2],xf[2]).item()
        style=sum(F.mse_loss(gram(a),b).item() for a,b in zip(yf,target))
        original=sum(F.mse_loss(gram(a),b).item() for a,b in zip(xf,target))
        d={'path':name,'content_feature_mse':content,'style_gram_mse':style,'original_style_mse':original,
           'pixel_mae_from_input':(y-x).abs().mean().item()}
        if teacher is not None: d['teacher_mae']=(y-teacher(x)).abs().mean().item()
        items.append(d); images.extend([x[0].cpu(),y[0].cpu()])
    sheet=Image.new('RGB',(4*256,((len(images)+3)//4)*280),'white'); draw=ImageDraw.Draw(sheet)
    for i,t in enumerate(images):
        sheet.paste(Image.fromarray((t.permute(1,2,0).numpy()*255).round().clip(0,255).astype('uint8')),(i%4*256,i//4*280+24))
        draw.text((i%4*256+4,i//4*280+4),'Input' if i%2==0 else f'Output step {step}',fill='black')
    sheet.save(out/f'validation_{step:06d}.png')
    report={'step':step,'content_feature_mse':np.mean([i['content_feature_mse'] for i in items]),
        'style_gram_mse':np.mean([i['style_gram_mse'] for i in items]),
        'original_style_mse':np.mean([i['original_style_mse'] for i in items]),'items':items}
    (out/f'validation_{step:06d}.json').write_text(json.dumps(report,indent=2)); return report


def main():
    p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--kind',choices=['teacher','student'],required=True)
    p.add_argument('--teacher',type=Path);p.add_argument('--resume',type=Path);p.add_argument('--steps',type=int,default=2000)
    p.add_argument('--batch',type=int,default=8);p.add_argument('--qat-after',type=int,default=1500)
    p.add_argument('--scales',type=Path);p.add_argument('--lr',type=float,default=1e-3)
    p.add_argument('--reference-student',type=Path)
    p.add_argument('--content-weight',type=float,default=1)
    p.add_argument('--style-weight',type=float,default=1500)
    p.add_argument('--distill-weight',type=float,default=5)
    p.add_argument('--validate-every',type=int,default=250); a=p.parse_args()
    torch.set_num_threads(8); random.seed(20261012);np.random.seed(20261012);torch.manual_seed(20261012)
    torch.backends.cudnn.benchmark=True; torch.backends.cuda.matmul.allow_tf32=True
    a.out.mkdir(parents=True,exist_ok=True); manifest=json.loads(a.manifest.read_text()); root=Path(manifest['dataset'])
    train=[r['path'] for r in manifest['records'] if r['domain']=='B' and r['split']=='train']
    val=[r['path'] for r in manifest['records'] if r['domain']=='B' and r['split']=='validation']
    val=[val[i*(len(val)-1)//7] for i in range(8)]
    refs=json.loads((a.manifest.parent/'style_refs.json').read_text())
    features=Features().cuda()
    with torch.no_grad():
        target=[g.mean(0,keepdim=True) for g in [gram(f) for f in features(torch.stack([image_tensor(root/n) for n in refs]).cuda())]]
    model=(Teacher() if a.kind=='teacher' else Student()).cuda();teacher=None
    if a.teacher:
        teacher=Teacher().cuda().eval();teacher.load_state_dict(torch.load(a.teacher,weights_only=False)['model']);teacher.requires_grad_(False)
    if a.reference_student:
        teacher=Student().cuda().eval();teacher.load_state_dict(torch.load(a.reference_student,weights_only=False)['model']);teacher.requires_grad_(False)
    if a.resume: model.load_state_dict(torch.load(a.resume,weights_only=False)['model'])
    activation_scales=json.loads(a.scales.read_text())['scales'] if a.scales else None
    if activation_scales:model.set_scales(activation_scales)
    opt=torch.optim.Adam(model.parameters(),lr=a.lr)
    loader=torch.utils.data.DataLoader(Photos(root,train),batch_size=a.batch,shuffle=True,num_workers=4,pin_memory=True,persistent_workers=True)
    iterator=iter(loader); log=(a.out/'train.jsonl').open('a'); start=time.monotonic()
    config=vars(a).copy();config={k:str(v) if isinstance(v,Path) else v for k,v in config.items()}
    config.update(torch=torch.__version__,device=torch.cuda.get_device_name(),manifest_sha256=hashlib.sha256(a.manifest.read_bytes()).hexdigest(),style_refs=refs,
        activation_scales=activation_scales,
        parameters=sum(p.numel() for p in model.parameters()),loss=f'{a.content_weight}*content VGG relu3_3 + {a.style_weight}*sum Gram + .03 TV + {a.distill_weight}*reference L1')
    (a.out/'config.json').write_text(json.dumps(config,indent=2))
    evaluate(model,features,target,root,val,a.out,0,teacher)
    scaler=torch.amp.GradScaler('cuda')
    for step in range(1,a.steps+1):
        model.train()
        qat=a.kind=='student' and step>=a.qat_after
        if a.kind=='student':
            model.set_qat(qat)
            if qat:
                for m in model.modules():
                    if isinstance(m,nn.BatchNorm2d): m.eval()
        try: x=next(iterator).cuda(non_blocking=True)
        except StopIteration: iterator=iter(loader); x=next(iterator).cuda(non_blocking=True)
        with torch.autocast('cuda',dtype=torch.float16):
            with torch.no_grad(): xf=features(x); t=teacher(x) if teacher else None
            y=model(x); yf=features(y)
            content=F.mse_loss(yf[2].float(),xf[2].float())
            style=sum(F.mse_loss(gram(f),g.expand(f.shape[0],-1,-1)) for f,g in zip(yf,target))
            tv=(y[:,:,1:,:]-y[:,:,:-1,:]).abs().mean()+(y[:,:,:,1:]-y[:,:,:,:-1]).abs().mean()
            distill=F.l1_loss(y,t) if t is not None else y.new_zeros(())
            loss=a.content_weight*content+a.style_weight*style+.03*tv+a.distill_weight*distill
        if not torch.isfinite(loss): raise RuntimeError(f'Nonfinite loss at step {step}')
        opt.zero_grad(set_to_none=True);scaler.scale(loss).backward();scaler.unscale_(opt)
        nn.utils.clip_grad_norm_(model.parameters(),10);scaler.step(opt);scaler.update()
        lr=a.lr*(.1+.9*(1-step/a.steps));
        for group in opt.param_groups: group['lr']=lr
        if step%25==0 or step==1:
            row={'step':step,'loss':float(loss.detach()),'content':float(content.detach()),'style':float(style.detach()),
                'distill':float(distill.detach()),'qat':qat,'seconds':time.monotonic()-start}
            log.write(json.dumps(row)+'\n');log.flush();print(json.dumps(row),flush=True)
        if step%a.validate_every==0 or step==a.steps:
            ck={'model':model.state_dict(),'step':step,'kind':a.kind,'qat':qat,'config':config,'optimizer':opt.state_dict(),'scaler':scaler.state_dict()}
            torch.save(ck,a.out/'latest.pt');torch.save(ck,a.out/f'step_{step:06d}.pt')
            report=evaluate(model,features,target,root,val,a.out,step,teacher)
            print('VALIDATION '+json.dumps({k:v for k,v in report.items() if k!='items'}),flush=True)
    log.close()

if __name__=='__main__': main()
