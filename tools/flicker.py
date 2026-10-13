"""**真连续帧的时域一致性量测** —— 运动补偿之后，看"内容没动的地方，输出抖多少"。

    python -m tools.flicker --self-check                       # 先验位移估计器
    python -m tools.flicker --content runs/VIDEO_material --stages runs/_video_mat

## 为什么不能直接做帧差

`video-temporal-instability` 那条（静止区每帧抖 3~7/255）是拿**固定机位**视频量的，
静止区直接框一块就行。**这批素材相机在动**（`runs/VIDEO_material/README.md`：
帧间 MAD 2~13/255），直接帧差量到的是**运动**，闪烁被淹在里面，量不出所以然。

两条路，都要做：

- **A 全局运动补偿**：相位相关估平移 `(dy,dx)`，把 t+1 帧对到 t 帧，残差就是"去掉运动之后还剩的逐帧变化"。
  ⚠ **只补平移**——旋转、视差、亚像素的残余会混进残差（已做抛物线亚像素细化压它，
  但**不能假装它不存在**：残差里有一部分是补偿不干净，不全是闪烁）。
- **B 在"内容动得最少"的像素上看输出抖多少** ← **这条是头号判据**。
  掩膜只在**内容帧**上选，输出帧只是被读，所以**不依赖补偿有多准**。

## 掩膜用分位，不用绝对阈值（第一版错了）

"静止像素"这个词只在**固定机位**素材上成立。这批素材相机在动，补偿后
**可能一个绝对静止的像素都没有**（残差来自旋转/视差/运动物体/亚像素误差），
硬用 `|dC| < tau` 会得到 "静止 0.3%" 这种没有统计意义的掩膜。

所以默认按**分位**取（局部 |Δ| 最低的 `--mask-q` 那一档），保证掩膜大小可比。
**但它不是"静止"，是"动得最少"**——所以报告里永远跟着一列「掩膜上的内容残差」，
一眼能看出掩膜到底有多静（实测 0.5~1.4/255，确实很静）。
`<2静止%` 是诊断列：这一段里真正没动的像素占多少，是 0 就说明只能按"动得最少"读。

⚠ **判据必须整轮统一**。第一版让每对帧自己挑"绝对还是退分位"，
结果同一段里两种模式混着、标签成了 `分位25%/绝对`，那个平均根本不是一回事。

## 三条纪律（都踩过坑）

1. **位移只从内容帧估**，输出帧用**同一个**位移。否则输出自己的抖动会污染对齐，
   变成"用闪烁去解释闪烁"。
2. **掩膜要取局部最大**（3×3）再比。逐像素比的话，
   运动边缘上刚好同色的孤立点会被选进来，而它们在输出上可能恰好抖得厉害。
   ⚠ **归一化量纲**：像素差是 0~1，阈值是 /255，不换算的话掩膜恒真
   （第一次跑出来"静止 100%"而同行帧间 MAD 有 13/255，自相矛盾）。
3. **不补偿的帧差也要报**（`帧间 MAD` 那列）——它是读者自己也能复算的锚点，
   而且能看到"补偿吃掉了多少"。补偿后残差和它差太远说明估计器没工作。

## 口径

- 亮度走 **BT.601**（`0.299/0.587/0.114`）——和 `train/data.py::to_luma`、
  和 MIPI/HDMI 视频通路同一个口径，换 BT.709 数会差一点但必须两边一致。
- 所有数值写成 **/255 的绝对差**，好和记忆里那张表并排看。
- 位移估计器自己验：`--self-check` 拿真帧平移已知量再估回来。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image  # noqa: E402

BT601 = np.array((0.299, 0.587, 0.114), dtype=np.float32)

# 输出目录里 --dump-panels 会产出的面板（顺序 = 报告里的列顺序 = 流水线顺序）
PANELS = ("content", "stylized", "flat", "lined")


# ---------------------------------------------------------------- 基础


def load_luma(path: Path) -> np.ndarray:
    """读图 → BT.601 亮度 (H,W) float32，量程 0~1。"""
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    return a @ BT601


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def _hann(h: int, w: int) -> np.ndarray:
    """二维 Hann 窗。**不加窗相位相关的峰会被画面四边主导**（边界不连续是最大的一块"运动"）。"""
    return np.hanning(h)[:, None] * np.hanning(w)[None, :]


def _parabolic(m1: float, m0: float, p1: float) -> float:
    """三个相邻相关值 → 亚像素峰位偏移。退化（三点共线）时给 0。"""
    den = m1 - 2.0 * m0 + p1
    if abs(den) < 1e-12:
        return 0.0
    d = 0.5 * (m1 - p1) / den
    # 抛物线细化只在半个像素内有意义；超过说明峰不是单峰，别信它
    return float(np.clip(d, -0.5, 0.5))


def est_shift(a: np.ndarray, b: np.ndarray) -> tuple:
    """估 `(dy, dx)`：满足 **`a(u) = b(u - d)`**，即把 b 按 `warp_luma(b, *d)` 采样就能对齐到 a。

    用相位相关（只取相位，幅度归一 —— 对亮度整体差/对比度差不敏感，
    这两样在风格化前后本来就会变）。
    """
    h, w = a.shape
    win = _hann(h, w).astype(np.float32)
    A = np.fft.fft2((a - a.mean()) * win)
    B = np.fft.fft2((b - b.mean()) * win)
    R = A * np.conj(B)
    R /= np.abs(R) + 1e-12
    r = np.real(np.fft.ifft2(R))

    p, q = np.unravel_index(int(np.argmax(r)), r.shape)
    dy = p + _parabolic(r[(p - 1) % h, q], r[p, q], r[(p + 1) % h, q])
    dx = q + _parabolic(r[p, (q - 1) % w], r[p, q], r[p, (q + 1) % w])
    # 循环相关：超过一半的是负位移
    if dy > h / 2:
        dy -= h
    if dx > w / 2:
        dx -= w
    return float(dy), float(dx)


def warp_luma(b: np.ndarray, dy: float, dx: float) -> np.ndarray:
    """把 b 重采样成 `b(y - dy, x - dx)`，双线性、边界取 clamp。

    ⚠ 走 torch 的 `grid_sample` 而不是手写插值：手写双线性在亚像素上是**最常写错的一段**
    （y/x 互换、align_corners 差半个像素），而差半个像素的残差**量级和要测的闪烁同阶**，
    错了看不出来。**能用验过的算子就别自己写。**
    """
    t = torch.from_numpy(b)[None, None]
    h, w = b.shape
    ys = torch.arange(h, dtype=torch.float32) - float(dy)
    xs = torch.arange(w, dtype=torch.float32) - float(dx)
    gy, gx = torch.meshgrid(ys, xs, indexing="ij")
    grid = torch.stack([gx / (w - 1) * 2 - 1, gy / (h - 1) * 2 - 1], -1)[None]
    out = F.grid_sample(t, grid, mode="bilinear", padding_mode="border", align_corners=True)
    return out[0, 0].numpy()


def max3(a: np.ndarray) -> np.ndarray:
    """3×3 局部最大。定义在 numpy 上，不引 scipy/skimage（本机没装）。"""
    pad = np.pad(a, 1, mode="edge")
    out = np.zeros_like(a)
    for i in range(3):
        for j in range(3):
            out = np.maximum(out, pad[i:i + a.shape[0], j:j + a.shape[1]])
    return out


def crop(a: np.ndarray, m: int) -> np.ndarray:
    return a[m:a.shape[0] - m, m:a.shape[1] - m] if m else a


# ---------------------------------------------------------------- 单段


def pair_stats(c: np.ndarray, c2: np.ndarray, panels: dict, tau: float, margin: int,
               q: float = 0.25, mode: str = "quantile") -> dict:
    """一对相邻帧的全部统计量。`c` 是 t 帧内容亮度，`c2` 是 t+1 帧。

    ⚠ **`dc` 是 0~1，`tau` 是 /255 —— 不换算的话 `mask` 恒真**（第一次跑就是这样，
    "静止% 100%" 而同一行的帧间 MAD 有 13/255，自相矛盾）。

    **判据必须整轮统一**，所以模式是 run 级参数、不是逐帧对的：
    第一版让每对帧自己挑"绝对阈值还是退到分位"，结果同一段里两种模式混着，
    标签成了 `分位25%/绝对`，那个平均**根本不是一回事**。

    - `quantile`（默认）：取**局部 |dc| 最小的那一档**像素。相机在动的时候
      绝对静止的像素可能一个都没有（残差来自旋转/视差/运动物体/亚像素误差），
      分位至少保证掩膜大小可比。**但它不是"静止"，是"动得最少"**——
      所以报告里永远跟着一列「掩膜上的内容残差」，好一眼看出掩膜有多静。
    - `absolute`：内容补偿后局部差小于 `tau/255` 才算没动。语义干净，
      但强运镜片段会挑不出像素（表里照实报 0%）。
    """
    raw = float(np.abs(c2 - c).mean()) * 255.0  # 不补偿的帧间 MAD（锚点）

    dy, dx = est_shift(c, c2)
    dc = crop(c - warp_luma(c2, dy, dx), margin)
    loc = max3(np.abs(dc))          # 局部最大：避免选进运动边缘上的孤立同色点

    static_abs = float((loc < tau / 255.0).mean())      # 诊断列，永远算
    if mode == "absolute":
        mask = loc < tau / 255.0
    else:
        mask = loc <= float(np.quantile(loc, q))

    out = {"dy": dy, "dx": dx, "raw": raw, "pairs": 1, "static_abs": static_abs,
           "static_frac": float(mask.mean()), "content": float(np.abs(dc[mask]).mean()) * 255.0
           if mask.any() else 0.0}
    for name, arr in panels.items():
        d = crop(arr[0] - warp_luma(arr[1], dy, dx), margin)
        out[name] = float(np.abs(d[mask]).mean()) * 255.0 if mask.any() else 0.0
        out[name + "_all"] = float(np.abs(d).mean()) * 255.0
    out["_mask"] = mask
    out["_dc"] = dc
    for name, arr in panels.items():
        out["_d_" + name] = crop(arr[0] - warp_luma(arr[1], dy, dx), margin)
    return out


def group_frames(content_dir: Path, stages_dir: Path, panels):
    """按 `v1_forest_h_f01` 这种 stem 分组。返回 {clip: [(idx, {panel: path})]}。"""
    import re
    pat = re.compile(r"^(?P<clip>.+)_f(?P<idx>\d+)$")
    out: dict = {}
    for f in sorted(content_dir.glob("*.png")) + sorted(content_dir.glob("*.jpg")):
        m = pat.match(f.stem)
        if not m:
            print(f"  ⚠ 跳过（名字对不上 `*_fNN`）：{f.name}")
            continue
        clip, idx = m.group("clip"), int(m.group("idx"))
        entry = {"content": f}
        for p in panels:
            if p == "content":
                continue
            g = stages_dir / f"{f.stem}__{p}.png"
            if g.exists():
                entry[p] = g
        out.setdefault(clip, []).append((idx, entry))
    for clip in out:
        out[clip].sort(key=lambda t: t[0])
    return out


# ---------------------------------------------------------------- 出图


def _label(im: Image.Image, text: str, size: int = 34) -> Image.Image:
    from PIL import ImageDraw, ImageFont
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except Exception:
        font = ImageFont.load_default()
    band = Image.new("RGB", (im.width, size + 14), (18, 18, 18))
    ImageDraw.Draw(band).text((10, 6), text, fill=(240, 240, 240), font=font)
    out = Image.new("RGB", (im.width, im.height + band.height), (18, 18, 18))
    out.paste(band, (0, 0))
    out.paste(im, (0, band.height))
    return out


def hstack(ims, gap: int = 8) -> Image.Image:
    h = max(i.height for i in ims)
    w = sum(i.width for i in ims) + gap * (len(ims) - 1)
    out = Image.new("RGB", (w, h), (18, 18, 18))
    x = 0
    for i in ims:
        out.paste(i, (x, 0))
        x += i.width + gap
    return out


def resid_img(mag: np.ndarray, mask: np.ndarray, gain: float) -> Image.Image:
    """逐帧差渲染成灰度图，**所有面板用同一个增益**。

    为什么要统一增益：这张图的全部意义就是"**输出那格比内容那格亮多少**"。
    各自归一化的话两格都变成"有的地方白有的地方黑"，结论就没了。
    gain 就是标尺，写在标题里。

    **只画掩膜内的像素**——掩膜外是运动补偿的残差（旋转/视差/亚像素），
    画上去会读成"整幅图都在闪"，那和数出来的那个数不是一回事。
    """
    v = np.clip(mag * 255.0 / max(gain, 1e-6), 0.0, 1.0)
    v = np.where(mask, v, 0.0)
    return Image.fromarray((v * 255.0).astype(np.uint8)).convert("RGB")


# ---------------------------------------------------------------- self-check


def self_check() -> int:
    """拿真帧平移已知量，看估不估得回来。**先验估计器，再拿它量东西。**"""
    cands = sorted(Path("runs/VIDEO_material").glob("*.png"))
    if not cands:
        print("找不到 runs/VIDEO_material/*.png，无法自检")
        return 1
    a = load_luma(cands[0])
    print(f"自检用图：{cands[0].name} {a.shape[1]}x{a.shape[0]}")
    # 约定：est_shift(a,b) 返回 d，满足 `a(u) = b(u - d)`，于是
    # `warp_luma(b, *d)`（在 (y-dy, x-dx) 处采样）就对齐到 a。
    # 造样本：b = warp_luma(a, -sy, -sx) ⇒ b(y) = a(y+sy, x+sx) ⇒ a(u) = b(u-(sy,sx)) ⇒ 期望 d=(sy,sx)。
    print(f"{'构造 (sy,sx)':>16} {'期望 d':>16} {'估计 d':>18} {'误差':>10}")
    worst = 0.0
    for sy, sx in ((0, 0), (3, -5), (-7, 2), (12, 9), (2.5, -3.25), (-4.75, 6.5)):
        b = warp_luma(a, -sy, -sx)
        dy, dx = est_shift(a, b)
        err = max(abs(dy - sy), abs(dx - sx))
        worst = max(worst, err)
        print(f"{str((sy, sx)):>16} {str((sy, sx)):>16} "
              f"{str((round(dy, 3), round(dx, 3))):>18} {err:>10.4f}")
    ok = worst < 0.25
    print(f"\n最大误差 {worst:.4f} 像素 —— {'✅ 通过' if ok else '❌ 不合格，别拿它量东西'}")
    print("（亚像素走的是峰值抛物线，0.1~0.2px 的误差是它的能力上限；"
          "这个量级的残余会留在残差里，报告里已写明）")
    return 0 if ok else 1


# ---------------------------------------------------------------- main


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(
        description="真连续帧的时域一致性量测：先按内容帧做全局运动补偿，"
                    "再在「内容动得最少」的那档像素上看输出抖多少")
    ap.add_argument("--content", type=Path, default=Path("runs/VIDEO_material"),
                    help="内容帧目录，文件名须是 <clip>_fNN.png")
    ap.add_argument("--stages", type=Path, default=Path("runs/_video_mat"),
                    help="--dump-panels 的输出目录（同名 <stem>__<panel>.png）")
    ap.add_argument("--out", type=Path, default=Path("runs/view_big/FLICKER"))
    ap.add_argument("--mask-mode", choices=("quantile", "absolute"), default="quantile",
                    help="挑哪些像素来量。quantile=动得最少的那一档（默认，掩膜大小可比）；"
                         "absolute=内容补偿后局部差 < tau 才算没动")
    ap.add_argument("--mask-q", type=float, default=0.25, help="quantile 模式下取最低的这档比例")
    ap.add_argument("--tau", type=float, default=2.0,
                    help="absolute 模式的静止判据（/255）；quantile 模式下只作诊断列")
    ap.add_argument("--margin", type=int, default=24, help="补偿后裁掉的边框（像素）")
    ap.add_argument("--gain", type=float, default=8.0,
                    help="残差图的显示放大倍数（/255）。**所有面板共用同一个**，别改成自动归一")
    ap.add_argument("--pairs-per-clip", type=int, default=3, help="每段出几张对照图")
    ap.add_argument("--self-check", action="store_true", help="只验位移估计器")
    args = ap.parse_args()

    if args.self_check:
        return self_check()

    groups = group_frames(args.content, args.stages, PANELS)
    if not groups:
        print(f"{args.content} 里没有 <clip>_fNN.png")
        return 1

    panel_names = [p for p in PANELS if p != "content" and
                   any((args.stages / f"{e['content'].stem}__{p}.png").exists()
                       for entries in groups.values() for _, e in entries)]
    if not panel_names:
        print(f"⚠ {args.stages} 里没有 __{PANELS[1]}.png 之类的面板，只量内容帧")

    print(f"内容帧：{args.content}")
    print(f"结果帧：{args.stages}   面板：{['content'] + panel_names}")
    print(f"掩膜模式 {args.mask_mode}"
          + (f"(最低 {args.mask_q:.0%})" if args.mask_mode == "quantile" else f"(tau={args.tau}/255)")
          + f"，边框裁 {args.margin}px")
    print("「静止%」是诊断列：这一段素材里真正没动的像素有多少。"
          "强运镜片段它是 0 → 那一行的数只能当「动得最少」读\n")

    args.out.mkdir(parents=True, exist_ok=True)
    rows, agg = [], {}

    for clip, entries in groups.items():
        panels = {}
        for name in panel_names:
            arrs = []
            ok = True
            for _, e in entries:
                if name not in e:
                    ok = False
                    break
                arrs.append(load_luma(e[name]))
            if ok and arrs:
                panels[name] = arrs
        cl = [load_luma(e["content"]) for _, e in entries]
        rgbs = [load_rgb(e["content"]) for _, e in entries]

        stats = []
        for t in range(len(entries) - 1):
            sub = {n: (v[t], v[t + 1]) for n, v in panels.items()}
            stats.append(pair_stats(cl[t], cl[t + 1], sub, args.tau, args.margin,
                                    q=args.mask_q, mode=args.mask_mode))

        n = len(stats)
        row = {"clip": clip, "n_pairs": n, "frames": len(entries),
               "raw": sum(s["raw"] for s in stats) / n,
               "static_frac": sum(s["static_frac"] for s in stats) / n,
               "static_abs": sum(s["static_abs"] for s in stats) / n,
               "content": sum(s["content"] for s in stats) / n}
        for name in panels:
            row[name] = sum(s[name] for s in stats) / n
            row[name + "_all"] = sum(s[name + "_all"] for s in stats) / n
        rows.append(row)
        for k, v in row.items():
            if isinstance(v, float):
                agg.setdefault(k, []).append(v)

        # ---- 出图
        for k in range(min(args.pairs_per_clip, len(entries))):
            t = min(k, len(stats) - 1)
            s = stats[t]
            m = args.margin
            cim = Image.fromarray(rgbs[t][m:rgbs[t].shape[0] - m, m:rgbs[t].shape[1] - m])

            # ① 双联「原图｜结果」—— 用户要的默认视角
            last = panel_names[-1] if panel_names else None
            pair = [_label(cim, f"{clip} f{t+1:02d} 内容")]
            if last:
                a = load_rgb(entries[t][1][last])
                pair.append(_label(
                    Image.fromarray(a[m:a.shape[0] - m, m:a.shape[1] - m]),
                    f"{last}  (逐帧抖 {s[last]:.2f}/255)"))
            _save(hstack(pair), args.out / f"{clip}__pair_f{t+1:02d}.png", args.out)

            # ② 各阶段残差并排，**同一个增益** —— 亮度差就是结论
            if panels:
                row = [_label(resid_img(s["_dc"], s["_mask"], args.gain),
                              f"内容补偿残差 ×{args.gain:g}  (抖 {s['content']:.2f}/255)")]
                for name in panels:
                    row.append(_label(resid_img(s["_d_" + name], s["_mask"], args.gain),
                                      f"{name} 残差  (抖 {s[name]:.2f}/255)"))
                _save(hstack(row), args.out / f"{clip}__resid_f{t+1:02d}.png", args.out)


                # ③ 全阶段面板（要看中间环节时用）
                stages = [_label(cim, f"{clip} f{t+1:02d} 内容  (抖 {s['content']:.2f}/255)")]
                for name in panels:
                    a = load_rgb(entries[t][1][name])
                    stages.append(_label(
                        Image.fromarray(a[m:a.shape[0] - m, m:a.shape[1] - m]),
                        f"{name}  (抖 {s[name]:.2f}/255)"))
                _save(hstack(stages), args.out / f"{clip}__stages_f{t+1:02d}.png", args.out, x2=False)

    # ---- 报告
    heads = ["片段", "帧间MAD", f"掩膜%({args.mask_mode})", f"<{args.tau:g}静止%",
             "内容(掩膜)"] + panel_names
    print("| " + " | ".join(heads) + " |")
    print("|" + "---|" * len(heads))
    for r in rows:
        cells = [r["clip"], f"{r['raw']:.2f}", f"{r['static_frac']*100:.0f}%",
                 f"{r['static_abs']*100:.0f}%", f"{r['content']:.2f}"]
        cells += [f"**{r[n]:.2f}**" if n == "flat" else f"{r[n]:.2f}" for n in panel_names]
        print("| " + " | ".join(cells) + " |")

    tot = {k: sum(v) / len(v) for k, v in agg.items()}
    cells = ["**平均**", f"{tot['raw']:.2f}", f"{tot['static_frac']*100:.0f}%",
             f"{tot['static_abs']*100:.0f}%", f"{tot['content']:.2f}"]
    cells += [f"**{tot[n_]:.2f}**" if n_ == "flat" else f"{tot[n_]:.2f}" for n_ in panel_names]
    print("| " + " | ".join(cells) + " |")

    print(f"\n放大倍率（掩膜像素上，÷ 内容帧）：", end="")
    for n_ in panel_names:
        print(f"  {n_}: {tot[n_]/max(tot['content'],1e-6):.1f}×", end="")
    print()
    print(f"\n图在 {args.out}（`__pair_*` 双联「原图｜结果」；`__resid_*` 各阶段残差（同一增益，亮度差=结论）；`__stages_*` 全阶段）")

    _write_readme(args, rows, tot, panel_names)
    return 0


def _save(im: Image.Image, path: Path, outdir: Path, x2: bool = True) -> None:
    """存图，另存一份 ×2（用户要能放大看）。"""
    im.save(path)
    if x2:
        up = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
        up.save(path.with_name(path.stem + "_x2" + path.suffix))


def _write_readme(args, rows, tot, panel_names) -> None:
    L = ["# 真连续帧的时域一致性量测", "",
         "由 `tools/flicker.py` 生成。素材 `runs/VIDEO_material/`（4 段实拍各 6 张**真相邻帧**）。", "",
         f"- 掩膜模式 **`{args.mask_mode}`**："
         + (f"局部 |Δ内容| 最低的 {args.mask_q:.0%}（**不是“静止”，是“动得最少”**）"
            if args.mask_mode == "quantile" else
            f"内容补偿后局部 |Δ| < {args.tau}/255"),
         f"- 「<{args.tau:g}静止%」是**诊断列**：内容补偿后局部 |Δ| < {args.tau}/255 的像素占比。"
         "**它是 0 就说明这段素材根本挑不出绝对静止的像素**，那一行的数只能在「动得最少」的意义上读",
         f"- 边框裁 {args.margin}px（补偿会动到边）",
         "- 位移**只从内容帧估**，输出帧用同一个位移", "",
         "## 数（全部 /255，掩膜像素上的逐帧绝对差）", "",
         "| 片段 | 帧间MAD | 掩膜% | 静止% | 内容(掩膜) | " + " | ".join(panel_names) + " |",
         "|" + "---|" * (5 + len(panel_names))]
    for r in rows:
        L.append("| " + " | ".join([r["clip"], f"{r['raw']:.2f}",
                                    f"{r['static_frac']*100:.0f}%",
                                    f"{r['static_abs']*100:.0f}%", f"{r['content']:.2f}"] +
                                   [f"{r[n]:.2f}" for n in panel_names]) + " |")
    L.append("| " + " | ".join(["**平均**", f"{tot['raw']:.2f}",
                                f"{tot['static_frac']*100:.0f}%",
                                f"{tot['static_abs']*100:.0f}%", f"{tot['content']:.2f}"] +
                               [f"**{tot[n]:.2f}**" for n in panel_names]) + " |")
    L += ["", "## ⚠ 这量不了什么", "",
          "- **残差里混着补偿误差**。只补了平移——旋转/视差/亚像素估不干净的部分全留在残差里，",
          "  所以绝对数偏高，**只有相对内容帧的倍率是可比的**。",
          "- **不是上板**。没有传感器噪声、编码抖动、真实运镜轨迹。",
          "- **不验观感**。“抖 X/255 算不算看得见”这里答不了。", ""]
    (args.out / "README.md").write_text("\n".join(L) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
