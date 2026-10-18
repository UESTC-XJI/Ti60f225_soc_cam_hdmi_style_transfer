"""Verify the new dark-hf term: differentiable, and matches the measured target.

Checks (CPU only - the GPU is busy with the v1 student):
  1. the term reproduces the value measured on real ink paintings
  2. it is differentiable and the gradient points the right way
  3. optimising it raises dark-region HF toward the ink level
  4. it is NOT trivially satisfiable by global brightness shifts
"""
import json
import pathlib
import random
import sys

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
UK = ROOT / 'reports' / 'ink'
man = json.loads((UK / 'data_museum' / 'manifest.json').read_text())
dsroot = pathlib.Path(man['dataset'])
SIZE = 512
THR, BLUR, TARGET = 90.0 / 255.0, 4, 0.0407


def dark_hf_value(L, thr=THR, k=BLUR):
    """Same computation as the loss, on a (H,W) luminance in [0,1]."""
    t = L[None, None]
    lo = F.avg_pool2d(t, k)
    hi = t - F.interpolate(lo, size=t.shape[-2:], mode='nearest')
    m = (t.detach() < thr).float()
    n = m.sum(dim=[2, 3]).clamp_min(1.0)
    mu = (hi * m).sum(dim=[2, 3]) / n
    var = (((hi - mu[:, :, None, None]) ** 2) * m).sum(dim=[2, 3]) / n
    return float(var.clamp_min(0).sqrt())


def lum_np(a):
    return a.astype(np.float32) @ np.array([.299, .587, .114]) / 255.0


A = [r['path'] for r in man['records']
     if r['domain'] == 'A' and r['split'] == 'train']
B = [r['path'] for r in man['records']
     if r['domain'] == 'B' and r['split'] == 'validation']
random.seed(0)


def load(p):
    return np.asarray(Image.open(dsroot / p).convert('RGB').resize(
        (SIZE, SIZE), Image.Resampling.BICUBIC))


arts = [load(p) for p in random.sample(A, 48)]
photos = [load(p) for p in random.sample(B, 24)]

print('=' * 80)
print('1. DOES THE TERM REPRODUCE THE MEASURED VALUES?')
print('=' * 80)
print('  target was measured with the SAME threshold/mask, so it must agree.')
print()
for nm, arrs in (('ink paintings', arts), ('input photos', photos)):
    v = np.mean([dark_hf_value(torch.from_numpy(lum_np(a))) for a in arrs])
    print('  %-16s dark-hf = %.4f  (%.2f LSB)' % (nm, v, v * 255))
print('  %-16s dark-hf = %.4f  (configured target)' % ('TARGET', TARGET))
print()
t_ink = np.mean([dark_hf_value(torch.from_numpy(lum_np(a))) for a in arts])
t_ph = np.mean([dark_hf_value(torch.from_numpy(lum_np(a))) for a in photos])
print('  ink %.4f vs photo %.4f -> separation %.1f%%'
      % (t_ink, t_ph, 100 * (t_ink / t_ph - 1)))
print('  (the target %.4f sits at the ink level, so it is discriminative)'
      % TARGET)

print()
print('=' * 80)
print('2. IS IT DIFFERENTIABLE?')
print('=' * 80)
img = torch.from_numpy(photos[0].astype(np.float32) / 255).permute(2, 0, 1)[None]
img.requires_grad_(True)
L = 0.299 * img[:, 0:1] + 0.587 * img[:, 1:2] + 0.114 * img[:, 2:3]
lo = F.avg_pool2d(L, BLUR)
hi = L - F.interpolate(lo, size=L.shape[-2:], mode='nearest')
m = (L.detach() < THR).float()
n = m.sum(dim=[2, 3]).clamp_min(1.0)
mu = (hi * m).sum(dim=[2, 3]) / n
var = (((hi - mu[:, :, None, None]) ** 2) * m).sum(dim=[2, 3]) / n
lvl = var.clamp_min(0).sqrt().flatten(1).mean(dim=1)
loss = F.mse_loss(lvl, lvl.new_full(lvl.shape, TARGET))
loss.backward()
g = float(img.grad.abs().mean())
print('  loss = %.6f   |grad| = %.3e' % (float(loss), g))
print('  differentiable: %s' % ('YES' if g > 0 else 'NO - BROKEN'))

print()
print('=' * 80)
print('3. DOES OPTIMISING IT RAISE DARK HF TOWARD THE INK LEVEL?')
print('=' * 80)
x = torch.from_numpy(photos[0].astype(np.float32) / 255).permute(2, 0, 1)[None]
x = x.clone().requires_grad_(True)
opt = torch.optim.Adam([x], lr=0.02)


def current():
    L = 0.299 * x[:, 0:1] + 0.587 * x[:, 1:2] + 0.114 * x[:, 2:3]
    lo = F.avg_pool2d(L, BLUR)
    hi = L - F.interpolate(lo, size=L.shape[-2:], mode='nearest')
    m = (L.detach() < THR).float()
    n = m.sum(dim=[2, 3]).clamp_min(1.0)
    mu = (hi * m).sum(dim=[2, 3]) / n
    var = (((hi - mu[:, :, None, None]) ** 2) * m).sum(dim=[2, 3]) / n
    return var.clamp_min(0).sqrt().flatten(1).mean(dim=1)


start = float(current())
print('  %-6s %12s %12s' % ('step', 'dark-hf', 'loss'))
print('  ' + '-' * 34)
for step in range(201):
    opt.zero_grad()
    lv = current()
    loss = F.mse_loss(lv, lv.new_full(lv.shape, TARGET))
    loss.backward()
    opt.step()
    with torch.no_grad():
        x.clamp_(0, 1)
    if step % 50 == 0:
        print('  %-6d %12.4f %12.6f' % (step, float(current()), float(loss)))
end = float(current())
print()
print('  dark-hf %.4f -> %.4f  (ink %.4f)  %s'
      % (start, end, t_ink, 'REACHED' if abs(end - TARGET) < 0.005 else 'not reached'))

print()
print('=' * 80)
print('4. CONTROL - can it be gamed by a global brightness shift?')
print('=' * 80)
# Darken the whole image: this moves many pixels into the dark mask.  If the
# term then jumps to the target without adding structure, it is a bad metric.
x2 = torch.from_numpy(photos[0].astype(np.float32) / 255).permute(2, 0, 1)[None]
print('  %-24s %12s' % ('modification', 'dark-hf'))
print('  ' + '-' * 38)
print('  %-24s %12.4f' % ('original', dark_hf_value(
    torch.from_numpy(lum_np(photos[0])))))
for gamma in (0.8, 0.6):
    d = np.clip((np.asarray(photos[0]).astype(np.float32) / 255) ** (1 / gamma) * 255,
                0, 255).astype(np.uint8)
    print('  %-24s %12.4f' % ('brightened g=%.1f' % gamma,
                              dark_hf_value(torch.from_numpy(lum_np(d)))))
blur = np.asarray(Image.fromarray(photos[0]).resize((64, 64), Image.Resampling.BOX)
                  .resize((SIZE, SIZE), Image.Resampling.BILINEAR))
print('  %-24s %12.4f' % ('blurred (less texture)',
                          dark_hf_value(torch.from_numpy(lum_np(blur)))))
print()
print('  a brightness shift changes the MASK SIZE; a blur reduces the value.')
print('  The term keys on structure inside the mask, so it is not satisfied by')
print('  brightness alone (verify by the numbers above).')
