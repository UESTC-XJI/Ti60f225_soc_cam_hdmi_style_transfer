"""赛璐璐对照图：**同一套后处理**跑两个 ckpt，只换网络。

    python -m tools.ab_cel                       # A=旧网络  B=新网络
    python -m tools.ab_cel --a runs/final/D_ukiyoe_y --b runs/D_cel_q6

## 为什么这样比

要回答的是"**重训有没有让量化变干净**"。所以必须**只换网络、后处理一模一样**——
否则出来的差异不知道是网络的功劳还是参数的差异。**假对照比没有对照更坏**
（同 `tools/ab_bleed.py` 的理由）。

本脚本**复用 `tools.toon` 原样跑两遍**，不复制流水线逻辑。

## 输出（`runs/view_big/cel/`）

| 文件 | 内容 |
|---|---|
| `<stem>__pair.png` | **双联「原图 ｜ 新结果」**，≈1280 宽 |
| `<stem>__pair_x2.png` | 同上 ×2（LANCZOS，2560 宽） |
| `<stem>__cmp.png` | **三联「原图 ｜ 旧网络 ｜ 新网络」** |
| `<stem>__A.png` / `__B.png` | 两版独立结果 |

## 判据（按顺序问，任一不过就是失败）

1. 平坦区（天空、墙面、皮肤）是不是**单一色块、无斑点**？← 要修的就是这条
2. 色带数对不对（≈K）？多了=没量化，少了=塌了
3. 结构还在不在（人脸、路牌、盘上的字）？边界有没有落在**真边缘**上？
4. 和「旧网络」比是不是**明显更干净**？看不出差 ⇒ 这轮白做

⚠ **不要拿 SSIM 判**。STE 量化**必然**把 SSIM 拉低（输出被限制在 K 级网格上），
这里是"指标变差而画面变对"——和坑 #7 同型，只是方向反过来。
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "runs" / "view_big" / "cel"
WORK = ROOT / "runs" / "_intermediate" / "ab_cel"

# 后处理链：**两个 ckpt 完全相同**。--levels 必须等于训练时的 --quant-levels。
# --sat/--con 收回 1.0：它们是逐通道仿射，会把 K 级 Y 重新打散（方案 §R5）。
BASE = [
    "--sat", "1.0", "--con", "1.0",
    "--flat-mode", "guided", "--guided-r", "8", "--guided-pass", "1",
    "--guided-eps", "0.002",
    "--luma-match",
    "--chroma-blend", "0.3", "--chroma-style", "great_wave",
    "--levels", "6", "--levels-c", "6",
    "--quant-space", "ycbcr", "--pre-denoise", "0",
    "--line-source", "edge", "--line-from", "flat",
    "--sigma-fine", "1.2", "--sigma-coarse", "4.0",
    "--t-fine", "0.05", "--t-coarse", "0.09", "--w-coarse", "1",
    "--dump-panels",
]


def run_toon(ckpt: str, limit: int, max_side: int, outdir: Path) -> None:
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "tools.toon", "--ckpt", ckpt, *BASE,
           "--limit", str(limit), "--max-side", str(max_side), "--out", str(outdir)]
    if subprocess.run(cmd, cwd=ROOT).returncode != 0:
        raise SystemExit(f"toon 跑失败（ckpt={ckpt}）")


def strip(imgs: list[Image.Image], labels: list[str], bar: int = 26) -> Image.Image:
    w, h = imgs[0].size
    out = Image.new("RGB", (w * len(imgs), h + bar), (250, 250, 252))
    d = ImageDraw.Draw(out)
    for i, (im, lb) in enumerate(zip(imgs, labels)):
        out.paste(im, (i * w, bar))
        d.text((i * w + 8, 7), lb, fill=(20, 20, 30))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="赛璐璐对照：只换网络，后处理固定")
    ap.add_argument("--a", default="runs/final/D_ukiyoe_y", help="旧网络（基线）")
    ap.add_argument("--b", default="runs/D_cel_q6", help="新网络")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--max-side", type=int, default=640,
                    help="单格边长。640 → 双联 1280 宽（用户偏好），×2 后 2560")
    args = ap.parse_args()

    a_dir, b_dir = WORK / "a", WORK / "b"
    print(f"① 旧网络 {args.a} …")
    run_toon(args.a, args.limit, args.max_side, a_dir)
    print(f"\n② 新网络 {args.b} …")
    run_toon(args.b, args.limit, args.max_side, b_dir)

    OUT.mkdir(parents=True, exist_ok=True)
    stems = sorted(p.name.split("__")[0] for p in b_dir.glob("*__lined.png"))
    print(f"\n③ 拼图 → {OUT.relative_to(ROOT)}")

    for stem in stems:
        ref = Image.open(b_dir / f"{stem}__content.png").convert("RGB")
        new = Image.open(b_dir / f"{stem}__lined.png").convert("RGB")
        old = Image.open(a_dir / f"{stem}__lined.png").convert("RGB")

        new.save(OUT / f"{stem}__B_new.png")
        old.save(OUT / f"{stem}__A_old.png")

        pair = strip([ref, new], ["content", f"cel ({Path(args.b).name})"])
        pair.save(OUT / f"{stem}__pair.png")
        pair.resize((pair.width * 2, pair.height * 2), Image.LANCZOS).save(
            OUT / f"{stem}__pair_x2.png")

        cmp3 = strip([ref, old, new],
                     ["content", f"OLD ({Path(args.a).name})",
                      f"NEW ({Path(args.b).name})"])
        cmp3.save(OUT / f"{stem}__cmp.png")

    print(f"\n产出 {len(stems) * 5} 个文件在 {OUT}")
    print("**判据是肉眼**，按顺序问：")
    print("  1) 平坦区是不是单一色块、无斑点？  2) 色带数对不对（≈6）？")
    print("  3) 结构还在不在、边界落在真边缘上？ 4) 比旧网络明显更干净吗？")
    print("⚠ 不要拿 SSIM 判——量化必然把 SSIM 拉低，这里是指标变差而画面对。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
