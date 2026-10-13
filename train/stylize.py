"""用训好的权重出图，并算出"画质"指标。

    python -m train.stylize --ckpt runs/_intermediate/改D_starry_night --input data/content --limit 5

网络是全卷积 + InstanceNorm，训练时用 256x256 裁剪，推理时可以直接喂 640x480。
两者结果不会完全一致（IN 的统计量随图大小变），但 style 的表现是一致的；
真要严格对齐硬件，后续得固定 IN 的统计量，那是另一件事。

**PSNR/SSIM 是拿输出和输入内容图比的**，衡量的是"内容保住了多少"。
风格迁移没有 ground truth，能横向比的就是这个数——通道数越少的网络，
理论上内容保得越好、风格越弱，所以这个指标不能单独看，必须配着样张一起看。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image  # noqa: E402

from train.data import (DATA, net_input, net_output_rgb,  # noqa: E402
                      to_batch)
from train.metrics import psnr, ssim  # noqa: E402
from train.model import build  # noqa: E402
from train.train import pick_device, save_png  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def load_net(ckpt: Path, device: torch.device):
    """从 runs/<tag>/net.pt 恢复网络。网络结构记在 ckpt 里，不用手动指定。"""
    blob = torch.load(ckpt, map_location=device, weights_only=False)
    # in_affine 决定 state_dict 里有没有 IN 的 scale/shift，必须跟训练时一致，
    # 所以从 ckpt 里读而不是用默认值——否则 load_state_dict 会报缺 key。
    net = build(blob["args"]["net"], in_affine=blob["args"].get("in_affine", True)).to(device)
    net.load_state_dict(blob["state_dict"])
    net.eval()
    return net, blob


def fit(img: Image.Image, max_side: int | None) -> Image.Image:
    """限制最长边。改D 的瓶颈在 1/4 分辨率的 3x3 卷积，尺寸越大显存越吃紧。"""
    if max_side and max(img.size) > max_side:
        s = max_side / max(img.size)
        img = img.resize((round(img.width * s), round(img.height * s)), Image.BICUBIC)
    return img


def process(net, img: Image.Image, device, multiple: int = 4
            ) -> tuple[Image.Image, float, float]:
    """出图 + 指标。

    先反射填充到 4 的倍数，跑完再裁回来：编码器每级 stride=2 用 ceil 取整
    （426 -> 213 -> 107），解码器却固定 ×2（107 -> 214 -> 428），
    所以 H/W 不是 4 的倍数时输出会比输入大 1~2 像素。
    标准 FNS 默认输入整除 4，不处理这个；真实视频帧不保证整除，必须自己兜。
    """
    # ⚠ 通道数**按网络自己取**：亮度域网络（改D-Y）是 ci=1，直接喂 [1,3,H,W] 会报错。
    # 这里也返回**可保存的 RGB**（亮度域要先把内容图的色度接回去），
    # 指标因此在 RGB 口径上算，和 3 通道网络可比。
    x3 = to_batch(img).to(device)
    x = net_input(x3, net)
    h, w = x.shape[-2:]
    ph, pw = (-h) % multiple, (-w) % multiple
    if ph or pw:
        # 反射填充要求 pad < 该维尺寸，图特别小时退回 replicate
        mode = "reflect" if min(h, w) > max(ph, pw) else "replicate"
        xp = F.pad(x, (0, pw, 0, ph), mode=mode)
    else:
        xp = x

    with torch.no_grad():
        y = net(xp)[..., :h, :w].clamp(0, 1)
    rgb = net_output_rgb(y, x3[..., :h, :w], net)
    return rgb, psnr(rgb, x3[..., :h, :w]), ssim(rgb, x3[..., :h, :w])


def main() -> int:
    ap = argparse.ArgumentParser(description="风格迁移出图 + 画质指标")
    ap.add_argument("--ckpt", type=Path, default=None,
                    help="runs/<tag> 目录或 net.pt 路径；不给则 --net/--style 自动拼")
    ap.add_argument("--net", default="改D: 1/8ch 3res 3x3")
    ap.add_argument("--style", default="starry_night")
    ap.add_argument("--input", type=Path, default=None,
                    help="内容图路径或目录，默认取 data/content 下第一张")
    ap.add_argument("--limit", type=int, default=1, help="input 是目录时最多处理几张")
    ap.add_argument("--max-side", type=int, default=640, help="最长边上限，0 表示原尺寸")
    ap.add_argument("--out", type=Path, default=None, help="输出目录，默认 runs/<tag>/out")
    args = ap.parse_args()

    ckpt = args.ckpt
    if ckpt is None:
        ckpt = ROOT / "runs" / f"{args.net.split(':')[0]}_{args.style}".replace(" ", "")
    ckpt = ckpt / "net.pt" if ckpt.is_dir() else ckpt
    if not ckpt.exists():
        print(f"找不到权重 {ckpt}，先训练：python -m train.train")
        return 1

    device = pick_device()
    net, blob = load_net(ckpt, device)
    outdir = args.out or ckpt.parent / "out"
    outdir.mkdir(parents=True, exist_ok=True)
    print(f"权重   {ckpt}（step {blob['step']}，{blob['args']['net']}）")
    print(f"输出   {outdir}")

    # 默认给**目录**而不是第一张图，否则 --limit 永远只能出 1 张
    src = args.input or (DATA / "content")
    # ⚠ 别写死 `*.jpg`：只认 jpg 时，喂一目录 PNG 会**静默地什么都不做**
    # （files 空 -> 循环不跑 -> 不报错也不出图），排查起来很费时。
    if src.is_dir():
        exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
        files = sorted(f for f in src.iterdir()
                       if f.suffix.lower() in exts)[:args.limit]
        if not files:
            print(f"目录里没有图片：{src}")
            return 1
    else:
        files = [src]

    rows = []
    for f in files:
        img = fit(Image.open(f).convert("RGB"), args.max_side or None)
        y, p, s = process(net, img, device)
        save_png(y, outdir / f"stylized_{f.stem}.png")
        save_png(to_batch(img).to(device), outdir / f"content_{f.stem}.png")
        rows.append((f.stem, img.size, p, s))
        print(f"  {f.stem}  {img.size[0]}x{img.size[1]}  PSNR {p:5.2f}dB  SSIM {s:.4f}")

    if len(rows) > 1:
        avg_p = sum(r[2] for r in rows) / len(rows)
        avg_s = sum(r[3] for r in rows) / len(rows)
        print(f"  {'平均':<12}{'':>13}  PSNR {avg_p:5.2f}dB  SSIM {avg_s:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
