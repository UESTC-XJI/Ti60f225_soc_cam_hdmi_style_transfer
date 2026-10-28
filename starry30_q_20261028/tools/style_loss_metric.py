#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
style_loss_metric.py —— 用**训练时同一套损失定义**评估板端输出

为什么需要它：
  之前判断画质靠"肉眼看截图"和"三通道均值/σ"，不可复现、也看不出"风格强度"。
  这个工具复刻 `demo/ml/style_transfer/train.py` 的损失函数（同一份 Features、同一个 gram），
  所以算出来的数字**与训练日志里的 content/style 同量纲、可直接对比**。

损失定义（逐字取自 train.py:13-29，未改语义）：
  Features : VGG16 features[:23]，取第 3/8/15/22 层的输出（relu1_2/relu2_2/relu3_3/relu4_3）
             输入先按 ImageNet 均值方差归一化 (mean=[.485,.456,.406], std=[.229,.224,.225])
  gram     : (z @ zᵀ) / (c·h·w)，z 是 [n, c, h·w]
  content  : MSE(feat_Y[2], feat_X[2])          — 第 3 个特征 = relu3_3
  style    : Σ MSE(gram(feat_Y[i]), gram_ref[i]) — 四层 Gram 之和

用法：
  # 板端输出 vs 风格参考图
  python tools/style_loss_metric.py --img out.png --ref starry_night.jpg --content src.png

  # 直接从 DDR dump 读（每像素 BGRX，需 --ddr 指定格式）
  python tools/style_loss_metric.py --ddr frame.bin --w 320 --h 240 --ref starry_night.jpg

注意：
  - 首次运行会下载 VGG16 权重（约 528 MB）到 ~/.cache/torch/hub/checkpoints
  - 所有图会 resize 到 256×256（与训练一致），所以不同分辨率之间可比
  - 数值越小越好；但**绝对值取决于参考图**，跨风格不可横向比较，只能同风格纵向比
"""

import argparse
import os
import sys

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from torchvision.models import vgg16, VGG16_Weights
from PIL import Image


# ---------------- 与 train.py 逐字一致 ----------------
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


# ---------------- 输入 ----------------
def image_tensor(path, size=256):
    im = Image.open(path).convert('RGB').resize((size, size), Image.Resampling.BICUBIC)
    return torch.from_numpy(np.asarray(im).copy()).permute(2, 0, 1).float() / 255


def ddr_tensor(path, w, h, size=256, invert=True):
    """DDR dump：每像素 {B,G,R,X}。显示端做 ^0x80，所以这里也做，得到"观众看到的"颜色。"""
    d = np.fromfile(path, dtype=np.uint8)
    need = w * h * 4
    if len(d) < need:
        raise SystemExit("%s 太小：%d < %d" % (path, len(d), need))
    px = d[:need].reshape(h, w, 4)
    if invert:
        px = px ^ 0x80
    rgb = np.stack([px[:, :, 2], px[:, :, 1], px[:, :, 0]], axis=2).astype(np.uint8)
    im = Image.fromarray(rgb).resize((size, size), Image.Resampling.BICUBIC)
    return torch.from_numpy(np.asarray(im).copy()).permute(2, 0, 1).float() / 255


def main(argv=None):
    ap = argparse.ArgumentParser(description="用训练时的损失定义评估板端输出")
    ap.add_argument("--img", help="待测图（png/jpg）")
    ap.add_argument("--ddr", help="待测 DDR dump（BGRX）")
    ap.add_argument("--w", type=int, default=320)
    ap.add_argument("--h", type=int, default=240)
    ap.add_argument("--no-invert", action="store_true", help="DDR 数据不做 ^0x80")
    ap.add_argument("--ref", required=True, help="风格参考图（训练时用的那张）")
    ap.add_argument("--content", help="内容图（源帧），给了就算 content loss")
    ap.add_argument("--json", help="把结果写成 JSON")
    args = ap.parse_args(argv)

    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    print("设备：%s  torch %s" % (dev, torch.__version__))
    print("参考：%s" % os.path.basename(args.ref))

    feat = Features().to(dev)

    if args.ddr:
        Y = ddr_tensor(args.ddr, args.w, args.h, invert=not args.no_invert)
        print("待测：%s (%dx%d DDR dump)" % (os.path.basename(args.ddr), args.w, args.h))
    elif args.img:
        Y = image_tensor(args.img)
        print("待测：%s" % os.path.basename(args.img))
    else:
        ap.print_help()
        return 2

    with torch.no_grad():
        R = image_tensor(args.ref).to(dev)          # 风格参考
        Y = Y.to(dev)

        ry = feat(R.unsqueeze(0))
        yy = feat(Y.unsqueeze(0))
        g_ref = [gram(f) for f in ry]
        g_y = [gram(f) for f in yy]

        style = sum(float(F.mse_loss(a, b)) for a, b in zip(g_y, g_ref))
        tv = float(((Y[:, 1:, :] - Y[:, :-1, :]).abs().mean()
                    + (Y[:, :, 1:] - Y[:, :, :-1]).abs().mean()))

        print()
        print("  style loss  = %.6f      （Σ 四层 Gram MSE）" % style)
        print("  TV          = %.6f" % tv)

        content = None
        if args.content:
            C = image_tensor(args.content).to(dev)
            cy = feat(C.unsqueeze(0))
            content = float(F.mse_loss(yy[2], cy[2]))
            print("  content loss= %.6f      （VGG relu3_3 MSE）" % content)

        # 参考图自己对自己的 style loss 应为 0（健全性检查）
        self_style = sum(float(F.mse_loss(a, a)) for a in g_ref)
        print()
        print("  健全性检查：参考图自比 style loss = %.6f（应为 0）" % self_style)

        # 逐层 style loss，看哪一层贡献最大
        print()
        print("  逐层 Gram MSE（relu1_2 / relu2_2 / relu3_3 / relu4_3）：")
        names = ["relu1_2", "relu2_2", "relu3_3", "relu4_3"]
        for i, (a, b) in enumerate(zip(g_y, g_ref)):
            print("    %-8s %.6f" % (names[i], float(F.mse_loss(a, b))))

    if args.json:
        import json
        d = {"style": style, "tv": tv, "content": content,
             "ref": os.path.basename(args.ref),
             "img": os.path.basename(args.ddr or args.img or "")}
        with open(args.json, 'w') as fh:
            json.dump(d, fh, indent=2)
        print("\n  已写 %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
