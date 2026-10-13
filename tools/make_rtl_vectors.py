"""把 `deploy/golden/` 的逐层向量翻成 RTL testbench 能 `$readmemh` 的格式。

    python -m tools.make_rtl_vectors D_sw1e5 -o ../hw/conv3x3/vectors/D_sw1e5

## 为什么要转

golden 的 `*_in.hex` / `*_acc.hex` 是给**人看和 Python 用的**（check_deploy.py 直接读），
尺寸信息在 `golden.json` 里、权重在 `weights.hex` 里、偏置在 `biases.hex` 里。
RTL 侧 `$readmemh` 一次只能吃一个文件且**位宽必须一致**，所以这里把一层要的东西
按定长头 + 定序拼好：

| 文件 | 位宽 | 内容 |
|---|---|---|
| `<L>.mem` | 8 位 | 8 个头部字 + 权重（cout·cin·9）+ 输入（cin·hin·win） |
| `<L>.acc` | 32 位 | 偏置（cout）+ 期望累加器（cout·hout·wout） |

头部 8 个字：`cin cout hin win hout wout stride in_signed`。

## 两个位宽陷阱

1. **权重和输入是 8 位，偏置和累加器是 32 位，不能混在一个文件里**——
   `$readmemh` 按数组元素宽度解析。所以拆成两个。
2. **输入的符号性逐层不同**：ReLU 之后的层是 uint8（0~255），残差相加之后的层是
   有符号（-127~127）。存的是**原始位模式**，符号性通过头部的 `in_signed` 告诉 RTL。
   写死成 int8 的话，`200` 会被当成 `-56`，乘出来的东西完全不对**而且不会报错**。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent


def _read_hex(path: Path, signed_bytes: bool, width: int) -> np.ndarray:
    """与 `tools/check_deploy.py::read_hex` 同构（这里不 import 它，免得绑在一起）。"""
    vals = [int(line, 16) for line in path.read_text(encoding="utf-8").split() if line]
    a = np.array(vals, dtype=np.int64)
    if width == 2:
        a = a & 0xFF
        return np.where(a >= 128, a - 256, a) if signed_bytes else a
    a = a & 0xFFFFFFFF
    return np.where(a >= 2 ** 31, a - 2 ** 32, a)


def _b8(vals: np.ndarray) -> str:
    return "".join(f"{int(v) & 0xFF:02x}\n" for v in vals.ravel())


def _b32(vals: np.ndarray) -> str:
    return "".join(f"{int(v) & 0xFFFFFFFF:08x}\n" for v in vals.ravel())


def export_layer(spec: dict, gj: dict, gdir: Path, deploy: Path, i: int,
                 outdir: Path) -> dict:
    L = spec["layers"][i]
    g = gj["layers"][i]
    cin, cout = int(L["cin"]), int(L["cout"])
    k = int(L["k"])
    stride = int(L["stride"])
    in_signed = bool(L["activation_signed"])

    # 输入是**该次卷积的输入**（已含 ReflectionPad），形状 [1,cin,hin,win]
    hin, win = int(g["in_shape"][2]), int(g["in_shape"][3])
    hout, wout = int(g["acc_shape"][2]), int(g["acc_shape"][3])
    q_in = _read_hex(gdir / g["in_file"], in_signed, 2).reshape(cin, hin, win)

    w_all = _read_hex(deploy / "weights.hex", True, 2)
    b_all = _read_hex(deploy / "biases.hex", True, 8)
    off, cnt = int(L["weight_offset"]), int(L["weight_count"])
    w = w_all[off:off + cnt].reshape(cout, cin, k, k)
    bo, bc = int(L["bias_offset"]), int(L["bias_count"])
    b = b_all[bo:bo + bc]

    acc = _read_hex(gdir / g["acc_file"], True, 8).reshape(cout, hout, wout)

    # ---- 无符号层做 -128 偏移，好让 tap 能塞进 8x8 乘法器 ----
    #
    # 为什么：成本模型要 256 MAC 只吃 128 个 DSP（`INT8_MAC_PER_DSP = 2`），
    # 而 DUAL 模式的 8x8 子乘法器**要求两个操作数都是 8 位有符号**。
    # ReLU 层的激活是 uint8（0~255），当有符号用要 9 位，塞不进 8x8。
    #
    # 做法：t' = t - 128 ∈ [-128,127]，正好是 int8。位模式上就是 `t ^ 0x80`，
    # 硬件一个 XOR。展开：
    #       Σ t·w = Σ (t'+128)·w = Σ t'·w + 128·Σw
    # 后一项是**逐输出通道的常数**，折进偏置即可 —— 数学上精确等价，没有近似。
    #
    # 有符号层（残差相加之后）本来就是 int8，不动，修正项为 0。
    tap_offset = 0 if in_signed else 1
    if tap_offset:
        taps_out = ((q_in.astype(np.int64) - 128) & 0xFF).astype(np.uint8)
        corr = 128 * w.astype(np.int64).sum(axis=(1, 2, 3))
    else:
        taps_out = (q_in.astype(np.int64) & 0xFF).astype(np.uint8)
        corr = np.zeros(cout, dtype=np.int64)
    b_corr = b + corr

    hdr = np.array([cin, cout, hin, win, hout, wout, stride, tap_offset])
    (outdir / f"L{i}.mem").write_text(
        _b8(hdr) + _b8(w) + _b8(taps_out), encoding="utf-8", newline="\n")
    # ⚠ 偏置写的是**修正后**的 b'。期望累加器仍然是原来那个，没动。
    (outdir / f"L{i}.acc").write_text(
        _b32(b_corr) + _b32(acc), encoding="utf-8", newline="\n")

    return dict(idx=i, name=g["name"], cin=cin, cout=cout, k=k, stride=stride,
                hin=hin, win=win, hout=hout, wout=wout, in_signed=in_signed,
                tap_offset=tap_offset, bias_corr=int(corr.max()) if cout else 0,
                mem_words=8 + w.size + q_in.size, acc_words=b.size + acc.size)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="golden -> RTL 向量")
    ap.add_argument("tag", help="网络 tag，如 D_sw1e5")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--deploy", type=Path, default=None,
                    help="deploy 目录，默认 ../deliverable/<tag>/deploy")
    args = ap.parse_args()

    deploy = args.deploy or (ROOT.parent / "deliverable" / args.tag / "deploy")
    spec = json.loads((deploy / "spec.json").read_text(encoding="utf-8"))
    gdir = deploy / "golden"
    gj = json.loads((gdir / "golden.json").read_text(encoding="utf-8"))

    outdir = args.out
    outdir.mkdir(parents=True, exist_ok=True)
    for pat in ("L*.mem", "L*.acc"):        # glob 返回生成器，不能直接并集
        for f in outdir.glob(pat):
            f.unlink()

    info = [export_layer(spec, gj, gdir, deploy, i, outdir)
            for i in range(len(spec["layers"]))]

    # 反射填充的对照向量：input.hex（未 pad）-> L00_in.hex（已 pad）
    from_array = _read_hex(gdir / "input.hex", spec["layers"][0]["activation_signed"], 2)
    to_array = _read_hex(gdir / gj["layers"][0]["in_file"],
                         spec["layers"][0]["activation_signed"], 2)
    (outdir / "pad.in").write_text(_b8(from_array), encoding="utf-8", newline="\n")
    (outdir / "pad.out").write_text(_b8(to_array), encoding="utf-8", newline="\n")

    max_mem = max(x["mem_words"] for x in info)
    max_acc = max(x["acc_words"] for x in info)
    (outdir / "layers.json").write_text(json.dumps(
        {"tag": args.tag, "net": spec["net"], "n_layers": len(info),
         "max_mem_words": max_mem, "max_acc_words": max_acc,
         "pad_in_len": int(from_array.size), "pad_out_len": int(to_array.size),
         "layers": info}, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"{outdir}: {len(info)} 层")
    print(f"  最大 mem {max_mem} 字 / acc {max_acc} 字")
    print(f"  反射填充对照：{from_array.size} -> {to_array.size}")
    for x in info:
        print(f"  L{x['idx']:02d} {x['name']:<16} {x['cin']:>2}->{x['cout']:<2} "
              f"k{x['k']}s{x['stride']}  in {x['hin']}x{x['win']} -> {x['hout']}x{x['wout']}"
              f"{'  有符号' if x['in_signed'] else ''}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
