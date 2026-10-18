"""Correct reference for the official model, then re-render every recent version
side by side.

Every script in this folder built the official generator with
BatchNorm2d + conv bias=False and load_state_dict(strict=False), which silently
dropped 24 of 117 keys.  This module provides the verified construction
(117/117 keys, 0 missing, 0 unexpected) and the standard projections so all
comparisons can be redone on a correct baseline.

Usage:
    from official_ref import official_generator, project, palette_metrics
"""
import pathlib

import numpy as np
import torch
import torch.nn as nn
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
CKPT = ROOT / '_data' / 'style_ukiyoe.pth'


def official_generator(ckpt=CKPT, ngf=64, n_blocks=9):
    """Exact reconstruction of the released style_ukiyoe.pth.

    Verified: loads all 117 keys.  The checkpoint carries conv BIASES and norm
    layers with running stats but no affine params, so the matching build needs
    conv bias=True and InstanceNorm2d(affine=False, track_running_stats=True).
    A bias=False build silently drops the 24 bias keys.
    """
    nl = lambda c: nn.InstanceNorm2d(c, affine=False, track_running_stats=True)

    class Blk(nn.Module):
        def __init__(self, d):
            super().__init__()
            self.conv_block = nn.Sequential(
                nn.ReflectionPad2d(1), nn.Conv2d(d, d, 3), nl(d), nn.ReLU(True),
                nn.ReflectionPad2d(1), nn.Conv2d(d, d, 3), nl(d))

        def forward(self, x):
            return x + self.conv_block(x)

    class Gen(nn.Module):
        """The .model wrapper reproduces the checkpoint's `model.N.*` names."""

        def __init__(self):
            super().__init__()
            m = [nn.ReflectionPad2d(3), nn.Conv2d(3, ngf, 7), nl(ngf), nn.ReLU(True),
                 nn.Conv2d(ngf, ngf * 2, 3, 2, 1), nl(ngf * 2), nn.ReLU(True),
                 nn.Conv2d(ngf * 2, ngf * 4, 3, 2, 1), nl(ngf * 4), nn.ReLU(True)]
            m += [Blk(ngf * 4) for _ in range(n_blocks)]
            m += [nn.ConvTranspose2d(ngf * 4, ngf * 2, 3, 2, 1, 1), nl(ngf * 2), nn.ReLU(True),
                  nn.ConvTranspose2d(ngf * 2, ngf, 3, 2, 1, 1), nl(ngf), nn.ReLU(True),
                  nn.ReflectionPad2d(3), nn.Conv2d(ngf, 3, 7), nn.Tanh()]
            self.model = nn.Sequential(*m)

        def forward(self, x):
            return self.model(x)

    net = Gen()
    sd = torch.load(ckpt, map_location='cpu', weights_only=False)
    missing, unexpected = net.load_state_dict(sd, strict=False)
    if missing or unexpected:
        raise RuntimeError('official generator did not load fully: '
                           '%d missing, %d unexpected' % (len(missing), len(unexpected)))
    return net.eval()


# ------------------------------------------------------------------ metrics


def lum(a):
    """a: HxWx3 float 0..255."""
    return a.astype(np.float32) @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def highpass(a, k=4):
    L = lum(a)
    h, w = L.shape
    ch, cw = h // k * k, w // k * k
    Lc = L[:ch, :cw]
    lo = Lc.reshape(ch // k, k, cw // k, k).mean(axis=(1, 3))
    return Lc - np.repeat(np.repeat(lo, k, 0), k, 1)


def flat_share(a, thr=3.0):
    L = lum(a)
    z = np.pad(L, 1)
    win = np.lib.stride_tricks.sliding_window_view(z, (3, 3))
    return float(((win.max(axis=(2, 3)) - win.min(axis=(2, 3))) < thr).mean())


def distinct_entropy(a):
    q = (a.astype(np.int32) // 8)
    key = q[..., 0] * 1024 + q[..., 1] * 32 + q[..., 2]
    uniq = int(np.unique(key).size)
    cnt = np.bincount(key.ravel(), minlength=32768).astype(np.float64)
    cnt = cnt[cnt > 0] / key.size
    return uniq, float(-(cnt * np.log2(cnt)).sum())


def anisotropy(a):
    L = lum(a)
    gx = np.zeros_like(L); gy = np.zeros_like(L)
    gx[:, 1:-1] = (L[:, 2:] - L[:, :-2]) * 0.5
    gy[1:-1, :] = (L[2:, :] - L[:-2, :]) * 0.5
    k = 5
    box = lambda x: np.lib.stride_tricks.sliding_window_view(
        np.pad(x, k // 2), (k, k)).mean(axis=(2, 3))
    Jxx, Jyy, Jxy = box(gx * gx), box(gy * gy), box(gx * gy)
    tr = Jxx + Jyy
    det = Jxx * Jyy - Jxy ** 2
    disc = np.sqrt(np.maximum(tr ** 2 / 4 - det, 0))
    l1, l2 = tr / 2 + disc, tr / 2 - disc
    an = (l1 - l2) / np.maximum(l1 + l2, 1e-9)
    return float(an[tr > np.percentile(tr, 90)].mean())


def dark_clumps(a, thr=80):
    """Connected components of the dark mask: brushstrokes form LARGE clumps."""
    m = lum(a) < thr
    if m.sum() == 0:
        return 0, 0, 0.0
    h, w = m.shape
    seen = np.zeros_like(m, dtype=bool)
    sizes = []
    for y0 in range(h):
        for x0 in range(w):
            if not m[y0, x0] or seen[y0, x0]:
                continue
            stack = [(y0, x0)]
            seen[y0, x0] = True
            n = 0
            while stack:
                y, x = stack.pop()
                n += 1
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < h and 0 <= xx < w and m[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True
                        stack.append((yy, xx))
            sizes.append(n)
    sizes = np.array(sizes)
    return len(sizes), int(sizes.max()), float(sizes.mean())


def project(a, size):
    """Resize an image array (HxWx3, 0..255) to `size` = (W, H)."""
    im = Image.fromarray(a.astype(np.uint8))
    return np.asarray(im.resize(size, Image.Resampling.LANCZOS)).astype(np.float32)


def palette_metrics(a):
    uniq, ent = distinct_entropy(a)
    L = lum(a)
    mx, mn = a.max(2).astype(np.float32), a.min(2).astype(np.float32)
    n, largest, mean = dark_clumps(a)
    return dict(distinct=uniq, entropy=ent, flat=100 * flat_share(a),
                lum=float(L.mean()), dark=100 * float((L < 80).mean()),
                sat=float(((mx - mn) / np.maximum(mx, 1)).mean()),
                rb=float(a.reshape(-1, 3).mean(0)[0] - a.reshape(-1, 3).mean(0)[2]),
                hf=float(highpass(a).std()), ani=anisotropy(a),
                clumps=n, largest=largest, clump_mean=mean)
