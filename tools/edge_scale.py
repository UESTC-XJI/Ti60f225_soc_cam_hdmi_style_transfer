"""边缘检测：阈值 vs 尺度，到底哪个能分开"纹理"和"结构"？

    python -m tools.edge_scale --input data/content/000000000285.jpg

**要回答的问题**：在边缘检测前加模糊（按尺度筛），能不能用"调阈值"（按强度筛）替代？

**预期结论**：不能，因为两者是**正交的两个维度**——

    阈值：梯度幅值 > T                 → 按【强度】筛
    模糊：梯度在空间尺度 σ 上仍然显著  → 按【尺度】筛

毛发的纹理和物体的轮廓，**强度范围是重叠的**（毛尖对毛根的高对比度可以很陡），
但**尺度范围不重叠**（纹理是高频，轮廓是低频）。所以阈值切不开它们。

本脚本用**百分位阈值**保证可对比性：不管 σ 多大，都取梯度最强的同样比例像素。
这样"同一比例下 σ 越大是不是越干净"才是公平的比较。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.toon import blur, gradient_xy, nonmax_suppress  # noqa: E402
from train.data import DATA  # noqa: E402


def mask_at(rgb: np.ndarray, sigma: float, pct: float) -> tuple[np.ndarray, float]:
    """在给定尺度下，取梯度最强的 pct% 像素作为边缘。返回 (掩码, 实际阈值)。"""
    mag, gx, gy = gradient_xy(rgb, sigma)
    n = nonmax_suppress(mag, gx, gy)
    thr = float(np.percentile(n, 100.0 - pct))
    return n > thr, thr


def main() -> int:
    ap = argparse.ArgumentParser(description="阈值 vs 尺度：边缘提取的两种筛选")
    ap.add_argument("--input", type=Path,
                    default=DATA / "content" / "000000000285.jpg")
    ap.add_argument("--max-side", type=int, default=420)
    ap.add_argument("--sigmas", type=float, nargs="*", default=[0.0, 1.5, 3.0, 5.0])
    ap.add_argument("--pcts", type=float, nargs="*", default=[2.0, 5.0, 10.0])
    ap.add_argument("--out", type=Path, default=Path("runs/edge_scale.png"))
    args = ap.parse_args()

    img = Image.open(args.input).convert("RGB")
    if max(img.size) > args.max_side:
        s = args.max_side / max(img.size)
        img = img.resize((round(img.width * s), round(img.height * s)), Image.BICUBIC)
    rgb = np.asarray(img).astype(np.float32) / 255.0
    h, w = rgb.shape[:2]

    print(f"图 {args.input.name}  {w}x{h}")
    print(f"列 = 边缘占比（百分位阈值，保证同一尺度内可比）")
    print(f"行 = 不同尺度 σ\n")

    # 阈值诊断表：同一 σ 下，纹理区和结构区能不能靠阈值分开？
    print("── 梯度幅值的百分位（看纹理把分布推到多高）")
    print(f"{'σ':>5} {'P50':>8} {'P90':>8} {'P99':>8} {'P99.9':>8}  {'最大':>8}")
    for sg in args.sigmas:
        mag, gx, gy = gradient_xy(rgb, sg)
        n = nonmax_suppress(mag, gx, gy)
        v = n.ravel()
        print(f"{sg:>5.1f} " + " ".join(
            f"{np.percentile(v, p):>8.4f}" for p in (50, 90, 99, 99.9))
            + f" {v.max():>8.4f}")
    print()

    # 拼图：每行一个 σ，每列一个占比
    cell = 300
    bar = 20
    sheet = Image.new("RGB", (cell * (len(args.pcts) + 1),
                              (cell + bar) * (len(args.sigmas) + 1)), (250, 250, 252))
    d = ImageDraw.Draw(sheet)

    thumb = img.resize((cell, cell), Image.BICUBIC)
    sheet.paste(thumb, (0, bar))
    d.text((5, 4), "content", fill=(20, 20, 30))
    for j, p in enumerate(args.pcts):
        d.text((cell * (j + 1) + 5, 4), f"top {p:g}%", fill=(20, 20, 30))

    for i, sg in enumerate(args.sigmas):
        y = (cell + bar) * (i + 1)
        d.text((5, y + 4), f"σ={sg:g}", fill=(20, 20, 30))
        for j, p in enumerate(args.pcts):
            m, thr = mask_at(rgb, sg, p)
            vis = np.where(m[..., None], rgb * 0.15, 1.0)
            sheet.paste(Image.fromarray((vis * 255).astype(np.uint8)).resize((cell, cell),
                        Image.NEAREST), (cell * (j + 1), y))
            d.text((cell * (j + 1) + 5, y + 4), f"T={thr:.3f}",
                   fill=(20, 20, 30))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print(f"对照图 -> {args.out}")
    print()
    print("看什么：找一行『σ=0 且阈值调到最高』，再和 σ=3 那一行比——")
    print("  如果 σ=0 无论阈值多高都清不掉毛发的碎线，就说明**阈值切不开纹理和结构**。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
