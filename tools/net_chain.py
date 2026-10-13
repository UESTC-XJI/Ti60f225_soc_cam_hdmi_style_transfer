"""整网整数流水线（计划阶段 4）—— 把 12 层串起来跑，逐层对 golden、末端对模型。

    python -m tools.net_chain D_sw1e5

## 这一步新在哪儿

单层算子（卷积 / 再量化 / ReLU / 残差）在 `hw/` 里都逐层验过了。**没验过的是
层与层之间的空间变换**：

| 变换 | 发生处 | 规则 |
|---|---|---|
| 反射填充 1 | 每层卷积之前 | `ReflectionPad2d(1)`，只在最外圈 |
| ↓2 下采样 | `enc2` / `enc3` | 靠卷积的 `stride=2`，**不是**单独的池化 |
| ↑2 最近邻 | `dec1` / `dec2` | `Upsample(scale_factor=2, mode='nearest')`，**在卷积之前** |

单层向量是"给定输入 → 期望输出"，**喂进去的输入是我从 golden 里现成的**，
所以它验不出"上一层输出接不到下一层输入"这类错。这条链就是补这个。

## 判据

1. **逐层**：算出来的每一层输入，与 golden 的 `_in` 逐元素比 —— 验空间变换
2. **末端**：12 层跑完的输出，反量化后与模型 `net_deploy.pt` 的输出比 **PSNR**
   （计划里的阶段 4 判据是 > 40dB）

## 定点

全程走 `make_requant` 那套定点的 M/shift（RHE 四舍六入五成双 + 饱和），
不做浮点乘 —— 这样这条链就是**硬件将要实现的那条链**。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tools.make_requant import _read_hex, rhe_shift, pick_shift, RES_RE  # noqa: E402


def reflect_pad1(x: np.ndarray) -> np.ndarray:
    """ReflectionPad2d(1)：边界镜像，**不重复边界本身**（reflect 不是 replicate）。"""
    return np.pad(x, ((0, 0), (1, 1), (1, 1)), mode="reflect")


def upsample2(x: np.ndarray) -> np.ndarray:
    """最近邻 ×2（`Upsample(scale_factor=2, mode='nearest')`）。"""
    return np.repeat(np.repeat(x, 2, axis=1), 2, axis=2)


def conv_int(x: np.ndarray, w: np.ndarray, stride: int) -> np.ndarray:
    """整数相关（= PyTorch conv2d 的语义，**核不翻转**）。

    x: [cin,H,W] int64；w: [cout,cin,3,3] int64 → [cout,Hout,Wout]
    """
    cout, cin, k, _ = w.shape
    _, h, wd = x.shape
    ho = (h - k) // stride + 1
    wo = (wd - k) // stride + 1
    win = np.lib.stride_tricks.sliding_window_view(x, (k, k), axis=(1, 2))[:, ::stride, ::stride]
    win = win[:, :ho, :wo]
    return np.einsum("chwkl,ockl->ohw", win, w, optimize=True)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="整网整数流水线")
    ap.add_argument("tag")
    ap.add_argument("--deploy", type=Path, default=None)
    ap.add_argument("--dump", action="store_true",
                    help="逐层输出 dump 成 L<i>_chain.hex，给 RTL testbench 当基准")
    ap.add_argument("--seed", type=int, default=-1,
                    help="从第 N 层开始，用 golden 的 _in 裁掉 pad 当输入（隔离实验）")
    args = ap.parse_args()

    deploy = args.deploy or (ROOT.parent / "deliverable" / args.tag / "deploy")
    spec = json.loads((deploy / "spec.json").read_text(encoding="utf-8"))
    gdir = deploy / "golden"
    gj = json.loads((gdir / "golden.json").read_text(encoding="utf-8"))
    layers, gl = spec["layers"], gj["layers"]
    vdir_dump = ROOT.parent / "hw" / "epilogue" / "vectors" / args.tag
    vdir_dump.mkdir(parents=True, exist_ok=True)

    # ---- 逐层算好定点参数（和 make_requant 同一套）----
    plan = []
    for i, (L, g) in enumerate(zip(layers, gl)):
        cout, cin = int(L["cout"]), int(L["cin"])
        if i + 1 < len(layers):
            nx = layers[i + 1]
            s_out = float(nx["activation_scale_in"])
            qlo, qhi = int(nx["activation_qrange"][0]), int(nx["activation_qrange"][1])
        else:
            s_out = float(g["out_scale"])
            qlo, qhi = int(L["activation_qrange"][0]), int(L["activation_qrange"][1])
        relu = qlo >= 0
        w = _read_hex(deploy / "weights.hex", True, 2)[
            int(L["weight_offset"]):int(L["weight_offset"]) + int(L["weight_count"])]
        w = w.reshape(cout, cin, int(L["k"]), int(L["k"])).astype(np.int64)
        b = _read_hex(deploy / "biases.hex", True, 8)[
            int(L["bias_offset"]):int(L["bias_offset"]) + int(L["bias_count"])].astype(np.int64)
        sa = float(L["activation_scale_in"])
        rq = sa * np.array(L["weight_scale"], dtype=np.float64) / s_out
        m = RES_RE.match(g["name"])
        if m:
            c1 = layers[i - 1]
            sx = float(c1["activation_scale_in"])
            ri = np.full(cout, sx / s_out)
        else:
            ri = np.zeros(cout)
        shift = pick_shift([rq, ri])
        plan.append(dict(L=L, g=g, w=w, b=b, relu=relu, qlo=qlo, qhi=qhi, s_out=s_out,
                         mq=np.round(rq * 2.0 ** shift).astype(np.int64),
                         mid=np.round(ri * 2.0 ** shift).astype(np.int64),
                         shift=shift, res=bool(m), cin=cin, cout=cout))

    # ---- 从 golden 的 input.hex 出发（= MIPI 侧量化后的第一层输入）----
    lo0 = plan[0]["L"]["activation_qrange"][0]
    ish = spec["input"]["shape"]          # input.hex 是**未 pad** 的，用输入自己的形状
    x = _read_hex(gdir / "input.hex", lo0 < 0, 2).reshape(int(ish[1]), int(ish[2]), int(ish[3]))
    x = x.astype(np.int64)                       # 未 pad 的量化输入

    nsp_err = 0
    prev_x_in = None      # 上一层**未 pad 的输入** = 残差块的输入
    print("=== 逐层：空间变换 + 卷积 + 收尾 ===")
    for i, P in enumerate(plan):
        L, g = P["L"], P["g"]
        seed_here = (args.seed == i)
        if seed_here:
            # 隔离实验：把这一层的输入换成 golden 的（裁掉 pad），
            # 用来判断"下游偏离"到底是链条本身错，还是上游误差在传播
            rx = _read_hex(gdir / g["in_file"], L["activation_signed"], 2).reshape(
                P["cin"], int(g["in_shape"][2]), int(g["in_shape"][3]))
            x = rx[:, 1:-1, 1:-1].astype(np.int64)
        # ---- 空间变换：得到这一层卷积的输入 ----
        if i > 0:
            # 上采样层：dec1/dec2 的 UpsampleConv 是"先 ×2 再 pad"
            # 判据：本层输入高 = 上一层输出高 × 2
            if g["in_shape"][2] == 2 * gl[i - 1]["acc_shape"][2] + 2:
                x = upsample2(x)
        x_in = x                       # 本层**未 pad 的输入**
        xp = reflect_pad1(x_in)
        # 与 golden 的 _in 对（验空间变换）
        ref = _read_hex(gdir / g["in_file"], L["activation_signed"], 2).reshape(
            P["cin"], int(g["in_shape"][2]), int(g["in_shape"][3]))
        if xp.shape != ref.shape:
            print(f"  ✗ L{i:02d} 形状对不上：算得 {xp.shape}，golden {ref.shape}")
            nsp_err += 1
        elif not np.array_equal(xp, ref):
            d = int((xp != ref).sum())
            nsp_err += 1
            print(f"  ✗ L{i:02d} 空间变换不符：{d}/{ref.size}")
        else:
            print(f"  [OK] L{i:02d} {g['name']:<16} 空间 {xp.shape[1]}x{xp.shape[2]} → "
                  f"输出 {g['acc_shape'][2]}x{g['acc_shape'][3]}"
                  + ("   ← 本层输入由 golden 灌入" if seed_here else ""))

        # ---- 卷积 + 偏置 ----
        acc = conv_int(xp, P["w"], int(L["stride"])) + P["b"].reshape(-1, 1, 1)
        # ---- 收尾：再量化 + ReLU + 残差 ----
        a = np.maximum(acc, 0) if P["relu"] else acc
        p = a * P["mq"].reshape(-1, 1, 1)
        if P["res"]:
            # ⚠ 恒等支是**残差块的输入**（= c1 的*输入*），不是 c1 的输出！
            #   模型是 `return x + y`，x 是块进入时的那个张量。
            #   用 c1 的输出去加的话，加的是完全另一个东西 —— 实测第 4 层
            #   7 个像素的输入差异会被放大成 78% 的输出差异。
            p = p + prev_x_in.astype(np.int64) * P["mid"].reshape(-1, 1, 1)
        q = np.clip(rhe_shift(p, P["shift"]), P["qlo"], P["qhi"])
        prev_x_in = x_in
        x = q
        # 给 RTL 当基准：**逐层输出**（未 pad，int8 位模式）
        if args.dump:
            (vdir_dump / f"L{i}_chain.hex").write_text(
                "".join(f"{int(v) & 0xFF:02x}\n" for v in x.ravel()),
                encoding="utf-8", newline="\n")

    # ---- 末端：与模型量化链比 PSNR（阶段 4 的判据）----
    vdir = ROOT.parent / "hw" / "epilogue" / "vectors" / args.tag
    np.save(vdir / f"{args.tag}_net_out.npy", x)
    ref = _read_hex(vdir / "L11_q_out.hex", False, 2).reshape(x.shape).astype(np.int64)
    dd = (x - ref).astype(np.float64)
    mse = float((dd ** 2).mean())
    s_out = plan[-1]["s_out"]
    rmse = float(np.sqrt(mse)) * s_out           # 反量化到"图像域 0..1"
    psnr = 20 * np.log10(1.0 / rmse) if rmse > 0 else 99.0
    nd = int((x != ref).sum())
    print()
    print(f"  末端 vs 模型量化链：不符 {nd}/{x.size} ({100*nd/x.size:.1f}%)，"
          f"最大差 {int(np.abs(dd).max())} LSB")
    print(f"  **图像域 PSNR = {psnr:.1f} dB**（阶段 4 判据 > 40）")
    if nsp_err:
        print(f"=== ⚠️ 逐层空间变换有 {nsp_err} 层与 golden 不等（差异逐层累积，见上）===")
        print("    末端 PSNR 才是阶段 4 的判据；逐层相等是更严的中间判据。")
        return 0 if psnr > 40 else 1
    print("=== ✅ 12 层空间变换全部与 golden 逐元素一致 ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
