"""消融「晕染外溢」算子：出「有 ｜ 无」对照图，**肉眼**判它值不值 12.5 KB。

    python -m tools.ab_bleed
    python -m tools.ab_bleed --bleed 0.30 --limit 5 --max-side 640

## 为什么值得单独立一个消融

`watercolor()` 的 `bleed`（晕染外溢）在水彩三件套里**最贵**：

| 算子 | 720p@D=4 |
|---|---|
| 边缘积色 | 1.9 KB |
| **晕染外溢** | **12.5 KB** ← 灰度 box r=3 ＋ **RGB box r=5** |
| 纸纹 | 4.0 KB（改 LFSR 则 0） |

占完整版后处理（48.4 KB）的 **26%**，是单项第一（导向滤波虽 25 KB，但它撑起了
水彩三件套的 a/b 图，砍不掉）。见 `tools/pp_cost.py`。

它同时也是**退化风险最高**的一个——`watercolor()` 的 docstring 自己写着：

> ⚠ 只在高梯度处混、且半径不大——否则就退化成普通模糊，把刚保住的细节又糊掉。

而"糊了 vs 画了"正是这个项目反复踩的那条轴（`README.md` 坑 #7 / #11，
`FPGA-IMPL.md` §1.6）。**所以判据是看图，不是指标。**

## 做法：复用同一条流水线，不复制逻辑

本脚本调 `tools.toon` **原样跑定稿流水线**（用 `--dump-panels` 导出单格），
只把 `--wc-bleed` 换成 0 和定稿值，再拼图。

**为什么不在这里重写一遍管线**：那样"消融版"和"正片"会各自漂移，
出来的差异就不知道是算子的功劳还是代码的差异——**假对照比没有对照更坏**。

## 输出（`runs/view_big/ab_bleed/`）

| 文件 | 内容 |
|---|---|
| `<stem>__A_bleedON.png` / `__B_bleedOFF.png` | 两版独立结果（原生分辨率） |
| `<stem>__pair.png` | **双联「有晕染 ｜ 无晕染」**，≈1280 宽 |
| `<stem>__pair_x2.png` | 同上 ×2（LANCZOS，方便细看） |
| `<stem>__trio.png` | 三联「原图 ｜ 有 ｜ 无」，带参考 |
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "runs" / "view_big" / "ab_bleed"
WORK = ROOT / "runs" / "_intermediate" / "ab_bleed"

# 定稿流水线（runs/final/showcase 用的那条），只有 --wc-bleed 会被换掉。
BASE = [
    # ⚠ 是 runs/D_wc_g15，**不是** runs/final/D_wc_g15 ——
    # runs/final/README.md 里那条命令的路径是过期的（该目录下没有 D_wc_*）。
    "--ckpt", "runs/D_wc_g15",
    "--sat", "1.0", "--con", "1.20",
    "--flat-mode", "guided", "--guided-r", "8", "--guided-eps", "0.002",
    "--luma-match",
    "--chroma-blend", "0.3", "--chroma-style", "great_wave",
    "--wc-edge", "0.5", "--wc-paper", "0.20",
    "--line-source", "none",
    "--dump-panels",
]


def run_toon(bleed: float, limit: int, max_side: int, outdir: Path) -> None:
    """跑一次 toon（bleed 是唯一变量）。"""
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "tools.toon", *BASE,
           "--wc-bleed", str(bleed),
           "--limit", str(limit), "--max-side", str(max_side),
           "--out", str(outdir)]
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode != 0:
        raise SystemExit(f"toon 跑失败（bleed={bleed}）")


def strip(imgs: list[Image.Image], labels: list[str], bar: int = 26) -> Image.Image:
    """横排拼图，顶部加标签条。"""
    w, h = imgs[0].size
    out = Image.new("RGB", (w * len(imgs), h + bar), (250, 250, 252))
    d = ImageDraw.Draw(out)
    for i, (im, lb) in enumerate(zip(imgs, labels)):
        out.paste(im, (i * w, bar))
        d.text((i * w + 8, 7), lb, fill=(20, 20, 30))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="消融「晕染外溢」算子")
    ap.add_argument("--bleed", type=float, default=0.30, help="定稿值（对照组的'有'）")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--max-side", type=int, default=640,
                    help="单格边长。640 → 双联 1280 宽（用户偏好），×2 后 2560")
    args = ap.parse_args()

    on_dir = WORK / "on"
    off_dir = WORK / "off"

    print(f"① 跑定稿（--wc-bleed {args.bleed}）…")
    run_toon(args.bleed, args.limit, args.max_side, on_dir)
    print(f"\n② 跑消融（--wc-bleed 0.0，其余完全相同）…")
    run_toon(0.0, args.limit, args.max_side, off_dir)

    OUT.mkdir(parents=True, exist_ok=True)
    stems = sorted(p.name.split("__")[0] for p in on_dir.glob("*__lined.png"))
    print(f"\n③ 拼图 → {OUT.relative_to(ROOT)}")

    rows: list[tuple[str, float, float]] = []
    for stem in stems:
        src = {n: Image.open(on_dir / f"{stem}__{n}.png").convert("RGB")
               for n in ("content", "lined")}
        off = Image.open(off_dir / f"{stem}__lined.png").convert("RGB")
        ref, on = src["content"], src["lined"]

        # 两版之间到底差多少 / 差在哪 —— 只用来**定位**，不用来下结论。
        a = np.asarray(on, np.float32) / 255.0
        b = np.asarray(off, np.float32) / 255.0
        d = np.abs(a - b).mean(axis=2)
        changed = float((d > 2 / 255).mean())      # 变化超过 2/255 的像素占比
        delta = float(d.mean())
        rows.append((stem, changed, delta))

        on.save(OUT / f"{stem}__A_bleedON.png")
        off.save(OUT / f"{stem}__B_bleedOFF.png")

        pair = strip([on, off], [f"WITH bleed {args.bleed}", "WITHOUT bleed (0.0)"])
        pair.save(OUT / f"{stem}__pair.png")
        pair.resize((pair.width * 2, pair.height * 2), Image.LANCZOS).save(
            OUT / f"{stem}__pair_x2.png")

        trio = strip([ref, on, off], ["content", f"bleed {args.bleed}", "bleed 0.0"])
        trio.save(OUT / f"{stem}__trio.png")

    print(f"\n{'图':<22}{'变化像素占比':>12}{'平均绝对差':>12}")
    for stem, c, d in rows:
        print(f"  {stem:<20}{c:>11.1%}{d:>12.4f}")
    print(f"\n  {'平均':<20}{np.mean([r[1] for r in rows]):>11.1%}"
          f"{np.mean([r[2] for r in rows]):>12.4f}")

    print(f"\n产出 {len(stems) * 5} 个文件在 {OUT}")
    print("**判据是肉眼**：并排看 `__pair.png`，问'少了这层晕染，"
          "画面是否明显不像水彩了'。")
    print("看不出差别 → 砍掉，省 12.5 KB（不做共享的退路余量 2.0 → 14.5 KB）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
