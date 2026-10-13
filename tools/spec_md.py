"""把 `deploy/spec.json` 渲染成 markdown。**给交付包生成层表用。**

    python -m tools.spec_md runs/final/D_wc_g15/deploy/spec.json -o 某处.md

## 为什么要生成而不是手抄

交接物里的层序/偏移/scale 全部由 `train/export.py` 写进 `spec.json`，
手抄进文档**必然会漂**（重导一次就过期）。这边只做渲染，一个数都不自己算。

⚠ 控制台在 Windows 上是 GBK，中文会乱码——所以这个工具**写文件**，不打印表格。
"""

from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path


def render(spec: dict) -> str:
    net = spec.get("net", "?")
    inp = spec.get("input", {})
    L = [f"# `{spec.get('tag', '?')}` —— {net}", "",
         "> 本文件由 `tools/spec_md.py` 从 `spec.json` 生成，**别手改**。", ""]

    L += ["## 输入 / 输出", "",
          f"- 输入形状 `{inp.get('shape')}`，通道数 **{inp.get('channels')}**",
          f"- 说明：{inp.get('note', '')}", ""]

    L += ["## 量化", ""]
    q = spec.get("quant", {})
    for k, v in q.items():
        L.append(f"- **{k}**：{v}")
    L += ["", f"- 权重总字节 **{spec.get('weight_total_bytes')} B**，"
              f"偏置 **{spec.get('bias_total_count')}** 个 int32", ""]

    if spec.get("constraint"):
        L += [f"> ⚠ **约束**：{spec['constraint']}", ""]

    L += ["## 层表", "",
          "| # | 层 | k | stride | cin | cout | 权重(B) | 累加器最坏 | 位宽 |",
          "|---|---|---|---|---|---|---|---|---|"]
    for i, ly in enumerate(spec.get("layers", [])):
        L.append(f"| {i} | `{ly['name']}` | {ly['k']} | {ly['stride']} | {ly['cin']} | "
                 f"{ly['cout']} | {ly['weight_count']} | {ly.get('int32_worst', '?')} | "
                 f"{ly.get('int32_bits', '?')} |")
    L += ["", "「累加器最坏」= 该层在 golden 输入下 int32 累加器的最大绝对值，"
              "「位宽」= 它需要几位。**都 < 31 就说明 int32 不会溢出。**", ""]

    L += ["## 权重 / 偏置布局", ""]
    if spec.get("layers"):
        L += [f"- `weight_layout`：`{spec['layers'][0]['weight_layout']}`",
              f"- `bias_quant`：`{spec['layers'][0]['bias_quant']}`"]
    L += ["- ⚠ `weights.hex`（int8）与 `biases.hex`（int32）是**两个文件**，"
          "各自有独立偏移；层记录里的 `weight_offset` / `bias_offset` 是**各自文件内**的偏移。", ""]

    L += ["## 每层的 scale", "",
          "| # | 层 | weight_scale | activation_scale_in | 激活范围 |",
          "|---|---|---|---|---|"]
    for i, ly in enumerate(spec.get("layers", [])):
        ws = ly.get("weight_scale")
        if isinstance(ws, list):
            ws = f"{ws[0]:.6g}" + (f"（{len(ws)} 个，逐通道同值）" if len(set(ws)) == 1 else
                                   f"（{len(ws)} 个，**逐通道不同**）")
        else:
            ws = f"{ws:.6g}" if isinstance(ws, float) else str(ws)
        L.append(f"| {i} | `{ly['name']}` | {ws} | {ly.get('activation_scale_in', '?')} | "
                 f"{ly.get('activation_qrange', '?')} |")
    L.append("")
    return "\n".join(L)


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="spec.json -> markdown（写文件，不打印表格）")
    ap.add_argument("spec", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    args = ap.parse_args()

    spec = json.load(io.open(args.spec, encoding="utf-8"))
    args.out.write_text(render(spec), encoding="utf-8")
    print(f"{args.spec} -> {args.out}（{len(spec.get('layers', []))} 层）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
