"""PSNR / SSIM——用来横向比"不同通道数的网络，画质差多少"。

自己实现而不引 skimage：本机没装，而且这两个公式短到不值得为它加一个依赖。

SSIM 用标准参数（11x11 高斯窗、σ=1.5），与 Wang et al. 2004 原文一致，
这样算出来的数才能和别处报的 SSIM 放在一张表里比。
"""

from __future__ import annotations

import math

import torch
import torch.nn.functional as F


def psnr(a: torch.Tensor, b: torch.Tensor, data_range: float = 1.0) -> float:
    """峰值信噪比（dB）。a/b 形状 [B,3,H,W]，范围 [0,data_range]。"""
    mse = F.mse_loss(a, b).item()
    if mse == 0:
        return float("inf")
    return 10 * math.log10(data_range ** 2 / mse)


def _gaussian_window(size: int = 11, sigma: float = 1.5) -> torch.Tensor:
    coords = torch.arange(size, dtype=torch.float32) - (size - 1) / 2
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = (g / g.sum()).unsqueeze(0)
    return (g.t() @ g).unsqueeze(0).unsqueeze(0)  # [1,1,size,size]


def ssim(a: torch.Tensor, b: torch.Tensor, data_range: float = 1.0) -> float:
    """结构相似度。逐通道算再平均（与 skimage 的 channel_axis 行为一致）。"""
    c = a.size(1)
    win = _gaussian_window().to(a.device).expand(c, 1, -1, -1)

    mu_a = F.conv2d(a, win, groups=c)
    mu_b = F.conv2d(b, win, groups=c)
    mu_a2, mu_b2, mu_ab = mu_a * mu_a, mu_b * mu_b, mu_a * mu_b

    sigma_a2 = F.conv2d(a * a, win, groups=c) - mu_a2
    sigma_b2 = F.conv2d(b * b, win, groups=c) - mu_b2
    sigma_ab = F.conv2d(a * b, win, groups=c) - mu_ab

    c1 = (0.01 * data_range) ** 2
    c2 = (0.03 * data_range) ** 2
    num = (2 * mu_ab + c1) * (2 * sigma_ab + c2)
    den = (mu_a2 + mu_b2 + c1) * (sigma_a2 + sigma_b2 + c2)
    # 边缘处方差可能因数值误差略为负，对分母加下限避免除出 NaN
    return (num / den.clamp_min(1e-12)).mean().item()


# ---------------------------------------------------------------- 卡通化量具
# 下面四个是**定位工具**，不是结论工具——它们回答"三个模块哪个没生效"，
# 不回答"好不好看"。判据永远是看图（README.md 坑 #7 的教训）。
# 实现在这里而不是 tools/ 里，是因为 train.py 要用；依赖方向是 tools → train，
# 反过来 import 会成环。

def _finite_diff_mag(y: torch.Tensor) -> torch.Tensor:
    """[B,1,H,W] 的前向差分幅值 |dx|+|dy|（与 train.py 的 grad_loss 同口径）。"""
    dx = (y[:, :, :, 1:] - y[:, :, :, :-1]).abs()
    dy = (y[:, :, 1:, :] - y[:, :, :-1, :]).abs()
    return dx, dy


def effective_levels(y: torch.Tensor, n: int = 16) -> int:
    """16 级亮度量化后还剩几级——**量化到底生效没有**。

    卡通应有的样子是 **4 ~ 7**。掉到 2~3 = 网络塌成双色木刻（失败，不是调参问题）。
    """
    q = torch.round(y.clamp(0, 1) * (n - 1))
    return int(torch.unique(q).numel())


def flat_noise(y: torch.Tensor, grad_pct: float = 40.0) -> float:
    """低梯度区的亮度标准差——**平坦处干不干净**。

    颗粒（椒盐）会把这个数顶上去。`grad_loss` 与量化器打架时网络学会"抖动"
    伪造梯度，这个数会**不降反升**，是风险 R1 的判据之一。
    """
    dx, dy = _finite_diff_mag(y)
    g = torch.zeros_like(y)
    g[:, :, :, :-1] += dx
    g[:, :, :-1, :] += dy
    thr = torch.quantile(g.flatten().float(), grad_pct / 100.0)
    return float(y[g <= thr].std())


def flatness_profile(x: torch.Tensor) -> tuple[float, float, float]:
    """内容图 (p10, p50, p90) 的 (|dx|+|dy|)/2 分位——用来**定 --flat-tv-thr**。

    不要用直觉量级定这个阈值（README 坑 #6 已复现过三次）。
    """
    dx, dy = _finite_diff_mag(x)
    g = torch.zeros_like(x)
    g[:, :, :, :-1] += dx
    g[:, :, :-1, :] += dy
    g = (g / 2).flatten().float()
    q = torch.quantile(g, torch.tensor([0.1, 0.5, 0.9], device=g.device))
    return float(q[0]), float(q[1]), float(q[2])
