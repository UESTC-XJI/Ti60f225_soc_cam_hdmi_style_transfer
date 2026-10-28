#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
style_metrics.py —— 风格化输出质量指标（PSNR / SSIM / 逐通道偏差）

为什么需要它：
  赛题高阶 C3 要求"与标准网络做 PSNR/SSIM + 推理延迟对比"。而在此之前，
  我们判断画质一直靠"肉眼看截图"和"三通道均值/σ"—— 前者不可复现，后者只看一阶统计量。

  这个工具给的是**可复现的客观数字**，能回答三类问题：
    1. 硬件输出 vs 参考输出（模型侧给的 float 结果）→ 量化损失了多少
    2. 改动前后（如 A-3 vs A-4、半分辨率 vs 全分辨率）→ 优化代价了多少
    3. 输出 vs 源帧 → 内容保真度

它不能做什么（说清楚）：
  - **没有参考输出就测不了 PSNR/SSIM**。PSNR/SSIM 是"有参考"指标，
    需要模型侧提供同场景的 float 输出，或至少一张已知良好的硬件输出。
  - 风格相似度没有标准指标。Gram 矩阵风格的 loss 需要 VGG 特征（要 torch）。

用法：
  # 两块帧 dump 对比（最常用）
  python tools/style_metrics.py --a ref.bin --b out.bin --w 640 --h 480

  # 直接从板子抓两帧对比（需要 OpenOCD）
  python tools/style_metrics.py --capture a --slot 0 --w 320 --h 240
  python tools/style_metrics.py --a _m/ref.bin --b _m/new.bin --w 320 --h 240

  # 车辆回归：先存基准，改动后比对，低于阈值就报警
  python tools/style_metrics.py --a _golden/style320.bin --b live.bin --w 320 --h 240 --psnr-min 30

帧格式：DDR 里是 {B,G,R,X} 每像素 4 字节，X 应为 0。
  注意 A-4 之后结果帧是 **320×240 原生**（显示端做 2× 放大），源帧仍是 640×480。
"""

import argparse
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_frame(path, w, h, channels=3, order="bgr"):
    """读 DDR dump（每像素 4 字节 BGRX）→ float64 [h, w, 3]"""
    d = np.fromfile(path, dtype=np.uint8)
    need = w * h * 4
    if len(d) < need:
        raise SystemExit("%s 太小：%d B，需要 %d B（%dx%d）" % (path, len(d), need, w, h))
    px = d[:need].reshape(h, w, 4).astype(np.float64)
    if order == "bgr":
        return np.stack([px[:, :, 2], px[:, :, 1], px[:, :, 0]], axis=2), px[:, :, 3]
    return px[:, :, :3].copy(), px[:, :, 3]


def psnr(a, b, peak=255.0):
    mse = np.mean((a - b) ** 2)
    if mse <= 1e-12:
        return float("inf"), 0.0
    return 10.0 * np.log10(peak * peak / mse), mse


def _gauss_kernel(size=11, sigma=1.5):
    x = np.arange(size) - size // 2
    g = np.exp(-(x ** 2) / (2 * sigma * sigma))
    g /= g.sum()
    return g


def _filter2(img, g):
    """可分离的高斯滤波（边界用反射）"""
    k = len(g)
    pad = k // 2
    h, w = img.shape
    tmp = np.zeros((h, w + 2 * pad))
    tmp[:, pad:pad + w] = img
    tmp[:, :pad] = img[:, 1:pad + 1][:, ::-1]
    tmp[:, pad + w:] = img[:, w - pad - 1:w - 1][:, ::-1]
    out = np.apply_along_axis(lambda r: np.convolve(r, g, mode="valid"), 1, tmp)

    tmp2 = np.zeros((h + 2 * pad, w))
    tmp2[pad:pad + h, :] = out
    tmp2[:pad, :] = out[1:pad + 1][::-1, :]
    tmp2[pad + h:, :] = out[h - pad - 1:h - 1][::-1, :]
    return np.apply_along_axis(lambda c: np.convolve(c, g, mode="valid"), 0, tmp2)


def ssim(a, b, peak=255.0, size=11, sigma=1.5):
    """标准 SSIM（高斯窗 11x11, σ=1.5），逐通道算再平均"""
    C1 = (0.01 * peak) ** 2
    C2 = (0.03 * peak) ** 2
    g = _gauss_kernel(size, sigma)
    vals = []
    for c in range(a.shape[2]):
        x, y = a[:, :, c], b[:, :, c]
        mx, my = _filter2(x, g), _filter2(y, g)
        mxx, myy, mxy = _filter2(x * x, g), _filter2(y * y, g), _filter2(x * y, g)
        vx = mxx - mx * mx
        vy = myy - my * my
        vxy = mxy - mx * my
        s = ((2 * mx * my + C1) * (2 * vxy + C2)) / ((mx * mx + my * my + C1) * (vx + vy + C2))
        vals.append(s.mean())
    return float(np.mean(vals)), [float(v) for v in vals]


def channel_stats(f, name):
    print("  %-8s " % name, end="")
    for i, c in enumerate("RGB"):
        print("%s mean %6.1f σ %5.1f   " % (c, f[:, :, i].mean(), f[:, :, i].std()), end="")
    print(" B−R %+6.1f" % (f[:, :, 2].mean() - f[:, :, 0].mean()))


def main(argv=None):
    ap = argparse.ArgumentParser(description="风格化输出质量指标（PSNR/SSIM）")
    ap.add_argument("--a", help="参考帧 .bin")
    ap.add_argument("--b", help="待测帧 .bin")
    ap.add_argument("--w", type=int, default=320, help="宽（A-4 之后结果帧是 320）")
    ap.add_argument("--h", type=int, default=240, help="高")
    ap.add_argument("--order", default="bgr", choices=["bgr", "rgb"])
    ap.add_argument("--psnr-min", type=float, default=None, help="PSNR 下限，低于则退出码 1")
    ap.add_argument("--ssim-min", type=float, default=None, help="SSIM 下限")
    args = ap.parse_args(argv)

    if not args.a or not args.b:
        ap.print_help()
        print("\n⚠ PSNR/SSIM 是**有参考**指标，必须给 --a（参考）和 --b（待测）。")
        print("  参考从哪来：模型侧给的同场景 float 输出，或一张已知良好的硬件输出。")
        return 2

    for p in (args.a, args.b):
        if not os.path.exists(p):
            raise SystemExit("找不到 %s" % p)

    A, Ax = load_frame(args.a, args.w, args.h, order=args.order)
    B, Bx = load_frame(args.b, args.w, args.h, order=args.order)

    print("帧：%dx%d（%.1f KB）" % (args.w, args.h, args.w * args.h * 4 / 1024))
    print()
    channel_stats(A, "参考 A")
    channel_stats(B, "待测 B")
    print()

    # X 字节应恒为 0（数据通路健康的标志）
    for nm, X in (("A", Ax), ("B", Bx)):
        bad = int((X != 0).sum())
        flag = "✓" if bad == 0 else "**%d 个非零**" % bad
        print("  %s 的 X 字节：%s" % (nm, flag))
    print()

    p, mse = psnr(A, B)
    sv, svc = ssim(A, B)
    print("  PSNR = %s   (MSE %.3f)" % ("∞" if p == float("inf") else "%.2f dB" % p, mse))
    print("  SSIM = %.4f   (R %.4f / G %.4f / B %.4f)" % (sv, svc[0], svc[1], svc[2]))
    print()

    # 判定
    ok = True
    if args.psnr_min is not None:
        good = p >= args.psnr_min
        ok &= good
        print("  PSNR ≥ %.1f : %s（实测 %s）" % (args.psnr_min, "OK" if good else "**NG**",
                                                "∞" if p == float("inf") else "%.2f" % p))
    if args.ssim_min is not None:
        good = sv >= args.ssim_min
        ok &= good
        print("  SSIM ≥ %.3f : %s（实测 %.4f）" % (args.ssim_min, "OK" if good else "**NG**", sv))

    print()
    print("=" * 62)
    if p == float("inf"):
        print("裁决：完全一致（逐像素相同）")
    elif sv >= 0.95 and p >= 30:
        print("裁决：视觉几乎无差异（SSIM ≥0.95 且 PSNR ≥30 dB）")
    elif sv >= 0.85:
        print("裁决：有可测差异但结构保留")
    else:
        print("裁决：**差异显著** —— 检查是否改了分辨率/几何/量化参数")
    print("=" * 62)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
