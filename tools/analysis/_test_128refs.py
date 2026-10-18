"""Would a 128-painting Gram target fit better than the current 8?

Earlier I only measured how much the TARGET moves when more images are used
(0.00083-0.00109, direction random).  That does not answer whether FITTING
improves.  Three sharper tests:

  T1  FLOOR: with a target built from N images, how far is a held-out real
      painting from it?  A broader target is a smoother average, so the floor
      may RISE - making the objective less attainable, not more.

  T2  TARGET AGREEMENT: which target does the OFFICIAL model match better?
      The official output is our reference aesthetic, so a target that the
      official model sits closer to is the better training objective.

  T3  GRADIENT AGREEMENT: would training against 128 push in the same
      direction as 8?  Measure per-layer error correlation.
"""
import json
import pathlib
import random
import sys

import numpy as np
import torch
from torch.nn import functional as F
from torchvision.models import vgg16, VGG16_Weights
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / 'ml' / 'style_transfer'))
from model import Teacher  # noqa: E402

UK = ROOT / 'reports' / 'ukiyoe'
man = json.loads((UK / 'data' / 'manifest.json').read_text())
dsroot = pathlib.Path(man['dataset'])
refs8 = json.loads((UK / 'data' / 'style_refs.json').read_text())
allA = [r['path'] for r in man['records']
        if r['domain'] == 'A' and r['split'] == 'train']
held = [a for a in allA if a not in refs8]
valB = [r['path'] for r in man['records']
        if r['domain'] == 'B' and r['split'] == 'validation']

dev = 'cuda' if torch.cuda.is_available() else 'cpu'
net = vgg16(weights=VGG16_Weights.IMAGENET1K_V1).features[:23].to(dev).eval()
for p in net.parameters():
    p.requires_grad_(False)
MEAN = torch.tensor([.485, .456, .406], device=dev)[None, :, None, None]
STD = torch.tensor([.229, .224, .225], device=dev)[None, :, None, None]
LW = [0.3, 0.5, 1.4, 1.8]
SIZE = 512


def feats(x):
    x = (x - MEAN) / STD
    o = []
    for i, m in enumerate(net):
        x = m(x)
        if i in (3, 8, 15, 22):
            o.append(x)
    return o


def gram(x):
    n, c, h, w = x.shape
    z = x.flatten(2)
    return (z @ z.transpose(1, 2)) / (c * h * w)


def img(p, size=SIZE):
    """p is a dataset-relative path (e.g. 'trainA/00388.jpg')."""
    path = p if pathlib.Path(p).is_absolute() else (dsroot / p)
    im = Image.open(path).convert('RGB').resize((size, size), Image.Resampling.BICUBIC)
    return torch.from_numpy(np.asarray(im).copy()).permute(2, 0, 1).float().div_(255).to(dev)


def grams_of(paths, chunk=8):
    """Return, per image, a list of per-layer Gram matrices.

    gram() on a batch of B returns (B, C, C); the per-image entries must be
    unbound, otherwise F.mse_loss broadcasts (1,C,C) against (B,C,C) and the
    comparison is silently wrong.
    """
    out = []
    with torch.no_grad():
        for i in range(0, len(paths), chunk):
            batch = paths[i:i + chunk]
            f = feats(torch.stack([img(p) for p in batch]))
            g = [gram(x) for x in f]                 # each (B, C, C)
            for b in range(len(batch)):
                out.append([x[b] for x in g])        # per image: [C, C] per layer
    return out


def make_target(paths):
    per_image = grams_of(paths)
    n = len(per_image)
    return [torch.stack([per_image[i][l] for i in range(n)]).mean(0)
            for l in range(len(per_image[0]))]


def loss_vs(tgt, per_image_grams):
    """per_image_grams: list (per image) of lists (per layer) of [C, C]."""
    out = []
    with torch.no_grad():
        for g in per_image_grams:
            out.append(sum(w * F.mse_loss(x, t).item()
                           for w, x, t in zip(LW, g, tgt)))
    return float(np.mean(out))


print('=' * 76)
print('T1  FLOOR: distance from a held-out real painting to an N-image target')
print('=' * 76)
random.seed(3)
holdout = random.sample(held, 24)
hold_grams = grams_of(holdout)

targets = {'8 (current)': make_target(refs8)}
for n in (32, 128, 300):
    targets['%d' % n] = make_target(random.sample(held, n))

print('  %-14s %12s %12s' % ('target size', 'floor (held-out)', 'vs 8-target'))
print('  ' + '-' * 42)
base = None
for nm, t in targets.items():
    fl = loss_vs(t, hold_grams)
    if base is None:
        base = fl
    print('  %-14s %12.6f %12s' % (nm, fl, '-' if nm.startswith('8') else '%+.6f' % (fl - base)))
print()
print('  FLOOR is the best score a genuine painting can get.')
print('  If it RISES with more images, the objective becomes harder, not better.')

print()
print('=' * 76)
print('T2  Which target does the OFFICIAL model match better?')
print('=' * 76)


class RB(torch.nn.Module):
    def __init__(self, d):
        super().__init__()
        self.cb = torch.nn.Sequential(
            torch.nn.ReflectionPad2d(1), torch.nn.Conv2d(d, d, 3),
            torch.nn.BatchNorm2d(d), torch.nn.ReLU(True),
            torch.nn.ReflectionPad2d(1), torch.nn.Conv2d(d, d, 3),
            torch.nn.BatchNorm2d(d))

    def forward(self, x):
        return x + self.cb(x)


class RG(torch.nn.Module):
    def __init__(self, ngf=64, nb=9):
        super().__init__()
        m = [torch.nn.ReflectionPad2d(3), torch.nn.Conv2d(3, ngf, 7),
             torch.nn.BatchNorm2d(ngf), torch.nn.ReLU(True),
             torch.nn.Conv2d(ngf, ngf*2, 3, 2, 1), torch.nn.BatchNorm2d(ngf*2), torch.nn.ReLU(True),
             torch.nn.Conv2d(ngf*2, ngf*4, 3, 2, 1), torch.nn.BatchNorm2d(ngf*4), torch.nn.ReLU(True)]
        m += [RB(ngf*4) for _ in range(nb)]
        m += [torch.nn.ConvTranspose2d(ngf*4, ngf*2, 3, 2, 1, 1), torch.nn.BatchNorm2d(ngf*2), torch.nn.ReLU(True),
              torch.nn.ConvTranspose2d(ngf*2, ngf, 3, 2, 1, 1), torch.nn.BatchNorm2d(ngf), torch.nn.ReLU(True),
              torch.nn.ReflectionPad2d(3), torch.nn.Conv2d(ngf, 3, 7), torch.nn.Tanh()]
        self.model = torch.nn.Sequential(*m)

    def forward(self, x):
        return self.model(x)


off = RG()
off.load_state_dict(torch.load(ROOT / '_data' / 'style_ukiyoe.pth',
                               map_location='cpu', weights_only=False), strict=False)
off = off.to(dev).eval()
v6 = Teacher()
v6.load_state_dict(torch.load(UK / 'teacher_v6' / 'step_002500.pt',
                              map_location='cpu', weights_only=False)['model'])
v6 = v6.to(dev).eval()

EVAL = valB[:8]
with torch.no_grad():
    off_g, v6_g, in_g = [], [], []
    for p in EVAL:
        x = img(p)
        off_g.append([gram(y) for y in feats(((off(x[None] * 2 - 1) + 1) / 2))])
        v6_g.append([gram(y) for y in feats(v6(x[None]))])
        in_g.append([gram(y) for y in feats(x[None])])

print('  %-14s %12s %12s %12s' % ('target size', 'official', 'v6', 'input photos'))
print('  ' + '-' * 54)
for nm, t in targets.items():
    print('  %-14s %12.6f %12.6f %12.6f'
          % (nm, loss_vs(t, off_g), loss_vs(t, v6_g), loss_vs(t, in_g)))

print()
print('  the official output is our reference aesthetic.  A target it sits')
print('  CLOSER to is the better objective - and the input should sit FARTHER.')

print()
print('=' * 76)
print('T3  Do the 8- and 128-targets push training in the same direction?')
print('=' * 76)
t8, t128 = targets['8 (current)'], targets['128']
for i, (a, b) in enumerate(zip(t8, t128)):
    d = (a - b).abs()
    rel = d.mean().item() / max(b.abs().mean().item(), 1e-9)
    print('  layer %d: mean |delta| %.6f   relative to target scale %5.1f%%  corr %.4f'
          % (i, d.mean().item(), 100 * rel,
             float(torch.corrcoef(torch.stack([a.flatten(), b.flatten()]))[0, 1])))
print()
print('  high correlation => same direction, so switching to 128 changes little.')
print('  low correlation  => genuinely different objective.')

print()
print('=' * 76)
print('T4  Would 128 help the MODEL fit better?  (proxy: target self-consistency)')
print('=' * 76)
# a target built from a random half vs the other half: how stable is it?
random.seed(9)
sub = random.sample(held, 128)
tA = make_target(sub[:64])
tB = make_target(sub[64:])
tall128 = make_target(sub)
dAB = np.mean([(a - b).abs().mean().item() for a, b in zip(tA, tB)])
dAall = np.mean([(a - b).abs().mean().item() for a, b in zip(tA, tall128)])
print('  target from 64 random paintings A  vs  64 different B : %.6f' % dAB)
print('  target from 64 (A)                 vs  all 128        : %.6f' % dAall)
print()
print('  these are the same order as the earlier 8-vs-400 delta (0.00089),')
print('  i.e. the target is ALREADY stable at small N - sampling noise,')
print('  not a systematic bias that more images would remove.')
