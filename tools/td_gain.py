"""**受控的时域增益探针** —— 不依赖任何真实素材、不依赖运动补偿。

    python -m tools.td_gain --mode real    -- <toon 的参数...>   # ← 主判据
    python -m tools.td_gain --mode uniform --delta 1.0 -- <toon 的参数...>
    python -m tools.td_gain --mode noise   --delta 1.0 -- <toon 的参数...>
    python -m tools.td_gain --mode local   --delta 1.0 -- <toon 的参数...>

## 它回答什么

`tools/flicker.py` 量的是真实视频：要先做运动补偿，而补偿的残余会混进残差里
（旋转/视差/亚像素）——**那个残差里有多少是闪烁、多少是补偿不干净，分不开**。

这个探针把那一层拿掉。做法：造两个**只差一个已知量**的输入丢进流水线，量输出的差。

```
内容 Δ = 已知        输出 Δ = 实测
增益   = 输出 Δ / 内容 Δ    ← 这一级的"时域增益"：没有运动、没有对齐、没有掩膜
```

**δ 是什么很重要**，因为网络里有 InstanceNorm，也因为**真实的时域残差不是白噪声**：

| 模式 | δ | 量到的是 |
|---|---|---|
| **`real`** | **实测的相邻帧内容残差场**（带运动补偿） | **整条链对真实时域信号的增益** ← 主判据 |
| `uniform` | 全图 +δ/255 | IN 会把它抹掉 ⇒ 几乎只剩后处理 |
| `noise` | 逐像素 σ=δ/255（白噪） | 整条链的增益，但**白噪不是真实信号** |
| `local` | 一小块 +δ/255 | 局部结构变化的增益 |

⚠ **`noise` 那档不能当结论**：实测流水线对白噪的增益是 **0.8×（在抹平）**——
因为 Kuwahara/模糊本来就是降噪器。真实帧间残差是**结构化的**（边缘、梯度），
拿白噪代表它会得出反向的结论。**要 `real` 那档才算数。**

⚠ **原型和部署不是一回事**：`tools/temporal_check.py` 记过，部署时 IN 被折叠成定值，
那份"统计量很稳"就没了。`tools/toon.py` **不折叠**，所以 `uniform` 那行
**不能代表上板行为**。

⚠ `real` 是**受控对照，不是真实视频**：B 是 A 加上残差场造出来的，
没有新的遮挡/形变，且加法在 0/255 处会**削顶**（报告里打削顶比例）。

## 为什么不直接拿处理后的图和原图比

那样比出来的差**全是处理本身**（配色、纸纹、对比度），和"抖动"没关系。
抖动只在**跨时间**上定义，所以这里也只在**同一条链的两个输出之间**比。
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

BT601 = np.array((0.299, 0.587, 0.114), dtype=np.float32)
SRC = Path("data/content")


def perturb(a: np.ndarray, mode: str, delta: float, rng: np.random.Generator) -> np.ndarray:
    """在 0~255 的 uint8 上造出只差 δ 的第二张。**先在 uint8 上做，别在浮点上做**——
    否则 δ 小于 1/255 时两张图会因舍入变得逐字节相同，增益就成了 0/0。"""
    d = max(1.0, delta)                      # 保证至少动 1/255，否则 uint8 上等于没动
    if mode == "uniform":
        out = a.astype(np.float32) + d
    elif mode == "noise":
        out = a.astype(np.float32) + rng.normal(0.0, d, size=a.shape)
    elif mode == "local":
        out = a.astype(np.float32).copy()
        h, w = a.shape[:2]
        cy, cx = h // 2, w // 2
        r = max(8, min(h, w) // 8)
        y0, y1 = max(0, cy - r), min(h, cy + r)
        x0, x1 = max(0, cx - r), min(w, cx + r)
        out[y0:y1, x0:x1] += d
    else:
        raise ValueError(mode)
    return np.clip(out, 0, 255).astype(np.uint8)


def luma(a: np.ndarray) -> np.ndarray:
    return (a.astype(np.float32) / 255.0) @ BT601


def build_pairs(args, rng):
    """产出 `[(名字, A_rgb, B_rgb, 备注)]`。**各模式的差别只在这里。**"""
    if args.mode == "real":
        # 复用 flicker 的对齐/亮度，别另写一套（两套实现必然会漂）
        import re
        from tools.flicker import est_shift, load_luma, warp_luma
        clips: dict = {}
        for f in sorted(args.clip_dir.glob("*.png")):
            m = re.match(r"^(?P<clip>.+)_f(?P<i>\d+)$", f.stem)
            if m:
                clips.setdefault(m.group("clip"), []).append((int(m.group("i")), f))
        out = []
        for clip, ents in sorted(clips.items()):
            if len(ents) < 2:
                continue
            ents.sort()
            f1, f2 = ents[0][1], ents[1][1]
            a = np.asarray(Image.open(f1).convert("RGB"), dtype=np.uint8)
            ya, y2 = load_luma(f1), load_luma(f2)
            dy, dx = est_shift(ya, y2)
            d = (ya - warp_luma(y2, dy, dx)) * 255.0     # 带符号的真实残差场（/255 域）
            raw = a.astype(np.float32) + d[..., None]
            clip_frac = float(((raw < 0) | (raw > 255)).any(-1).mean())
            b = np.clip(raw, 0, 255).astype(np.uint8)
            out.append((clip, a, b, f"对齐 (dy,dx)=({dy:.2f},{dx:.2f}) 削顶 {clip_frac*100:.1f}%"))
        return out[:args.limit]

    srcs = sorted(p for p in args.src.glob("*.jpg"))[:args.limit]
    if not srcs:
        print(f"{args.src} 里没有 *.jpg")
        return []
    out = []
    for f in srcs:
        im = np.asarray(Image.open(f).convert("RGB"), dtype=np.uint8)
        out.append((f.stem, im, perturb(im, args.mode, args.delta, rng), ""))
    return out


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(
        description="受控时域增益探针：同一张图造一对已知微差的输入，量输出的差")
    ap.add_argument("--mode", choices=("real", "uniform", "noise", "local"), default="real")
    ap.add_argument("--delta", type=float, default=1.0, help="输入差（/255），默认 1")
    ap.add_argument("--limit", type=int, default=4, help="用几张内容图 / 几段视频")
    ap.add_argument("--src", type=Path, default=SRC, help="非 real 模式的内容图目录")
    ap.add_argument("--clip-dir", type=Path, default=Path("runs/VIDEO_material"),
                    help="real 模式的连续帧目录")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--work", type=Path, default=Path("runs/_gain"))
    # `--` 之后原样转给 tools.toon。**自己切，不用 nargs=REMAINDER**——
    # argparse 对裸 `--` 有特殊处理，`--` 会被它自己吃掉，REMAINDER 收到的是空。
    argv = sys.argv[1:]
    if "--" in argv:
        cut = argv.index("--")
        argv, toon_args = argv[:cut], argv[cut + 1:]
    else:
        toon_args = []
    args = ap.parse_args(argv)

    if not toon_args:
        print("⚠ 需要在 `--` 之后给 tools.toon 的参数（至少 --ckpt）")
        return 1

    indir = args.work / f"{args.mode}_in"
    outdir = args.work / f"{args.mode}_out"
    if indir.exists():
        shutil.rmtree(indir)
    indir.mkdir(parents=True)

    rng = np.random.default_rng(args.seed)
    pairs = []
    for stem, a, b, note in build_pairs(args, rng):
        d = float(np.abs(luma(b) - luma(a)).mean()) * 255.0
        if d < 0.4:
            print(f"  ⚠ {stem}：δ 落到 uint8 上等于没动，跳过")
            continue
        Image.fromarray(a).save(indir / f"{stem}_f01.png")
        Image.fromarray(b).save(indir / f"{stem}_f02.png")
        pairs.append((stem, d, note))

    cmd = [sys.executable, "-m", "tools.toon", "--input", str(indir), "--limit", "99",
           "--max-side", "0", "--out", str(outdir), "--dump-panels", *toon_args]
    print("跑：" + " ".join(cmd[:8]) + " ...")
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout[-2000:])
        print(r.stderr[-2000:])
        return r.returncode

    panels = [p for p in ("stylized", "flat", "lined")
              if (outdir / f"{pairs[0][0]}_f01__{p}.png").exists()]
    if not panels:
        print(f"⚠ {outdir} 里没有面板输出")
        return 1

    print(f"\n模式 **{args.mode}**" + (f"，δ={args.delta}/255" if args.mode != "real" else
                                    "（扰动 = 实测的相邻帧内容残差场）"))
    print(f"| 样张 | 输入 Δ | " + " | ".join(f"{p} Δ(增益)" for p in panels) + " | 备注 |")
    print("|" + "---|" * (3 + len(panels)))
    acc = {p: [] for p in panels}
    xacc = []
    for stem, d, note in pairs:
        cells = []
        cim = np.asarray(Image.open(indir / f"{stem}_f01.png").convert("RGB"), dtype=np.uint8)
        c2 = np.asarray(Image.open(indir / f"{stem}_f02.png").convert("RGB"), dtype=np.uint8)
        dc = float(np.abs(luma(c2) - luma(cim)).mean()) * 255.0
        for p in panels:
            o1 = np.asarray(Image.open(outdir / f"{stem}_f01__{p}.png").convert("RGB"), dtype=np.uint8)
            o2 = np.asarray(Image.open(outdir / f"{stem}_f02__{p}.png").convert("RGB"), dtype=np.uint8)
            do = float(np.abs(luma(o2) - luma(o1)).mean()) * 255.0
            acc[p].append(do / max(dc, 1e-6))
            cells.append(f"{do:.2f} ({do/max(dc,1e-6):.1f}×)")
        xacc.append(dc)
        print(f"| {stem} | {dc:.2f} | " + " | ".join(cells) + f" | {note} |")
    print(f"| **平均** | {np.mean(xacc):.2f} | " +
          " | ".join(f"**{np.mean(acc[p]):.1f}×**" for p in panels) + " | |")

    print("\n读法：增益 = 输出逐帧差 ÷ 输入逐帧差。"
          "\n  ≈1 = 这一级对时间差是透明的；>1 = 它在放大；<1 = 它在抹平。")
    if args.mode == "uniform":
        print("  ⚠ uniform 模式下网络那格接近 0 是 InstanceNorm 抹掉的**假象**，"
              "部署折叠后没有这层保护。别按这行读网络。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
