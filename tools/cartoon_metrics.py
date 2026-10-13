r"""卡通化程度的四个量具 —— **只用来定位，不用来下结论**。

    python -m tools.cartoon_metrics --a runs/final/showcase/toon_000000000139.png

## 指标是用户 2026-09-29 定义的，这里复现，先校准再使用

| 指标 | 定义 | 卡通应有的样子 |
|---|---|---|
| 有效色阶数 | 16 级亮度量化后剩几级 | **4 ~ 7**（明显色带） |
| ink% | 暗边缘像素占比 | **6 ~ 10%**（黑描边） |
| 梯度能量 | 平均 \|∇Y\| | 内部纹理再降 50%+，边界保留 |
| 平坦区噪声 std | 低梯度区的 Y 标准差 | **不得反弹** |

⚠ **校准基准**（用户的 content 列）：11.81 / 4.19% / 83.3 / 18.5
（这里的梯度能量按 0~255 口径，用户的 83.3 也是这个口径）。

## 为什么单独成文件

`README.md` 坑 #7 那条教训：**Gram/SSIM 这类统计量衡量的是"像不像"，
不是"看起来对不对"**。这四个指标同样**不能单独下结论**——
它们是用来回答"三个模块哪个没生效"的**定位工具**，
最终判据仍是看图（`tools/ab_bleed.py` 那种双联）。

## 本工具**故意不输出**的东西

不输出"卡通分数"之类的合成指标。合成指标会掩盖"某一项其实没动"这个事实,
而这正是本次要查的问题（`--levels` 是死参数、`lines` 是直通, 合成指标会把它们平均掉）。
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent


def luma(rgb: np.ndarray) -> np.ndarray:
    """Rec.601 亮度，0~1。"""
    return (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2])


def load(p: Path) -> np.ndarray:
    a = np.asarray(Image.open(p).convert("RGB"), np.float32)
    return a[..., :3] / 255.0


def gradmag(y: np.ndarray) -> np.ndarray:
    ex = np.abs(np.diff(y, axis=1, prepend=y[:, :1]))
    ey = np.abs(np.diff(y, axis=0, prepend=y[:1, :]))
    return ex + ey


def _t(y: np.ndarray):
    """[H,W] numpy → [1,1,H,W] torch（量具的真身在 train/metrics.py）。"""
    import torch
    return torch.from_numpy(np.ascontiguousarray(y, np.float32))[None, None]


def effective_levels(y: np.ndarray, n: int = 16) -> int:
    """16 级亮度量化后还剩几级。

    ⚠ **实身在 `train/metrics.py`**——`train.py --calibrate` 也要用它，
    而依赖方向是 tools → train，反过来会在 train 里 import tools 成环。
    这里只做 numpy → torch 的转换，**不要在这里再写一份实现**。
    """
    from train.metrics import effective_levels as _impl
    return _impl(_t(y), n)


def ink_ratio(y: np.ndarray, dark: float = 0.20, grad_pct: float = 75.0) -> float:
    """暗**边缘**像素占比 = Y 暗 且 处在高梯度处。

    单纯"暗像素占比"会把大片阴影算进去；描边要的是"暗且细"，
    所以加一道高梯度约束。
    """
    g = gradmag(y)
    thr = np.percentile(g, grad_pct)
    return float(((y < dark) & (g >= thr)).mean())


def flat_noise(y: np.ndarray, grad_pct: float = 40.0) -> float:
    """低梯度区的亮度标准差 —— "平坦处干不干净"。实身在 `train/metrics.py`。"""
    from train.metrics import flat_noise as _impl
    return _impl(_t(y), grad_pct)


def gradient_energy(y: np.ndarray) -> float:
    """平均梯度幅值（0~255 口径，和用户的 83.3 对齐）。"""
    return float(gradmag(y).mean() * 255.0)


def measure(img: np.ndarray) -> dict[str, float]:
    y = luma(img)
    return {
        "有效色阶数": effective_levels(y),
        "ink%": ink_ratio(y) * 100.0,
        "梯度能量": gradient_energy(y),
        "平坦区噪声std": flat_noise(y) * 255.0,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="卡通化程度的四个量具（定位用，不下结论）")
    ap.add_argument("--a", type=Path, help="图 A（--calibrate 时不需要）")
    ap.add_argument("--b", type=Path, help="图 B（给了就出对照表）")
    ap.add_argument("--left", type=int, default=0, help="只量左起第 N 格（四联图用）")
    ap.add_argument("--ncell", type=int, default=1, help="把图横切成几格")
    ap.add_argument("--calibrate", action="store_true",
                    help="拿 data/content 的前 5 张做校准，核对是否复现用户的 11.81/4.19/83.3/18.5")
    args = ap.parse_args()

    def one(p: Path) -> dict[str, float]:
        im = load(p)
        if args.ncell > 1:
            h, w, _ = im.shape
            cw = w // args.ncell
            im = im[:, args.left * cw:(args.left + 1) * cw]
        return measure(im)

    if args.calibrate:
        files = sorted((ROOT / "data" / "content").iterdir())[:5]
        print(f"校准：data/content 前 {len(files)} 张（用户基准 11.81 / 4.19% / 83.3 / 18.5）\n")
        print(f"{'文件':<20}{'色阶':>7}{'ink%':>9}{'梯度能量':>10}{'平坦std':>10}")
        acc = []
        for f in files:
            m = one(f)
            acc.append(m)
            print(f"  {f.stem:<18}{m['有效色阶数']:>7}{m['ink%']:>8.2f}%"
                  f"{m['梯度能量']:>10.1f}{m['平坦区噪声std']:>10.1f}")
        print(f"\n  {'均值':<18}{np.mean([a['有效色阶数'] for a in acc]):>7.2f}"
              f"{np.mean([a['ink%'] for a in acc]):>8.2f}%"
              f"{np.mean([a['梯度能量'] for a in acc]):>10.1f}"
              f"{np.mean([a['平坦区噪声std'] for a in acc]):>10.1f}")
        return 0

    if args.a is None:
        ap.error("要么给 --a，要么用 --calibrate")
    ma = one(args.a)
    print(f"{'指标':<14}{'A':>12}" + (f"{'B':>12}{'变化':>12}" if args.b else ""))
    mb = one(args.b) if args.b else None
    for k in ma:
        line = f"  {k:<12}{ma[k]:>12.2f}"
        if mb:
            d = mb[k] - ma[k]
            line += f"{mb[k]:>12.2f}{d:>+12.2f}"
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
