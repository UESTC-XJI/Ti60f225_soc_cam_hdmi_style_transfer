"""把几个网络的出图并排成一张对照图，并打出指标表。

    python -m train.compare --images 2 --max-side 512
    python -m train.compare --tags 改D_starry_night cg_sw3e4    # 比不同配方

**PSNR/SSIM 是和内容原图比的**，衡量"内容保住了多少"，不是"风格像不像"。
通道越少的网络天然越容易保内容（它本来就没什么能力去改），所以
单看这两个数会把改D 看得比实际好——必须配着风格距离一起看。

风格距离用**各网络自己训练时的那种** Gram（原始 / 去均值）来算，
否则拿未去均值的尺子去量去均值训练的网络，数字没有可比性。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image  # noqa: E402
from torchvision.utils import save_image  # noqa: E402

from train.data import DATA, load_style, resolve_style_pool, to_batch  # noqa: E402
from train.model import build, norm_params, num_params  # noqa: E402
from train.stylize import ROOT, fit, process  # noqa: E402
from train.train import pick_device  # noqa: E402
from train.vgg import STYLE_LAYERS, VGG16Features, gram_matrix, style_grams  # noqa: E402

DEFAULT_TAGS = ["改D_starry_night", "改A_starry_night", "对照_starry_night"]


def load(tag: str, device):
    """返回 (网络, 训练时是否用去均值 Gram)，权重不存在就返回 None。"""
    ckpt = ROOT / "runs" / tag / "net.pt"
    if not ckpt.exists():
        return None
    blob = torch.load(ckpt, map_location=device, weights_only=False)
    net = build(blob["args"]["net"], in_affine=blob["args"].get("in_affine", True)).to(device)
    net.load_state_dict(blob["state_dict"])
    return net.eval(), blob["args"].get("gram_centered", False)


def main() -> int:
    ap = argparse.ArgumentParser(description="多网络出图对照")
    ap.add_argument("--tags", nargs="*", default=DEFAULT_TAGS,
                    help="runs/ 下的目录名，默认比三个网络的同一套配方")
    ap.add_argument("--images", type=int, default=2)
    ap.add_argument("--max-side", type=int, default=512)
    ap.add_argument("--style", default="starry_night")
    ap.add_argument("--out", type=Path, default=ROOT / "runs" / "compare.png")
    args = ap.parse_args()

    device = pick_device()
    vgg = VGG16Features().to(device)
    # --style 可以是短名、文件路径，或目录（多图时取第一张当参照，
    # 因为风格距离必须有个确定的比对对象；多图训练的网络这里数字仅供参考）
    _pool = resolve_style_pool(args.style)
    style_t = load_style(_pool[0]).to(device)
    if len(_pool) > 1:
        print(f"[注] --style 是 {len(_pool)} 张图的目录，"
              f"风格距离按第一张 {_pool[0].name} 计算")

    nets = {}
    for tag in args.tags:
        got = load(tag, device)
        if got is None:
            print(f"  [跳过] {tag}：没有 net.pt")
            continue
        nets[tag] = got
    if not nets:
        print("没有训好的权重，先跑 python -m train.train")
        return 1

    # 两种 Gram 模式的风格目标各算一份，按网络取用
    grams = {c: style_grams(vgg, style_t, centered=c) for c in {v[1] for v in nets.values()}}

    def gram_dist(y: torch.Tensor, centered: bool) -> float:
        f = vgg(y)
        return sum(F.mse_loss(gram_matrix(f[k], centered), g)
                   for k, g in zip(STYLE_LAYERS, grams[centered])).item()

    files = sorted((DATA / "content").glob("*.jpg"))[:args.images]
    for f in files:
        img = fit(Image.open(f).convert("RGB"), args.max_side)
        cells = [to_batch(img).to(device)]
        print(f"\n{f.stem}  {img.width}x{img.height}")
        for tag, (net, centered) in nets.items():
            y, p, s = process(net, img, device)
            gd = gram_dist(y, centered)
            cells.append(y)
            print(f"  {tag:<24} PSNR {p:5.2f}dB  SSIM {s:.4f}  "
                  f"风格距离 {gd:.6f}{' (去均值)' if centered else ''}")
        # 拼成一行：内容原图 + 各网络出图
        save_image(torch.cat(cells, dim=3)[0].clamp(0, 1),
                   args.out.with_name(f"{args.out.stem}_{f.stem}.png"))

    print(f"\n对照图：{args.out.parent / (args.out.stem + '_<图片名>.png')}")
    print("\n参数：")
    for tag, (net, _) in nets.items():
        n = norm_params(net)
        print(f"  {tag:<24} 卷积 {num_params(net) - n:>9,} + IN affine {n:>5,} "
              f"= {num_params(net):>9,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
