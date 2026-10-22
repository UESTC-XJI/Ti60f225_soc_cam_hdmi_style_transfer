"""VGG16 感知损失（content + style Gram + TV）。

切层方式与 pytorch/examples/fast_neural_style 一致：

    slice1 = features[0:4]   -> relu1_2
    slice2 = features[4:9]   -> relu2_2
    slice3 = features[9:16]  -> relu3_3
    slice4 = features[16:23] -> relu4_3

内容用 relu3_3（Johnson et al. 原文的选择），风格用四个层全上。
Gram 按 1/(C*H*W) 归一化——不归一化的话 Gram 的元素量级随特征图尺寸变化，
换训练分辨率就得重调权重。

注意 VGG 的权重和输入归一化：网络的输出是 [0,1] 量纲的图，
但 VGG 是在 ImageNet mean/std 归一化过的输入上预训练的，所以喂进去之前必须先归一化。
忘了这步 loss 照样下降，只是收敛到一个和原版 FNS 完全不同的解。
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision.models import VGG16_Weights, vgg16

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)

STYLE_LAYERS = ("relu1_2", "relu2_2", "relu3_3", "relu4_3")


class VGG16Features(nn.Module):
    """只做前向的特征提取器，参数冻结。"""

    def __init__(self):
        super().__init__()
        feats = vgg16(weights=VGG16_Weights.IMAGENET1K_V1).features
        self.s1 = feats[0:4].eval()    # -> relu1_2
        self.s2 = feats[4:9].eval()    # -> relu2_2
        self.s3 = feats[9:16].eval()   # -> relu3_3
        self.s4 = feats[16:23].eval()  # -> relu4_3
        for p in self.parameters():
            p.requires_grad_(False)

    def forward(self, x: torch.Tensor) -> dict[str, torch.Tensor]:
        x = normalize(x)
        h1 = self.s1(x)
        h2 = self.s2(h1)
        h3 = self.s3(h2)
        h4 = self.s4(h3)
        return {"relu1_2": h1, "relu2_2": h2, "relu3_3": h3, "relu4_3": h4}


def normalize(batch: torch.Tensor) -> torch.Tensor:
    """[0,1] RGB -> VGG 期望的归一化输入。"""
    mean = batch.new_tensor(IMAGENET_MEAN).view(1, -1, 1, 1)
    std = batch.new_tensor(IMAGENET_STD).view(1, -1, 1, 1)
    return (batch - mean) / std


def gram_matrix(y: torch.Tensor, centered: bool = False) -> torch.Tensor:
    """按 1/(C*H*W) 归一化的 Gram 矩阵，形状 [B, C, C]。

    `centered=True` 时先减掉每个通道的空间均值，即用**协方差**而不是二阶矩。

    为什么这是本工程的关键开关：原始 Gram 的二阶矩里，`E[f_i]·E[f_j]` 那一项远大于
    协方差项，而自然图像各通道的空间均值彼此很接近——于是原始 Gram 距离对"有没有笔触"
    几乎不敏感。实测（未去均值）：内容原图 0.00036、纯灰图 0.00052、训练 4000 步的输出
    0.00039，三者分不开，风格项根本给不出方向。去掉均值后损失才对纹理敏感。
    """
    b, c, h, w = y.size()
    f = y.view(b, c, h * w)
    if centered:
        f = f - f.mean(dim=2, keepdim=True)
    return f.bmm(f.transpose(1, 2)) / (c * h * w)


@torch.no_grad()
def style_grams(vgg: VGG16Features, style: torch.Tensor,
                centered: bool = False) -> list[torch.Tensor]:
    """风格图的 Gram 目标，训练前算一次即可。

    **必须和训练时用的 gram_matrix 同一种模式**，否则风格目标和自己算的东西不是一回事。
    """
    feats = vgg(style)
    return [gram_matrix(feats[k], centered) for k in STYLE_LAYERS]


def content_loss(vgg: VGG16Features, y: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    return F.mse_loss(vgg(y)["relu3_3"], vgg(target)["relu3_3"])


def style_layer_weights(grams_s: list[torch.Tensor], mode: str = "none") -> list[float]:
    """逐层风格损失的权重。

    **为什么需要它**：4 层 Gram 的量级差几个数量级，直接相加时**梯度是按损失量级
    分配的**——小的那层等于没在训。本工程实测（浮世绘，4000 步后各层占总风格损失）：

        relu1_2  6.9%  |  relu2_2 37.2%  |  relu3_3 55.4%  |  **relu4_3 0.4%**

    而 relu4_3 恰恰是四层里最"结构/语义"的一层。0.4% 就是 0.4% 的梯度。
    这也是"3e4 时风格很弱"的一个候选解释：不是权重不够，是**有一层根本没工作**。

    mode:
      "none"   —— 全 1，即本工程的历史行为。
      "gatys"  —— 回到 Gatys 论文的原始口径 N_l²/4。`gram_matrix` 已经除过 (C·H·W)，
                  外面又对 N² 个元素取 MSE，等价于**额外**乘了 1/N² ——
                  **通道越多压得越狠**（relu4_3 有 512 通道，被压得最惨）。
                  乘回 N_l²/4 正好消掉这个额外因子。
                  ⚠ 总风格损失会放大几个数量级，`--style-weight` 必须重新标定。
      "target" —— 除以该层风格目标自身的均方，每层损失变成无量纲的"相对误差"，
                  量纲自动统一，不需要手工配平，也不会随风格图换一张就失衡。
    """
    if mode == "none":
        return [1.0] * len(grams_s)
    if mode == "gatys":
        return [float(g.shape[1] ** 2) / 4.0 for g in grams_s]
    if mode == "target":
        return [1.0 / float((g.double() ** 2).mean()) for g in grams_s]
    raise ValueError(f"未知的 --style-layer-norm 模式: {mode}")


def style_loss(grams_y: list[torch.Tensor], grams_s: list[torch.Tensor],
               weights: "list[float] | None" = None, per_layer: bool = False):
    """4 层 Gram 的加权 MSE。

    `weights` 见 `style_layer_weights`；不传 = 等权（历史行为）。
    `per_layer=True` 时额外返回逐层损失，供诊断打印。
    """
    per = []
    for g_y, g_s in zip(grams_y, grams_s):
        # 风格 Gram 是拿一张风格图算的，形状 [1,C,C]，而 g_y 是 [B,C,C]。
        # 不显式 expand 的话 mse_loss 会静默广播（并丢掉一条 UserWarning），
        # 结果看着差不多，但批内每张图都在跟同一个风格目标比——这里写明意图。
        per.append(F.mse_loss(g_y, g_s.expand_as(g_y)))
    if weights is not None:
        per = [w * p for w, p in zip(weights, per)]
    total = torch.stack(per).sum()
    return (total, per) if per_layer else total


def tv_loss(y: torch.Tensor) -> torch.Tensor:
    """全变分正则：抑制输出里的高频噪点。"""
    dh = (y[:, :, 1:, :] - y[:, :, :-1, :]).abs().mean()
    dw = (y[:, :, :, 1:] - y[:, :, :, :-1]).abs().mean()
    return dh + dw
