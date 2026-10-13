"""把训练好的 FP32 网络变成能交给 RTL 的 INT8 网络。

三步，每步都会掉画质，所以每一步单独量一次，掉在哪儿一目了然：

    FP32 原模型（逐图 IN）
      -> [1] IN 折叠（换固定统计量）      <- 掉多少？
      -> [2] INT8 量化（权重+激活）        <- 再掉多少？

**为什么必须做这件事**：`stnet/hw.py` 里所有结论都建立在 INT8 上——
`INT8_MAC_PER_DSP = 2`、权重按 1 字节/参数算、改A 的 65.9KB 预算。
量化后画质掉多少，之前从没量过。如果掉得太狠，那条 `= 2` 和整个权重预算都要重算。

关于 IN 折叠的一个要点：我们的 IN 是**逐图统计量**（`track_running_stats=False`），
没有现成的 running stats 可折。要折必须先换成**固定统计量**——这本身就是
"固定 affine 折叠"那条路线，代价是丢掉逐图自适应性，这个代价由 [1] 量出来。
"""

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

from train.data import (DATA, net_input,  # noqa: E402
                      net_output_rgb, to_batch)
from train.model import ConvNorm, UpsampleConv, build  # noqa: E402
from train.metrics import psnr, ssim  # noqa: E402
from train.stylize import fit  # noqa: E402
from train.train import pick_device  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

QMAX_W = 127   # 权重 int8 对称
QMAX_A = 255   # 激活 uint8（ReLU 后非负，零点恒为 0，不用存 zero-point）


# ---------------------------------------------------------------- IN 折叠

def conv_norm_pairs(net: nn.Module):
    """产出网络里所有 (模块名, 父模块, 卷积, 归一化) 四元组。"""
    for name, m in net.named_modules():
        if isinstance(m, (ConvNorm, UpsampleConv)) and m.norm is not None:
            yield name, m, m.conv, m.norm


@torch.no_grad()
def collect_in_stats(net: nn.Module, images, device) -> dict:
    """统计每个 IN 输入通道的空间均值/方差，按图取平均。

    用"逐图统计量的平均"而不是"全量统计"，是因为要替代的正是逐图统计量——
    只有用它俩的平均才能把分布中心的偏移拿到。
    """
    acc: dict[str, list] = {}
    hooks = []
    for name, _, _, norm in conv_norm_pairs(net):
        def hook(_mod, inp, _out, key=name):
            x = inp[0].detach()
            s = acc.setdefault(key, [torch.zeros(x.shape[1], device=x.device),
                                     torch.zeros(x.shape[1], device=x.device), 0])
            s[0] += x.mean(dim=(2, 3)).sum(0)
            s[1] += x.var(dim=(2, 3), unbiased=False).sum(0)
            s[2] += x.shape[0]
        hooks.append(norm.register_forward_hook(hook))

    # ⚠ 通道数按网络取：亮度域网络（改D-Y）要 [B,1,H,W]，喂 3 通道直接报错。
    for img in images:
        net(net_input(img, net))
    for h in hooks:
        h.remove()
    if not acc:
        raise RuntimeError("一个 IN 都没找到——模型是不是已经折叠过了？")
    return {k: (m / n, v / n) for k, (m, v, n) in acc.items()}


def load_deploy_net(ckpt: Path, device):
    """载入 `net_folded_fp32.pt` / `net_deploy.pt` 这类**已折叠**的权重。

    折叠后的网络没有 IN 参数（`fold_in` 把 norm 换成了 Identity），直接
    `load_state_dict` 到一个带 IN 的新网络会报缺 key；即使用 strict=False 蒙混过去，
    那些**新随机初始化的 IN 照样会在 forward 里生效**，结果静默地全错。
    所以必须先按结构把 norm 也换成 Identity，再严格载入。
    """
    blob = torch.load(ckpt, map_location=device, weights_only=False)
    net = build(blob["args"]["net"], in_affine=True).to(device)
    for _, parent, _, _ in conv_norm_pairs(net):
        parent.norm = nn.Identity()
    net.load_state_dict(blob["state_dict"])
    return net.eval(), blob


def fold_in(net: nn.Module, stats: dict) -> nn.Module:
    """把 IN 折进前一层卷积，返回**新的**纯 conv+ReLU 网络。

    推导：IN 是 z = γ·(y-μ)/σ + β，固定 μ、σ 后 a = γ/σ、d = β - a·μ 都是逐通道常数。
    代入 y = W*x + b 得 z = (a·W)*x + (a·b + d)——还是同一个卷积，只是换了权重和偏置。

    折完把 IN 换成 `nn.Identity()` 而不是删掉：模块结构保持不变，
    forward 不用改，也不会打乱 `named_modules()` 的顺序。
    """
    folded = copy.deepcopy(net)
    for name, parent, conv, norm in conv_norm_pairs(folded):
        m, v = stats[name]
        a = norm.weight.detach() / torch.sqrt(v.to(norm.weight.device) + norm.eps)
        d = norm.bias.detach() - a * m.to(norm.weight.device)
        conv.weight.data.mul_(a.view(-1, 1, 1, 1))
        conv.bias.data.mul_(a).add_(d)
        parent.norm = nn.Identity()
    return folded.eval()


# ---------------------------------------------------------------- 量化

@torch.no_grad()
def calibrate_activations(net: nn.Module, images, percentile: float = 99.9,
                          max_samples: int = 20000) -> dict:
    """每个卷积输入的量化参数 -> `{层名: (scale, qmin, qmax)}`。

    **关键：逐层判断激活是有符号还是无符号。**

    残差块里第二个卷积后面**没有 ReLU**（`y = c2(relu(c1(x))); return x + y`），
    所以恒等通路的 `x + y` 是有符号的——实测这些层的激活最小值明显为负。
    如果一律按 ReLU 后的非负假设 `clamp(0, 255)`，**所有负值会被抹成 0**。
    这正是 INT8 把风格距离打坏 4 倍（0.000050 -> 0.000210）的真正原因，
    而且**加位宽完全救不回来**：实测 8/10/12/14/16 位结果一模一样，
    因为损失不是精度问题，是系统性削掉了半个动态范围。

    有符号用对称量化 [-127,127]，无符号用 [0,255]，两者零点都是 0，
    硬件上只需多一个"这一层要不要取绝对值/补码"的标志位。

    百分位裁剪（默认 99.9）用于压制长尾离群值；完整特征图太占内存，按 max_samples 抽样。
    """
    samples: dict[str, list[torch.Tensor]] = {}
    hooks = []
    for name, mod in net.named_modules():
        if isinstance(mod, nn.Conv2d):
            def hook(_m, inp, _out, key=name):
                v = inp[0].detach().flatten()
                if v.numel() > max_samples:
                    idx = torch.randperm(v.numel(), device=v.device)[:max_samples]
                    v = v[idx]
                samples.setdefault(key, []).append(v.cpu())
            hooks.append(mod.register_forward_hook(hook))
    for img in images:
        net(net_input(img, net))
    for h in hooks:
        h.remove()
    if not samples:
        raise RuntimeError("一个卷积都没找到")

    out = {}
    for k, chunks in samples.items():
        v = torch.cat(chunks)
        q = percentile / 100.0
        lo = v.quantile(1 - q).item()
        hi = v.quantile(q).item()
        if lo < -1e-6:   # 有符号（残差相加之后的层）
            scale = max(abs(lo), abs(hi)) / QMAX_W
            out[k] = (max(scale, 1e-8), -QMAX_W, QMAX_W)
        else:            # 无符号（ReLU 之后、以及网络输入）
            out[k] = (max(hi / QMAX_A, 1e-8), 0, QMAX_A)
    return out


def weight_scales(net: nn.Module, per_channel: bool) -> dict:
    """权重 scale。逐输出通道（画质好、要 per-channel 乘法器）或逐张量（硬件简单）。"""
    out = {}
    for name, mod in net.named_modules():
        if isinstance(mod, nn.Conv2d):
            amax = mod.weight.detach().abs().amax(dim=(1, 2, 3))  # [co]
            s = amax / QMAX_W
            out[name] = s.clamp_min(1e-8) if per_channel else s.max().clamp_min(1e-8).repeat(len(s))
    return out


def fake_quant(net: nn.Module, w_scales: dict, a_scales: dict) -> nn.Module:
    """就地做"量化—反量化"，量出量化误差。

    激活在每个卷积输入上量化，权重一次性量化后写回——**不建模 int32 累加溢出**，
    那是位宽问题，由 `int32_bound` 单独算。
    """
    for name, mod in net.named_modules():
        if not isinstance(mod, nn.Conv2d):
            continue
        s = w_scales[name].view(-1, 1, 1, 1)
        mod.weight.data = torch.round(mod.weight.data / s).clamp(-QMAX_W, QMAX_W) * s

        sa, qlo, qhi = a_scales[name]   # 逐层的有符号/无符号标志就体现在 qlo 上

        def pre_hook(_m, inp, sa=sa, qlo=qlo, qhi=qhi):
            return (torch.round(inp[0] / sa).clamp(qlo, qhi) * sa,)
        mod.register_forward_pre_hook(pre_hook)
    return net


def act_scale(a_scales: dict, name: str) -> float:
    """从校准结果里取纯粹的 scale（导出/整数流水线只关心这个）。"""
    return a_scales[name][0]


def int32_bound(net: nn.Module) -> list[tuple[str, int, int]]:
    """每层累加器的最坏情况上界 = (ci·k·k) · 255 · 127，以及需要的位宽。"""
    rows = []
    for name, mod in net.named_modules():
        if isinstance(mod, nn.Conv2d):
            terms = mod.in_channels * mod.kernel_size[0] * mod.kernel_size[1]
            worst = terms * QMAX_A * QMAX_W
            bits = max(1, worst.bit_length() + 1)  # +1 给符号位
            rows.append((name, worst, bits))
    return rows


# ---------------------------------------------------------------- 评估

def eval_images(n: int, max_side: int) -> list[torch.Tensor]:
    """取前 n 张内容图，限最长边后转成 [1,3,H,W] 张量（CPU）。"""
    from PIL import Image
    files = sorted((DATA / "content").glob("*.jpg"))[:n]
    return [to_batch(fit(Image.open(f).convert("RGB"), max_side)) for f in files]


@torch.no_grad()
@torch.no_grad()
def quality(net, images, device, vgg, grams_s) -> dict:
    """网络自身的画质：对内容保真 + 风格强度。

    折叠/微调之后不能再拿"和 FP32 原模型的差异"当指标了——微调出来的是另一个
    （自洽的）网络，它跟原模型的输出本来就该不一样。这时候要比的是它自己的画质。
    """
    import torch.nn.functional as F
    from train.vgg import STYLE_LAYERS, gram_matrix
    ps, ss, gd = [], [], []
    for t in images:
        x3 = t.to(device)
        x = net_input(x3, net)
        # 编码器每级 stride=2 按 ceil 取整、解码器固定 x2，非 4 倍数的尺寸输出会大 1~2 像素
        h, w = x.shape[-2:]
        ph, pw = (-h) % 4, (-w) % 4
        xp = F.pad(x, (0, pw, 0, ph), mode="reflect") if (ph or pw) else x
        y = net(xp)[..., :h, :w].clamp(0, 1)
        # 统一在 **RGB 口径**上算指标与 VGG：亮度域网络把内容色度接回来，
        # 这样和 3 通道网络的数才可比，VGG 也收得下。
        y = net_output_rgb(y, x3[..., :h, :w], net)
        ref = x3[..., :h, :w]
        ps.append(psnr(y, ref))
        ss.append(ssim(y, ref))
        f = vgg(y)
        gd.append(sum(F.mse_loss(gram_matrix(f[k]), g)
                      for k, g in zip(STYLE_LAYERS, grams_s)).item())
    n = len(ps)
    return {"psnr": sum(ps) / n, "ssim": sum(ss) / n, "gram": sum(gd) / n}


def finetune(net, device, steps: int, style_path: Path, lr: float, crop: int,
             batch: int, cw: float, sw: float, tw: float) -> nn.Module:
    """微调折叠后的网络。

    为什么必须做：训练时用逐图统计量、部署时用固定统计量，是**训练/部署错配**，
    实测后折一次掉 19.67dB。折叠后的网络已经是纯 conv+ReLU，可以像普通网络一样继续训，
    让卷积权重自己去补偿固定统计量带来的偏差。

    这里用的是和训练时完全相同的感知损失（VGG content + Gram style + TV），
    只是网络里已经没有了 IN。
    """
    import torch.nn.functional as F
    from torch.utils.data import DataLoader

    from train.data import ContentCrops, load_style
    from train.vgg import (STYLE_LAYERS, VGG16Features, gram_matrix,
                           style_grams, style_loss, tv_loss)

    vgg = VGG16Features().to(device)
    grams_s = style_grams(vgg, load_style(style_path).to(device))
    it = iter(DataLoader(ContentCrops(crop=crop, steps=10 ** 9, seed=1),
                         batch_size=batch, drop_last=True))
    opt = torch.optim.Adam(net.parameters(), lr=lr)
    for step in range(1, steps + 1):
        x3 = next(it).to(device)
        x = net_input(x3, net)
        y = net(x)
        # VGG 只认 3 通道。亮度域网络的输出是 1 通道，**必须先把内容图的色度接回去**
        # 再喂 VGG —— 否则 perceptual loss 算的是另一张图（甚至直接报错）。
        y_rgb = net_output_rgb(y, x3[..., :y.shape[-2], :y.shape[-1]], net)
        f_y = vgg(y_rgb)
        with torch.no_grad():
            f_x = vgg(x3)
        cl = F.mse_loss(f_y["relu3_3"], f_x["relu3_3"])
        sl = style_loss([gram_matrix(f_y[k]) for k in STYLE_LAYERS], grams_s)
        loss = cw * cl + sw * sl + tw * tv_loss(y)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
        if step % 200 == 0 or step == steps:
            print(f"    微调 {step:>5}/{steps}  content {cl.item():.3f}  "
                  f"style {sl.item():.5f}", flush=True)
    return net.eval()


@torch.no_grad()
def compare(ref_net, net, images, device) -> dict:
    """和参考网络（通常是 FP32 原模型）比：输出之间的 PSNR/SSIM = 纯退化量。"""
    ps, ss, mad = [], [], []
    for t in images:
        x = net_input(t.to(device), net)
        a, b = ref_net(x).clamp(0, 1), net(x).clamp(0, 1)
        ps.append(psnr(b, a))
        ss.append(ssim(b, a))
        mad.append((b - a).abs().mean().item())
    n = len(ps)
    return {"psnr": sum(ps) / n, "ssim": sum(ss) / n, "mad": sum(mad) / n,
            "psnr_each": ps, "ssim_each": ss}


def reexport(deploy_pt: Path, device, side: int = 64) -> None:
    """只重新生成 RTL 交接物，不重训。

    `net_deploy.pt` 里存了权重和它实际用的两套 scale，所以改了导出格式（比如补个偏置文件）
    时用这条路径，不必再花十几分钟重跑折叠+微调。重新量化是幂等的：已经是量化值的权重
    用同一个 scale 再量化一次还是原值。
    """
    from train.export import export_all, golden_input
    blob = torch.load(deploy_pt, map_location=device, weights_only=False)
    net = build(blob["args"]["net"], in_affine=True).to(device)
    for _, parent, _, _ in conv_norm_pairs(net):
        parent.norm = nn.Identity()
    net.load_state_dict(blob["state_dict"])
    net.eval()
    a_scales = {k: (v["scale"], v["qmin"], v["qmax"])
                for k, v in blob["activation_scales"].items()}
    export_all(net, blob["weight_scales"], a_scales, outdir=deploy_pt.parent,
               first=golden_input(net, device, side),
               tag=deploy_pt.parent.name, net_name=blob["args"]["net"])


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="IN 折叠 + 微调 + INT8 量化仿真")
    ap.add_argument("--ckpt", type=Path, required=True, help="runs/<tag> 目录或 net.pt")
    ap.add_argument("--style", default=None,
                    help="风格图：短名 / 路径 / 目录 / 通配符。**不给就用 ckpt 里记录的那张**"
                         "（训练时的 --style 存在 blob 里）。"
                         "⚠ 别再硬拼 data/styles/<名>.jpg —— 风格图可能在子目录里"
                         "（如 data/styles_watercolor/），硬拼会找不到")
    ap.add_argument("--calib", type=int, default=48, help="校准图数量")
    ap.add_argument("--act-percentile", type=float, default=99.9,
                    help="激活 scale 取的百分位（100 = 直接取 max，实测会显著掉画质）")
    ap.add_argument("--eval", type=int, default=5, help="评估图数量")
    ap.add_argument("--eval-side", type=int, default=640)
    ap.add_argument("--finetune", type=int, default=1500, help="折叠后微调步数，0 表示不微调")
    ap.add_argument("--lr", type=float, default=5e-4)
    ap.add_argument("--crop", type=int, default=256)
    ap.add_argument("--batch", type=int, default=8)
    # ⚠ 这三个**不给就用 ckpt 里训练时的值**（default=None）。
    # 写死 1e5 是只对 `D_sw1e5` 成立的巧合：`D_wc_g15` 训练用的是 **25000**，
    # 沿用 1e5 等于微调时把风格压力偷偷放大 4 倍，实测把 PSNR 从 24.5dB 打到 15.6dB。
    # **和 --style 是同一类坑：训练设置的默认值不能写死在部署侧。**
    ap.add_argument("--style-weight", type=float, default=None,
                    help="微调的风格权重；不给则用 ckpt 里训练时的值")
    ap.add_argument("--content-weight", type=float, default=None,
                    help="微调的内容权重；不给则用 ckpt 里训练时的值")
    ap.add_argument("--tv-weight", type=float, default=None,
                    help="微调的 TV 权重；不给则用 ckpt 里训练时的值")
    ap.add_argument("--out", type=Path, default=None, help="导出目录，默认 runs/<tag>/deploy")
    ap.add_argument("--golden-side", type=int, default=64,
                    help="golden 测试输入的边长（4 的倍数）。**默认 64**（golden 约 1.15MB）—— "
                         "原来是全分辨率 426x640，golden 单份 74~82MB，交接太重")
    ap.add_argument("--skip-export", action="store_true")
    ap.add_argument("--reexport", action="store_true",
                    help="只按现有 net_deploy.pt 重新生成交接物，不重训")
    args = ap.parse_args()

    if args.reexport:
        d = args.ckpt if args.ckpt.suffix == ".pt" else args.ckpt / "deploy" / "net_deploy.pt"
        reexport(d, pick_device(), args.golden_side)
        return 0

    ckpt = args.ckpt / "net.pt" if args.ckpt.is_dir() else args.ckpt
    device = pick_device()
    blob = torch.load(ckpt, map_location=device, weights_only=False)
    net = build(blob["args"]["net"], in_affine=blob["args"].get("in_affine", True)).to(device)
    net.load_state_dict(blob["state_dict"])
    net.eval()

    tag = ckpt.parent.name
    print(f"网络 {blob['args']['net']}   权重 {ckpt}")

    # 微调的损失权重：命令行优先，否则**继承训练时的值**（见 argparse 处的说明）
    trained = blob["args"]
    cw = args.content_weight if args.content_weight is not None         else float(trained.get("content_weight", 1.0))
    sw = args.style_weight if args.style_weight is not None         else float(trained.get("style_weight", 1e5))
    tw = args.tv_weight if args.tv_weight is not None         else float(trained.get("tv_weight", 1e-4))
    print(f"微调损失权重（{'命令行' if args.style_weight is not None else '继承 ckpt'}）: "
          f"content {cw:g}  style {sw:g}  tv {tw:g}")

    from train.data import DATA
    from train.vgg import VGG16Features, style_grams
    from train.data import load_style, resolve_style_pool
    # **风格图从 ckpt 里取**，别硬拼路径：训练时可能是子目录/通配符/直接路径。
    style_path = resolve_style_pool(
        args.style or str(blob["args"].get("style", "starry_night")))[0]
    print(f"风格图 {style_path}")
    vgg = VGG16Features().to(device)
    grams_s = style_grams(vgg, load_style(style_path).to(device))

    calib = [t.to(device) for t in eval_images(args.calib, 256)]
    test = [t.to(device) for t in eval_images(args.eval, args.eval_side)]

    stages = []  # (名字, 网络, 退化指标)
    stages.append(("FP32 原模型", net, None))

    # [1] 折叠
    folded = fold_in(net, collect_in_stats(net, calib, device))
    stages.append(("①IN 折叠", folded, compare(net, folded, test, device)))

    target = folded
    if args.finetune:
        print(f"\n折叠后微调 {args.finetune} 步（让卷积去补偿固定统计量）...")
        ft = finetune(copy.deepcopy(folded), device, args.finetune,
                      style_path, args.lr, args.crop,
                      args.batch, cw, sw, tw)
        target = ft
        stages.append(("②折叠+微调", ft, compare(net, ft, test, device)))
    else:
        ft = folded

    # [2] 量化
    a_scales = calibrate_activations(target, calib, args.act_percentile)
    quantized = {}
    for label, per_ch in [("逐通道", True), ("逐张量", False)]:
        ws = weight_scales(target, per_ch)
        qnet = fake_quant(copy.deepcopy(target), ws, a_scales)
        quantized[label] = (qnet, ws)
        stages.append((f"③+INT8({label})", qnet, compare(net, qnet, test, device)))

    if args.finetune:
        print("\n相对 FP32 原模型输出的退化（仅用于看变形程度，不是最终画质）：")
        print(f"  {'阶段':<20}{'PSNR':>9}{'SSIM':>9}{'平均绝对差':>12}")
        for name, _, r in stages[1:]:
            print(f"  {name:<20}{r['psnr']:>8.2f}dB{r['ssim']:>9.4f}{r['mad']:>12.5f}")

    print("\n各阶段网络自身的画质（PSNR/SSIM 对内容图，越大内容保真越好；"
          "风格距离越小越像星空）：")
    print(f"  {'阶段':<20}{'PSNR':>9}{'SSIM':>9}{'风格距离':>12}")
    for name, m, _ in stages:
        qq = quality(m, test, device, vgg, grams_s)
        print(f"  {name:<20}{qq['psnr']:>8.2f}dB{qq['ssim']:>9.4f}{qq['gram']:>12.6f}")

    rows = int32_bound(target)
    worst = max(rows, key=lambda r: r[1])
    print(f"\nINT32 累加器：最坏 {worst[0]} = {worst[1]:,}（{worst[2]} 位），"
          f"int32 上限 2,147,483,647 -> {'够用' if worst[1] < 2**31 else '不够'}")

    # 导出逐张量版：硬件最省（不需要 per-channel 乘法器），实测画质与逐通道无差
    q_net, q_w_scales = quantized["逐张量"]
    outdir = args.out or (ckpt.parent / "deploy")
    outdir.mkdir(parents=True, exist_ok=True)
    # 存一份部署网络的 state_dict，方便后面出图和做行为级仿真
    torch.save({"state_dict": q_net.state_dict(), "args": blob["args"],
                "weight_scales": {k: v.cpu() for k, v in q_w_scales.items()},
                # a_scales 现在是 (scale, qmin, qmax)，qmin<0 表示该层激活有符号
                "activation_scales": {k: {"scale": float(v[0]), "qmin": int(v[1]),
                                          "qmax": int(v[2]), "signed": bool(v[1] < 0)}
                                      for k, v in a_scales.items()},
                "note": "IN 折叠 + 微调 + INT8(逐张量) —— 交付 RTL 的那只网络"},
               outdir / "net_deploy.pt")

    if not args.skip_export:
        from train.export import export_all, golden_input
        export_all(q_net, q_w_scales, a_scales, outdir=outdir,
                   first=golden_input(q_net, device, args.golden_side),
                   tag=tag, net_name=blob["args"]["net"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
