"""Improved training: adds tone/contrast matching and low-frequency style weighting.

Why (measured on the ukiyo-e run):
  * official ukiyo-e output mean RGB is (137.5,128.4,113.1); ours was
    (104.0,104.2,102.5) -- a 22.7 LSB tone gap.
  * VGG features are mean/std normalised, so Gram loss is BLIND to a global
    brightening.  That is why our teacher had better Gram (0.595 vs 0.618)
    but only 59% of the official pixel intensity.
  * our style delta put 6.9% of its energy above the board's 4x cutoff
    (official: 1.2%).  Weighting the deeper VGG layers moves energy into the
    band the FPGA can actually display.

This is a wrapper: it imports the original train.py and replaces only the loss
computation and the feature weighting, so the tracked file stays untouched.
Run it exactly like train.py.
"""
import argparse
import hashlib
import json
import pathlib
import random
import sys
import time

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch import nn
from torch.nn import functional as F
from torchvision.models import vgg16, VGG16_Weights

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent # repo root (moved to tools/analysis)
sys.path.insert(0, str(ROOT / 'ml' / 'style_transfer'))
from model import Teacher, Student, fake  # noqa: E402

# VGG layer indices inside features[:23]: 3->relu1_2, 8->relu2_2,
# 15->relu3_3, 22->relu4_3.  Layer weights default to favour the deeper
# (larger-scale) layers that survive the board's 160x120 bottleneck.
LAYER_WEIGHTS = [0.3, 0.5, 1.4, 1.8]


class Features(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = vgg16(weights=VGG16_Weights.IMAGENET1K_V1).features[:23].eval()
        self.net.requires_grad_(False)
        self.register_buffer('mean', torch.tensor([.485, .456, .406])[None, :, None, None])
        self.register_buffer('std', torch.tensor([.229, .224, .225])[None, :, None, None])

    def forward(self, x):
        x = (x - self.mean) / self.std
        out = []
        for i, m in enumerate(self.net):
            x = m(x)
            if i in (3, 8, 15, 22):
                out.append(x)
        return out


def gram(x):
    with torch.autocast('cuda', enabled=False):
        n, c, h, w = x.shape
        z = x.flatten(2).float()
        return (z @ z.transpose(1, 2)) / (c * h * w)


def image_tensor(path, size=256):
    im = Image.open(path).convert('RGB').resize((size, size), Image.Resampling.BICUBIC)
    return torch.from_numpy(np.asarray(im).copy()).permute(2, 0, 1).float() / 255


class Photos(torch.utils.data.Dataset):
    def __init__(self, root, paths):
        self.root, self.paths = root, paths

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, i):
        x = image_tensor(self.root / self.paths[i], TRAIN_SIZE)
        return x.flip(2) if random.random() < .5 else x


# set from --size; module level so Photos/eval share it
TRAIN_SIZE = 256


def style_stats(paths, root, size=None):
    """Per-channel mean/std of the style reference paintings, in [0,1]."""
    size = size or TRAIN_SIZE
    ims = [image_tensor(root / n, size) for n in paths]
    s = torch.stack(ims)
    return s.mean(dim=[0, 2, 3]), s.std(dim=[0, 2, 3])


# Quantiles of the OFFICIAL style_ukiyoe output, measured over 12 validation
# photos at 512x512 (see reports/analysis for the measurement script).  Used
# when --quantile-target=official.  Order: R per level; G; B.
OFFICIAL_QUANTILES = [
    [0.3608, 0.4667, 0.5922, 0.6941, 0.8118],
    [0.3176, 0.4431, 0.5686, 0.6431, 0.7569],
    [0.2902, 0.3843, 0.5059, 0.5843, 0.6667],
]


def style_quantiles(paths, root, levels, size=None):
    """Per-channel quantiles of the style reference paintings.

    Quantiles carry distribution shape, which a mean cannot.  Matching them is
    what lets the model move hue and compress the palette.
    """
    size = size or TRAIN_SIZE
    s = torch.stack([image_tensor(root / n, size) for n in paths])
    s = s.permute(1, 0, 2, 3).reshape(3, -1)          # (3, N) = (channels, pixels)
    q = torch.tensor([float(v) for v in levels])
    # torch.quantile(x, q, dim=-1) on a 2-D tensor returns the QUANTILE axis
    # first: (L, 3), not (3, L).  Build per channel to get exactly (3, L).
    return torch.stack([torch.quantile(s[c], q, dim=-1) for c in range(3)])


def soft_palette(y, centers, temp, max_pixels=8192):
    """Soft-quantised reconstruction of y, computed on a pixel SAMPLE.

    The full (b, N, k, 3) distance tensor is O(4 x 1M x 32 x 3) at 512x512 and
    made a training step 376x slower, so only `max_pixels` pixels are used.  The
    palette statistic is a global colour property, so a sample is sufficient.
    """
    b, c, h, w = y.shape
    z = y.permute(0, 2, 3, 1).reshape(b, -1, c)                      # (b, N, 3)
    n = z.shape[1]
    if n > max_pixels:
        idx = torch.randperm(n, device=z.device)[:max_pixels]
        z = z[:, idx]
    k = centers
    g = torch.linspace(0.05, 0.95, k, device=y.device, dtype=z.dtype)
    grid = torch.stack(torch.meshgrid(g, g, g, indexing='ij'), -1).reshape(-1, 3)
    if grid.shape[0] > k:
        gi = torch.linspace(0, grid.shape[0] - 1, k).long().to(z.device)
        grid = grid[gi]
    d = ((z[:, :, None, :] - grid[None, None]) ** 2).sum(-1)          # (b, S, k)
    a = torch.softmax(-d / max(temp, 1e-6), dim=-1)
    rec = (a[..., None] * grid[None, None]).sum(-2)                   # (b, S, 3)
    return rec, z


def tone_targets(root, content_paths):
    """Derive a CONTENT-RELATIVE tone target from the style references.

    An absolute mean target destroys the input-dependent brightness the style
    model should keep (a night scene must stay dark).  Measured on the official
    ukiyo-e model: out_mean = 0.859 * in_mean + 45.6, i.e. a roughly constant
    +32 LSB offset with a mild contrast reduction.  So target an OFFSET and a
    contrast ratio, both relative to each input.
    """
    with torch.no_grad():
        refs = torch.stack([image_tensor(root / n, TRAIN_SIZE) for n in content_paths])
        cmean = refs.mean(dim=[0, 2, 3])
        cstd = refs.std(dim=[0, 2, 3])
    return cmean, cstd


@torch.no_grad()
def evaluate(model, features, target, root, paths, out, step, teacher=None,
             style_mean=None, style_std=None):
    model.eval()
    items = []
    images = []
    for name in paths:
        x = image_tensor(root / name, TRAIN_SIZE)[None].cuda()
        y = model(x)
        xf = features(x)
        yf = features(y)
        content = F.mse_loss(yf[2], xf[2]).item()
        style = sum(w * F.mse_loss(gram(a), b).item()
                    for w, a, b in zip(LAYER_WEIGHTS, yf, target))
        original = sum(w * F.mse_loss(gram(a), b).item()
                       for w, a, b in zip(LAYER_WEIGHTS, xf, target))
        d = {'path': name, 'content_feature_mse': content,
             'style_gram_mse': style, 'original_style_mse': original,
             'pixel_mae_from_input': (y - x).abs().mean().item()}
        # palette metrics, to track the gap the official model closes
        with torch.no_grad():
            yo = y[0].permute(1, 2, 0)
            q8 = (yo.mul(255).round().clip(0, 255) // 8).to(torch.int32)
            key = q8[..., 0] * 1024 + q8[..., 1] * 32 + q8[..., 2]
            uniq = int(torch.unique(key).numel())
            cnt = torch.bincount(key.flatten(), minlength=32768).float()
            cnt = cnt[cnt > 0] / key.numel()
            d['distinct_colours'] = uniq
            d['colour_entropy'] = float(-(cnt * cnt.log2()).sum())
            L = (0.299 * yo[..., 0] + 0.587 * yo[..., 1] + 0.114 * yo[..., 2])
            z = torch.nn.functional.pad(L, (1, 1, 1, 1))
            win = z.unfold(0, 3, 1).unfold(1, 3, 1)
            d['flat_share'] = float(((win.max(dim=-1).values.max(dim=-1).values
                                      - win.min(dim=-1).values.min(dim=-1).values) < 3/255)
                                    .float().mean())
            # high-frequency (grain) level, 4x-blur high-pass std; the official
            # output measures 0.0484 and v6 measures 0.0383
            Lf = L[None, None]
            if Lf.shape[-1] >= 4 and Lf.shape[-2] >= 4:
                lo = F.avg_pool2d(Lf, 4)
                hi = Lf - F.interpolate(lo, size=Lf.shape[-2:], mode='nearest')
                d['grain_hf'] = float(hi.std())
                # per-channel mean, to check the warm cast
                d['out_mean_r'] = float(yo[..., 0].mean())
                d['out_mean_g'] = float(yo[..., 1].mean())
                d['out_mean_b'] = float(yo[..., 2].mean())
        if style_mean is not None:
            d['tone_mean_err'] = F.mse_loss(y.mean(dim=[2, 3]),
                                            style_mean[None]).item()
            d['tone_std_err'] = F.mse_loss(y.std(dim=[2, 3]),
                                           style_std[None]).item()
            d['out_mean'] = y.mean().item()
        if teacher is not None:
            d['teacher_mae'] = (y - teacher(x)).abs().mean().item()
        items.append(d)
        images.extend([x[0].cpu(), y[0].cpu()])
    sheet = Image.new('RGB', (4 * 256, ((len(images) + 3) // 4) * 280), 'white')
    draw = ImageDraw.Draw(sheet)
    for i, t in enumerate(images):
        sheet.paste(Image.fromarray(
            (t.permute(1, 2, 0).numpy() * 255).round().clip(0, 255).astype('uint8')),
            (i % 4 * 256, i // 4 * 280 + 24))
        draw.text((i % 4 * 256 + 4, i // 4 * 280 + 4),
                  'Input' if i % 2 == 0 else f'Output step {step}', fill='black')
    sheet.save(out / f'validation_{step:06d}.png')
    keys = [k for k in items[0] if k != 'path']
    report = {'step': step}
    for k in keys:
        report[k] = float(np.mean([i[k] for i in items]))
    (out / f'validation_{step:06d}.json').write_text(json.dumps(report, indent=2))
    return report


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--manifest', type=pathlib.Path, required=True)
    p.add_argument('--out', type=pathlib.Path, required=True)
    p.add_argument('--kind', choices=['teacher', 'student'], required=True)
    p.add_argument('--teacher', type=pathlib.Path)
    p.add_argument('--resume', type=pathlib.Path)
    p.add_argument('--steps', type=int, default=2000)
    p.add_argument('--batch', type=int, default=8)
    p.add_argument('--qat-after', type=int, default=1500)
    p.add_argument('--scales', type=pathlib.Path)
    p.add_argument('--lr', type=float, default=1e-3)
    p.add_argument('--reference-student', type=pathlib.Path)
    p.add_argument('--content-weight', type=float, default=1)
    p.add_argument('--style-weight', type=float, default=1500)
    p.add_argument('--distill-weight', type=float, default=5)
    # TV (total variation) penalises local differences, i.e. it SMOOTHS.
    # Measured: the official output keeps 117% of the input TV (it ADDS grain)
    # while our v6 keeps 87% (it REMOVES grain).  Real ukiyo-e prints sit at
    # 111% and have hf 13.82 vs our 9.64.  So a positive TV weight fights the
    # texture we are missing.  Kept as a parameter (default 0.03 = old value)
    # so the effect can be tested rather than assumed.
    p.add_argument('--tv-weight', type=float, default=0.03,
                   help='TV weight; 0 disables the smoothing term')
    # content-relative tone / contrast matching
    p.add_argument('--tone-weight', type=float, default=0)
    p.add_argument('--tone-offset', type=float, default=0.127,
                   help='target (out_mean - in_mean) in [0,1]; used when '
                        'tone-slope is 0')
    # AFFINE tone target: out_mean = tone-slope * in_mean + tone-bias.
    # Measured on the official style_ukiyoe model: out = 0.859*in + 0.179.
    # A pure constant offset over-brightens bright scenes, which was the cause
    # of the +16 LSB overshoot on the paper's poppy-field image.
    p.add_argument('--tone-slope', type=float, default=0.0,
                   help='affine slope; 0 disables and uses --tone-offset')
    p.add_argument('--tone-bias', type=float, default=0.0,
                   help='affine intercept in [0,1]')
    # A pure affine fit over-brightens DARK scenes: measured, an input at
    # Y=15 LSB maps to 49.8 with the official model but the affine target asks
    # for 63.7.  A quadratic fits the full range much better (R^2 0.980 vs
    # 0.963), so the official mapping is compressive at both ends.
    p.add_argument('--tone-quad', type=float, default=0.0,
                   help='quadratic coefficient; target = quad*in^2 '
                        '+ slope*in + bias.  Full-range fit: '
                        'quad=-0.638, slope=1.266, bias=0.128')
    p.add_argument('--contrast-ratio', type=float, default=0.86,
                   help='target out_std / in_std; official ~= 0.86.  RELATIVE, so '
                        'it can never suppress contrast below in_std*ratio.')
    # ABSOLUTE contrast target.  Needed for ink: the relative target ties the
    # output std to the INPUT photo's std, so it cannot reach the ink level.
    # Measured (160 paintings / 96 photos, trainer units x in [0,1]):
    #   photo std 0.1835 -> relative target 0.86*that = 0.1835 (46.8 LSB)
    #   INK   std 0.1176 (30.0 LSB)
    # i.e. the relative target is 56% too high, and contrast is the STRONGEST
    # domain discriminator (Welch t = -11.5).  When set > 0 this REPLACES the
    # relative term with an absolute per-channel std target.
    p.add_argument('--contrast-absolute', type=float, default=0.0,
                   help='absolute target for the output std in [0,1]; 0 uses the '
                        'relative --contrast-ratio instead.  Ink measured 0.1176.')
    # Per-channel warm cast.  Measured on the official model over 40 photos:
    #   R: out = 0.5668*in + 0.3701   (mean shift +51.9 LSB)
    #   G: out = 0.5958*in + 0.3322   (mean shift +46.1 LSB)
    #   B: out = 0.4964*in + 0.3211   (mean shift +35.2 LSB)
    # Relative to the mean bias the cast is R +0.0289, G -0.0089, B -0.0200.
    p.add_argument('--cast-weight', type=float, default=0.0,
                   help='0 disables; >0 enables the per-channel cast below')
    p.add_argument('--cast-rgb', type=str, default='0.0294,0.0067,-0.0361',
                   help='per-channel additive cast in [0,1].  Derived from the '
                        'measured official shifts R +0.2035 / G +0.1808 / '
                        'B +0.1380 minus their common mean 0.1741; the three '
                        'values sum to 0 so brightness is untouched and only '
                        'hue moves (R-B +0.0655, G-B +0.0427, matching the '
                        'measured official hue addition).')
    # Colour DISTRIBUTION losses.  Every earlier term constrained only the mean
    # and std of the output, which cannot express "turn the blue sky beige" or
    # "reduce 3812 distinct colours to 1234".  Measured on the paper example:
    #   input 2820 colours -> official 1102 (-61%), entropy 8.52 -> 7.53
    # while v6 stayed at 2560 colours and entropy 8.66 (higher than the input).
    p.add_argument('--quantile-weight', type=float, default=0.0,
                   help='match per-channel quantiles of the style references; '
                        'this is the term that can move hue, not just mean')
    p.add_argument('--quantile-levels', type=str, default='0.05,0.25,0.5,0.75,0.95')
    # WHICH distribution to match.  The user compares against the official
    # style_ukiyoe MODEL output, not against raw paintings - and the two differ:
    #   input photos  R 0.004..0.910   (wide)
    #   official out  R 0.361..0.812   (narrow)   <- the look being asked for
    #   real prints   R 0.129..0.992   (widest)
    # Matching raw paintings therefore asks for the WRONG distribution.
    p.add_argument('--quantile-target', type=str, default='refs',
                   choices=['refs', 'official'],
                   help='refs = the 8 style paintings; official = the measured '
                        'style_ukiyoe model output distribution')
    p.add_argument('--quantile-pixels', type=int, default=65536,
                   help='pixels sampled for the quantile loss; torch.quantile '
                        'sorts, so the full 1M-pixel tensor is too slow')
    p.add_argument('--palette-weight', type=float, default=0.0,
                   help='reward colour clustering (fewer distinct colours)')
    p.add_argument('--palette-centers', type=int, default=32,
                   help='soft-quantisation centres used by the palette loss')
    p.add_argument('--palette-temp', type=float, default=0.02,
                   help='soft-assignment temperature')
    # SATURATION.  Needed because NONE of the existing terms reads chroma:
    # measured, two images with saturation differing by 0.2203 have a per-channel
    # luminance-quantile L1 of only 0.000923 - the quantile term is blind to
    # cross-channel differences.  The ink domain separates from photos by 3.4
    # sigma on this axis (ink 0.0224 vs photo 0.3887), so it is worth a term.
    #
    # TWO-SIDED on purpose: a one-sided floor would push toward flat grey mush
    # (saturation 0 but no ink/paper contrast), so this must be paired with the
    # contrast term.  "Black ink on white paper" and "grey mush" are BOTH
    # low-saturation; only contrast distinguishes them.
    p.add_argument('--sat-weight', type=float, default=0.0,
                   help='match mean saturation (max_c-min_c)/max_c; 0 disables')
    p.add_argument('--sat-target', type=float, default=0.02,
                   help='target mean saturation; measure it with THIS formula')
    p.add_argument('--sat-mode', type=str, default='mean',
                   choices=['mean', 'dark', 'light'],
                   help='mean = whole image; dark/light restrict to that region')
    # DARK SHARE: fraction of the canvas that is ink-dark.  Exists because the
    # tone term pins the mean to the input photo (0.343) while ink is 0.709, so
    # the output stays dark; the quantile term fixed the middle of the histogram
    # but not this tail.  SOFT sigmoid mask, never a hard one - a hard mask was
    # the v2 death (gradient dies when coverage reaches zero).
    p.add_argument('--dark-share-weight', type=float, default=0.0)
    p.add_argument('--dark-share-target', type=float, default=0.066)
    p.add_argument('--dark-share-threshold', type=float, default=90.0)
    p.add_argument('--dark-share-temp', type=float, default=0.04)
    # PATCH TEXTURE FLOOR: mean |high-pass| per 64x64 tile must not fall below
    # the floor.  One-sided hinge, so it only opposes collapse.  Needed because
    # a whole-image hf std is satisfied by flat areas + a few edges (v5).
    p.add_argument('--patch-tex-weight', type=float, default=0.0)
    p.add_argument('--patch-tex-floor', type=float, default=0.010)
    p.add_argument('--patch-tex-size', type=int, default=64)
    # HIGHLIGHT GUARD: penalise the share of pixels clipped at the top end.
    # Measured: the +0.25 cast lifts the bright end into clipping (blown 15-17%
    # against ink's 3.06%), and the sweep showed it is NOT caused by quantile
    # (q0 already shows 16.96%).  One-sided hinge above a threshold, so it only
    # opposes clipping and leaves legitimate paper white alone.
    p.add_argument('--hl-weight', type=float, default=0.0)
    p.add_argument('--hl-threshold', type=float, default=0.98,
                   help='luminance above which pixels count as clipped')
    p.add_argument('--hl-target', type=float, default=0.031,
                   help='allowed clipped share; ink measured 0.031')
    # Conditional sky constraint: in the official output the sky (bright, low
    # saturation, blue-dominant) becomes WARM beige (R-B = +37 on the paper
    # tile).  A global mean cannot do this because the sky is only ~25% of the
    # frame while the bright field dominates the average.
    p.add_argument('--sky-weight', type=float, default=0.0)
    p.add_argument('--sky-lum-threshold', type=float, default=0.62)
    p.add_argument('--sky-target-rb', type=float, default=0.10,
                   help='target (R-B) for sky pixels, in [0,1]; paper tile ~= +0.15')
    # GRAIN: the official output carries MORE high-frequency energy than the
    # input (0.0484 vs 0.0420 at 512) while ours carries less (0.0383).  The
    # palette losses raise flatness, so grain needs its own opposing term.
    p.add_argument('--grain-weight', type=float, default=0.0)
    p.add_argument('--grain-target', type=float, default=0.0484,
                   help='target high-pass std; official measured 0.0484')
    # DARK-REGION HIGH FREQUENCY.  For ink the discriminative texture is not the
    # global level but the level INSIDE dark marks.  Measured with THIS formula
    # (std of the 4x-blur high-pass inside an absolute L<90 mask, [0,1] units):
    #   ink A/validation 0.0567 | A/train 0.0575 | photos 0.0418
    # -> separation 35.8%, Welch t = -5.6, so the target IS discriminative.
    # (The global grain level does NOT separate: ink 0.0418 vs photo 0.0421.)
    p.add_argument('--dark-hf-weight', type=float, default=0.0)
    p.add_argument('--dark-hf-target', type=float, default=0.0567,
                   help='target HF std INSIDE the dark mask, in [0,1] units, '
                        'measured with THIS loss formula on ink A/validation '
                        '(185 images) = 0.0567; photos measure 0.0418, so the '
                        'target sits above the photo level (separation 35.8%%, '
                        'Welch t = -5.6).  NOTE: an earlier 0.0407 came from a '
                        'DIFFERENT statistic (mean|hf| with a quantile mask) and '
                        'was wrong - always calibrate with the loss formula.')
    p.add_argument('--dark-hf-threshold', type=float, default=90.0,
                   help='luminance below which a pixel counts as dark (LSB)')
    p.add_argument('--dark-hf-blur', type=int, default=4,
                   help='box size of the high-pass; must match how the target '
                        'was measured')
    # STROKE: elongate the dark marks.  Real ukiyo-e shows eH/eV rising with
    # kernel size (1.07 / 1.23 / 1.54 / 2.05 at k=5/9/13/21) while photos stay
    # flat near 1.0 and our models sit at 1.0-1.2.  Constraining this directly
    # targets the "brushstroke" property.
    p.add_argument('--stroke-weight', type=float, default=0.0)
    p.add_argument('--stroke-target', type=float, default=1.138,
                   help='target sum(eH)/sum(eV).  The loss POOLS over the batch, '
                        'so the target must be measured the same way: real '
                        'paintings pool to 1.138.  (Per-image averaging gives '
                        '1.378 - a different number; using it over-extends the '
                        'strokes, as v11/v12 did.)')
    p.add_argument('--stroke-threshold', type=float, default=80.0,
                   help='luminance below which a pixel counts as dark')
    p.add_argument('--stroke-kernels', type=str, default='9,13,21',
                   help='kernel sizes whose average elongation is constrained')
    # PLAN A: coarse-stage stroke loss.  Put elongation pressure where long
    # strokes can actually be born (the 128x128 res stack at size 512), because
    # the final full-res stage has RF 3 physical px and cannot create a 9-21 px
    # mark.  Measured batch-pooled targets with the thr=80 mask:
    #   coarse (128x128, k=[3,5])  1.098   | final (512, k=[9,13,21]) 1.138
    p.add_argument('--stroke-coarse-weight', type=float, default=0.0)
    p.add_argument('--stroke-coarse-target', type=float, default=1.175,
                   help='batch-pooled target at the res stack, measured on real '
                        'paintings with the SAME mask scheme (per-image q=0.08, '
                        'then pooled ratio) = 1.175.  v14 sits at 0.998 there, so '
                        'this term has a real gap to close (the earlier note that '
                        'it was already at target was based on a WRONG hook: '
                        'relu(pre+skip) instead of fake(relu(pre+skip))).')
    p.add_argument('--stroke-coarse-kernels', type=str, default='3,5',
                   help='local kernels at the res scale (unit is 4 px at size 512)')
    p.add_argument('--stroke-coarse-q', type=float, default=0.08,
                   help='darkest fraction used as the coarse mask (relative)')
    p.add_argument('--stroke-coarse-temp', type=float, default=0.02,
                   help='softness of the coarse mask')
    p.add_argument('--debug-coarse', action='store_true',
                   help='print the hook state on the first step')
    # identity loss (CycleGAN qa.md:96-106): feeding a target-domain image to
    # the generator should leave it unchanged.  This makes the model
    # conservative and reduces spurious recolouring.
    p.add_argument('--identity-weight', type=float, default=0.0)
    # training resolution.  The board infers at 640x480 and its encoder
    # downsamples 4x, i.e. 160x120 internally.  Training at 256 gives 64x64
    # internally, a 2.5x scale mismatch (docs/tips.md:39 recommends matching
    # train and test scale).  512 gives 128x128, a 1.25x mismatch.
    p.add_argument('--size', type=int, default=256)
    # Mid-network channel count.  The RTL tile is sized for up to 32 output
    # channels; lowering this reduces the MAC count quadratically in the 18
    # middle layers, which dominate the inference time.
    p.add_argument('--channels', type=int, default=24)
    p.add_argument('--validate-every', type=int, default=250)
    # How many validation images the in-loop check uses.  The reported numbers
    # are MEANS over these images, so more images = a less noisy curve; the cost
    # is one forward pass per image (0.012 s, under @torch.no_grad()) every
    # --validate-every steps.  Was hardcoded to 8.
    p.add_argument('--val-count', type=int, default=8)
    # AMP toggle.  v3 froze because a GradScaler death spiral drove the scale to
    # 1.5e-36, at which point fp16 gradients underflow to zero and the weights
    # stop changing while the optimiser counter keeps rising.
    #
    # Modes:
    #   amp=1 fp16  fast but NARROW range (exponent 5 bits, max 65504); needs a
    #               GradScaler that can spiral, as v3 showed.
    #   amp=2 bf16  same exponent range as fp32 (8 bits, max 3.39e38), so the
    #               under/overflow that drives the spiral cannot occur and no
    #               GradScaler is required.  7 mantissa bits is ample for image
    #               regression.
    #   amp=0 fp32  slowest, zero risk.
    p.add_argument('--amp', type=int, default=1,
                   help='1 = fp16+GradScaler, 2 = bf16 (no scaler), 0 = fp32')
    a = p.parse_args()

    torch.set_num_threads(8)
    random.seed(20261012)
    np.random.seed(20261012)
    torch.manual_seed(20261012)
    torch.backends.cudnn.benchmark = True
    torch.backends.cuda.matmul.allow_tf32 = True

    global TRAIN_SIZE
    TRAIN_SIZE = a.size
    print('training resolution: %dx%d (internal %dx%d)'
          % (a.size, a.size, a.size // 4, a.size // 4))

    a.out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(a.manifest.read_text())
    root = pathlib.Path(manifest['dataset'])
    train = [r['path'] for r in manifest['records']
             if r['domain'] == 'B' and r['split'] == 'train']
    val = [r['path'] for r in manifest['records']
           if r['domain'] == 'B' and r['split'] == 'validation']
    # The 8 validation images used to be picked by a fixed stride:
    #   val[i * (len(val) - 1) // 7] for i in range(8)
    # That is content-blind, and on the 黑白ink set it selected 5 sky-dominated
    # frames (photo_01847 is almost entirely blue sky with one bird), whose mean
    # high-frequency energy is 0.0356 - the lowest of any candidate set.  The
    # validation curve therefore measured brushwork on the one kind of image that
    # has no brushwork to measure.
    #
    # Selection order is now:
    #   1. eval_photos.json next to the manifest (content-ranked, sky-free)
    #   2. a content filter over B/validation, colour-agnostic
    #   3. the old stride, so other datasets keep working unchanged
    # The count comes from --val-count (default 8, was hardcoded).  The reported
    # metrics are means over the selected images, so raising it tightens the
    # curve; cost is a no_grad forward per image per validation.
    NVAL = max(int(a.val_count), 1)
    val_pick = []
    ref = a.manifest.parent / 'eval_photos.json'
    if ref.exists():
        cand = json.loads(ref.read_text())
        cand = [c for c in cand if c in
                {r['path'] for r in manifest['records']
                 if r['domain'] == 'B' and r['split'] == 'validation'}]
        if len(cand) >= NVAL:
            # an evenly spaced subset keeps the set representative when the
            # requested count is smaller than the file, and uses the whole file
            # when it is larger
            stride = max(len(cand) // NVAL, 1)
            val_pick = [cand[i * stride] for i in range(min(NVAL, len(cand)))]
        else:
            val_pick = cand
        if val_pick:
            print('validation images: %d from eval_photos.json (%d available)'
                  % (len(val_pick), len(cand)))
    if not val_pick and val:
        import torch as _t
        import torch.nn.functional as _F

        def _content_ok(path):
            """Sky/heavy-smoothness test: location + flatness, colour-agnostic.
            Keying on low chroma would miss coloured skies (blue, sunset), which
            is exactly how the bad selection went unnoticed."""
            try:
                x = image_tensor(root / path, 256)[None]
            except Exception:
                return True
            L = 0.299 * x[:, 0:1] + 0.587 * x[:, 1:2] + 0.114 * x[:, 2:3]
            hi = (L - _F.interpolate(_F.avg_pool2d(L, 4), size=L.shape[-2:],
                                     mode='nearest')).abs()
            h = L.shape[-2]
            top = int(h * 0.4)
            mt = float(hi[0, 0].mean())
            smooth_top = float((hi[0, 0, :top] < mt * 0.5).float().mean())
            td, bd = float(hi[0, 0, :top].mean()), float(hi[0, 0, top:].mean())
            return not (smooth_top > 0.62 and bd > td * 1.8)

        good = [p for p in val if _content_ok(p)]
        pool = good if len(good) >= NVAL else val
        if good and len(good) >= NVAL:
            step = max(len(pool) // NVAL, 1)
            val_pick = [pool[i * step] for i in range(min(NVAL, len(pool)))]
            print('validation images: %d content-selected from %d candidates'
                  % (len(val_pick), len(good)))
    val = val_pick if val_pick else [val[i * (len(val) - 1) // max(NVAL - 1, 1)]
                                     for i in range(min(NVAL, len(val)))]
    # domain A = the real ukiyo-e paintings.  These are the correct input for
    # the identity loss (CycleGAN qa.md:96-106): G_A must leave a painting
    # unchanged.  My earlier implementation used a synthetic proxy built from
    # the content batch, which does not teach "do not alter a painting".
    paintings = [r['path'] for r in manifest['records']
                 if r['domain'] == 'A' and r['split'] == 'train']
    print('identity paintings available: %d' % len(paintings))
    refs = json.loads((a.manifest.parent / 'style_refs.json').read_text())

    features = Features().cuda()
    with torch.no_grad():
        target = [g.mean(0, keepdim=True)
                  for g in [gram(f) for f in features(
                      torch.stack([image_tensor(root / n, TRAIN_SIZE) for n in refs]).cuda())]]
    style_mean, style_std = style_stats(refs, root)
    style_mean = style_mean.cuda()
    style_std = style_std.cuda()
    q_levels = [float(v) for v in a.quantile_levels.split(',') if v.strip()]
    q_tensor = torch.tensor(q_levels)
    a.stroke_kernels = [int(v) for v in a.stroke_kernels.split(',') if v.strip()]
    print('stroke kernels: %s' % a.stroke_kernels)
    a.stroke_coarse_kernels = [int(v) for v in a.stroke_coarse_kernels.split(',')
                               if v.strip()]
    if a.stroke_coarse_weight > 0:
        print('coarse stroke kernels: %s  target %.3f  q %.2f'
              % (a.stroke_coarse_kernels, a.stroke_coarse_target, a.stroke_coarse_q))
    if a.quantile_weight > 0:
        if a.quantile_target == 'official':
            if len(q_levels) != len(OFFICIAL_QUANTILES[0]):
                raise ValueError('--quantile-target official expects %d levels'
                                 % len(OFFICIAL_QUANTILES[0]))
            style_q = torch.tensor(OFFICIAL_QUANTILES)
            print('quantile target: OFFICIAL model output distribution')
        else:
            style_q = style_quantiles(refs, root, q_levels)
            print('quantile target: the %d style reference paintings' % len(refs))
        style_q = style_q.cuda()
        for c, nm in enumerate('RGB'):
            print('  %s %s' % (nm, np.round(style_q[c].cpu().numpy(), 4)))
    else:
        style_q = None
    print('style ref mean (RGB): %s' % np.round(style_mean.cpu().numpy(), 4))
    print('style ref std  (RGB): %s' % np.round(style_std.cpu().numpy(), 4))
    print('layer weights: %s' % LAYER_WEIGHTS)

    model = (Teacher() if a.kind == 'teacher' else Student(channels=a.channels)).cuda()
    teacher = None
    if a.teacher:
        teacher = Teacher().cuda().eval()
        teacher.load_state_dict(torch.load(a.teacher, weights_only=False)['model'])
        teacher.requires_grad_(False)
    if a.reference_student:
        teacher = Student(channels=a.channels).cuda().eval()
        teacher.load_state_dict(torch.load(a.reference_student,
                                           weights_only=False)['model'])
        teacher.requires_grad_(False)
    if a.resume:
        model.load_state_dict(torch.load(a.resume, weights_only=False)['model'])
    # PLAN A hook: capture the res-stack OUTPUT each step so the coarse stroke
    # loss can be evaluated there.
    #
    # BUG I made first time: I hooked enc[2], but that is the res-stack INPUT
    # (a 1x1 conv output at 128x128), not its output.  forward() computes the
    # res output as relu(x + skip) after the last block, and that value is not
    # any single module's output.  Two hooks recover it exactly:
    #   * res[-1][0] receives the block's skip as its INPUT
    #   * res[-1][-1] returns the pre-activation as its OUTPUT
    #   * res_out = relu(pre + skip)   <- identical to forward()
    a.stroke_coarse_acts = {}
    if a.stroke_coarse_weight > 0 and a.kind == 'student':
        if model.head > 0:
            raise SystemExit('coarse stroke loss assumes head=0 (res at 128x128)')

        def _cap_skip(mo, inp, out):
            a.stroke_coarse_acts['skip'] = inp[0]

        def _cap_pre(mo, inp, out):
            a.stroke_coarse_acts['pre'] = out

        model.res[-1][0].register_forward_hook(_cap_skip)
        model.res[-1][-1].register_forward_hook(_cap_pre)
        print('coarse stroke hooks: res[-1][0] input (skip) + res[-1][-1] output '
              '(pre-activation) -> res_out = relu(pre + skip)')
    activation_scales = (json.loads(a.scales.read_text())['scales']
                         if a.scales else None)
    if activation_scales:
        model.set_scales(activation_scales)

    opt = torch.optim.Adam(model.parameters(), lr=a.lr)
    loader = torch.utils.data.DataLoader(Photos(root, train), batch_size=a.batch,
                                         shuffle=True, num_workers=0,
                                         pin_memory=False, persistent_workers=False)
    iterator = iter(loader)
    log = (a.out / 'train.jsonl').open('a')
    start = time.monotonic()
    config = vars(a).copy()
    config = {k: str(v) if isinstance(v, pathlib.Path) else v
              for k, v in config.items()}
    config.update(torch=torch.__version__,
                  device=torch.cuda.get_device_name(),
                  manifest_sha256=hashlib.sha256(a.manifest.read_bytes()).hexdigest(),
                  style_refs=refs, activation_scales=activation_scales,
                  layer_weights=LAYER_WEIGHTS,
                  parameters=sum(q.numel() for q in model.parameters()),
                  loss=f'{a.content_weight}*content + {a.style_weight}*weighted Gram'
                       f' + .03 TV + {a.distill_weight}*L1'
                       f' + {a.tone_weight}*tone'
                       f' + {a.identity_weight}*identity'
                       f' + {a.quantile_weight}*quantile'
                       f' + {a.palette_weight}*palette'
                       f' + {a.sky_weight}*sky')
    (a.out / 'config.json').write_text(json.dumps(config, indent=2))

    evaluate(model, features, target, root, val, a.out, 0, teacher,
             style_mean, style_std)
    # GradScaler.  The 黑白v3 run FROZE because of a scaler death spiral, measured
    # as follows: its scale fell 128 -> 0.0625 -> 9.3e-10 -> 6.6e-24 -> 1.5e-36,
    # i.e. ~126 halvings = ~126 backward passes that reported inf.  Default
    # growth_interval is 2000, so with an inf every ~11 steps the scale can only
    # fall and never recovers.  At 1.5e-36 the fp16 gradients UNDERFLOW to zero:
    # scaler.step() sees finite (all-zero) gradients and does not skip, so the
    # optimizer step counter keeps rising while every weight stays byte-identical
    # (verified: hash unchanged from step 1500 to 2500, optimizer step 1454->2365).
    #
    # Fixes, all cheap:
    #   * lower init_scale so the first infs do not cost so many halvings
    #   * short growth_interval so the scale can RECOVER between inf events
    #   * a floor plus an explicit abort, so a collapse is reported instead of
    #     silently training nothing for thousands of steps
    # An inf every ~11 steps at growth_interval 200 is still net-negative, so the
    # floor/abort is what guarantees the failure is loud rather than silent.
    # GradScaler is only needed for fp16.  bf16 shares fp32's exponent range, so
    # gradients neither underflow nor overflow and a scaler would be a no-op that
    # could still spiral; fp32 needs none at all.
    scaler_used = (a.amp == 1)
    scaler = torch.amp.GradScaler('cuda', enabled=scaler_used,
                                  init_scale=256.0, growth_interval=200)
    MIN_SCALE = 1e-2
    scale_collapse_step = None

    for step in range(1, a.steps + 1):
        model.train()
        a.stroke_coarse_acts.clear()   # the hooks write skip/pre; keep one pair
        qat = a.kind == 'student' and step >= a.qat_after
        if a.kind == 'student':
            model.set_qat(qat)
            if qat:
                for m in model.modules():
                    if isinstance(m, nn.BatchNorm2d):
                        m.eval()
        try:
            x = next(iterator).cuda(non_blocking=True)
        except StopIteration:
            iterator = iter(loader)
            x = next(iterator).cuda(non_blocking=True)

        if a.amp == 2:
            _ac = torch.autocast('cuda', enabled=True, dtype=torch.bfloat16)
        elif a.amp == 1:
            _ac = torch.autocast('cuda', enabled=True, dtype=torch.float16)
        else:
            _ac = torch.autocast('cuda', enabled=False)
        with _ac:
            with torch.no_grad():
                xf = features(x)
                t = teacher(x) if teacher else None
            y = model(x)
            # SNAPSHOT the res hooks HERE.  The identity term below runs a SECOND
            # forward on a different batch size (model(art) with batch 4 vs 8), and
            # the hooks would be overwritten by it.  That is why the shape guard
            # failed and stroke_coarse_ratio stayed -1 for whole runs: the tensors
            # read at the loss site belonged to the identity pass, not this one.
            coarse_got = None
            if a.stroke_coarse_weight > 0:
                _s = a.stroke_coarse_acts.get('skip')
                _p = a.stroke_coarse_acts.get('pre')
                if _s is not None and _p is not None:
                    coarse_got = (_s, _p)
            yf = features(y)
            content = F.mse_loss(yf[2].float(), xf[2].float())
            style = sum(w * F.mse_loss(gram(f), g.expand(f.shape[0], -1, -1))
                        for w, f, g in zip(LAYER_WEIGHTS, yf, target))
            tv = ((y[:, :, 1:, :] - y[:, :, :-1, :]).abs().mean()
                  + (y[:, :, :, 1:] - y[:, :, :, :-1]).abs().mean())
            distill = F.l1_loss(y, t) if t is not None else y.new_zeros(())
            # Tone: content-RELATIVE, optionally affine.
            #   tone-slope == 0 -> out_mean = in_mean + tone_offset (old mode)
            #   tone-slope  > 0 -> out_mean = slope*in_mean + bias  (affine)
            # Absolute-mean matching was tried and failed: it flattened every
            # image to one brightness.  The constant-offset mode then
            # over-brightened bright scenes (paper poppy field, +16 LSB).
            y_mean = y.mean(dim=[2, 3])
            y_std = y.std(dim=[2, 3])
            x_mean = x.mean(dim=[2, 3])
            x_std = x.std(dim=[2, 3])
            if a.tone_quad != 0.0 or a.tone_slope > 0:
                base = (a.tone_quad * x_mean * x_mean
                        + a.tone_slope * x_mean + a.tone_bias)
            else:
                base = x_mean + a.tone_offset
            # Per-channel CAST.  The official model shifts R by +51.9 LSB,
            # G by +46.1 and B by +35.2 (measured over 40 photos, R^2 0.95),
            # i.e. it ADDS a warm cast.  A single scalar bias is channel-blind
            # and structurally cannot produce that, which is why our output
            # stays near-neutral grey (R~G~B) while the official is warm.
            if a.cast_weight > 0:
                # Shape MUST be (3,) to match y_mean's (B, 3).  An earlier
                # version used .view(1, 3, 1, 1), which broadcast the target to
                # (1, 3, B, 3); F.mse_loss then averaged over all three channel
                # copies, and since the cast offsets sum to zero the term
                # silently collapsed to the plain tone loss and had NO effect.
                cast = torch.tensor([float(v) for v in a.cast_rgb.split(',')],
                                    device=y.device, dtype=y_mean.dtype)
                assert cast.shape == (3,), 'cast shape %s' % (tuple(cast.shape),)
                assert y_mean.shape[-1] == 3, 'y_mean shape %s' % (tuple(y_mean.shape),)
                mean_target = base + cast
            else:
                mean_target = base
            # CONTRAST.  Two modes:
            #   contrast-absolute > 0 -> an ABSOLUTE per-channel std target
            #   otherwise             -> the old RELATIVE x_std*contrast_ratio
            # The relative form cannot go below in_std*ratio, which is why the
            # ink teacher kept photo-like contrast (144.5 LSB vs ink 97.5) even
            # though contrast is the strongest domain discriminator (t=-11.5).
            if a.contrast_absolute > 0:
                std_target = torch.full_like(y_std, float(a.contrast_absolute))
            else:
                std_target = x_std * a.contrast_ratio
            tone = (F.mse_loss(y_mean, mean_target)
                    + F.mse_loss(y_std, std_target))
            # Identity (CycleGAN qa.md:96-106): G_A applied to a real ukiyo-e
            # painting must return that painting unchanged.  This is what makes
            # the generator conservative about recolouring.
            identity = y.new_zeros(())
            if a.identity_weight > 0:
                with torch.no_grad():
                    idx = torch.randint(0, len(paintings), (min(a.batch, 4),))
                    art = torch.stack([image_tensor(root / paintings[i], TRAIN_SIZE)
                                       for i in idx.tolist()]).cuda()
                identity = F.l1_loss(model(art), art)
            # STROKE: make the dark marks ELONGATED, like real ukiyo-e.
            # Measured with a soft dark mask m = sigmoid((80 - L)/8) and
            # max-pool "erosion" proxies:
            #   real paintings  eH/eV = 1.07 (k=5), 1.23 (k=9), 1.54 (k=13), 2.05 (k=21)
            #   real photos     eH/eV = 1.01, 1.02, 1.03, 1.06   (flat)
            #   our v9/v10      ~1.0-1.2 at all kernels
            # The signal GROWS with kernel size for art but stays flat for
            # photos, i.e. art has long strokes rather than isotropic speckle.
            # It is also rotation-robust: photos score 1.002 across 0/90/180/270,
            # paintings 1.102, so it is not driven by content orientation.
            stroke = y.new_zeros(())
            if a.stroke_weight > 0:
                L = 0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3]
                m = torch.sigmoid((a.stroke_threshold - L * 255.0) / 8.0)
                eH = y.new_zeros(())
                eV = y.new_zeros(())
                for k in a.stroke_kernels:
                    eH = eH - F.max_pool2d(-m, (1, k), stride=1,
                                           padding=(0, k // 2)).mean()
                    eV = eV - F.max_pool2d(-m, (k, 1), stride=1,
                                           padding=(k // 2, 0)).mean()
                # Match the target on BOTH sides.  A one-sided hinge
                # F.relu(target - ratio) is ZERO once ratio exceeds the target,
                # so nothing pulls elongation back down: v11 (weight 60) reached
                # 2.074 and v12 (weight 15) still reached 2.031, i.e. the weight
                # barely mattered.  A symmetric penalty fixes the operating
                # point instead of only setting a floor.
                ratio = eH / (eV + 1e-6)
                stroke = (ratio - a.stroke_target) ** 2
            # PLAN A: COARSE-STAGE STROKE.  The final 640x480 stage is only
            # DW3x3 + 1x1 (RF 3 physical px), so it CANNOT create a 9-21 px
            # mark - long strokes must originate at the 160x120 res stack.
            # Verified offline: optimising ONLY that stage moved full-res
            # elongation from 1.434 to 3.783 (real art 1.528) with 0.0005 drift.
            #
            # At training size 512 the res output is 128x128, i.e. unit 4 px, so
            # a 9-21 px stroke is a 2-5 px structure there -> kernels [3,5].
            # TARGET: measured on real paintings with the SAME mask scheme
            # (PER-IMAGE quantile q=0.08, then a batch-pooled ratio) = 1.175.
            # v14 measures 0.998 at this stage (correctly hooked), so the loss
            # has a real gap to close.  A batch-level threshold gives a different
            # number for the same tensors - mixing the two is the aggregation
            # mismatch that broke v13.
            stroke_coarse = y.new_zeros(())
            rc_val = None
            if a.stroke_coarse_weight > 0:
                _snap = coarse_got
                _skip = _snap[0] if _snap else None
                _pre = _snap[1] if _snap else None
                if a.debug_coarse:
                    print('DEBUG coarse: snapshot=%s skip=%s pre=%s y0=%s'
                          % (_snap is not None,
                             None if _skip is None else tuple(_skip.shape),
                             None if _pre is None else tuple(_pre.shape),
                             y.shape[0]))
                    a.debug_coarse = False
                if _skip is not None and _pre is not None \
                        and _skip.shape[0] == y.shape[0]:
                    # The res-stack output as forward() leaves it.  Verified
                    # bit-identical to an instrumented forward():
                    #   relu(pre + skip) alone differs by up to 1.8
                    #   fake(relu(pre + skip), residual_scale) is exact
                    # because the loop applies QAT to the residual sum.
                    got = F.relu(_pre + _skip)
                    if getattr(model, 'qat', False):
                        got = fake(got, model.residual_scale)
                    Lc = got.float().mean(dim=1, keepdim=True)  # channel-mean map
                    _fl = Lc.detach().flatten(1)
                    thr_c = torch.quantile(_fl, a.stroke_coarse_q,
                                           dim=1).view(-1, 1, 1, 1)   # (B,1,1,1)
                    mc = torch.sigmoid((thr_c - Lc) / a.stroke_coarse_temp)
                    eHc = y.new_zeros(())
                    eVc = y.new_zeros(())
                    for k in a.stroke_coarse_kernels:
                        eHc = eHc - F.max_pool2d(
                            -mc, (1, k), stride=1, padding=(0, k // 2)).mean()
                        eVc = eVc - F.max_pool2d(
                            -mc, (k, 1), stride=1, padding=(k // 2, 0)).mean()
                    rc = eHc / (eVc + 1e-6)
                    rc_val = rc.detach()
                    # TWO-SIDED: the coarse stage is ALREADY at the art level
                    # (measured ~1.17 vs target 1.175), so a one-sided floor would
                    # do nothing.  A symmetric penalty holds the operating point.
                    stroke_coarse = (rc - a.stroke_coarse_target) ** 2
            # SATURATION: the only term that reads CHROMA.  Measured: two images
            # whose saturation differs by 0.2203 have a per-channel luminance
            # quantile L1 of 0.000923, so the quantile/style terms cannot see
            # this axis at all.  Ink separates from photos by 3.4 sigma here.
            #
            # Two-sided by design: a one-sided floor would collapse the image to
            # flat grey (saturation 0, no ink/paper contrast), and "grey mush" is
            # also low-saturation.  The contrast term is what keeps the two-tone
            # structure, so this term must not be used alone.
            sat_loss = y.new_zeros(())
            sat_val = None
            if a.sat_weight > 0:
                mx = y.max(dim=1).values                  # (B,H,W)
                mn = y.min(dim=1).values
                # clamp_min 1e-2, not 1e-6: the gradient of (mx-mn)/mx is
                # -mn/mx**2, which for mx=1e-6 reaches 1e6..1e12 and can
                # overflow fp16 (max 65504).  Tested: the real data never
                # produced an inf from this term, but 1e-2 costs nothing and
                # removes the theoretical path.  A pure black pixel is safe
                # either way (mx=mn=0 gives derivative 0).
                sat_map = (mx - mn) / mx.clamp_min(1e-2)
                if a.sat_mode in ('dark', 'light'):
                    L = 0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3]
                    sel = ((L < 90 / 255) if a.sat_mode == 'dark'
                           else (L > 160 / 255)).float()[0]
                    num = (sat_map * sel).sum()
                    den = sel.sum().clamp_min(1.0)
                    sat_val = (num / den)          # scalar, whole-batch pooled
                else:
                    sat_val = sat_map.mean()
                sat_loss = (sat_val - a.sat_target) ** 2
            # DARK SHARE: how much of the canvas is ink-dark.  Ink paintings are
            # paper-dominant (dark 6.6%, light 70.6%), while the output held dark
            # at 15-20% because the tone term pins the mean to the INPUT photo
            # (photos 0.343 vs ink 0.709).  Measured: raising the quantile weight
            # fixed the middle but not the dark tail, and pin density did not
            # help (5 pins was best of 4 layouts), so the tail needs its own term.
            #
            # SOFT mask on purpose.  A hard mask was the v2 failure: when
            # coverage hits zero the gradient dies exactly when it is needed
            # (INK_V2_FAILURE.md).  A sigmoid keeps the gradient alive, and the
            # mask here is NOT detached because the term must be able to move
            # pixels across the threshold.
            dark_share = y.new_zeros(())
            dark_share_val = None
            if a.dark_share_weight > 0:
                L = 0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3]
                soft = torch.sigmoid((a.dark_share_threshold / 255.0 - L)
                                     / max(a.dark_share_temp, 1e-3))
                dark_share_val = soft.mean()
                dark_share = (dark_share_val - a.dark_share_target) ** 2
            # PATCH TEXTURE FLOOR.  Added because v5 proved the grain term can be
            # satisfied while the image collapses: v5's grain loss read 1e-4
            # ("satisfied", hf_std 0.031 vs ink 0.047) yet its patch-level
            # texture was destroyed -
            #     hf_mean 0.0364 -> 0.0146, edge 0.0277 -> 0.0091
            #     flat%     2.0  -> 42.8
            # A whole-image std is satisfied by large flat areas plus a few sharp
            # edges, so it does not protect local texture.  This term instead
            # floors the MEAN high-frequency energy of each 64x64 tile, which is
            # what posterization actually destroys.
            #
            # hf_floor_weight scales a hinge: tiles already above the floor cost
            # nothing, so this only opposes collapse and does not fight the
            # legitimate flatness of paper (ink itself is flat% 21.5).
            patch_tex = y.new_zeros(())
            patch_tex_val = None
            if a.patch_tex_weight > 0:
                Lp = 0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3]
                hip = (Lp - F.interpolate(F.avg_pool2d(Lp, 4),
                                          size=Lp.shape[-2:], mode='nearest')).abs()
                unfold = F.unfold(hip, a.patch_tex_size, stride=a.patch_tex_size)
                pmean = unfold.mean(dim=1)                     # (B, n_patch)
                # one-sided hinge: penalise only tiles BELOW the floor
                patch_tex_val = pmean.mean()
                patch_tex = F.relu(a.patch_tex_floor - pmean).mean()
            # HIGHLIGHT GUARD: the +0.25 cast pushes the bright end into
            # clipping (measured blown 15-17% vs ink 3.06%, and NOT caused by
            # quantile).  One-sided above the threshold so paper white is safe.
            hl_guard = y.new_zeros(())
            hl_val = None
            if a.hl_weight > 0:
                Lh = 0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3]
                clipped = (Lh > a.hl_threshold).float().mean()
                hl_val = clipped
                hl_guard = F.relu(clipped - a.hl_target)
            # GRAIN: match the high-frequency level of the official output.
            # Measured at 512 (4x-blur high-pass std):
            #   input 0.0420 | official 0.0484 | v6 0.0383 | prints 0.0552
            # The official output has MORE high-frequency energy than the input
            # (ratio 1.150) while ours has LESS (0.910).  This is the axis the
            # palette losses damage, so it needs its own term.
            grain = y.new_zeros(())
            if a.grain_weight > 0:
                # high-pass via average pooling (no learned params)
                L = (0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3])
                lo = F.avg_pool2d(L, 4)
                hi = L - F.interpolate(lo, size=L.shape[-2:], mode='nearest')
                lvl = hi.flatten(1).std(dim=1)
                grain = F.mse_loss(lvl, lvl.new_full(lvl.shape, a.grain_target))
            # DARK-REGION HF: the ink brushstroke axis.  Global grain alone is
            # not discriminative for ink (hf std t=1.1 between domains), but the
            # level INSIDE dark marks is (ratio 1.93 vs 1.19).  Two-sided squared
            # form, matching the target's own aggregation (both computed inside
            # the dark mask), and the mask is DETACHED so it is not optimised.
            dark_hf = y.new_zeros(())
            if a.dark_hf_weight > 0:
                L = (0.299 * y[:, 0:1] + 0.587 * y[:, 1:2] + 0.114 * y[:, 2:3])
                k = max(2, int(a.dark_hf_blur))
                lo = F.avg_pool2d(L, k)
                hi = L - F.interpolate(lo, size=L.shape[-2:], mode='nearest')
                m = (L.detach() < a.dark_hf_threshold / 255.0).float()
                n = m.sum(dim=[2, 3]).clamp_min(1.0)          # (B,1)
                # per-image mean of hi inside the mask, then its std inside it
                mu = (hi * m).sum(dim=[2, 3]) / n
                var = (((hi - mu[:, :, None, None]) ** 2) * m).sum(dim=[2, 3]) / n
                lvl = var.clamp_min(0.0).sqrt().flatten(1).mean(dim=1)
                dark_hf = F.mse_loss(lvl, lvl.new_full(lvl.shape, a.dark_hf_target))
            # Colour DISTRIBUTION: match per-channel quantiles of the style
            # references.  This is the first term in the whole project that can
            # move hue and compress the palette, because quantiles carry
            # distribution shape while a mean does not.
            quant = y.new_zeros(())
            if a.quantile_weight > 0 and style_q is not None:
                # autocast gives fp16 here; quantile requires float32/float64.
                # y is (b,3,h,w) with the batch pooled, so channels become the
                # first axis: (3, N).  torch.quantile(x, q, dim=-1) returns
                # (L, 3) - the quantile axis comes FIRST - so compute per
                # channel to obtain exactly (3, L) and match style_q.
                #
                # torch.quantile SORTS, so it is O(N log N).  At 512x512x4 the
                # pooled tensor is ~1M pixels per channel and made one step
                # 9.8x slower (1.0s -> 9.8s).  Quantiles are a distribution
                # statistic, so a random sample is sufficient.
                with torch.autocast('cuda', enabled=False):
                    flat = y.float().permute(1, 0, 2, 3).reshape(3, -1)
                    n = flat.shape[1]
                    if n > a.quantile_pixels:
                        idx = torch.randperm(n, device=flat.device)[:a.quantile_pixels]
                        flat = flat[:, idx]
                    yq = torch.stack([torch.quantile(flat[c], q_tensor.to(y.device),
                                                     dim=-1) for c in range(3)])
                    assert yq.shape == style_q.shape, \
                        'quantile shape %s vs target %s' % (tuple(yq.shape),
                                                            tuple(style_q.shape))
                    quant = F.l1_loss(yq, style_q.to(y.device).float())
            # Colour CLUSTERING: pull pixels toward a small set of centres so
            # the distinct-colour count falls, as the official output does
            # (3812 to 1234 on the paper example).  Sampled, not full-frame.
            palette = y.new_zeros(())
            if a.palette_weight > 0:
                with torch.autocast('cuda', enabled=False):
                    rec, z = soft_palette(y.float(), a.palette_centers,
                                          a.palette_temp)
                    palette = F.l1_loss(rec, z)
            # Conditional SKY: bright, low-saturation, blue-dominant regions
            # should turn WARM, which no global mean can achieve because the
            # bright field dominates the frame average.
            sky = y.new_zeros(())
            if a.sky_weight > 0:
                lum_y = (0.299 * y[:, 0] + 0.587 * y[:, 1] + 0.114 * y[:, 2])
                mx = y.max(dim=1).values
                mn = y.min(dim=1).values
                sat = (mx - mn) / mx.clamp_min(1e-6)
                mask = (lum_y > a.sky_lum_threshold) & (sat < 0.25) \
                    & (y[:, 2] > y[:, 0])
                if mask.any():
                    rb = (y[:, 0] - y[:, 2])[mask]
                    sky = (a.sky_target_rb - rb).clamp_min(0).mean()
            loss = (a.content_weight * content + a.style_weight * style
                    + a.tv_weight * tv + a.distill_weight * distill
                    + a.tone_weight * tone
                    + a.identity_weight * identity
                    + a.quantile_weight * quant
                    + a.palette_weight * palette
                    + a.sky_weight * sky
                    + a.grain_weight * grain
                    + a.dark_hf_weight * dark_hf
                    + a.sat_weight * sat_loss
                    + a.dark_share_weight * dark_share
                    + a.patch_tex_weight * patch_tex
                    + a.hl_weight * hl_guard
                    + a.stroke_weight * stroke
                    + a.stroke_coarse_weight * stroke_coarse)

        if not torch.isfinite(loss):
            raise RuntimeError(f'Nonfinite loss at step {step}')
        opt.zero_grad(set_to_none=True)
        scaler.scale(loss).backward()
        scaler.unscale_(opt)
        nn.utils.clip_grad_norm_(model.parameters(), 10)
        scaler.step(opt)
        scaler.update()
        # Detect the death spiral LOUDLY.  Without this the run trains nothing
        # for thousands of steps while looking healthy in the log.
        _sc = float(scaler.state_dict().get('scale', 1.0))
        if _sc < MIN_SCALE and scale_collapse_step is None:
            scale_collapse_step = step
            print('WARNING scaler collapse at step %d: scale=%.3e. '
                  'fp16 gradients now underflow; weights have stopped changing. '
                  'Check for repeated inf gradients.' % (step, _sc), flush=True)
        lr = a.lr * (.1 + .9 * (1 - step / a.steps))
        for group in opt.param_groups:
            group['lr'] = lr

        if step % 25 == 0 or step == 1:
            row = {'step': step, 'loss': float(loss.detach()),
                   'scale': _sc,          # AMP scaler; a collapse is the freeze
                   'content': float(content.detach()), 'style': float(style.detach()),
                   'tone': float(tone.detach()), 'distill': float(distill.detach()),
                   'identity': float(identity.detach()),
                   'quant': float(quant.detach()),
                   'palette': float(palette.detach()),
                   'sat_loss': float(sat_loss.detach()),
                   'sat_val': (float(sat_val.detach()) if sat_val is not None
                               else -1.0),
                   'dark_share': float(dark_share.detach()),
                   'dark_share_val': (float(dark_share_val.detach())
                                      if dark_share_val is not None else -1.0),
                   'patch_tex': float(patch_tex.detach()),
                   'patch_tex_val': (float(patch_tex_val.detach())
                                     if patch_tex_val is not None else -1.0),
                   'hl_guard': float(hl_guard.detach()),
                   'hl_val': (float(hl_val.detach())
                              if hl_val is not None else -1.0),
                   'grain': float(grain.detach()),
                   'dark_hf': float(dark_hf.detach()),
                   'stroke': float(stroke.detach()),
                   'stroke_coarse': float(stroke_coarse.detach()),
                   'stroke_coarse_ratio': (float(rc_val) if rc_val is not None else -1.0),
                   'sky': float(sky.detach()),
                   'qat': qat, 'seconds': time.monotonic() - start}
            log.write(json.dumps(row) + '\n')
            log.flush()
            print(json.dumps(row), flush=True)

        if step % a.validate_every == 0 or step == a.steps:
            ck = {'model': model.state_dict(), 'step': step, 'kind': a.kind,
                  'qat': qat, 'config': config,
                  'optimizer': opt.state_dict(), 'scaler': scaler.state_dict()}
            torch.save(ck, a.out / 'latest.pt')
            torch.save(ck, a.out / f'step_{step:06d}.pt')
            report = evaluate(model, features, target, root, val, a.out, step,
                              teacher, style_mean, style_std)
            print('VALIDATION ' + json.dumps(report), flush=True)
    log.close()


if __name__ == '__main__':
    main()
