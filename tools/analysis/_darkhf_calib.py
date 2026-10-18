"""Calibrate the dark-hf target using the LOSS'S OWN formula, and test separation.

My earlier target (0.0407) was measured with a DIFFERENT statistic than the loss
computes:
    diagnostic : mean(|hf|) with a QUANTILE threshold, in LSB
    loss       : std(hf)    with an ABSOLUTE threshold, in [0,1]
That is the same aggregation-mismatch class of error that broke v13 (batch
pooling), the official reconstruction, and the elongation statistic.  Fix it by
measuring the target with the exact loss formula.

Also quantify the domain separation with that exact statistic (with a Welch t),
since the earlier "1.93 vs 1.19" figure came from the other statistic.

CPU only.
"""
import json
import math
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


def dark_hf_batch(t, thr_lsb, k):
    """EXACTLY the loss computation.  t: (N,3,H,W) in [0,1]."""
    L = 0.299 * t[:, 0:1] + 0.587 * t[:, 1:2] + 0.114 * t[:, 2:3]
    lo = F.avg_pool2d(L, k)
    hi = L - F.interpolate(lo, size=L.shape[-2:], mode='nearest')
    m = (L.detach() < thr_lsb / 255.0).float()
    n = m.sum(dim=[2, 3]).clamp_min(1.0)
    mu = (hi * m).sum(dim=[2, 3]) / n
    var = (((hi - mu[:, :, None, None]) ** 2) * m).sum(dim=[2, 3]) / n
    lvl = var.clamp_min(0.0).sqrt().flatten(1).mean(dim=1)
    return lvl, m.mean()          # per-image value, and mask coverage


def load_t(paths):
    a = [np.asarray(Image.open(dsroot / p).convert('RGB').resize(
        (SIZE, SIZE), Image.Resampling.BICUBIC)) for p in paths]
    return torch.stack([torch.from_numpy(x.astype(np.float32) / 255).permute(2, 0, 1)
                        for x in a])


A = [r['path'] for r in man['records']
     if r['domain'] == 'A' and r['split'] == 'train']
AV = [r['path'] for r in man['records']
      if r['domain'] == 'A' and r['split'] == 'validation']
B = [r['path'] for r in man['records']
     if r['domain'] == 'B' and r['split'] == 'validation']
random.seed(0)
At = load_t(random.sample(A, 128))
AVt = load_t(AV)                                  # ALL 185 validation paintings
Bt = load_t(random.sample(B, 128))
print('samples: %d A/train, %d A/validation (all), %d B/validation'
      % (At.shape[0], AVt.shape[0], Bt.shape[0]))

print()
print('=' * 88)
print('DARK-HF MEASURED WITH THE LOSS\'S OWN FORMULA')
print('=' * 88)
print('  %-24s %12s %12s %12s' % ('source', 'dark-hf', 'LSB', 'mask cov'))
print('  ' + '-' * 62)
vals = {}
for nm, t in (('A/train (ink)', At), ('A/validation (ink)', AVt),
              ('B/validation (photo)', Bt)):
    lv, cov = dark_hf_batch(t, 90.0, 4)
    vals[nm] = lv
    print('  %-24s %12.4f %12.2f %11.1f%%'
          % (nm, float(lv.mean()), float(lv.mean()) * 255, 100 * float(cov)))

print()
print('  comparison with the OTHER statistic used earlier (mean|hf|, quantile):')
print('    that one gave ink 1.93x photo; the loss formula gives a different ratio.')
ink = vals['A/validation (ink)'].numpy()
ph = vals['B/validation (photo)'].numpy()
tr = vals['A/train (ink)'].numpy()
print()
print('  %-28s %10s %10s %9s %8s' % ('pair', 'mean', 'std', 'ratio', 't'))
print('  ' + '-' * 70)


def welch(x, y):
    vx, vy = x.var(ddof=1) / len(x), y.var(ddof=1) / len(y)
    t = (y.mean() - x.mean()) / math.sqrt(float(vx + vy) if False else float(vx + vy))
    return t, math.erfc(abs(t) / math.sqrt(2))


for nm, x, y in (('A/val vs B/val', ink, ph),
                 ('A/train vs B/val', tr, ph)):
    t, p = welch(x, y)
    print('  %-28s %10.4f %10.4f %9.3f %8.1f'
          % (nm, x.mean(), y.mean(), x.mean() / max(y.mean(), 1e-9), t))

print()
print('=' * 88)
print('THE TARGET (by construction = the ink level)')
print('=' * 88)
tgt = float(ink.mean())
print('  ink A/validation  mean %.4f  median %.4f  p10 %.4f  p90 %.4f'
      % (ink.mean(), np.median(ink), np.percentile(ink, 10), np.percentile(ink, 90)))
print('  ink A/train       mean %.4f' % tr.mean())
print()
print('  -> use --dark-hf-target %.4f  (ink validation mean, loss formula)' % tgt)
print('  the earlier 0.0407 was measured with a DIFFERENT statistic and is WRONG.')
print()
gap = 100 * (ink.mean() / max(ph.mean(), 1e-9) - 1)
print('  separation with the loss formula: %.1f%%' % gap)
if gap > 10:
    print('  -> usable: the target sits above the photo level, so pushing toward')
    print('     it moves the output AWAY from photo texture.')
else:
    print('  -> WEAK separation; the term may not distinguish the domains.')
print()
print('  NOTE: because the two domains differ by only %.0f%%, the term is best' % gap)
print('  used as a FLOOR (restore destroyed texture), and the target should sit')
print('  at the ink level so the two goals coincide.')
