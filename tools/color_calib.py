#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
color_calib.py —— 24 色卡定位与颜色校准【⚠ 实验性，几何定位未达标，勿用于生产校准】

⛔ 当前状态（2026-10-27 用户实测否证）：**不推荐使用**。
   自动网格拟合的判据是"24 块颜色图案像 ColorChecker"，它会为了色彩匹配牺牲
   几何准确度 —— 在倾斜色卡上拟合出 ax=140 / bx=24（真实 144 / 0），采样窗口
   压在色块边缘：**均值勉强对、边界全错**，目视采样点明显偏离色块中心。
   要修需要①把边界/梯度作为独立约束，或②用色块四条边的直线检测定四角。
   在此之前请用**手工网格**（目视定四个角块中心再线性插值），
   见 reports/COLOR_CHECKER_CALIB_2026-10-27.md —— 那份结论用的就是手工网格。

保留本文件的原因：`_sample_patches` 与 6 参数网格（含旋转）的量化思路是对的，
修好几何约束后可直接复用。
"""

为什么需要它：
  1. 摄像机装上去会倾斜（本板实测约 3°），手工点 24 个色块不现实
  2. 判色不能用屏摄（采集卡会把色偏放大 ~1.5 倍），但色卡位置又只能在屏摄上找
  3. 白平衡应该只用**中性灰阶**拟合，不能用 24 块的平均 B-R —— 色卡本身色彩丰富、
     平均值偏暖（标准 B-R = -20.9），拿它当白平衡目标会跑偏

它做的事：
  ① 自动拟合 6x4 网格（含旋转）—— 目标函数 = 块内均匀度 / 块间色差
     （只用"块内均匀"会掉进退化解：整片暗边框也很均匀）
  ② 采样 24 块，左右两半各采一次
  ③ 与标准 sRGB 值对比，给出误差
  ④ 用**中性灰阶（底排）**反解相机增益建议

用法：
  python color_calib.py --img grab.png                  # 左右各 960 px 的并排画面
  python color_calib.py --img grab.png --split 959      # 指定左右分界
  python color_calib.py --img grab.png --save-pts pts.png   # 画采样点，目视验证
  python color_calib.py --img grab.png --gains 400,256,414  # 给出现有增益下的建议值

依赖：numpy + Pillow
"""

import argparse
import numpy as np
from PIL import Image

# 标准 ColorChecker sRGB 值（D65，24 块，行优先）
STD = np.array([
    (115,  82,  68), (194, 150, 130), ( 98, 122, 157), ( 87, 108,  67),
    (133, 128, 177), (103, 189, 170), (214, 126,  44), ( 80,  91, 166),
    (193,  90,  99), ( 94,  60, 108), (157, 188,  64), (224, 163,  46),
    ( 56,  61, 150), ( 70, 148,  73), (175,  54,  60), (231, 199,  31),
    (187,  86, 149), (  8, 133, 161), (243, 243, 242), (200, 200, 200),
    (160, 160, 160), (122, 122, 121), ( 85,  85,  85), ( 52,  52,  52),
], dtype=float)

# 底排 6 个中性块在 STD 里的下标（白 → 黑）
NEUTRAL_IDX = [18, 19, 20, 21, 22, 23]


def _sample_patches(img, p, r=13):
    """p = (x0, y0, ax, ay, bx, by)：网格起点 + 列步进 + 行步进（含旋转）"""
    x0, y0, ax, ay, bx, by = p
    out = []
    for row in range(4):
        for col in range(6):
            xi = int(round(x0 + col * ax + row * bx))
            yi = int(round(y0 + col * ay + row * by))
            if xi - r < 0 or yi - r < 0 or xi + r >= img.shape[1] or yi + r >= img.shape[0]:
                return None
            w = img[yi - r:yi + r, xi - r:xi + r]
            out.append(w.reshape(-1, 3).mean(axis=0))
    return np.array(out)


def _score(img, p, r=13):
    """打分 = 与标准 ColorChecker 图案的残差（唯一判据）。

    只用"块内均匀 / 块间分散"会掉进退化解：整片暗边框也很均匀、也有点差异。
    真正的判据是"这 24 块的颜色**图案**要像 ColorChecker"——先逐通道做最小二乘
    缩放（吸收曝光/增益差异），再算与标准值的平均绝对残差。这样只有真正的色卡
    网格能得低分（实测：正确网格 14.3，错解 26.0）。
    """
    m = _sample_patches(img, p, r)
    if m is None:
        return 1e9
    if m.sum() < 100:                      # 全黑，判废（避免 0/0）
        return 1e9
    k = np.array([(m[:, i] @ STD[:, i]) / (m[:, i] @ m[:, i] + 1e-6) for i in range(3)])
    return float(np.abs(m * k - STD).mean())


def fit_grid(img, verbose=True):
    """粗搜（降采样加速）+ 全分辨率精修。返回 (params, score)。"""
    h, w = img.shape[:2]
    # ---- 粗搜：降到 1/4 分辨率（6 维嵌套很贵，这一步占 95% 时间）----
    sc = 4
    small = img[::sc, ::sc]
    hs, ws = small.shape[:2]
    cand = []
    for x0 in range(int(ws * 0.01), int(ws * 0.22), max(2, int(ws * 0.04))):
        for y0 in range(int(hs * 0.08), int(hs * 0.50), max(2, int(hs * 0.05))):
            for ax in range(int(ws * 0.08), int(ws * 0.21), max(1, int(ws * 0.02))):
                for ay in range(-6, 7, 3):
                    for bx in range(-6, 7, 3):
                        for by in range(int(hs * 0.08), int(hs * 0.23), max(2, int(hs * 0.025))):
                            q = (x0, y0, ax, ay, bx, by)
                            s = _score(small, q, r=4)
                            if s < 1e8:
                                cand.append((s, q))
    if not cand:
        raise SystemExit(
            "自动定位失败：所有候选网格都越界。\n"
            "  请用 --crop y0,y1 裁掉上下黑边后重试，或确认图里真的有 6x4 色卡。")
    cand.sort(key=lambda t: t[0])
    # ---- 多样本精修：粗搜前 8 名各自精修，取全局最优（单一 basin 容易卡在错解）----
    best = None
    for _, q0 in cand[:8]:
        p = [v * sc for v in q0]
        cur = (_score(img, tuple(p)), tuple(p))
        for step in (8, 4, 2, 1):
            improved = True
            while improved:
                improved = False
                for i in range(6):
                    for d in (-step, step):
                        q = list(p)
                        q[i] += d
                        s = _score(img, tuple(q))
                        if s < cur[0] - 1e-9:
                            cur = (s, tuple(q))
                            p = q
                            improved = True
        if best is None or cur[0] < best[0]:
            best = cur
    p = list(best[1])
    if verbose:
        print("网格参数: x0=%.0f y0=%.0f ax=%.0f ay=%.0f bx=%.0f by=%.0f  (score %.4f)"
              % (*best[1], best[0]))
        print("            ay=%+.0f 即倾斜补偿（每右移一列，色块中心上移 %.0f px）"
              % (best[1][3], -best[1][3]))
    return best[1], best[0]


def measure(img_left, img_right, p):
    L = _sample_patches(img_left, p)
    R = _sample_patches(img_right, p) if img_right is not None else None
    return L, R


def report(L, R, cur_gains=None):
    ok = (L.max(axis=1) < 248)
    err = np.abs(L[ok] - STD[ok]).mean() if ok.sum() else float("nan")
    print()
    print("%-4s %-18s %-18s %-18s" % ("#", "左(原画)", "右(风格)", "标准"))
    for i in range(24):
        r = "" if R is None else "(%3.0f,%3.0f,%3.0f)" % tuple(R[i])
        print("%-4d (%3.0f,%3.0f,%3.0f)   %-18s (%3.0f,%3.0f,%3.0f)" % (
            i + 1, *L[i], r, *STD[i]))
    print()
    print("左 mean (%.0f,%.0f,%.0f)   B-R %+.1f   可用色块 %d/24   平均色块误差 %.2f"
          % (*L.mean(axis=0), L[:, 2].mean() - L[:, 0].mean(), ok.sum(), err))
    if R is not None:
        print("右 mean (%.0f,%.0f,%.0f)   B-R %+.1f"
              % (*R.mean(axis=0), R[:, 2].mean() - R[:, 0].mean()))
    print("标准 mean (%.0f,%.0f,%.0f)   B-R %+.1f"
          % (*STD.mean(axis=0), STD[:, 2].mean() - STD[:, 0].mean()))

    # 白平衡：只用未削顶的中性灰阶
    pts = [L[i] for i in NEUTRAL_IDX if L[i].max() < 248]
    print()
    if len(pts) >= 2:
        pts = np.array(pts)
        rg = float(np.mean(pts[:, 0] / pts[:, 1]))
        bg = float(np.mean(pts[:, 2] / pts[:, 1]))
        print("中性灰阶（未削顶 %d 块）: R/G = %.3f  B/G = %.3f   （白平衡目标 1.000 / 1.000）"
              % (len(pts), rg, bg))
        if cur_gains:
            r, g, b = [float(x) for x in cur_gains.split(",")]
            nr, ng, nb = r / rg, g, b / bg
            k = ng / 256.0                       # 归一化到 G=256，保持整体亮度
            print("当前增益 %d/%d/%d  \u2192  建议 %.0f/256/%.0f" % (r, g, b, nr / k, nb / k))
        else:
            print("建议：在当前增益基础上 R \u00d7%.3f、B \u00d7%.3f（再归一化到 G 不变）"
                  % (1.0 / rg, 1.0 / bg))
    else:
        print("中性灰阶可用块不足（全被削顶）\u2014\u2014 先降曝光再校准")


def save_pts(img, p, path):
    from PIL import ImageDraw
    im = Image.fromarray(img.astype(np.uint8)).convert("RGB")
    d = ImageDraw.Draw(im)
    x0, y0, ax, ay, bx, by = p
    for row in range(4):
        for col in range(6):
            x = x0 + col * ax + row * by
            y = y0 + col * ay + row * by
            d.ellipse([x - 10, y - 10, x + 10, y + 10], outline=(255, 0, 255), width=3)
            d.text((x - 8, y - 6), str(row * 6 + col + 1), fill=(255, 0, 255))
    im.save(path)
    print("采样点已画到 %s（目视确认点是否落在色块中心）" % path)


def main(argv=None):
    ap = argparse.ArgumentParser(description="24 色卡自动定位与颜色校准")
    ap.add_argument("--img", required=True, help="并排画面（左=原画，右=风格化）")
    ap.add_argument("--split", type=int, default=None, help="左右分界 x（默认自动：画面中央）")
    ap.add_argument("--save-pts", default=None, help="把采样点画出来存到这里")
    ap.add_argument("--gains", default=None, help="当前相机增益 R,G,B（Q8.8），用于给建议值")
    ap.add_argument("--crop", default=None, help="裁掉上下黑边：y0,y1")
    args = ap.parse_args(argv)

    a = np.asarray(Image.open(args.img).convert("RGB")).astype(float)
    if args.crop:
        y0, y1 = [int(v) for v in args.crop.split(",")]
        a = a[y0:y1, :]
    split = args.split if args.split else a.shape[1] // 2
    left, right = a[:, :split], a[:, split:]

    print("图像 %dx%d，左右分界 x=%d" % (a.shape[1], a.shape[0], split))
    p, _ = fit_grid(left)
    L, R = measure(left, right if right.shape[1] > 100 else None, p)
    report(L, R, args.gains)
    if args.save_pts:
        save_pts(a, p, args.save_pts)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# ---------------------------------------------------------------------------
# 已知局限
#   1. 左右两半被假设为**几何完全一致**。实测右半（风格化）的色卡位置比左半
#      略偏右十几像素，因为两个面板的画框边距不完全相同。若右半采样压到色块边缘，
#      办法是把 --split 调小几像素，或先只信左半的结果（白平衡本来就只用左半）。
#   2. 需要图里有完整的 6x4 色卡。歪斜可以，被裁掉一角不行。
#   3. 白平衡只用**底排中性灰阶**拟合——不能用 24 块的平均 B-R：色卡本身色彩丰富、
#      平均值偏暖（标准值 B-R = -20.9），拿它当白平衡目标会跑偏。
# ---------------------------------------------------------------------------
