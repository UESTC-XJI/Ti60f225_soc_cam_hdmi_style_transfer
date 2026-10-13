"""**当前**后处理流水线的片上存储开销（720p30 口径）。

    python -m tools.pp_cost              # 默认配置
    python -m tools.pp_cost --down 2     # 全部按 D=2 算（保边更好、更贵）
    python -m tools.pp_cost --guide-luma # 导向滤波只用亮度通道（省一半）

## 为什么要重算

`FPGA-IMPL.md` §3.7 的 **23.5KB** 是给**旧流水线**算的：
它包含两个内容侧模糊（给线条用的）和区域颜色表（给 `region_colorize` 用的）。

**现在这套流水线里这三样一个都不用**——线条关了、`region_colorize` 换成了
导向滤波。所以旧预算既**高估**了（残留三样没用的）又**漏算**了
（导向滤波、水彩三件套、α 矩阵全是新的）。

## 单位

和 `tools/blur_mem.py` 对齐：720p 宽 1280。一个通道一行 = 1280/D 字节。
- D=2 → 每行 0.64 KB
- D=4 → 每行 0.32 KB

（反推校验：`blur_mem` 报 σ=3 @D=2 用 5 行 3.1KB → 5×0.64=3.2 ✓）

## 关键前提：**盒滤波的行缓冲是 H 行，不是 1 行**

详见 `FPGA-IMPL.md` §3.7「更正二」——滑动求和还要减掉"出窗"的那一行，
那行必须以行缓冲留着。**盒滤波省的是乘法器，不是行缓冲。**

## 2026-09-29 补充：降采样级的垂直缓冲

第一版漏了**降采样级本身**的缓冲（把全分辨率引导图降到 1/D 要先攒 D 行）。
旧 §3.7 的表里这项本来是显式列出的。补上后每个档位 **+~5 KB**（D=4）。

**这个遗漏会改变结论**：补上后"不做共享"只剩最省档能过、余 2.0 KB，
⇒ `FPGA-IMPL.md` §3.7-bis 的结论从"共享是建议"变成"**共享是硬要求**"。
"""

from __future__ import annotations

import argparse
import sys

W = 1280          # 720p 宽度


def kb(rows: int, down: int, ch: int = 1) -> float:
    """rows 行、ch 个通道、降采样 D 的缓冲，单位 KB。"""
    return rows * (W / down) * ch / 1024.0


def box_rows(r: int) -> int:
    """半径 r 的盒滤波需要的行数 = 窗口高度。"""
    return 2 * r + 1


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="当前后处理流水线的片上存储开销")
    ap.add_argument("--down", type=int, default=4,
                    help="降采样倍数。4 = 和现有 §3.7 一致；2 = 保边更精细但更贵")
    ap.add_argument("--guide-luma", action="store_true",
                    help="导向滤波只对亮度通道算统计量、a/b 复用到三通道（省一半，但边缘可能有色晕）")
    ap.add_argument("--guide-r", type=int, default=8, help="导向滤波半径（全分辨率口径）")
    ap.add_argument("--paper-tile", type=int, default=64,
                    help="纸纹贴图边长（0 = 用 LFSR 现生成，不占存储；64 -> 4KB，256 -> 64KB 太大）")
    # ⚠ 这个参数**一直是缺的**：下面的 `elif args.kuwahara > 0` 引用了它，
    # 而 argparse 从没定义过 ⇒ **不带 `--kuwahara-aniso` 时必崩**
    # （`AttributeError: 'Namespace' object has no attribute 'kuwahara'`）。
    # 补上，默认值和 `tools/toon.py` 对齐（0 = 关）。
    ap.add_argument("--kuwahara", type=int, default=0,
                   help="Kuwahara 各向**同性**半径（0 = 关）。各向异性走 --kuwahara-aniso")
    ap.add_argument("--kuwahara-aniso", type=int, default=0,
                    help="各向异性 Kuwahara 半径（0 = 关）。**唯一吃采样带宽的算子**")
    ap.add_argument("--kuwahara-sharp", type=float, default=3.0,
                    help="各向异性拉伸强度（决定采样窗要开多大）")
    ap.add_argument("--kuwahara-down", type=int, default=1,
                    help="Kuwahara 在 1/D 分辨率上做（采样窗按 1/D² 缩）")
    ap.add_argument("--kuwahara-angles", type=int, default=0,
                    help="方向离散档数（>0 时整数偏移可查表，免掉双线性，带宽降 4 倍）")
    ap.add_argument("--kuwahara-guide", type=int, default=0,
                    help="结构混合半径（0 = 关）。把降采样毁掉的细文字接回来")
    ap.add_argument("--kuwahara-guide-eps", type=float, default=2e-3,
                    help="结构混合的 eps = '多强才算结构'")
    ap.add_argument("--wc-bleed", type=float, default=0.0,
                    help="**晕染外溢强度。默认 0 = 已砍掉**（2026-09-29 消融，肉眼看不出差别）。"
                         "给 >0 的值可以算'它还在'时候的账")
    ap.add_argument("--budget", type=float, default=60.8,
                    help="后处理可用预算 KB。= 单核 215 − 网络 154.2（做完共享）；"
                         "不做共享则是 215 − 184.2 = 30.8")
    args = ap.parse_args()

    D = args.down
    r = max(1, round(args.guide_r / D))       # 半径按降采样倍数折算
    items: list[tuple[str, float]] = []

    # ---------- ① 导向滤波 ----------
    # He et al. 2010 需要 6 个盒滤波：mean_I / mean_p / mean_Ip / mean_II / mean_a / mean_b
    # 我们把统计量都建在**灰度引导**上（guide 用亮度），只有 p 和 b 是三通道。
    n = box_rows(r)
    if args.guide_luma:
        ch_I = ch_Ip = ch_II = ch_a = 1
    else:
        ch_I = ch_Ip = ch_II = ch_a = 3
    guide = (kb(n, D, ch_I)      # mean_I  （引导的均值）
             + kb(n, D, 1)       # mean_II （引导平方的均值）—— 用于 var
             + kb(n, D, ch_Ip)   # mean_Ip （引导×输入的均值）—— 用于 cov
             + kb(n, D, 3)       # mean_p  （输入的均值）
             + kb(n, D, ch_a)    # mean_a
             + kb(n, D, 3))      # mean_b
    # ⚠ **导向滤波和 Kuwahara 是互斥的两条路**（`tools/toon.py`：
    # `if flat_mode == "none"` 走 Kuwahara / `elif flat_mode == "guided"` 走导向滤波）。
    # 旧版这里**无条件**把导向滤波的 25 KB 加上，于是开 Kuwahara 时两条路一起计费
    # ——定稿用的就是 Kuwahara，那 25 KB 根本不在链上。
    # 判据用「有没有开 Kuwahara」：开了就说明走的是 flat_mode=none 那条。
    use_kuwahara = args.kuwahara_aniso > 0 or args.kuwahara > 0
    if not use_kuwahara:
        items.append((f"导向滤波 r={args.guide_r}@D={D}（6 个盒滤波 × {n} 行）", guide))
    else:
        guide = 0.0
        print("  〔导向滤波不计费〕已开 Kuwahara ⇒ 走 flat_mode=none，两者互斥")

    # ---------- ② 水彩三件套 ----------
    # 边缘积色：梯度（1 行）+ 盒滤波 r=2
    items.append(("水彩·边缘积色（梯度 + box r=2）", kb(1, D) + kb(box_rows(2), D)))
    # 晕染外溢：**2026-09-29 已砍**（`tools/ab_bleed.py` 消融，肉眼看不出差别）。
    # 它是三件套里最贵的（12.5 KB @D=4），砍掉后"不做共享"的退路从 2.0 KB 余量变 14.6 KB。
    # 想看它在的时候的账：`--wc-bleed` 给个 >0 的值。
    if args.wc_bleed > 0:
        items.append((f"水彩·晕染外溢（灰度 box r=3 + RGB box r=5，强度 {args.wc_bleed}）",
                      kb(box_rows(3), D) + kb(box_rows(5), D, 3)))
    # 纸纹：固定图案 → 贴图 ROM（或 LFSR 现生成，0 开销）
    paper_kb = 0.0 if args.paper_tile == 0 else (args.paper_tile ** 2) / 1024.0
    items.append((f"水彩·纸纹（{args.paper_tile}^2 灰度贴图 ROM，0 = LFSR 现生成）", paper_kb))

    # ---------- ③ 降采样级本身的垂直缓冲 ----------
    # 把全分辨率引导图降到 1/D，要先在**全分辨率**上攒够 D 行才能做 D×D 盒平均。
    # （旧 §3.7 的表里这项是显式列出的，本脚本第一版漏了，2026-09-29 补上。）
    # 按单级 D×D 保守估；若做成两级 2×2 级联会更省（≈D+1 行的半分辨率量）。
    items.append((f"降采样级垂直缓冲（全分辨率 {D} 行）", kb(D, 1)))

    # ---------- ③b Kuwahara ----------
    # ⚠ 这是后处理链里**唯一吃采样带宽**的算子，存储反而不是大头。
    if args.kuwahara_aniso > 0:
        import math
        r = args.kuwahara_aniso
        tr = max(2, r)
        kd = max(1, args.kuwahara_down)                       # 在 1/kd 分辨率上做
        R = int(math.ceil(r * (1.0 + args.kuwahara_sharp)))   # 沿走向拉伸后的半窗
        nin = 4 * (r + 1) ** 2                                # 4 象限 × (r+1)² 个采样点
        # 方向离散化后整数偏移可查表 → 单点采样（1 抽头）；否则双线性（4 抽头）
        per_tap = 1 if args.kuwahara_angles > 0 else 4
        taps = nin * per_tap
        # 采样窗的行数按 1/kd 缩（窗在降采样域里张开），宽度也按 1/kd 缩
        rows = (2 * R + 1) // kd + 1
        items.append((f"Kuwahara 结构张量（{2+box_rows(tr)} 行灰度 @1/{kd}）",
                      kb(2 + box_rows(tr), kd)))
        items.append((f"Kuwahara 采样窗（R={R} @1/{kd} → {rows} 行三通道）",
                      kb(rows, kd, 3)))
        mode = f"{args.kuwahara_angles} 档离散" if args.kuwahara_angles else "浮点角"
        print(f"  [带宽] Kuwahara {nin} 点/像素 ×{per_tap} 抽头（{mode}）= {taps} 抽头/像素")
        print(f"         720p30 @250MHz → {taps * 27.6e6 / 250e6:.1f} 抽头/拍"
              f"（对照：conv 峰值 14.2 字节/拍，靠 9-tap 共窗才成立）")
        if kd > 1 and args.kuwahara_guide > 0:
            # 结构混合（`structure_blend`）：2 个盒滤波 × 单通道 @全分辨率。
            # **不要用 guided_filter 做这件事**——它要 6 个盒滤波 × 3 通道，
            # 全分辨率 r=6 时约 260KB，比 Kuwahara 本身还贵。
            n = box_rows(args.kuwahara_guide)
            items.append((f"结构混合（2 个盒滤波 × {n} 行，单通道@全分辨率）",
                          2 * kb(n, 1, 1)))
            print(f"  [结构混合] r={args.kuwahara_guide} eps={args.kuwahara_guide_eps:g}"
                  f"  ← 把降采样毁掉的细文字接回来")
    elif args.kuwahara > 0:
        r = args.kuwahara
        items.append((f"Kuwahara 各向同性（窗 {2*r+1} 行，三通道@全分辨率）",
                      kb(2 * r + 1, 1, 3)))

    # ---------- ④ 逐像素算子（**不占行缓冲**） ----------
    # α 配色矩阵（3×3 + 偏置）、饱和/对比、亮度统计（逐帧 2 个累加器）
    items.append(("α 配色矩阵 / 饱和对比 / luma-match（逐像素或逐帧累加）", 0.0))

    total = sum(v for _, v in items)
    print(f"降采样 D={args.down}    半径折算 r={r}（全分辨率口径 {args.guide_r}）\n")
    print(f"{'项':<52}{'KB':>8}")
    for name, v in items:
        print(f"  {name:<50}{v:>8.2f}")
    print(f"  {'合计':<50}{total:>8.2f}")
    print(f"\n后处理预算 {args.budget:.1f} KB → " +
          (f"[OK] 余 {args.budget - total:.1f} KB" if total <= args.budget
           else f"[FAIL] 超 {total - args.budget:.1f} KB"))
    print(f"\n（旧的 §3.7 记的是 23.5KB，但那是给**旧流水线**算的——"
          f"它含两个内容侧模糊 + 区域颜色表，现在一样都不用；")
    print(f"  同时又漏算了导向滤波和水彩三件套。所以要按上面这个数重新设计。）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
