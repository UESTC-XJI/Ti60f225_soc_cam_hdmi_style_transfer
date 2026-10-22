"""候选网络的 PyTorch 实现——与 `stnet/archs.py` 严格同构。

这是 `sim/` 里唯一依赖 torch 的模块；`stnet/` 保持纯标准库不变。
两者必须能对账：`train/parity.py` 会拿这里的模型去比 `stnet/` 的参数量和 MAC，
对不上就报错——防止实现悄悄走样成"另一个网络"，而成本模型算的还是老结构。

网络定义沿用 Johnson et al. Fast Neural Style 的参考实现：
    ConvNorm = ReflectionPad2d(k//2) -> Conv2d(k, stride) -> InstanceNorm2d
    enc1(3->c1, head) -> enc2(c1->c2, s2) -> enc3(c2->c3, s2)
    -> nres x [conv-IN-ReLU -> conv-IN -> +x]
    -> UpsampleConv(c3->c2, up2) -> UpsampleConv(c2->c1, up2) -> out conv(->3, tail)

两个刻意的选择：

1. **InstanceNorm 用 affine=True**（对齐参考实现）。一开始我为了凑上 `stnet/spec.py`
   的参数量公式 `ci*co*k*k + co` 用了 affine=False，结果画质明显吃亏——affine 是网络
   重新拿回"归一化抹掉的那部分尺度/偏移"的唯一手段。代价只有 2×136 = 272 个参数（+1.6%），
   而且 affine 是**逐通道常数**，可以完全折进前一层卷积——正是本项"IN 训练期折叠"
   路线要做的事，硬件上零额外代价。`train/parity.py` 因此把 IN 的 272 个参数单独列出，
   卷积部分仍与成本模型逐位对齐。
2. **reflection pad 而不是 zero pad**，这是 FNS 出图不产生黑边的原因，也是参考实现的做法。
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


class ConvNorm(nn.Module):
    """反射填充卷积 + （可选）实例归一化。"""

    def __init__(self, ci: int, co: int, k: int = 3, stride: int = 1,
                 norm: bool = True, in_affine: bool = True):
        super().__init__()
        self.pad = nn.ReflectionPad2d(k // 2)
        self.conv = nn.Conv2d(ci, co, k, stride)
        self.norm = nn.InstanceNorm2d(co, affine=in_affine) if norm else None

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = self.conv(self.pad(x))
        return self.norm(y) if self.norm is not None else y


class UpsampleConv(nn.Module):
    """最近邻上采样后再做反射填充卷积。

    注意与 `stnet/spec.py` 的对齐点：上采样本身无算力，
    代价全部落在紧随其后的那次卷积上（且按**输出**像素数计）。
    """

    def __init__(self, ci: int, co: int, k: int = 3, r: int = 2,
                 norm: bool = True, in_affine: bool = True):
        super().__init__()
        self.up = nn.Upsample(scale_factor=r, mode="nearest")
        self.pad = nn.ReflectionPad2d(k // 2)
        self.conv = nn.Conv2d(ci, co, k, 1)
        self.norm = nn.InstanceNorm2d(co, affine=in_affine) if norm else None

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = self.conv(self.pad(self.up(x)))
        return self.norm(y) if self.norm is not None else y


class ResidualBlock(nn.Module):
    """conv-IN-ReLU -> conv-IN -> add（恒等通路不经过激活，参考实现即如此）。"""

    def __init__(self, c: int, in_affine: bool = True):
        super().__init__()
        self.c1 = ConvNorm(c, c, 3, 1, in_affine=in_affine)
        self.c2 = ConvNorm(c, c, 3, 1, in_affine=in_affine)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu(self.c1(x))
        y = self.c2(y)
        return x + y


class FNSNet(nn.Module):
    """Fast Neural Style 主干，通道数由 mult 缩放。

    与 `stnet/archs.py::fns()` 一一对应：
        c(base) = max(1, round(base * mult))
        enc1: 3     -> c(32)   k=head
        enc2: c(32) -> c(64)   k=3 s=2
        enc3: c(64) -> c(128)  k=3 s=2
        res x nres @ c(128)
        dec1: c(128) -> c(64)  k=3（先 x2 上采样）
        dec2: c(64)  -> c(32)  k=3（先 x2 上采样）
        out:  c(32)  -> 3      k=tail，无归一化无激活
    """

    def __init__(self, mult: float = 0.125, nres: int = 3, head: int = 3,
                 tail: int = 3, in_affine: bool = True,
                 ci: int = 3, co: int = 3, cap: int | None = None):
        super().__init__()
        base_c = lambda base: max(1, round(base * mult))  # noqa: E731
        c = (lambda base: min(base_c(base), cap)) if cap else base_c
        self.mult, self.nres, self.head, self.tail = mult, nres, head, tail
        # ci/co=1 就是**亮度域**（Y-only）模式：网络只学明暗纹理，碰不到颜色，
        # 推理时把内容图的色度原样接回去 → 颜色由构造保证。见 train.py 的 y_only。
        self.ci, self.co = ci, co
        self.channels = (c(32), c(64), c(128))

        c1, c2, c3 = self.channels
        self.enc1 = ConvNorm(ci, c1, head, 1, in_affine=in_affine)
        self.enc2 = ConvNorm(c1, c2, 3, 2, in_affine=in_affine)
        self.enc3 = ConvNorm(c2, c3, 3, 2, in_affine=in_affine)
        self.res = nn.Sequential(*[ResidualBlock(c3, in_affine=in_affine)
                                   for _ in range(nres)])
        self.dec1 = UpsampleConv(c3, c2, 3, 2, in_affine=in_affine)
        self.dec2 = UpsampleConv(c2, c1, 3, 2, in_affine=in_affine)
        self.out = ConvNorm(c1, co, tail, 1, norm=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu(self.enc1(x))
        y = F.relu(self.enc2(y))
        y = F.relu(self.enc3(y))
        y = self.res(y)
        y = F.relu(self.dec1(y))
        y = F.relu(self.dec2(y))
        return self.out(y)


def icnr_init(conv: nn.Conv2d, scale: int) -> None:
    """ICNR 初始化：让 subpixel 卷积的初始状态等价于最近邻上采样。

    不做这一步，PixelShuffle 会训出**棋盘格伪影**——实测改C 的 SSIM 只有 0.09
    （同为 sw=1e5 的改A 是 0.32），并排图上是肉眼可见的斜向交叉网格，
    而且训 4000 步也不消失，是个局部极小。

    原理：PixelShuffle 把输出通道 `c*scale^2 + t` 铺到第 t 个子像素位置。
    只要让这 scale^2 个子通道的权重**完全相同**，shuffle 出来的就是同一张低分辨率图
    的 scale x scale 复制，即最近邻上采样——没有格子。
    参考 Aitken et al. 2017, "Checkerboard artifact free sub-pixel convolution"。

    只改初始化，不改结构：参数量、MAC 都不变，对账照旧成立。
    """
    out_ch, in_ch, kh, kw = conv.weight.shape
    base = torch.empty(out_ch // (scale ** 2), in_ch, kh, kw)
    nn.init.kaiming_normal_(base)
    conv.weight.data.copy_(base.repeat_interleave(scale ** 2, dim=0))


class LowResDomainNet(nn.Module):
    """全程在 1/down 分辨率域运算，末尾一次 subpixel 卷积上采样回原尺寸。

    与 `stnet/archs.py::lowres_domain()` 一一对应：
        down(4)：640x480 -> 160x120，**无乘法**（4x4 平均，硬件上是加法+移位）
        pre:  3    -> ch     k=pre_k
        res:  ch x nres
        head: ch   -> ch     k=3
        subpix: ch -> 3*down^2  k=3，然后 pixel shuffle 到 down 倍分辨率

    两条与 FNS 不同的地方，都是这个拓扑的特点：

    1. **最后一层不做归一化**。`archs.py` 的 Builder 给 subpix 标了 `norm="in"`，
       但那是 Builder 的默认值，且成本模型不读 norm 字段（参数量/MAC 都不变）。
       真在输出前套一层 IN 会把 48 个通道归一化成零均值单位方差，shuffle 出来的
       就不再是 [0,1] 的 RGB 了——所以按 FNS 对 `out` 层的处理，这里不归一化。
    2. **算力按低分辨率像素数计**。subpix 的卷积在 160x120 上做，不是 640x480，
       这正是这个架构省算力的原因（成本模型 `Layer.macs` 也是这么算的）。
    """

    def __init__(self, ch: int = 32, nres: int = 2, down: int = 4,
                 pre_k: int = 5, in_affine: bool = True):
        super().__init__()
        self.down, self.ch, self.nres = down, ch, nres
        self.pre = ConvNorm(3, ch, pre_k, 1, in_affine=in_affine)
        self.res = nn.Sequential(*[ResidualBlock(ch, in_affine=in_affine)
                                   for _ in range(nres)])
        self.head = ConvNorm(ch, ch, 3, 1, in_affine=in_affine)
        subpix_conv = nn.Conv2d(ch, 3 * down * down, 3, 1)
        icnr_init(subpix_conv, down)
        self.subpix = nn.Sequential(
            nn.ReflectionPad2d(1),
            subpix_conv,
            nn.PixelShuffle(down),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # avg_pool 与 Builder 的 down() 都按 floor 取整，非整除时两者一致
        y = F.avg_pool2d(x, self.down)
        y = F.relu(self.pre(y))
        y = self.res(y)
        y = F.relu(self.head(y))
        return self.subpix(y)


# ---- 候选网络工厂（与 stnet/archs.py::candidate_factories 同名同义）----
# 这里只放训练/出图要用的几个；成本模型那边的全集不在这里重复。
# 值是可调用对象而不是 kwargs：改C 是另一个拓扑，不吃 FNSNet 的那套参数。
BUILDERS: dict[str, callable] = {
    "改D: 1/8ch 3res 3x3":
        lambda aff=True: FNSNet(mult=0.125, nres=3, head=3, tail=3, in_affine=aff),
    "改D: 1/16ch 3res 3x3":
        lambda aff=True: FNSNet(mult=0.0625, nres=3, head=3, tail=3, in_affine=aff),
    "改D: cap8 3res 3x3":
        lambda aff=True: FNSNet(mult=0.125, nres=3, head=3, tail=3, in_affine=aff, cap=8),
    "改A: 1/4ch 3res 3x3":
        lambda aff=True: FNSNet(mult=0.25, nres=3, head=3, tail=3, in_affine=aff),
    "改B: 1/4ch 2res 3x3":
        lambda aff=True: FNSNet(mult=0.25, nres=2, head=3, tail=3, in_affine=aff),
    "改C: 1/4分辨率域 32ch 2res":
        lambda aff=True: LowResDomainNet(ch=32, nres=2, down=4, pre_k=5, in_affine=aff),
    "改D-Y: 1/16ch 2res 3x3":
        lambda aff=True: FNSNet(mult=0.0625, nres=2, head=3, tail=3, in_affine=aff,
                                ci=1, co=1),
    "改D-Y: 1/16ch 3res 3x3":
        lambda aff=True: FNSNet(mult=0.0625, nres=3, head=3, tail=3, in_affine=aff,
                                ci=1, co=1),
    "改D-Y: 1/32ch 3res 3x3":
        lambda aff=True: FNSNet(mult=0.03125, nres=3, head=3, tail=3, in_affine=aff,
                                ci=1, co=1),
    "改D-Y: cap8 3res 3x3":
        lambda aff=True: FNSNet(mult=0.125, nres=3, head=3, tail=3, in_affine=aff,
                                ci=1, co=1, cap=8),
    "改D-Y: 1/8ch 3res 3x3 亮度域":
        lambda aff=True: FNSNet(mult=0.125, nres=3, head=3, tail=3, in_affine=aff,
                                ci=1, co=1),
    "对照: 全通道 5res 9x9":
        lambda aff=True: FNSNet(mult=1.0, nres=5, head=9, tail=9, in_affine=aff),
}


def build(name: str, in_affine: bool = True) -> nn.Module:
    if name not in BUILDERS:
        raise KeyError(f"未知网络 {name!r}，可选：{list(BUILDERS)}")
    return BUILDERS[name](in_affine)


def norm_params(net: nn.Module) -> int:
    """InstanceNorm 的 affine 参数量（scale + shift）。

    成本模型 `stnet/spec.py` 只算卷积的 `ci*co*k*k + co`，不含这部分。
    单独数出来，好让对账脚本把"卷积对得上"和"IN 多花了多少"分清楚。
    """
    return sum(p.numel() for m in net.modules() if isinstance(m, nn.InstanceNorm2d)
               for p in m.parameters())


def num_params(net: nn.Module) -> int:
    """参数量——与 stnet 的 `spec.params` 对齐（IN affine=False 时无额外参数）。"""
    return sum(p.numel() for p in net.parameters())


def num_macs(net: nn.Module, h: int, w: int) -> int:
    """@给定输入尺寸的 MAC 数。

    用 forward hook 实测每层输出的空间尺寸，不做 stride 推导——
    这正是 `stnet/spec.py` 开头记的那个坑（"stride 算错导致 MAC 少算 7%"）。
    """
    total = 0

    def hook(mod: nn.Conv2d, inp, out):
        nonlocal total
        k = mod.kernel_size[0] * mod.kernel_size[1]
        total += mod.in_channels * mod.out_channels * k * out.shape[-2] * out.shape[-1]

    handles = [m.register_forward_hook(hook)
               for m in net.modules() if isinstance(m, nn.Conv2d)]
    was_training = net.training
    # ⚠ 通道数按网络自身取，**不能写死 3**——亮度域网络（改D-Y）是 ci=1。
    net.eval()
    with torch.no_grad():
        net(torch.zeros(1, getattr(net, "ci", 3), h, w))
    net.train(was_training)
    for hd in handles:
        hd.remove()
    return total
