"""从 `deploy/spec.json` 生成网络结构图（SVG）。

    python -m tools.net_diagram <deploy 目录> -o out.svg [--size 1280x720]

## 为什么要有

赛题「超轻量化网络自设计」要求提交**网络结构图**。之前只有 `LAYERS.md` 那样的
**逐层表**——表能查数，但看不出拓扑：哪几层在下采样、残差从哪接到哪、
哪一层之后是 ReLU、上采样发生在卷积之前还是之后。这些恰恰是 RTL 侧最容易接错的。

## 只画 FNS 拓扑

拓扑（残差、上采样位置、激活位置）**不在 spec.json 里**——spec 只有一张按模块顺序
排的卷积表。所以这里把 FNS 的接线**写死**，只从 spec.json 取*数字*（通道、核、stride、
量化范围、scale）。层名对不上就**直接报错**，不静默画一张错的图。

## 为什么是 SVG 不是 PNG

纯文本、能进版本管理、在文档里放大不糊，而且**不依赖 matplotlib/PIL**——
`stnet/` 那一侧的"纯标准库"传统延续到这里。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# ---- 版面 ----
# 主链居中；注释放**底部两栏**，不要放右侧——放右边会被画布宽度裁掉
# （第一版就是右侧注释，实测「zero-point 恒 0」那几行直接切掉一半）。
BOX_W, BOX_H, GAP = 420, 76, 26
WIDTH = 1000
COL_MAIN = (WIDTH - BOX_W) // 2
TOP = 84
PAD = 28

FONT = "ui-sans-serif, Segoe UI, system-ui, sans-serif"
MONO = "ui-monospace, Consolas, monospace"

C_IO = "#1f6feb"      # 输入/输出
C_CONV = "#3fb950"    # 卷积
C_SIGN = "#d29922"    # 有符号层（残差相加之后）
C_ADD = "#8957e5"     # 残差相加
C_UP = "#58a6ff"      # 上采样


def _esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _text(x, y, s, size=13, fill="#1f2328", anchor="start", weight="400", font=FONT):
    return (f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" '
            f'fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">'
            f'{_esc(s)}</text>')


def _box(x, y, w, h, fill, stroke, rx=8, op=1.0):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
            f'fill="{fill}" fill-opacity="{op}" stroke="{stroke}" stroke-width="1.5"/>')


def _arrow(x1, y1, x2, y2, color="#57606a", dash=None, marker="arrow"):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
            f'stroke-width="1.8"{d} marker-end="url(#{marker})"/>')


def _spatial(hw, stride, up):
    h, w = hw
    if up:
        return (h * up, w * up)
    if stride == 2:
        return ((h - 1) // 2 + 1, (w - 1) // 2 + 1)   # k3 p1 s2
    return (h, w)


def build_svg(spec: dict, size: tuple[int, int]) -> str:
    layers = {L["name"]: L for L in spec["layers"]}

    ci = int(spec["input"]["channels"])
    names = [L["name"] for L in spec["layers"]]
    # 接线写死，数字取自 spec。名字对不上就炸，别静默画错。
    expect = ["enc1.conv", "enc2.conv", "enc3.conv",
              "res.0.c1.conv", "res.0.c2.conv", "res.1.c1.conv", "res.1.c2.conv",
              "res.2.c1.conv", "res.2.c2.conv", "dec1.conv", "dec2.conv", "out.conv"]
    if names != expect:
        raise SystemExit(
            "net_diagram 只认识 FNS 拓扑（enc1/2/3 → res.0~2 → dec1/2 → out），"
            f"spec.json 里是：{names}\n"
            "换了网络就得同步改本文件的接线，别让图跟实现脱节。")

    # 逐段推进空间尺寸，记录每层在 720p（或 --size）下的特征图大小
    h, w = size[1], size[0]
    # row = dict(kind, name, op, num, extra, color, signed)
    rows = [dict(kind="io", name=f"输入 {ci}ch", op="", num=f"特征图 {w}×{h}",
                 extra="", color=C_IO, signed=False)]

    def conv_row(name, op, extra="", up=0):
        nonlocal h, w
        L = layers[name]
        h, w = _spatial((h, w), int(L["stride"]), up)
        sd = L["activation_qrange"][0] < 0
        rows.append(dict(
            kind="conv", name=name.replace(".conv", ""), op=op,
            num=(f"{L['cin']}→{L['cout']}ch　k{L['k']}s{L['stride']}　"
                 f"{w}×{h}　scale {L['activation_scale_in']:.5f}"),
            extra=extra, color=C_SIGN if sd else C_CONV, signed=sd))

    conv_row("enc1.conv", "反射填充 + 卷积 + IN + ReLU")
    conv_row("enc2.conv", "↓2　反射填充 + 卷积 + IN + ReLU")
    conv_row("enc3.conv", "↓2　反射填充 + 卷积 + IN + ReLU")

    for i in (0, 1, 2):
        conv_row(f"res.{i}.c1.conv", "反射填充 + 卷积 + IN + ReLU",
                 extra=f"↳ 残差块 res.{i} 的输入")
        conv_row(f"res.{i}.c2.conv", "反射填充 + 卷积 + IN",
                 extra=f"⊕ 与 res.{i} 输入相加")

    conv_row("dec1.conv", "↑2 最近邻 + 反射填充 + 卷积 + IN + ReLU", up=2)
    conv_row("dec2.conv", "↑2 最近邻 + 反射填充 + 卷积 + IN + ReLU", up=2)
    conv_row("out.conv", "反射填充 + 卷积（无归一化、无激活）")

    rows.append(dict(kind="io", name=f"输出 {int(spec['layers'][-1]['cout'])}ch",
                     op="", num=f"特征图 {w}×{h}", extra="", color=C_IO, signed=False))

    wx = int(spec["weight_total_bytes"])
    body_h = sum(BOX_H + GAP for _ in rows) - GAP
    panel_h = 48 + 5 * 18 + 14      # 标题 + 5 行 + 下边距
    height = TOP + body_h + 40 + panel_h + PAD

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
           f'viewBox="0 0 {WIDTH} {height}">',
           '<defs>',
           '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
           'markerHeight="7" orient="auto-start-reverse">'
           '<path d="M 0 0 L 10 5 L 0 10 z" fill="#57606a"/></marker>',
           '<marker id="arrowR" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
           'markerHeight="7" orient="auto-start-reverse">'
           '<path d="M 0 0 L 10 5 L 0 10 z" fill="#8957e5"/></marker>',
           '</defs>',
           f'<rect width="{WIDTH}" height="{height}" fill="#ffffff"/>']

    out.append(_text(PAD, 34, spec["net"], 19, "#1f2328", weight="700"))
    out.append(_text(PAD, 56,
                     f"INT8 定点部署版　{len(spec['layers'])} 层卷积　"
                     f"权重 {wx:,} B　激活 uint8　"
                     f"特征图按 {size[0]}×{size[1]} 输入标注",
                     12, "#57606a"))

    # ---- 主链 ----
    y = TOP
    box_y = {}
    for r in rows:
        box_y[r["name"]] = y
        out.append(_box(COL_MAIN, y, BOX_W, BOX_H, r["color"], r["color"], op=0.08))
        out.append(f'<rect x="{COL_MAIN}" y="{y}" width="4" height="{BOX_H}" '
                   f'rx="2" fill="{r["color"]}"/>')
        tx = COL_MAIN + 18
        out.append(_text(tx, y + 24, r["name"], 13.5, "#1f2328", weight="700"))
        if r["signed"]:
            bw = 52
            out.append(f'<rect x="{COL_MAIN + BOX_W - bw - 14}" y="{y + 11}" '
                       f'width="{bw}" height="18" rx="9" fill="{C_SIGN}" '
                       f'fill-opacity="0.16" stroke="{C_SIGN}"/>')
            out.append(_text(COL_MAIN + BOX_W - 14 - bw / 2, y + 24, "有符号", 10.5,
                             "#9a6700", anchor="middle", weight="700"))
        if r["op"]:
            out.append(_text(tx, y + 44, r["op"], 12, "#57606a"))
        out.append(_text(tx, y + 63, r["num"], 11.5, "#8c959f", font=MONO))
        if r["extra"]:
            out.append(_text(COL_MAIN + BOX_W + 16, y + 44, r["extra"], 11,
                             "#8957e5"))
        y += BOX_H + GAP

    for a, b in zip(rows, rows[1:]):
        y1 = box_y[a["name"]] + BOX_H
        y2 = box_y[b["name"]]
        out.append(_arrow(COL_MAIN + BOX_W / 2, y1, COL_MAIN + BOX_W / 2, y2 - 2))

    # 残差旁路：res.i 的输入接到 res.i.c2 的输出
    for i in (0, 1, 2):
        y0 = box_y[f"res.{i}.c1"]
        y1 = box_y[f"res.{i}.c2"]
        xb = COL_MAIN - 30 - i * 26
        out.append(f'<path d="M {COL_MAIN} {y0 + BOX_H/2} H {xb} V {y1 + BOX_H/2} '
                   f'H {COL_MAIN - 6}" fill="none" stroke="#8957e5" stroke-width="1.8" '
                   f'marker-end="url(#arrowR)"/>')
        out.append(_text(xb - 8, (y0 + y1) / 2 + BOX_H / 2 + 5, "⊕", 15, "#8957e5",
                         anchor="end", weight="700"))

    # ---- 底部两栏注释 ----
    py = TOP + body_h + 34
    colw = (WIDTH - 2 * PAD - 24) / 2
    panels = [
        ("量化（全部取自 spec.json，不手抄）", [
            "权重：int8 对称，逐张量 per-tensor",
            "激活：uint8 非对称；ReLU 后非负 → zero-point 恒 0",
            "累加器：int32，最坏 (ci·k·k)·255·127",
            "残差相加的两支必须共用同一条 scale",
            "残差 c1 的输入可能为负 → 该层转有符号 ±127",
        ]),
        ("硬件要点（RTL 侧最容易接错的地方）", [
            "反射填充，不是零填充 —— 边界要自己算",
            "InstanceNorm 已折进前一层卷积 → 硬件零成本",
            "上采样在卷积之前，最近邻、无乘法",
            "做的是相关，卷积核不翻转",
            "边长必须 4 的倍数（两级 ↓2 × 两级 ↑2）",
        ]),
    ]
    for ci2, (title, items) in enumerate(panels):
        px = PAD + ci2 * (colw + 24)
        out.append(f'<rect x="{px}" y="{py}" width="{colw}" height="{panel_h}" '
                   f'rx="10" fill="#f6f8fa" stroke="#d0d7de"/>')
        out.append(_text(px + 14, py + 26, title, 12, "#1f2328", weight="700"))
        for j, s in enumerate(items):
            out.append(_text(px + 14, py + 48 + j * 18, "· " + s, 11, "#57606a"))

    out.append("</svg>")
    return "\n".join(out)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="从 spec.json 生成网络结构图（SVG）")
    ap.add_argument("deploy", type=Path, help="deploy/ 目录")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--size", default="1280x720",
                    help="用来标注特征图尺寸的输入分辨率，默认 1280x720")
    args = ap.parse_args()

    spec = json.loads((args.deploy / "spec.json").read_text(encoding="utf-8"))
    w, h = (int(v) for v in args.size.lower().split("x"))
    svg = build_svg(spec, (w, h))
    args.out.write_text(svg, encoding="utf-8")
    print(f"{args.out}  ({len(svg)/1024:.1f} KB, {spec['net']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
