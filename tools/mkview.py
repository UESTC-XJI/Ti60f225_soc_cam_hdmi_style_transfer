"""把 `--dump-panels` 的输出拼成**双联大图**（原图｜结果）。

    python -m tools.mkview runs/toon_out                 # 就地出 <stem>__pair.png
    python -m tools.mkview runs/toon_out --x2            # 再出一份 ×2 的
    python -m tools.mkview A/base A/mine --label 基线 --label 我的   # 两套结果并排比

## 为什么要有它

`tools.toon --dump-panels` 会把四联图的每一格单独存成
`<stem>__content.png` / `__stylized.png` / `__flat.png` / `__lined.png`，
但**拼图**这件事之前一直是临时 Python 干的——调参时每改一次就要手写一遍，很容易抄错。

## 面板怎么选（容易搞混，写在这）

| 文件 | 是什么 |
|---|---|
| `__content.png` | **原图**（内容） |
| `__stylized.png` | **网络原始输出**，后处理之前 |
| `__flat.png` | **后处理结果** ← 要看的通常是这个 |
| `__lined.png` | 加描边之后（`--line-source none` 时等于 `__flat`） |

⚠ 2026-09-29 踩过：拿 `__stylized` 当结果做对照，三张图**逐字节相同**却据此下了结论。
**看清楚再比。**

## 尺寸

一张 `__pair.png` 正好 **1280 宽**（两格各 640）。原图比 640 小就按原尺寸，
不放大——放大只会让像素看着更糊。`--x2` 出 2560 宽的 LANCZOS 版，给挑细节用。
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def _font(size: int = 24):
    for name in ("msyh.ttc", "simhei.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(f" C:/Windows/Fonts/{name}".strip(), size)
        except Exception:
            continue
    return ImageFont.load_default()


def _read(path: Path, panel: str) -> Image.Image | None:
    p = path / f"{path.stem}__{panel}.png" if path.is_file() is False else None
    return Image.open(p).convert("RGB") if p and p.exists() else None


def collect(d: Path, panel: str) -> dict[str, Path]:
    """目录里所有 `<stem>__<panel>.png` -> {stem: 路径}。"""
    out = {}
    for f in sorted(d.glob(f"*__{panel}.png")):
        out[f.name[: -len(f"__{panel}.png")]] = f
    return out


def build(rows, *, bar: int = 30, panel_w: int = 640, title: str = "") -> Image.Image:
    """rows: [(stem, [Image, ...], [label, ...])] —— 每行左起并排。"""
    fnt = _font()
    prep = []
    for stem, imgs, labels in rows:
        sc = [min(1.0, panel_w / im.width) for im in imgs]
        sz = [(max(1, int(im.width * s)), max(1, int(im.height * s)))
              for im, s in zip(imgs, sc)]
        h = max(z[1] for z in sz)
        prep.append((stem, imgs, labels, sz, h))
    W = sum(z[0] for z in prep[0][3])
    H = sum(p[4] + bar for p in prep)
    o = Image.new("RGB", (W, H), (250, 250, 252))
    d = ImageDraw.Draw(o)
    y = 0
    for stem, imgs, labels, sz, h in prep:
        d.text((8, y + 4), f"{stem}   {title}".strip(), fill=(10, 10, 20), font=fnt)
        x = 0
        for im, (w, hh), lb in zip(imgs, sz, labels):
            o.paste(im.resize((w, hh), Image.LANCZOS), (x, y + bar))
            if lb:
                d.text((x + 8, y + 4), lb, fill=(10, 10, 20), font=fnt)
            x += w
        y += h + bar
    return o


def main() -> int:
    import sys
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="把 --dump-panels 的输出拼成双联大图")
    ap.add_argument("dirs", nargs="+", type=Path,
                    help="一个目录：出「原图｜结果」双联；"
                         "两个目录：出「基线｜对照」双联（都用各自的 __flat）")
    ap.add_argument("--panel", default="flat",
                    help="右侧用哪个面板：flat（默认，后处理结果）/ stylized（网络输出）")
    ap.add_argument("--x2", action="store_true", help="额外出一份 LANCZOS ×2")
    ap.add_argument("--width", type=int, default=640, help="每一格的宽度（默认 640）")
    args = ap.parse_args()

    if len(args.dirs) == 1:
        d = args.dirs[0]
        base, res = collect(d, "content"), collect(d, args.panel)
        stems = [s for s in sorted(res) if s in base]
        if not stems:
            print(f"{d} 里没有 content/{args.panel} 配对的图。"
                  f"先跑 tools.toon --dump-panels")
            return 1
        rows = [(s, [Image.open(base[s]).convert("RGB"),
                    Image.open(res[s]).convert("RGB")], ["原图", "结果"])
                for s in stems]
        title = ""
    else:
        (d0, d1) = args.dirs[0], args.dirs[1]
        a, b = collect(d0, args.panel), collect(d1, args.panel)
        stems = [s for s in sorted(a) if s in b]
        if not stems:
            print("两个目录里没有同名的图")
            return 1
        rows = [(s, [Image.open(a[s]).convert("RGB"),
                    Image.open(b[s]).convert("RGB")],
                 [d0.name, d1.name]) for s in stems]

    one = build(rows, panel_w=args.width, title=title)
    dst = args.dirs[0] / ("__pair.png" if len(args.dirs) == 1 else "__cmp.png")
    one.save(dst)
    print(f"{dst}  {one.size}")
    if args.x2:
        big = one.resize((one.width * 2, one.height * 2), Image.LANCZOS)
        dst2 = dst.with_name(dst.stem + "_x2.png")
        big.save(dst2)
        print(f"{dst2}  {big.size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
