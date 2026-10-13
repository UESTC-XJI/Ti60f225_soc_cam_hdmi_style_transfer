"""量化损伤归因：到底是权重还是激活把画质搞坏的？

    python -m train.quant_ablation --ckpt runs/final/D_sw1e5

只量化权重 / 只量化激活 / 两个都量化，各自跑一遍量风格距离。
知道损坏来自哪一侧，才知道下一步该做什么——若是权重，逐通道量化或 QAT 权重侧下手；
若是激活，得往 per-channel 激活或换激活函数的方向想。

注意基准必须是**折叠+微调之后、量化之前**的那只网络。用 `net_deploy.pt` 当基准是错的
（它已经量化过了），所以这里自己重新折一遍再微调。
"""

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

from train.data import DATA, load_style  # noqa: E402
from train.deploy import (  # noqa: E402
    QMAX_A, QMAX_W, calibrate_activations, collect_in_stats, eval_images,
    finetune, fold_in, quality, weight_scales,
)
from train.model import build  # noqa: E402
from train.train import pick_device  # noqa: E402
from train.vgg import VGG16Features, style_grams  # noqa: E402


def quantize_weights(net: nn.Module, w_scales: dict, per_channel: bool = False) -> nn.Module:
    """只量化权重，激活保持浮点。"""
    out = copy.deepcopy(net)
    for name, mod in out.named_modules():
        if isinstance(mod, nn.Conv2d):
            s = w_scales[name].view(-1, 1, 1, 1)
            mod.weight.data = torch.round(mod.weight.data / s).clamp(-QMAX_W, QMAX_W) * s
    return out


def quantize_activations(net: nn.Module, a_scales: dict) -> nn.Module:
    """只量化激活，权重保持浮点。"""
    out = copy.deepcopy(net)
    for name, mod in out.named_modules():
        if isinstance(mod, nn.Conv2d):
            sa, qlo, qhi = a_scales[name]

            def pre(_m, inp, sa=sa, qlo=qlo, qhi=qhi):
                return (torch.round(inp[0] / sa).clamp(qlo, qhi) * sa,)
            mod.register_forward_pre_hook(pre)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="量化损伤归因")
    ap.add_argument("--ckpt", type=Path, required=True)
    ap.add_argument("--style", default="starry_night")
    ap.add_argument("--calib", type=int, default=48)
    ap.add_argument("--finetune", type=int, default=1500)
    ap.add_argument("--eval", type=int, default=5)
    args = ap.parse_args()

    ckpt = args.ckpt / "net.pt" if args.ckpt.is_dir() else args.ckpt
    dev = pick_device()
    blob = torch.load(ckpt, map_location=dev, weights_only=False)
    net = build(blob["args"]["net"], in_affine=True).to(dev)
    net.load_state_dict(blob["state_dict"])
    net.eval()

    vgg = VGG16Features().to(dev)
    gs = style_grams(vgg, load_style(DATA / "styles" / f"{args.style}.jpg").to(dev))
    calib = [t.to(dev) for t in eval_images(args.calib, 256)]
    test = eval_images(args.eval, 640)

    folded = fold_in(net, collect_in_stats(net, calib, dev))
    base = finetune(copy.deepcopy(folded), dev, args.finetune,
                    DATA / "styles" / f"{args.style}.jpg", 5e-4, 256, 8, 1.0, 1e5, 1e-4)

    a_s = calibrate_activations(base, calib)
    w_s = weight_scales(base, per_channel=False)

    variants = [
        ("折叠+微调 FP32（基准）", base),
        ("只量化权重 (int8)", quantize_weights(base, w_s)),
        ("只量化激活 (uint8)", quantize_activations(base, a_s)),
        ("权重+激活 (完整 INT8)",
         quantize_activations(quantize_weights(base, w_s), a_s)),
    ]
    print("\n量化损伤归因：")
    print(f"  {'变体':<26}{'PSNR':>9}{'SSIM':>9}{'风格距离':>12}")
    for label, m in variants:
        q = quality(m, test, dev, vgg, gs)
        print(f"  {label:<26}{q['psnr']:>8.2f}dB{q['ssim']:>9.4f}{q['gram']:>12.6f}")

    torch.save({"state_dict": base.state_dict(), "args": blob["args"],
                "weight_scales": {k: v.cpu() for k, v in w_s.items()},
                "activation_scales": {k: float(v.cpu()) for k, v in a_s.items()},
                "note": "IN 折叠 + 微调，量化之前"},
               ckpt.parent / "net_folded_fp32.pt")
    print(f"\n已存 {ckpt.parent / 'net_folded_fp32.pt'}（折叠+微调、未量化）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
