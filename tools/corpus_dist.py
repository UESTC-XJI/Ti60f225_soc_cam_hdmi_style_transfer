"""公平地比较"单图风格"和"多图风格"网络：对语料里**每一张**都算距离，再取平均。

    python -m tools.corpus_dist --tags D_ukiyoe D_ukiyoe_multi D_ukiyoe_blue

## 为什么需要这个脚本

`train.compare` 的风格距离是拿**一张固定参考图**算的。用它比较多图网络会误导：

    单图网络（训练目标 = 那张图）  → 距离必然很低
    多图网络（那张图只是 N 张之一）→ 距离必然偏高

**这是同义反复。** 公平的比法是：对语料里每张图都算一遍再平均——
问的是"**这个网络整体上有多接近这组风格**"，而不是"有多接近其中一张"。

## 指标

    mean      对语料各图的平均风格距离（越小越接近整体）
    worst     最差的那张（衡量"偏科"程度）
    uniform   各图距离的离散度：越接近 0 说明对每张都同样地像
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import load_style  # noqa: E402
from train.stylize import fit, load_net, ROOT  # noqa: E402
from train.train import pick_device  # noqa: E402
from train.vgg import STYLE_LAYERS, VGG16Features, gram_matrix, style_grams  # noqa: E402
from train.data import (DATA, net_input, net_output_rgb,  # noqa: E402
                        to_batch)
from PIL import Image  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description="对语料各图算风格距离再平均")
    ap.add_argument("--tags", nargs="+", required=True)
    ap.add_argument("--styles-dir", type=Path, default=DATA / "styles_ukiyoe")
    ap.add_argument("--images", type=int, default=2, help="每张内容图算几张的均值")
    ap.add_argument("--max-side", type=int, default=512)
    args = ap.parse_args()

    device = pick_device()
    vgg = VGG16Features().to(device)

    styles = sorted(f for f in args.styles_dir.iterdir()
                    if f.suffix.lower() in {".jpg", ".jpeg", ".png"})
    if not styles:
        print(f"目录里没有图：{args.styles_dir}")
        return 1
    print(f"语料 {len(styles)} 张：{[s.stem for s in styles]}\n")

    contents = sorted(f for f in (DATA / "content").iterdir()
                      if f.suffix.lower() in {".jpg", ".jpeg", ".png"})[: args.images]

    # 先把语料各图的 Gram 目标算好（不随网络变）
    targets = {}
    for s in styles:
        t = load_style(s).to(device)
        targets[s.stem] = style_grams(vgg, t, centered=False)

    print(f"{'网络':<20} {'mean':>10} {'worst':>10} {'uniform':>10}  逐图")
    print("-" * 78)
    for tag in args.tags:
        ckpt = ROOT / "runs" / tag / "net.pt"
        if not ckpt.exists():
            print(f"{tag:<20} 找不到 {ckpt}")
            continue
        net, _ = load_net(ckpt, device)
        per_style = []
        for s in styles:
            ds = []
            for c in contents:
                x3 = to_batch(fit(Image.open(c).convert("RGB"), args.max_side)).to(device)
                with torch.no_grad():
                    y = net(net_input(x3, net))
                    # VGG 只认 3 通道；亮度域网络要先把内容色度接回去，
                    # 否则风格距离量的是另一张图（或直接报错）。
                    y = net_output_rgb(y, x3[..., :y.shape[-2], :y.shape[-1]], net)
                    feats = vgg(y)
                    # style_grams 返回的是**列表**（按 STYLE_LAYERS 的顺序），不是字典
                    sl = np.mean([
                        torch.mean((gram_matrix(feats[k], False) - tgt) ** 2).item()
                        for k, tgt in zip(STYLE_LAYERS, targets[s.stem])])
                ds.append(sl)
            per_style.append(float(np.mean(ds)))

        per_style = np.array(per_style)
        print(f"{tag:<20} {per_style.mean():>10.6f} {per_style.max():>10.6f} "
              f"{per_style.std():>10.6f}  "
              + " ".join(f"{v:.5f}" for v in per_style))
    print()
    print("mean 越小 = 整体越接近这组风格；worst 小 = 不偏科。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
