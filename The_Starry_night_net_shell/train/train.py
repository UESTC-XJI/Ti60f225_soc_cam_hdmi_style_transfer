"""训练一个风格迁移网络（一次跑一种风格）。

    python -m train.train --net "改D: 1/8ch 3res 3x3" --style starry_night --steps 3000
    python -m train.train --calibrate          # 只跑一步，打印三项损失的原始量级

风格迁移是**每种风格训一个网络**（Fast Neural Style 的核心把戏），
所以"2 种风格"就是训 2 个权重文件；硬件上对应改D 的"切权重 bank"。

--calibrate 是刻意留的：三项损失的权重不是拍脑袋来的，
先看一步里 content/style/tv 各自多大，再决定 λ 该取多少。
量级不对的话 loss 照样在降，只是降到一个风格盖死内容、或者完全没风格的解。
"""

from __future__ import annotations

import argparse
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from torch.utils.data import DataLoader  # noqa: E402

from train.data import (  # noqa: E402
    DATA,
    ContentCrops,
    color_stats,
    load_style,
    match_color,
    merge_luma,
    resolve_style_pool,
    quantize_perceptual_t,
    style_paths,
    to_batch,
    to_luma,
)
from train.metrics import effective_levels, flat_noise, flatness_profile  # noqa: E402
from train.model import BUILDERS, build, num_params  # noqa: E402
from train.quant import STEQuantize  # noqa: E402
from train.vgg import (  # noqa: E402
    STYLE_LAYERS,
    VGG16Features,
    gram_matrix,
    style_grams,
    style_layer_weights,
    style_loss,
    tv_loss,
)

ROOT = Path(__file__).resolve().parent.parent
RUNS = ROOT / "runs"


def pick_device() -> torch.device:
    return torch.device("cuda" if torch.cuda.is_available() else "cpu")


def resolve_style(name: str) -> Path:
    """风格可以给 data/styles 里的短名，也可以直接给图片路径。"""
    p = Path(name)
    if p.exists():
        return p
    cand = DATA / "styles" / f"{name}.jpg"
    if cand.exists():
        return cand
    raise FileNotFoundError(f"找不到风格图 {name!r}，现有：{[p.stem for p in style_paths()]}")


def sample_image(size: int = 256) -> torch.Tensor:
    """固定的样张输入：从第一张内容图中心裁一块，用来横向对比不同 step 的进度。"""
    from PIL import Image
    f = sorted((DATA / "content").glob("*.jpg"))[0]
    img = Image.open(f).convert("RGB")
    left, top = (img.width - size) // 2, (img.height - size) // 2
    return to_batch(img.crop((left, top, left + size, top + size)))


def save_png(t: torch.Tensor, path: Path) -> None:
    """[1,3,H,W] 的 [0,1] 张量存成 PNG。"""
    from torchvision.utils import save_image
    path.parent.mkdir(parents=True, exist_ok=True)
    save_image(t.clamp(0, 1), path)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="训练风格迁移网络")
    ap.add_argument("--net", default="改D: 1/8ch 3res 3x3", choices=list(BUILDERS))
    ap.add_argument("--no-in-affine", dest="in_affine", action="store_false",
                    help="关掉 InstanceNorm 的 affine（默认开：能折进前层卷积，且画质更好）")
    ap.add_argument("--style", default="starry_night",
                    help="风格图：可给短名（data/styles 下）、文件路径，"
                         "或**目录/通配符**（多图模式，从整组图里随机采样）")
    ap.add_argument("--style-posterize", type=int, default=0,
                    help="对风格图做**亮色度分离**量化后再算 Gram（0/1 = 关）。"
                         "后处理要走赛璐璐平涂时用这个，让网络学平坦色块而不是细纹理。"
                         "⚠ **实测不推荐**（2026-09-29）：great_wave 量化后 "
                         "mean|∇Y| 从 0.0560 涨到 0.0618，**Gram 目标反而变噪**——"
                         "纸纹和印痕被切成硬边界，等于教网络到处画边。"
                         "要用请配 --style-blur 先降噪。默认关")
    ap.add_argument("--style-posterize-c", type=int, default=0,
                    help="--style-posterize 的**色度**级数（0 = 跟随亮度级数）。"
                         "亮度域网络用不到——色度支路在 to_luma 之后是死的")
    ap.add_argument("--style-blur", type=float, default=0.0,
                    help="算 Gram 目标前对风格图做高斯模糊（像素）。>0 会去掉细笔触、"
                         "让网络输出更平滑——做赛璐璐平涂（后处理量化上色）时应该开。"
                         "默认 0 = 原始行为")
    ap.add_argument("--style-every", type=int, default=25,
                    help="多图模式下，每多少步重新采一张风格图和一块随机裁切。"
                         "目标固定会让网络过拟合到单张图的构图。单图模式忽略此项")
    ap.add_argument("--init", type=Path, default=None,
                    help="**热启动**：从一个已有 ckpt（目录或 net.pt）载入权重再训，"
                         "用于在已收敛的网络上做微调。网络结构仍由 --net 指定，必须和它一致")
    ap.add_argument("--grad-weight", type=float, default=0.0,
                    help="**边缘保持项**的权重：惩罚输出与原图的**梯度幅值**差异。"
                         "为什么需要：亮度域网络自己就丢掉约 41%% 的细节，后处理只是接不住——"
                         "实测人脸、车牌、印花这类语义细节会被抹糊，观感是'糊了'不是'画了'。"
                         "这一项直接逼网络把边缘留住。先用 --calibrate 看量级")
    ap.add_argument("--quant-levels", type=int, default=0,
                    help="**训练期输出量化**的亮度级数 K（0/1 = 直通，保持历史行为）。"
                         "网络在训练时就知道输出会被切成 K 级，从而主动学出"
                         "'大片平坦 + 边界锐利'，而不是硬量化时才把颗粒放大成椒盐。"
                         "STE 让梯度穿过 round()。见 train/quant.py。"
                         "⚠ 必须逐字等于部署期 tools/toon.py --levels，且 K ≤ 8")
    ap.add_argument("--quant-levels-c", type=int, default=0,
                    help="三通道网络时的色度级数。0 = 跟随 --quant-levels。"
                         "亮度域网络（改D-Y）用不到——to_luma 之后色度那一半是白做的")
    ap.add_argument("--flat-tv-weight", type=float, default=0.0,
                    help="**平坦区梯度惩罚**的权重：只在内容平坦处惩罚输出的梯度。"
                         "颗粒 = 内容无梯度而输出有梯度的像素，这一项直接打这个失效模式。"
                         "与 --tv-weight 的区别：TV 无条件压梯度（连真边缘一起抹），"
                         "这一项按内容梯度加权，内容越平权重越大")
    ap.add_argument("--flat-tv-thr", type=float, default=0.02,
                    help="--flat-tv-weight 的平坦度阈值。**先用 --calibrate 看 (gx+gy) 的"
                         "分位数再定**，不要用直觉量级")
    ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--crop", type=int, default=256)
    ap.add_argument("--lr", type=float, default=1e-3)
    # 损失权重：先用 --calibrate 看量级再定
    ap.add_argument("--content-weight", type=float, default=1.0)
    ap.add_argument("--style-weight", type=float, default=1e5)
    ap.add_argument("--tv-weight", type=float, default=1e-4)
    ap.add_argument("--gram-centered", action="store_true",
                    help="用去均值的 Gram（协方差）算风格损失——对纹理敏感得多，"
                         "原始 Gram 对笔触几乎不敏感。注意它量级更小，要重调 --style-weight。"
                         "⚠ 实测它把'色调偏移'换成了'纹理平铺'，不是通用解，见 README 坑 8")
    ap.add_argument("--style-layer-norm", default="none",
                    choices=("none", "gatys", "target"),
                    help="逐层平衡风格损失。默认 none = 四层等权（历史行为，实测 "
                         "relu4_3 只占 0.4%% 的梯度，等于没在训）。"
                         "gatys = 回到论文口径 N²/4；target = 按各层目标量级归一。"
                         "后者换风格图不会失衡，推荐先试它。详见 vgg.style_layer_weights")
    ap.add_argument("--match-per-sample", action="store_true",
                    help="把颜色匹配从'整批一个目标'改成**每张内容图各配一份**。"
                         "默认做法是把风格图匹配到**内容图集的平均色**（一个中性灰），"
                         "结果网络把所有内容都映射成那个中性色——**还是色偏**，只是从蓝白换成灰青。"
                         "逐样本匹配让风格目标带上**这张图自己的调色板**，"
                         "网络才有可能学会'保留输入的色彩'。需配合 --style-color-match 使用。"
                         "代价：每步多跑一次 VGG（风格图那一侧）")
    ap.add_argument("--style-color-match", nargs="?", const="std", default=None,
                    choices=("mean", "std", "full"),
                    help="训练前把**风格图**的颜色分布搬到内容图那一侧。"
                         "Gram 里 μμᵀ 那一项就是色调，优化器最省力的方向是匹配它——"
                         "这正是'输出成了滤镜'的根因；搬走颜色后风格项只剩纹理可学。"
                         "mean = 只搬均值（最稳）；std = 均值+逐通道标准差（默认）；"
                         "full = Gatys 原始协方差口径，⚠ 实测在单色调画上会炸成乱色块。"
                         "只改送进 VGG 的风格图，推理期零代价")
    ap.add_argument("--sample-every", type=int, default=250)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--calibrate", action="store_true", help="只跑一步，打印原始损失量级")
    ap.add_argument("--tag", default=None, help="输出目录名，默认按网络+风格自动生成")
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    device = pick_device()
    style_pool = resolve_style_pool(args.style)
    multi = len(style_pool) > 1
    style_tag = (style_pool[0].parent.name if multi else style_pool[0].stem)
    tag = args.tag or f"{args.net.split(':')[0]}_{style_tag}".replace(" ", "")
    outdir = RUNS / tag

    net = build(args.net, in_affine=args.in_affine).to(device)
    vgg = VGG16Features().to(device)

    # **亮度域模式由网络结构决定**（ci=co=1），不设单独开关——
    # 否则会出现"选了 1 通道网络却按 RGB 训"这种对不上的状态。
    y_only = getattr(net, "ci", 3) == 1

    # **训练期输出量化（STE）**。刻意放在 `net` 外面而不是 forward 末尾——
    # 这样 net 的结构/参数量/state_dict 全不变，`--init` 热启动和
    # `train/parity.py` 的参数对账都不受影响。见 train/quant.py 的 docstring。
    quant = STEQuantize(args.quant_levels, args.quant_levels_c).to(device)
    if args.quant_levels > 1:
        print(f"输出量化    K={args.quant_levels} 级（STE，"
              f"色度 {quant.levels_c} 级）")

    if args.init is not None:
        # 热启动：微调时网络结构必须和 ckpt 里的一致，这里不校验，交给 load_state_dict 报错
        init_p = args.init / "net.pt" if args.init.is_dir() else args.init
        net.load_state_dict(torch.load(init_p, map_location=device,
                                       weights_only=False)["state_dict"])
        print(f"热启动  从 {init_p} 载入权重")

    def grad_loss(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
        """**边缘保持项**：输出与原图的梯度幅值之差（L1）。

        只看**亮度**通道（多通道时先取均值）——我们要的是"边缘在不在"，
        不是"边缘两侧是什么颜色"，颜色由 α 旋钮管。
        和 TV 的区别：TV 是无条件压梯度（会把真边缘也压掉），
        这一项是**对齐**原图的梯度（边缘该有就得有），所以它保边、TV 抹边。
        """
        ga = a.mean(1, keepdim=True) if a.shape[1] > 1 else a
        gb = b.mean(1, keepdim=True) if b.shape[1] > 1 else b
        dx = (ga[:, :, :, 1:] - ga[:, :, :, :-1]) - (gb[:, :, :, 1:] - gb[:, :, :, :-1])
        dy = (ga[:, :, 1:, :] - ga[:, :, :-1, :]) - (gb[:, :, 1:, :] - gb[:, :, :-1, :])
        return dx.abs().mean() + dy.abs().mean()

    def flat_tv_loss(yq: torch.Tensor, x: torch.Tensor, thr: float) -> torch.Tensor:
        """**平坦区梯度惩罚**：只在内容平坦处惩罚输出的梯度。

        颗粒的定义就是"内容没有梯度而输出有梯度"的像素。`tv_loss` 做不到这件事
        ——它无条件压梯度，会把内容真边缘一起抹掉。这一项按**内容自身的梯度**
        加权：内容越平，权重越接近 1；内容真有边的地方，权重趋近 0。

        ⚠ 这不只是"锦上添花"。量化后 `|∇yq|` 只能是 0 或 `1/(K-1)` 两个取值，
        而 `grad_loss` 要匹配原图的梯度幅值——网络满足两边**最省力的作弊**是
        在平滑区放交替的相邻两级来"伪造梯度"。那正是 QAT 的经典伪影，
        而且**看起来和要除掉的椒盐一模一样**。这一项是专门堵它的。
        """
        # ⚠ 两个方向的差分形状不同（W-1 vs H-1），**必须分开加权**，
        # 不能先合成一个 w —— 那样广播会直接报错。
        gx = (x[:, :, :, 1:] - x[:, :, :, :-1]).abs().mean(1, keepdim=True)
        gy = (x[:, :, 1:, :] - x[:, :, :-1, :]).abs().mean(1, keepdim=True)
        dx = (yq[:, :, :, 1:] - yq[:, :, :, :-1]).abs().mean(1, keepdim=True)
        dy = (yq[:, :, 1:, :] - yq[:, :, :-1, :]).abs().mean(1, keepdim=True)
        wx = torch.exp(-gx / max(thr, 1e-6)).detach()        # 内容越平越接近 1
        wy = torch.exp(-gy / max(thr, 1e-6)).detach()
        return (wx * dx).mean() + (wy * dy).mean()

    def to_vgg(t: torch.Tensor) -> torch.Tensor:
        """VGG 只吃 3 通道。亮度域下把单通道复制成 3 通道再送，
        等价于拿一张灰度图去做感知损失。"""
        return t.repeat(1, 3, 1, 1) if y_only else t

    srng = random.Random(args.seed + 1)

    def posterize_style(t: torch.Tensor) -> torch.Tensor:
        """风格图的色阶量化。**亮色度分离**，不是 RGB 逐通道。

        ⚠ 这里原来写的是 `torch.round(t*(L-1))/(L-1)`（RGB 逐通道）。那是错的：
        N 级**逐通道** round 其实是 **N³ 色**，而**亮度仍然连续**——想切出"平涂色块"
        却切不出来。实测（2026-09-29）：对已平滑图套 L=6，16 级亮度口径下
        有效色阶**仍是 16**，等于没量化。

        真正能出色带的是亮色度分离量化，与部署期 `toon.py --levels` 同一张表
        （见 `train/data.py::quantize_perceptual_t`）。

        ⚠ 另外：对 改D-Y 这种 1 通道网络，"亮色度分离"会**退化成纯量化亮度**
        （色度那一半 `to_luma` 之后就丢了）。仍然走同一函数，是为了与部署链路同构、
        将来三通道网络能直接复用。
        """
        if args.style_posterize <= 1:
            return t
        return quantize_perceptual_t(
            t, levels_y=args.style_posterize,
            levels_c=args.style_posterize_c or args.style_posterize)

    def _gauss_blur(t: torch.Tensor, sigma: float) -> torch.Tensor:
        """对 (1,C,H,W) 做可分离高斯模糊。"""
        if sigma <= 0:
            return t
        r = max(1, int(round(3 * sigma)))
        x = torch.arange(-r, r + 1, dtype=t.dtype, device=t.device)
        k = torch.exp(-(x ** 2) / (2 * sigma ** 2))
        k = k / k.sum()
        c = t.shape[1]
        kx = k.view(1, 1, 1, -1).repeat(c, 1, 1, 1)
        ky = k.view(1, 1, -1, 1).repeat(c, 1, 1, 1)
        t = F.conv2d(F.pad(t, (r, r, 0, 0), mode="replicate"), kx, groups=c)
        t = F.conv2d(F.pad(t, (0, 0, r, r), mode="replicate"), ky, groups=c)
        return t

    # 内容图的颜色统计，供 --style-color-match 用。
    # 用固定 seed 的独立采样，**不碰训练时的取数顺序**。
    color_ref = None
    if args.style_color_match:
        ds_c = ContentCrops(crop=args.crop, steps=10 ** 9, seed=args.seed + 7)
        ld_c = DataLoader(ds_c, batch_size=8, num_workers=0, drop_last=True)
        with torch.no_grad():
            color_ref = color_stats(next(iter(ld_c)).to(device))
        mu = ", ".join(f"{v:.3f}" for v in color_ref[0].tolist())
        print(f"颜色匹配  风格图颜色统计 → 内容图   内容 μ = ({mu})")

    def sample_style_grams():
        """从风格图池里随机取一张、随机裁一块，算 Gram 目标。

        多图模式下每 `--style-every` 步重采一次：目标固定的话，网络会过拟合到
        那张图的构图；随机采样学的是整组图的**共性风格**。
        单图模式下池子只有一张，random_crop 也关掉，行为与原管线完全一致。
        """
        p = srng.choice(style_pool)
        t = load_style(p, random_crop=multi, rng=srng).to(device)
        # ① 颜色匹配放在**最前面**：它是一次颜色空间的仿射变换，
        #    按 Gatys 2016 的定义就该作用在原始风格图上。
        #    后面的模糊是线性的、和它可交换；量化是硬切块，放在它后面才能
        #    在"已经搬到内容图色域"的空间里切出平坦色块。
        if color_ref is not None:
            t = match_color(t, *color_ref, mode=args.style_color_match)
        # ② 模糊掉风格图的细笔触，让网络学"大色块"而不是"到处画细纹"。
        # ⚠ 实测**不推荐**：模糊会把颜色和结构一起抹掉，输出像蒙了层灰。
        #   想让网络输出平坦色块，用下面的 --style-posterize 而不是这个。
        t = _gauss_blur(t, args.style_blur)
        # ③ 量化风格图：**保留硬色块和明确色界**，只去掉细纹理。
        # 和模糊的区别就在这里——模糊是"抹平"，量化是"切块"。
        # 后处理管线要的就是平坦色块，让网络对着量化目标学，方向才一致。
        t = posterize_style(t)
        if y_only:
            # 风格图也只看亮度——**颜色的活儿压根不归网络管**
            t = to_luma(t)
        return style_grams(vgg, to_vgg(t), centered=args.gram_centered)

    def style_grams_for_batch(x: torch.Tensor):
        """逐样本颜色匹配的风格 Gram（[B,C,C] 而不是 [1,C,C]）。

        每张内容图各自算一次颜色统计，把风格图搬到**这张图自己的色域**，
        再一起送 VGG 算 Gram。这样风格目标带着每张图自己的调色板，
        网络才可能学到"保留输入色彩"而不是"统一映射成某个中性色"。
        """
        p = srng.choice(style_pool)
        t = load_style(p, random_crop=multi, rng=srng).to(device)
        t = _gauss_blur(t, args.style_blur)
        t = posterize_style(t)
        ts = torch.cat([match_color(t, *color_stats(x[i:i + 1]),
                                    mode=args.style_color_match)
                        for i in range(x.shape[0])])
        return style_grams(vgg, ts, centered=args.gram_centered)

    def show_layer_share(per, tag: str) -> None:
        """打印各层对风格损失的占比——**这是本工程最该盯的诊断量**。"""
        vals = [p.item() for p in per]
        tot = sum(vals)
        if tot <= 0:
            return
        parts = "  ".join(f"{k} {v / tot * 100:5.1f}%"
                          for k, v in zip(STYLE_LAYERS, vals))
        print(f"  逐层风格占比 [{tag}]   {parts}")

    grams_s = sample_style_grams()
    layer_w = style_layer_weights(grams_s, args.style_layer_norm)
    if args.style_layer_norm != "none":
        print(f"逐层权重  --style-layer-norm {args.style_layer_norm}  "
              f"{[f'{w:.3g}' for w in layer_w]}")

    print(f"网络   {args.net}  ({num_params(net):,} 参数)")
    print(f"风格   {len(style_pool)} 张" if multi else f"风格   {style_pool[0].name}")
    print(f"设备   {device}")
    print(f"输出   {outdir}")

    ds = ContentCrops(crop=args.crop, steps=10 ** 9, seed=args.seed)
    loader = DataLoader(ds, batch_size=args.batch, num_workers=0, drop_last=True)
    it = iter(loader)

    opt = torch.optim.Adam(net.parameters(), lr=args.lr)

    def step_losses(x3: torch.Tensor):
        # x3 恒为原始 RGB：内容损失的目标、颜色统计、预览合成都用它。
        # 亮度域下网络只吃 Y，所以单独转一份。
        x = to_luma(x3) if y_only else x3
        # ⚠ `quant` 包在这里，所以下游**所有**损失项（cl/sl/gl/tv）看到的都是
        # **量化后**的输出——这正是我们要的：网络必须学会"产出经得起量化的输出"。
        y = quant(net(x))
        feats_y = vgg(to_vgg(y))
        with torch.no_grad():  # 目标特征是常量，不需要建图
            feats_x = vgg(to_vgg(x))
        cl = F.mse_loss(feats_y["relu3_3"], feats_x["relu3_3"])
        gs, w = grams_s, layer_w
        if args.match_per_sample:
            # 风格目标随每张内容图变 → 只能每步重算（target 模式的权重也要跟着重算）
            gs = style_grams_for_batch(x)
            w = style_layer_weights(gs, args.style_layer_norm)
        sl, sl_per = style_loss([gram_matrix(feats_y[k], args.gram_centered)
                                 for k in STYLE_LAYERS], gs,
                                weights=w, per_layer=True)
        # 边缘保持项：拿**网络的原始输出**和内容比，不能拿 to_vgg 之后的。
        # ⚠ 此时 y 已是量化后的输出。语义变了：K 级图上 |∇y| 只能是 0 或 1/(K-1)，
        # 所以这一项在量化后**管不了梯度幅值、只能管边界位置**——恰好是赛璐璐要的。
        gl = grad_loss(y, x) if args.grad_weight > 0 else torch.zeros((), device=device)
        ftvl = (flat_tv_loss(y, x, args.flat_tv_thr)
                if args.flat_tv_weight > 0 else torch.zeros((), device=device))
        return y, cl, sl, tv_loss(y), sl_per, gl, ftvl

    if args.calibrate:
        x = next(it).to(device)
        with torch.no_grad():
            yq, cl, sl, tvl, sl_per, gl, ftvl = step_losses(x)
        print("\n单步原始损失量级（未加权）：")
        print(f"  content (relu3_3 MSE)  {cl.item():.6f}")
        print(f"  style   (4 层 Gram MSE) {sl.item():.6f}")
        print(f"  tv      (全变分)        {tvl.item():.6f}")
        print(f"  grad    (边缘保持 L1)   {gl.item():.6f}")
        print(f"  flat_tv (平坦区梯度)    {ftvl.item():.6f}")
        show_layer_share(sl_per, "加权后")
        print("\n加权后占比：")
        print(f"  content x {args.content_weight:g} = {cl.item() * args.content_weight:.4g}")
        print(f"  style   x {args.style_weight:g} = {sl.item() * args.style_weight:.4g}")
        print(f"  tv      x {args.tv_weight:g} = {tvl.item() * args.tv_weight:.4g}")
        print(f"  grad    x {args.grad_weight:g} = {gl.item() * args.grad_weight:.4g}")
        print(f"  flat_tv x {args.flat_tv_weight:g} = {ftvl.item() * args.flat_tv_weight:.4g}")
        # ---- 诊断：量化到底有没有生效（训练中唯一能自动判的量）----
        # ⚠ 这两个数**不要**拿来下"好不好看"的结论，只用来判"量化生效没有"。
        yv = yq[:, 0:1] if yq.shape[1] == 1 else to_luma(yq)
        xv = x[:, 0:1] if x.shape[1] == 1 else to_luma(x)
        print(f"\n量化诊断（K={args.quant_levels}，0=直通）：")
        print(f"  有效色阶数      {effective_levels(yv):>3}   （应 ≈ K={max(args.quant_levels, 1)}）")
        print(f"  平坦区 Y std    {flat_noise(yv):.4f}   （内容图 {flat_noise(xv):.4f}）"
              f"   ← 训练中要盯到 < 0.05")
        g = flatness_profile(x)
        print(f"  内容平坦度 (gx+gy) 分位：p10 {g[0]:.4f}  p50 {g[1]:.4f}  p90 {g[2]:.4f}")
        print(f"   ⇒ --flat-tv-thr 建议取 p50~p90 之间，当前 {args.flat_tv_thr:g}")
        return 0

    ref = sample_image(args.crop).to(device)
    outdir.mkdir(parents=True, exist_ok=True)
    save_png(ref, outdir / "input.png")

    t0 = time.time()
    for step in range(1, args.steps + 1):
        # 多图模式：定期换风格目标和裁切位置，学整组图的共性而不是某一张的构图
        if multi and args.style_every > 0 and step % args.style_every == 0:
            grams_s = sample_style_grams()
            # target 模式依赖具体的风格目标，换图后必须重算权重
            layer_w = style_layer_weights(grams_s, args.style_layer_norm)

        x = next(it).to(device)
        y, cl, sl, tvl, sl_per, gl, ftvl = step_losses(x)
        if step == 1 or step == args.steps:
            show_layer_share(sl_per, f"step {step}")
        loss = (args.content_weight * cl + args.style_weight * sl
                + args.tv_weight * tvl + args.grad_weight * gl
                + args.flat_tv_weight * ftvl)

        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()

        if step % 50 == 0 or step == 1:
            sps = step / max(time.time() - t0, 1e-9)
            # ⚠ 这是**随机批**上的读数，批间抖动 ±0.05，只当粗略参考。
            # 判趋势请看每 --sample-every 步那行 [样张]（固定图，跨 step 可比）。
            yv = y.detach()[:, 0:1] if y.shape[1] == 1 else to_luma(y.detach())
            diag = (f"  色阶 {effective_levels(yv):>2}  平坦std~{flat_noise(yv):.4f}"
                    if args.quant_levels > 1 else "")
            print(f"step {step:>5}/{args.steps}  "
                  f"content {cl.item():.4f}  style {sl.item():.5f}  tv {tvl.item():.5f}"
                  f"{diag}  | {sps:.1f} step/s  {time.time() - t0:.0f}s", flush=True)

        if step % args.sample_every == 0 or step == args.steps:
            net.eval()
            with torch.no_grad():
                # ⚠ 预览**必须**过量化器。否则训练中看到的图和部署看到的是两张图
                # ——坑 #7「尺子拿错了」的同型错误。
                yraw = quant(net(to_luma(ref) if y_only else ref))
                if y_only:
                    # 预览必须**把色度接回去**，否则看到的是一张灰度图，判不了效果
                    out = merge_luma(yraw, ref)
                else:
                    out = yraw
                save_png(out, outdir / f"step_{step:05d}.png")
                # **稳定版**量化诊断：在**固定样张**上算，跨 step 可比。
                # 每 50 步那个是在随机批上算的，躁得看不出版趋势，只当粗略参考——
                # 判"量化生效没有、平不平"一律以这一行为准。
                if args.quant_levels > 1:
                    yv = yraw[:, 0:1] if yraw.shape[1] == 1 else to_luma(yraw)
                    print(f"        [样张] 色阶 {effective_levels(yv):>2}  "
                          f"平坦std {flat_noise(yv):.4f}", flush=True)
            net.train()
            torch.save({"step": step, "args": vars(args), "state_dict": net.state_dict()},
                       outdir / "net.pt")

    print(f"\n完成，用时 {time.time() - t0:.0f}s，权重 {outdir / 'net.pt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
