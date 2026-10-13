"""色度混合系数 α 的扫描：在"完全保真"和"完全用风格配色"之间找位置。

    python -m tools.chroma_sweep --ckpt runs/D_ukiyoe_y --style great_wave

## 为什么需要这个旋钮

亮度域（Y-only）路线把"不失真"做到了极致——网络只学明暗纹理，颜色由构造保证。
**但代价是风格里"配色"那一半整个传不过来**：浮世绘之所以像浮世绘，
靛蓝米白的配色占了大半，只剩纹理就退化成"加了滤镜的原图"。

这个工具把配色**按比例**混回去：

    色度 = (1−α)·原图色度 + α·风格色度

    α = 0  → 完全保真，风格只剩纹理（现在的行为）
    α = 1  → 完全采用风格配色（风格最强，色偏最大）

## 硬件代价

整条色彩混合就是一个**逐像素 3×3 矩阵 + 偏置**，等价于一个 **1×1 卷积**——
加速器本来就在做卷积，代价接近零。矩阵可以离线算好存成常数（冻结），
也可以逐帧用 3 个通道的均值/方差现算（6 个累加器 + RISC-V 上算 3×3 矩阵）。

⚠ 逐帧现算会引入帧间闪烁（每帧矩阵略有不同），演示时建议先冻结。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import (  # noqa: E402
    DATA,
    blend_chroma,
    color_stats,
    load_style,
    merge_luma,
    to_batch,
    net_input,
    transfer_matrix,
)
from train.stylize import fit, load_net  # noqa: E402

from PIL import Image, ImageDraw  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def chroma(t: torch.Tensor) -> torch.Tensor:
    f = t.reshape(3, -1)
    mu = f.mean(dim=1)
    return mu - mu.mean()


def main() -> int:
    ap = argparse.ArgumentParser(description="色度混合系数 α 扫描")
    ap.add_argument("--ckpt", type=Path, default=ROOT / "runs" / "D_ukiyoe_y")
    ap.add_argument("--style", default="great_wave", help="风格图短名，取它的配色")
    ap.add_argument("--input", type=Path, default=DATA / "content")
    ap.add_argument("--limit", type=int, default=1, help="出对照图的张数")
    ap.add_argument("--max-side", type=int, default=320)
    ap.add_argument("--steps", type=int, default=11, help="α 的档数（0→1 均分）")
    ap.add_argument("--out", type=Path, default=ROOT / "runs" / "chroma_sweep")
    args = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    # 和 toon.py 一样的约定：--ckpt 给目录就自动找里面的 net.pt
    ckpt = args.ckpt / "net.pt" if args.ckpt.is_dir() else args.ckpt
    net, _ = load_net(ckpt, device)
    if getattr(net, "ci", 3) != 1:
        print("⚠ 这个网络不是亮度域（ci≠1），色度混合没有意义——它本来就会改颜色")
        return 1

    style = load_style(DATA / "styles" / f"{args.style}.jpg").to(device)
    mu_s, cov_s = color_stats(style)

    alphas = [i / (args.steps - 1) for i in range(args.steps)]
    args.out.mkdir(parents=True, exist_ok=True)

    files = sorted(f for f in args.input.iterdir()
                   if f.suffix.lower() in {".jpg", ".jpeg", ".png"})

    print(f"{'图':<18}" + "".join(f"  a={a:.1f}" for a in alphas))
    for f in files[:args.limit]:
        img = fit(Image.open(f).convert("RGB"), args.max_side)
        x = to_batch(img).to(device)
        with torch.no_grad():
            y = net(net_input(x, net))
        y = y[:, :, :x.shape[2], :x.shape[3]]     # 编码器 ceil / 解码器 ×2 会有几像素差

        M, b = transfer_matrix(*color_stats(x), mu_s, cov_s, mode="std")
        ch_c = chroma(x)

        panels, devs = [], []
        for a in alphas:
            xa = blend_chroma(x, M, b, a)
            out = merge_luma(y, xa)               # 亮度用网络的，色度用混合后的
            panels.append(out)
            devs.append((chroma(out) - ch_c).abs().sum().item())

        print(f"{f.stem:<18}" + "".join(f"  {d:6.3f}" for d in devs))

        # 拼一条对照带：最左是原图，右边依次是各 α 档，每格上面标 α
        from torchvision.transforms.functional import to_pil_image
        tiles = [to_pil_image(x[0].cpu())] + [to_pil_image(p[0].cpu()) for p in panels]
        tw, th = tiles[0].size
        bar = 18
        sheet = Image.new("RGB", (tw * len(tiles), th + bar), (250, 250, 252))
        draw = ImageDraw.Draw(sheet)
        for i, (tile, lb) in enumerate(zip(tiles, ["orig"] + [f"a={a:.1f}" for a in alphas])):
            sheet.paste(tile, (i * tw, bar))
            draw.text((i * tw + 4, 4), lb, fill=(20, 20, 20))
        sheet.save(args.out / f"sheet_{f.stem}.png")

    print(f"\n输出在 {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
