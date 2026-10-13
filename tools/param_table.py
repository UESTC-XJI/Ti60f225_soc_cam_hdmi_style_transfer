"""从 ckpt + `deploy/spec.json` 生成**参数量统计表**（赛题「超轻量化网络自设计」要交）。

    python -m tools.param_table --tag D_wc_g15 --ckpt runs/final/D_wc_g15/net.pt \\
        --deploy runs/final/D_wc_g15/deploy --out 某处.md

## 为什么这个表比看上去麻烦

同一个网络有**三种都能叫"参数量"**的数，差 4 倍以上，**报错口径就是虚报**：

| 口径 | 为什么会有这个数 |
|---|---|
| 训练 ckpt 总参数 | `net.pt` 里 `state_dict` 所有张量之和。**含 InstanceNorm 的 w/b** |
| **折叠后参数量** | 部署时 IN 被折进卷积 ⇒ norm 的两个参数**消失**。= 卷积权重 + 偏置 |
| **字节数** | 同一组参数，**INT8 和 FP32 差 4 倍** |

赛题原文只说「网络参数量小于 **500KB**」，**没说精度、也没说算不算 norm**。
⇒ 这张表**把每种口径都列出来**，让看的人自己挑，别替他们选。

## 不自己算数

`weights.hex` 的字节数、偏置个数都从 `spec.json` 读（那是导出的权威记录），
只从 ckpt 数「训练态」的那几个数。两边对不上就报错——
`改D 17,059−139 = 16,920` 这条恒等式是 `ARCH-DECISION.md` 里对过的账。
"""

from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path

import torch  # noqa: E402


def count(sd) -> dict:
    """按**名字**分类，不按形状猜——`norm.weight` 和 `conv.weight` 都是 1 维以外的张量。"""
    c = {"conv_w": 0, "conv_b": 0, "norm_w": 0, "norm_b": 0, "other": 0, "total": 0}
    for k, v in sd.items():
        n = int(v.numel())
        c["total"] += n
        if k.endswith("conv.weight"):
            c["conv_w"] += n
        elif k.endswith("conv.bias"):
            c["conv_b"] += n
        elif k.endswith("norm.weight"):
            c["norm_w"] += n
        elif k.endswith("norm.bias"):
            c["norm_b"] += n
        else:
            c["other"] += n
    return c


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="生成参数量统计表（多口径，从 ckpt/spec 实数）")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--ckpt", type=Path, required=True)
    ap.add_argument("--deploy", type=Path, required=True)
    ap.add_argument("--net", default="", help="网络描述，留空则从 spec.json 读")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    m = torch.load(args.ckpt, map_location="cpu", weights_only=False)
    sd = m["state_dict"] if isinstance(m, dict) and "state_dict" in m else m
    c = count(sd)

    spec = json.load(io.open(args.deploy / "spec.json", encoding="utf-8"))
    w_bytes = int(spec["weight_total_bytes"])
    b_cnt = int(spec["bias_total_count"])
    net = args.net or spec.get("net", "?")

    folded = c["conv_w"] + c["conv_b"]
    norm = c["norm_w"] + c["norm_b"]

    # 对账：导出的权重字节数必须等于折叠后的卷积权重数（INT8 = 1 B/参数）
    ok = (w_bytes == c["conv_w"]) and (b_cnt == c["conv_b"])
    warn = [] if ok else [
        f"⚠ **对不上**：`weights.hex` {w_bytes} B vs ckpt 卷积权重 {c['conv_w']}；"
        f"`biases` {b_cnt} vs ckpt 卷积偏置 {c['conv_b']}。",
        "  说明 ckpt 和 `deploy/` **不是同一次导出的**，先重导再报数。"]

    L = [f"## `{args.tag}` —— {net}", ""]
    L += warn
    L += ["| 口径 | 参数个数 | 字节数 | 相对 500KB(512,000 B) |", "|---|---|---|---|",
          f"| 训练 ckpt 全部（含 InstanceNorm） | {c['total']:,} | {c['total']*4:,} B (FP32) | "
          f"{512000/(c['total']*4):.1f}× 余量 |",
          f"| — 其中 卷积权重 | {c['conv_w']:,} | — | — |",
          f"| — 其中 卷积偏置 | {c['conv_b']:,} | — | — |",
          f"| — 其中 InstanceNorm | {norm:,} | — | **部署时折叠掉，不占硬件** |",
          f"| **折叠后参数量** | **{folded:,}** | **{folded*4:,} B (FP32)** | "
          f"**{512000/(folded*4):.1f}× 余量** |",
          f"| **部署权重（INT8）** | {c['conv_w']:,} | **{w_bytes:,} B ({w_bytes/1024:.1f} KiB)** | "
          f"**{512000/w_bytes:.1f}× 余量** |",
          f"| 部署偏置 | {b_cnt:,} | {b_cnt*4:,} B (int32) | |", ""]
    L += ["> ⚠ **赛题原文只说「参数量小于 500KB」，没说精度、也没说算不算 norm。**",
          "> 上表把三种口径都列出来——**报的时候说清用的是哪个**，别挑最大的那个报。",
          "> 若按常见口径「FP32 的全部参数」，取**折叠后**那一行最稳（norm 已经不存在了）。", ""]

    args.out.write_text("\n".join(L), encoding="utf-8")
    print(f"{args.tag}: 训练态 {c['total']:,} / 折叠后 {folded:,} / INT8 {w_bytes:,} B"
          f"  {'✓ 对账一致' if ok else '✗ 对账不一致'}")
    for w in warn:
        print("  " + w)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
